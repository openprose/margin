import Darwin
import Dispatch
import Foundation
import MarginCore

struct CommentWatchFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct CommentWatchState: Codable, Equatable, Sendable {
    let documentID: String?
    let protocolVersion: Int?
    let revision: Int
    let contentSha256: String
    let commentsSha256: String
    let annotationCount: Int
    let fileIdentity: CommentWatchFileIdentity
}

struct CommentWatchChanges: Codable, Equatable, Sendable {
    let fileReplaced: Bool
    let documentIdentityChanged: Bool
    let protocolVersionChanged: Bool
    let revisionChanged: Bool
    let contentChanged: Bool
    let commentsChanged: Bool
    let annotationCountChanged: Bool
}

struct CommentWatchFailure: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let recoverable: Bool
}

struct CommentWatchEvent: Encodable, Sendable {
    let schema = "urn:margin:comments-watch:v1"
    let sequence: Int
    let event: String
    let file: String
    let timestamp: String
    let sinceRevision: Int?
    let changeFromSince: ReviewChange?
    let previous: CommentWatchState?
    let current: CommentWatchState?
    let changes: CommentWatchChanges?
    let error: CommentWatchFailure?
}

final class CommentWatchSession {
    typealias Emitter = (CommentWatchEvent) -> Void

    private let file: URL
    private let codec: EmbeddedCommentCodec
    private let queue = DispatchQueue(label: "dev.margin.cli.comments-watch", qos: .utility)
    private let stopped = DispatchSemaphore(value: 0)
    private var source: DispatchSourceFileSystemObject?
    private var pendingRead: DispatchWorkItem?
    private var emitter: Emitter?
    private var state: CommentWatchState?
    private var sinceRevision: Int?
    private var sequence = 0
    private var unavailable = false
    private var lastErrorSignature: String?
    private var didStop = false

    init(file: URL, codec: EmbeddedCommentCodec = EmbeddedCommentCodec()) {
        self.file = file.standardizedFileURL
        self.codec = codec
    }

    func start(sinceRevision: Int?, emit: @escaping Emitter) throws {
        guard source == nil else {
            throw CLIError("WATCH_ALREADY_STARTED", "The comment watcher is already running.", exit: .software)
        }
        let directory = file.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CLIError(
                "WATCH_FAILED",
                "Could not watch \(directory.path): \(String(cString: strerror(errno))).",
                exit: .io
            )
        }

        self.emitter = emit
        self.state = nil
        self.sinceRevision = sinceRevision
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleRead() }
        source.setCancelHandler { _ = Darwin.close(descriptor) }
        self.source = source
        source.resume()

        // Register the directory source before taking the first snapshot. The
        // serial queue ensures any event observed during this read is handled
        // only after the snapshot has been published, closing the startup gap.
        do {
            try queue.sync {
                let initial = try captureState()
                state = initial
                let relation = relation(from: sinceRevision, to: initial.revision)
                emit(makeEvent(
                    event: relation == .notModified ? "ready" : "snapshot",
                    changeFromSince: relation,
                    current: initial
                ))
            }
        } catch {
            source.cancel()
            self.source = nil
            self.emitter = nil
            throw error
        }
    }

    func run(sinceRevision: Int?, emit: @escaping Emitter) throws {
        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousTerminate = signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        interrupt.setEventHandler { [weak self] in self?.stop() }
        terminate.setEventHandler { [weak self] in self?.stop() }
        interrupt.resume()
        terminate.resume()
        defer {
            interrupt.cancel()
            terminate.cancel()
            _ = signal(SIGINT, previousInterrupt)
            _ = signal(SIGTERM, previousTerminate)
        }

        try start(sinceRevision: sinceRevision, emit: emit)
        stopped.wait()
    }

    func stop() {
        queue.async { [weak self] in self?.finish() }
    }

    private func scheduleRead() {
        pendingRead?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readChange() }
        pendingRead = work
        queue.asyncAfter(deadline: .now() + .milliseconds(60), execute: work)
    }

    private func readChange() {
        guard !didStop else { return }
        do {
            let next = try captureState()
            lastErrorSignature = nil
            guard let previous = state else {
                state = next
                emit(makeEvent(event: "reconnected", current: next))
                unavailable = false
                return
            }
            let changes = CommentWatchChanges(
                fileReplaced: previous.fileIdentity != next.fileIdentity,
                documentIdentityChanged: previous.documentID != next.documentID,
                protocolVersionChanged: previous.protocolVersion != next.protocolVersion,
                revisionChanged: previous.revision != next.revision,
                contentChanged: previous.contentSha256 != next.contentSha256,
                commentsChanged: previous.commentsSha256 != next.commentsSha256,
                annotationCountChanged: previous.annotationCount != next.annotationCount
            )
            guard changes.fileReplaced || changes.documentIdentityChanged || changes.protocolVersionChanged || changes.revisionChanged ||
                    changes.contentChanged || changes.commentsChanged || changes.annotationCountChanged else {
                unavailable = false
                return
            }
            state = next
            let event = unavailable ? "reconnected" : "change"
            unavailable = false
            emit(makeEvent(event: event, previous: previous, current: next, changes: changes))
        } catch {
            unavailable = true
            let failure = watchFailure(error)
            let signature = "\(failure.code):\(failure.message)"
            guard signature != lastErrorSignature else { return }
            lastErrorSignature = signature
            emit(makeEvent(event: "error", current: state, error: failure))
        }
    }

    private func finish() {
        guard !didStop else { return }
        didStop = true
        pendingRead?.cancel()
        pendingRead = nil
        emit(makeEvent(event: "stopped", current: state))
        source?.cancel()
        source = nil
        stopped.signal()
    }

    private func captureState() throws -> CommentWatchState {
        // A replacement can race a read. Two bounded attempts avoid publishing
        // bytes from one inode with the identity of another without polling.
        for attempt in 0..<2 {
            let before = try fileIdentity()
            let data: Data
            do {
                data = try Data(contentsOf: file, options: .mappedIfSafe)
            } catch {
                throw CommentProtocolError.io("Could not read '\(file.path)': \(error.localizedDescription)")
            }
            let after = try fileIdentity()
            if before != after {
                if attempt == 0 { continue }
                throw CommentProtocolError.concurrentModification
            }
            let decoded = try codec.decode(data)
            let envelope = decoded.envelope
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let commentsData = try encoder.encode(envelope?.items ?? [])
            return CommentWatchState(
                documentID: envelope?.document.id,
                protocolVersion: envelope?.version,
                revision: envelope?.revision ?? 0,
                contentSha256: EmbeddedCommentCodec.contentHash(decoded.bodyData),
                commentsSha256: "sha256:\(DocumentRevision(data: commentsData).sha256)",
                annotationCount: envelope?.items.count ?? 0,
                fileIdentity: after
            )
        }
        throw CommentProtocolError.concurrentModification
    }

    private func fileIdentity() throws -> CommentWatchFileIdentity {
        var information = stat()
        guard lstat(file.path, &information) == 0 else {
            throw CommentProtocolError.io(
                "Could not inspect '\(file.path)': \(String(cString: strerror(errno)))."
            )
        }
        return CommentWatchFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private func relation(from sinceRevision: Int?, to revision: Int) -> ReviewChange {
        guard let sinceRevision else { return .snapshot }
        if sinceRevision == revision { return .notModified }
        return sinceRevision < revision ? .advanced : .reset
    }

    private func makeEvent(
        event: String,
        changeFromSince: ReviewChange? = nil,
        previous: CommentWatchState? = nil,
        current: CommentWatchState? = nil,
        changes: CommentWatchChanges? = nil,
        error: CommentWatchFailure? = nil
    ) -> CommentWatchEvent {
        defer { sequence += 1 }
        return CommentWatchEvent(
            sequence: sequence,
            event: event,
            file: file.path,
            timestamp: Self.timestamp(),
            sinceRevision: sinceRevision,
            changeFromSince: changeFromSince,
            previous: previous,
            current: current,
            changes: changes,
            error: error
        )
    }

    private func emit(_ event: CommentWatchEvent) {
        emitter?(event)
    }

    private func watchFailure(_ error: Error) -> CommentWatchFailure {
        if let protocolError = error as? CommentProtocolError {
            return CommentWatchFailure(
                code: protocolError.code,
                message: protocolError.localizedDescription,
                recoverable: true
            )
        }
        return CommentWatchFailure(
            code: "WATCH_READ_FAILED",
            message: error.localizedDescription,
            recoverable: true
        )
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
