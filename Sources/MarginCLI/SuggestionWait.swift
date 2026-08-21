import Dispatch
import Foundation
import MarginCore

#if canImport(Darwin)
import Darwin
#endif

struct SuggestionWaitMatch: Encodable, Sendable {
    let id: String
    let status: String
}

struct SuggestionWaitResult: Encodable, Sendable {
    let complete: Bool
    let expectedCount: Int
    let matchedCount: Int
    let matched: [SuggestionWaitMatch]
    let omittedMatchedCount: Int
    let missingIDs: [String]
    let revision: Int
    let contentSha256: String
    let elapsedMilliseconds: Int
}

/// A bounded, explicitly invoked wait for durable suggestion identifiers.
///
/// This is intentionally not a presence service. Success means only that every
/// requested suggestion is embedded in this Markdown file at one observed
/// revision. No daemon, directory crawl, network request, or startup work is
/// involved.
final class SuggestionWaitSession {
    static let maximumExpectedIDs = 256
    static let maximumExpectedIDBytes = 512
    static let maximumReportedMatches = 64
    static let maximumTimeoutSeconds = 120

    private let file: URL
    private let codec: EmbeddedCommentCodec

    init(file: URL, codec: EmbeddedCommentCodec = EmbeddedCommentCodec()) {
        self.file = file.standardizedFileURL
        self.codec = codec
    }

    func wait(expectedIDs rawIDs: [String], timeoutSeconds: Int) throws -> SuggestionWaitResult {
        guard !rawIDs.isEmpty, rawIDs.count <= Self.maximumExpectedIDs else {
            throw CLIError.usage(
                "suggest wait requires 1 to \(Self.maximumExpectedIDs) suggestion ids."
            )
        }
        guard (0...Self.maximumTimeoutSeconds).contains(timeoutSeconds) else {
            throw CLIError.usage(
                "--timeout must be between 0 and \(Self.maximumTimeoutSeconds) seconds."
            )
        }
        guard rawIDs.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= Self.maximumExpectedIDBytes
                && !$0.hasPrefix("-")
        }) else {
            throw CLIError.usage(
                "Every expected suggestion id must be nonempty, at most \(Self.maximumExpectedIDBytes) UTF-8 bytes, and not option-like."
            )
        }
        let expectedIDs = rawIDs.map(MarginID.annotation).sorted()
        guard Set(expectedIDs).count == expectedIDs.count else {
            throw CLIError.usage("Expected suggestion ids must be distinct.")
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
        let deadline = started > UInt64.max - timeoutNanoseconds
            ? UInt64.max
            : started + timeoutNanoseconds
        let changed = DispatchSemaphore(value: 0)

#if canImport(Darwin)
        // Register the parent-directory source before the initial snapshot, so
        // an atomic replacement between the first read and the first wait cannot
        // be lost. The process owns no watcher until this command is invoked.
        let directory = file.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CLIError(
                "SUGGESTION_WAIT_FAILED",
                "Could not watch \(directory.path): \(String(cString: strerror(errno))).",
                exit: .io
            )
        }
        let queue = DispatchQueue(label: "dev.margin.cli.suggestion-wait", qos: .utility)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { changed.signal() }
        source.setCancelHandler { _ = Darwin.close(descriptor) }
        source.resume()
        defer { source.cancel() }
#endif

        while true {
            let result = try capture(expectedIDs: expectedIDs, started: started)
            if result.complete { return result }

            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return result }
            let recheckInterval: UInt64
#if canImport(Darwin)
            // The periodic bound is only a lost/coalesced-event safety net.
            recheckInterval = 1_000_000_000
#else
            // Dispatch vnode sources are Darwin-only. This process is already
            // an explicitly requested wait, so a 100 ms portable fallback does
            // not create background work or affect ordinary CLI startup.
            recheckInterval = 100_000_000
#endif
            let next = min(deadline, now > UInt64.max - recheckInterval
                ? UInt64.max
                : now + recheckInterval)
            _ = changed.wait(timeout: DispatchTime(uptimeNanoseconds: next))
        }
    }

    private func capture(
        expectedIDs: [String],
        started: UInt64
    ) throws -> SuggestionWaitResult {
        let data: Data
        do {
            data = try Data(contentsOf: file, options: .mappedIfSafe)
        } catch {
            throw CLIError(
                "SUGGESTION_WAIT_READ_FAILED",
                "Could not read '\(file.path)': \(error.localizedDescription)",
                exit: .io
            )
        }
        let document = try codec.decode(data)
        let revision = document.envelope?.revision ?? 0
        var suggestions: [String: SuggestionWaitMatch] = [:]
        for annotation in document.envelope?.items ?? [] {
            guard case .string(let kind)? = annotation.extensions["margin:kind"],
                  kind == CollaborationContributionKind.suggestion.rawValue,
                  case .object(let details)? = annotation.extensions["margin:suggestion"],
                  case .string(let status)? = details["status"] else {
                continue
            }
            suggestions[annotation.id] = SuggestionWaitMatch(
                id: annotation.id,
                status: status
            )
        }
        let allMatched = expectedIDs.compactMap { suggestions[$0] }
        let matched = Array(allMatched.prefix(Self.maximumReportedMatches))
        let missing = expectedIDs.filter { suggestions[$0] == nil }
        return SuggestionWaitResult(
            complete: missing.isEmpty,
            expectedCount: expectedIDs.count,
            matchedCount: allMatched.count,
            matched: matched,
            omittedMatchedCount: allMatched.count - matched.count,
            missingIDs: missing,
            revision: revision,
            contentSha256: EmbeddedCommentCodec.contentHash(document.bodyData),
            elapsedMilliseconds: Self.elapsedMilliseconds(since: started)
        )
    }

    private static func elapsedMilliseconds(since started: UInt64) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= started ? now - started : 0
        return Int(min(elapsed / 1_000_000, UInt64(Int.max)))
    }
}
