import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ComparisonReviewMutationReceipt: Codable, Hashable, Sendable {
    public let review: ComparisonReview
    public let previousRevision: Int
    public let revision: Int
    public let changed: Bool

    public init(
        review: ComparisonReview,
        previousRevision: Int,
        revision: Int,
        changed: Bool
    ) {
        self.review = review
        self.previousRevision = previousRevision
        self.revision = revision
        self.changed = changed
    }
}

/// Atomic comparison-review persistence with optimistic revision checks.
/// Snapshot replacement is unavailable through ordinary mutation and requires
/// the explicit `refresh` entry point.
public struct ComparisonReviewStore: Sendable {
    public var documentStore: AtomicDocumentStore
    public var limits: ComparisonLimits

    public init(
        documentStore: AtomicDocumentStore = AtomicDocumentStore(),
        limits: ComparisonLimits = .default
    ) {
        self.documentStore = documentStore
        self.limits = limits
    }

    public func load(at url: URL) throws -> ComparisonReview {
        do {
            let data = try ComparisonRegularFile.read(
                at: url,
                maximumBytes: limits.maxArtifactBytes
            )
            return try ComparisonReviewCodec.decode(data, limits: limits)
        } catch ComparisonError.inputNotFound {
            throw ComparisonError.reviewNotFound(url.standardizedFileURL.path)
        }
    }

    /// Exclusively creates a new review. Repeating the exact create is
    /// idempotent; different content at the same path is a conflict.
    public func create(
        _ review: ComparisonReview,
        at url: URL
    ) throws -> ComparisonReviewMutationReceipt {
        guard review.revision == 0 else {
            throw ComparisonError.invalidArtifact("A new review must begin at revision zero.")
        }
        let data = try ComparisonReviewCodec.encode(review, limits: limits)
        do {
            try Self.atomicCreate(data, at: url)
            return ComparisonReviewMutationReceipt(
                review: review,
                previousRevision: 0,
                revision: 0,
                changed: true
            )
        } catch ComparisonError.reviewAlreadyExists {
            let existing = try load(at: url)
            guard existing == review else {
                throw ComparisonError.reviewAlreadyExists(url.standardizedFileURL.path)
            }
            return ComparisonReviewMutationReceipt(
                review: existing,
                previousRevision: existing.revision,
                revision: existing.revision,
                changed: false
            )
        }
    }

    public func update(
        at url: URL,
        expectedRevision: Int,
        modified: String,
        _ transform: (inout ComparisonReview) throws -> Void
    ) throws -> ComparisonReviewMutationReceipt {
        try transaction(
            at: url,
            expectedRevision: expectedRevision,
            modified: modified,
            allowsSnapshotRefresh: false,
            transform
        )
    }

    public func refresh(
        at url: URL,
        expectedRevision: Int,
        snapshots: ComparisonSnapshotPair,
        modified: String,
        cancellation: ComparisonCancellationToken? = nil,
        maximumScalarComparisons: Int = ComparisonHardLimits.anchorRefreshScalarComparisons
    ) throws -> ComparisonReviewMutationReceipt {
        try transaction(
            at: url,
            expectedRevision: expectedRevision,
            modified: modified,
            allowsSnapshotRefresh: true
        ) { review in
            try review.refreshSnapshots(
                snapshots,
                modified: modified,
                cancellation: cancellation,
                maximumScalarComparisons: maximumScalarComparisons
            )
        }
    }

    private func transaction(
        at url: URL,
        expectedRevision: Int,
        modified: String,
        allowsSnapshotRefresh: Bool,
        _ transform: (inout ComparisonReview) throws -> Void
    ) throws -> ComparisonReviewMutationReceipt {
        guard expectedRevision >= 0, !modified.isEmpty else {
            throw ComparisonError.invalidArtifact("Review mutation precondition or timestamp is invalid.")
        }
        try Self.rejectFinalSymlink(url)
        do {
            return try documentStore.transaction(
                at: url,
                maximumBytes: limits.maxArtifactBytes,
                rejectSymbolicLinks: true
            ) { data in
                let original = try ComparisonReviewCodec.decode(data, limits: limits)
                guard original.revision == expectedRevision else {
                    throw ComparisonError.revisionConflict(
                        expected: expectedRevision,
                        actual: original.revision
                    )
                }
                var updated = original
                try transform(&updated)
                guard allowsSnapshotRefresh || updated.snapshots == original.snapshots else {
                    throw ComparisonError.immutableSnapshots
                }
                if updated == original {
                    return AtomicDocumentMutation(
                        data: data,
                        result: ComparisonReviewMutationReceipt(
                            review: original,
                            previousRevision: original.revision,
                            revision: original.revision,
                            changed: false
                        )
                    )
                }
                let (nextRevision, overflow) = original.revision.addingReportingOverflow(1)
                guard !overflow else {
                    throw ComparisonError.invalidArtifact(
                        "The comparison review revision cannot be advanced safely."
                    )
                }
                try updated.preparePersistenceRevision(nextRevision, modified: modified)
                let encoded = try ComparisonReviewCodec.encode(updated, limits: limits)
                return AtomicDocumentMutation(
                    data: encoded,
                    result: ComparisonReviewMutationReceipt(
                        review: updated,
                        previousRevision: original.revision,
                        revision: updated.revision,
                        changed: true
                    )
                )
            }
        } catch CommentProtocolError.concurrentModification {
            throw ComparisonError.concurrentModification
        } catch CommentProtocolError.io(let message) {
            throw ComparisonError.io(message)
        }
    }

    private static func rejectFinalSymlink(_ url: URL) throws {
        guard url.isFileURL else {
            throw ComparisonError.notRegularFile(url.absoluteString)
        }
        // swift-corelibs Foundation resolves symbolic links while computing a
        // standardized file URL. Preserve the requested final component so
        // `lstat` can reject it consistently on Linux and Darwin.
        let path = url.path
        var information = stat()
        guard lstat(path, &information) == 0 else {
            if errno == ENOENT { throw ComparisonError.reviewNotFound(path) }
            throw ComparisonError.io("Could not inspect '\(path)': \(String(cString: strerror(errno))).")
        }
        if (information.st_mode & S_IFMT) == S_IFLNK {
            throw ComparisonError.symbolicLink(path)
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw ComparisonError.notRegularFile(path)
        }
    }

    private static func atomicCreate(_ data: Data, at url: URL) throws {
        guard url.isFileURL else {
            throw ComparisonError.notRegularFile(url.absoluteString)
        }
        // Atomic creation must preserve the literal destination path; using a
        // standardized URL can silently resolve a symlink on Linux.
        let target = url
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ComparisonError.io("Could not create the review directory: \(error.localizedDescription)")
        }
        let temporary = directory.appendingPathComponent(
            ".margin-review.\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ComparisonError.io(
                "Could not create a temporary review: \(String(cString: strerror(errno)))."
            )
        }
        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = close(descriptor) }
            if temporaryExists { _ = unlink(temporary.path) }
        }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let base = buffer.baseAddress!.advanced(by: offset)
#if canImport(Darwin)
                    let count = Darwin.write(descriptor, base, buffer.count - offset)
#else
                    let count = Glibc.write(descriptor, base, buffer.count - offset)
#endif
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw ComparisonError.io("The atomic review write did not make progress.")
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw ComparisonError.io("Could not synchronize the new review.")
            }
            _ = close(descriptor)
            descriptorIsOpen = false
            guard link(temporary.path, target.path) == 0 else {
                if errno == EEXIST {
                    throw ComparisonError.reviewAlreadyExists(target.path)
                }
                throw ComparisonError.io(
                    "Could not install the new review: \(String(cString: strerror(errno)))."
                )
            }
            guard unlink(temporary.path) == 0 else {
                throw ComparisonError.io("Could not remove the temporary review link.")
            }
            temporaryExists = false
            let directoryDescriptor = open(directory.path, O_RDONLY)
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                _ = close(directoryDescriptor)
            }
        } catch {
            throw error
        }
    }
}
