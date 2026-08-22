import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct AtomicDocumentMutation<Result> {
    public var data: Data
    public var result: Result

    public init(data: Data, result: Result) {
        self.data = data
        self.result = result
    }
}

public struct AtomicDocumentStore: Sendable {
    public var lockTimeout: TimeInterval
    public var retryLimit: Int
    private let beforeReplaceForTesting: (@Sendable () -> Void)?

    public init(lockTimeout: TimeInterval = 5, retryLimit: Int = 3) {
        self.lockTimeout = max(0, lockTimeout)
        self.retryLimit = max(0, retryLimit)
        beforeReplaceForTesting = nil
    }

    init(
        lockTimeout: TimeInterval = 5,
        retryLimit: Int = 3,
        beforeReplaceForTesting: @escaping @Sendable () -> Void
    ) {
        self.lockTimeout = max(0, lockTimeout)
        self.retryLimit = max(0, retryLimit)
        self.beforeReplaceForTesting = beforeReplaceForTesting
    }

    public func read(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: canonicalURL(url), options: .mappedIfSafe)
        } catch {
            throw CommentProtocolError.io("Could not read '\(url.path)': \(error.localizedDescription)")
        }
    }

    /// Serializes all Margin writers for a path and replaces the document atomically.
    /// The transform can be invoked again if a non-Margin writer races the first attempt.
    public func transaction<Result>(
        at url: URL,
        _ transform: (Data) throws -> AtomicDocumentMutation<Result>
    ) throws -> Result {
        try transaction(at: url, maximumBytes: nil, transform)
    }

    /// The bounded form prevents a structured sidecar from reaching its
    /// decoder after it grows beyond the caller's hard artifact ceiling.
    public func transaction<Result>(
        at url: URL,
        maximumBytes: Int?,
        _ transform: (Data) throws -> AtomicDocumentMutation<Result>
    ) throws -> Result {
        try transaction(
            at: url,
            maximumBytes: maximumBytes,
            rejectSymbolicLinks: false,
            transform
        )
    }

    /// Strict comparison persistence never resolves or follows the final path.
    /// It is internal because ordinary document editing historically permits
    /// symlink-backed files, while comparison apply/review explicitly does not.
    func transaction<Result>(
        at url: URL,
        maximumBytes: Int?,
        rejectSymbolicLinks: Bool,
        _ transform: (Data) throws -> AtomicDocumentMutation<Result>
    ) throws -> Result {
        // `URL.standardizedFileURL` resolves symbolic links in swift-corelibs
        // Foundation. Strict comparison writes must retain the caller's final
        // path component so `lstat`/`O_NOFOLLOW` can reject it on every
        // supported platform.
        let documentURL = rejectSymbolicLinks ? url : canonicalURL(url)
        let lockIdentityURL = rejectSymbolicLinks
            ? strictLockIdentityURL(documentURL)
            : documentURL
        let lockDescriptor = try acquireLock(for: lockIdentityURL)
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = close(lockDescriptor)
        }

        var attempt = 0
        while true {
            let original: Data
            if rejectSymbolicLinks {
                original = try ComparisonRegularFile.read(
                    at: documentURL,
                    maximumBytes: maximumBytes ?? Int.max
                )
            } else {
                do {
                    original = try Data(contentsOf: documentURL)
                } catch {
                    throw CommentProtocolError.io(
                        "Could not read '\(documentURL.path)': \(error.localizedDescription)"
                    )
                }
            }
            if let maximumBytes, original.count > max(0, maximumBytes) {
                throw CommentProtocolError.io(
                    "Document exceeds the transaction byte limit of \(max(0, maximumBytes))."
                )
            }
            let mutation = try transform(original)
            if mutation.data == original { return mutation.result }
            beforeReplaceForTesting?()
            do {
                try atomicReplace(
                    documentURL,
                    expected: original,
                    with: mutation.data,
                    rejectSymbolicLinks: rejectSymbolicLinks,
                    maximumBytes: maximumBytes
                )
                return mutation.result
            } catch CommentProtocolError.concurrentModification where attempt < retryLimit {
                attempt += 1
                continue
            }
        }
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Parent aliases must converge on one writer lock, while the final
    /// component remains literal for every strict `lstat`/`O_NOFOLLOW` read.
    private func strictLockIdentityURL(_ url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent, isDirectory: false)
    }

    private func acquireLock(for documentURL: URL) throws -> Int32 {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let lockDirectory = cacheRoot
            .appendingPathComponent("Margin", isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)
        do {
            try fileManager.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        } catch {
            throw CommentProtocolError.io("Could not create Margin's lock directory: \(error.localizedDescription)")
        }

        let digest = MarginSHA256.hexDigest(of: Data(documentURL.path.utf8))
        let lockURL = lockDirectory.appendingPathComponent("\(digest).lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CommentProtocolError.io(
                "Could not open Margin's lock file: \(String(cString: strerror(errno)))."
            )
        }

        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            if lockError != EWOULDBLOCK && lockError != EAGAIN {
                _ = close(descriptor)
                throw CommentProtocolError.io(
                    "Could not lock the document: \(String(cString: strerror(lockError)))."
                )
            }
            if Date() >= deadline {
                _ = close(descriptor)
                throw CommentProtocolError.lockTimeout
            }
            usleep(10_000)
        }
        return descriptor
    }

    private func atomicReplace(
        _ url: URL,
        expected: Data,
        with replacement: Data,
        rejectSymbolicLinks: Bool,
        maximumBytes: Int?
    ) throws {
        let fileManager = FileManager.default
        let beforeWrite: Data
        if rejectSymbolicLinks {
            beforeWrite = try ComparisonRegularFile.read(
                at: url,
                maximumBytes: maximumBytes ?? Int.max
            )
        } else {
            do {
                beforeWrite = try Data(contentsOf: url)
            } catch {
                throw CommentProtocolError.io("Could not re-read '\(url.path)': \(error.localizedDescription)")
            }
        }
        guard beforeWrite == expected else { throw CommentProtocolError.concurrentModification }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".margin.\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var temporaryExists = false
        defer {
            if temporaryExists { try? fileManager.removeItem(at: temporaryURL) }
        }

        do {
            try fileManager.copyItem(at: url, to: temporaryURL)
            temporaryExists = true
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: replacement)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            throw CommentProtocolError.io(
                "Could not prepare the atomic document write: \(error.localizedDescription)"
            )
        }

        let immediatelyBeforeRename: Data
        if rejectSymbolicLinks {
            immediatelyBeforeRename = try ComparisonRegularFile.read(
                at: url,
                maximumBytes: maximumBytes ?? Int.max
            )
        } else {
            do {
                immediatelyBeforeRename = try Data(contentsOf: url)
            } catch {
                throw CommentProtocolError.io("Could not verify '\(url.path)': \(error.localizedDescription)")
            }
        }
        guard immediatelyBeforeRename == expected else {
            throw CommentProtocolError.concurrentModification
        }

        guard rename(temporaryURL.path, url.path) == 0 else {
            let renameError = errno
            throw CommentProtocolError.io(
                "Could not replace '\(url.path)': \(String(cString: strerror(renameError)))."
            )
        }
        temporaryExists = false

        let directoryDescriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            _ = close(directoryDescriptor)
        }
    }
}
