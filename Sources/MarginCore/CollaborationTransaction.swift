import Darwin
import Foundation

public enum CollaborationTransactionDisposition: String, Codable, Sendable {
    case applied
    case alreadyApplied = "already-applied"
    case recovered
}

public struct CollaborationTransactionFileReceipt: Codable, Hashable, Sendable {
    public let path: String
    public let removed: Bool
    public let wholeFileSha256: String?
}

public struct CollaborationTransactionReceipt: Codable, Hashable, Sendable {
    public let transactionID: String
    public let changeSetID: String
    public let requestID: String
    public let stageID: String
    public let rootID: String
    public let disposition: CollaborationTransactionDisposition
    public let committedAt: String
    public let files: [CollaborationTransactionFileReceipt]
}

public struct CollaborationLockedFile: Codable, Hashable, Sendable {
    public let path: String
    public let data: Data
}

public struct CollaborationLockedPathState: Codable, Hashable, Sendable {
    public let path: String
    public let data: Data?

    public var exists: Bool { data != nil }
}

/// A journaled multi-file filesystem transaction.
///
/// Margin readers should use `read(root:paths:)`; it shares the workspace lock
/// with submission and therefore never observes a partially installed change set.
/// POSIX has no cross-file atomic rename primitive, so an arbitrary reader that
/// bypasses this lock can theoretically observe the short deterministic install
/// interval between independent file renames.
public struct CollaborationTransactionEngine: @unchecked Sendable {
    private static let maximumJournalCount = 64
    private static let maximumJournalBytes = 64 * 1_024 * 1_024
    private static let maximumAggregateJournalBytes = 128 * 1_024 * 1_024

    public let lockTimeout: TimeInterval
    private let stateDirectory: URL?
    private let cursors: CollaborationCursorService
    private let activityStore: CollaborationActivityStore
    private let faultInjector: CollaborationTransactionFaultInjector?

    public init(
        lockTimeout: TimeInterval = 5,
        stateDirectory: URL? = nil,
        cursors: CollaborationCursorService = CollaborationCursorService(),
        activityStore: CollaborationActivityStore? = nil
    ) {
        self.lockTimeout = max(0, lockTimeout)
        self.stateDirectory = stateDirectory
        self.cursors = cursors
        self.activityStore = activityStore ?? CollaborationActivityStore(stateDirectory: stateDirectory)
        self.faultInjector = nil
    }

    init(
        lockTimeout: TimeInterval = 5,
        stateDirectory: URL? = nil,
        cursors: CollaborationCursorService = CollaborationCursorService(),
        activityStore: CollaborationActivityStore? = nil,
        faultInjector: @escaping CollaborationTransactionFaultInjector
    ) {
        self.lockTimeout = max(0, lockTimeout)
        self.stateDirectory = stateDirectory
        self.cursors = cursors
        self.activityStore = activityStore ?? CollaborationActivityStore(stateDirectory: stateDirectory)
        self.faultInjector = faultInjector
    }

    /// Submits an immutable change set. A change set containing only `.file`
    /// operations needs no second argument. Callers that stage semantic operations
    /// pass their fully evaluated, validated final file images in `mutations`.
    public func submit(
        _ changeSet: CollaborationChangeSet,
        evaluatedMutations mutations: [CollaborationFileMutation]? = nil
    ) throws -> CollaborationTransactionReceipt {
        try changeSet.validate()
        let resolvedMutations = try validatedMutations(changeSet, explicit: mutations)
        let targets = try resolvedTargets(root: changeSet.root, mutations: resolvedMutations)
        let rootLock = try acquireRootLock(root: changeSet.root)
        defer { rootLock.release() }
        try recoverLocked(root: changeSet.root)
        let transactionID = Self.transactionID(for: changeSet)
        let baseURLs = try changeSet.baseCursor.files.map {
            try CollaborationPathResolver.resolve(
                root: changeSet.root,
                relativePath: $0.path,
                allowMissingFinal: true
            )
        }
        let documentLocks = try acquireDocumentLocks(urls: baseURLs + targets.map(\.url))
        defer { documentLocks.release() }
        try cleanupPreJournalArtifacts(
            transactionID: transactionID,
            changeSet: changeSet,
            targets: targets
        )
        if try resultsAreInstalled(targets) {
            let value = receipt(
                transactionID: transactionID,
                changeSet: changeSet,
                disposition: .alreadyApplied,
                targets: targets
            )
            try persistCommittedActivity(changeSet: changeSet, transactionID: transactionID, targets: targets)
            return value
        }

        try cursors.verify(changeSet.baseCursor)
        try verifyMutationPreconditions(targets, baseCursor: changeSet.baseCursor)

        var journal: CollaborationTransactionJournal?
        do {
            let prepared = try prepare(
                transactionID: transactionID,
                changeSet: changeSet,
                targets: targets
            )
            journal = prepared
            try writeJournal(prepared)
            try inject(.afterJournalPrepared, index: -1, url: journalURL(for: prepared))

            for (index, entry) in prepared.entries.enumerated() {
                let target = targets[index]
                try inject(.beforeInstall, index: index, url: target.url)
                try verifyOriginalStillCurrent(entry: entry, target: target)
                try install(entry: entry, target: target)
                try inject(.afterInstall, index: index, url: target.url)
            }
            try synchronizeDirectories(targets.map { $0.url.deletingLastPathComponent() })
            try inject(.beforeCommitRecord, index: prepared.entries.count, url: journalURL(for: prepared))
            let committed = prepared.withState(.committed)
            try writeJournal(committed)
            journal = committed
            try persistCommittedActivity(changeSet: changeSet, transactionID: transactionID, targets: targets)
            try cleanup(committed, removeJournal: true)
            return receipt(
                transactionID: transactionID,
                changeSet: changeSet,
                disposition: .applied,
                targets: targets
            )
        } catch is CollaborationSimulatedCrash {
            // Test-only fault models sudden process termination: recovery material
            // is intentionally preserved and ordinary rollback is skipped.
            throw CollaborationError.transactionFailed("Simulated interruption left a recoverable journal.")
        } catch {
            guard let journal else { throw Self.transactionError(error) }
            if journal.state == .committed {
                throw CollaborationError.transactionFailed(
                    "The change set committed durably but final cleanup failed; retry the same request to recover idempotently: \(error.localizedDescription)"
                )
            }
            do {
                try rollback(journal)
                try cleanup(journal, removeJournal: true)
            } catch {
                throw CollaborationError.rollbackFailed(error.localizedDescription)
            }
            throw Self.transactionError(error)
        }
    }

    /// Reads a set of files while holding the same root submission lock used by
    /// `submit`, providing an all-before or all-after view to Margin callers.
    public func read(root: CollaborationRoot, paths: [String]) throws -> [CollaborationLockedFile] {
        try root.validate()
        let ordered = CollaborationValidation.sortedUnique(paths)
        guard ordered.count == paths.count else {
            throw CollaborationError.invalidPath("Duplicate read paths are not allowed.")
        }
        let urls = try ordered.map {
            try CollaborationPathResolver.resolve(root: root, relativePath: $0, allowMissingFinal: false)
        }
        let rootLock = try acquireRootLock(root: root)
        defer { rootLock.release() }
        try recoverLocked(root: root)
        let documentLocks = try acquireDocumentLocks(urls: urls)
        defer { documentLocks.release() }
        return try zip(ordered, urls).map { path, url in
            CollaborationLockedFile(
                path: path,
                data: try CollaborationPathResolver.readBounded(url, maximumBytes: 128 * 1_024 * 1_024)
            )
        }
    }

    /// Variant of `read` used by idempotent planners whose change set may create
    /// or remove a target. Missing final path components are represented by nil.
    public func readState(
        root: CollaborationRoot,
        paths: [String]
    ) throws -> [CollaborationLockedPathState] {
        try root.validate()
        let ordered = CollaborationValidation.sortedUnique(paths)
        guard ordered.count == paths.count else {
            throw CollaborationError.invalidPath("Duplicate read-state paths are not allowed.")
        }
        let urls = try ordered.map {
            try CollaborationPathResolver.resolve(root: root, relativePath: $0, allowMissingFinal: true)
        }
        let rootLock = try acquireRootLock(root: root)
        defer { rootLock.release() }
        try recoverLocked(root: root)
        let documentLocks = try acquireDocumentLocks(urls: urls)
        defer { documentLocks.release() }
        return try zip(ordered, urls).map { path, url in
            guard Self.exists(url) else { return CollaborationLockedPathState(path: path, data: nil) }
            guard try CollaborationPathResolver.kind(of: url) == .regularFile else {
                throw CollaborationError.invalidPath(path)
            }
            return CollaborationLockedPathState(
                path: path,
                data: try CollaborationPathResolver.readBounded(url, maximumBytes: 128 * 1_024 * 1_024)
            )
        }
    }

    /// Runs an explicit Margin read operation while holding the root submission
    /// lock. This is the integration point for bounded context discovery, which
    /// needs its directory listing, document bytes, and durable activity to share
    /// one all-before or all-after view.
    public func withLockedRoot<Result>(
        root: CollaborationRoot,
        _ body: () throws -> Result
    ) throws -> Result {
        try root.validate()
        let rootLock = try acquireRootLock(root: root)
        defer { rootLock.release() }
        try recoverLocked(root: root)
        return try body()
    }

    /// Recovers every durable journal for a root in deterministic transaction-id
    /// order. Prepared journals roll back; committed journals only clean residue.
    @discardableResult
    public func recover(root: CollaborationRoot) throws -> [CollaborationTransactionReceipt] {
        try root.validate()
        // Recovery participates in the same root-wide serialization as submit
        // and locked reads. Acquire it before discovering journals so two
        // recovery callers cannot both retain a stale snapshot of the same WAL.
        let rootLock = try acquireRootLock(root: root)
        defer { rootLock.release() }
        let journals = try loadJournals(root: root)
        let targetURLs = try journals.flatMap { journal in
            try journal.entries.map {
                try CollaborationPathResolver.resolve(
                    root: root,
                    relativePath: $0.path,
                    allowMissingFinal: true
                )
            }
        }
        let documentLocks = try acquireDocumentLocks(urls: targetURLs)
        defer { documentLocks.release() }
        var receipts: [CollaborationTransactionReceipt] = []
        for journal in journals {
            if journal.state == .prepared {
                try rollback(journal)
                try persistJournalActivity(journal, kind: .transactionRecovered)
            } else {
                try persistJournalActivity(journal, kind: .transactionCommitted)
            }
            try cleanup(journal, removeJournal: true)
            receipts.append(CollaborationTransactionReceipt(
                transactionID: journal.transactionID,
                changeSetID: journal.changeSetID,
                requestID: journal.requestID,
                stageID: journal.stageID,
                rootID: root.id,
                disposition: .recovered,
                committedAt: CollaborationTimestamp.string(),
                files: journal.entries.map {
                    CollaborationTransactionFileReceipt(
                        path: $0.path,
                        removed: $0.resultSha256 == nil,
                        wholeFileSha256: $0.resultSha256
                    )
                }
            ))
        }
        return receipts
    }

    private func validatedMutations(
        _ changeSet: CollaborationChangeSet,
        explicit: [CollaborationFileMutation]?
    ) throws -> [CollaborationFileMutation] {
        let semanticCount = changeSet.operations.count - changeSet.fileMutations.count
        let values: [CollaborationFileMutation]
        if let explicit {
            values = explicit
        } else {
            guard semanticCount == 0 else {
                throw CollaborationError.invalidChangeSet(
                    "Semantic operations must be evaluated into final file mutations before submission."
                )
            }
            values = changeSet.fileMutations
        }
        guard !values.isEmpty, values.count <= 4_096 else {
            throw CollaborationError.invalidChangeSet("Submission needs between 1 and 4,096 evaluated file mutations.")
        }
        var paths = Set<String>()
        for value in values {
            try value.validate()
            guard paths.insert(value.path).inserted else { throw CollaborationError.duplicateTarget(value.path) }
            if changeSet.root.kind == .document, value.path != "." {
                throw CollaborationError.pathEscapesRoot(value.path)
            }
        }
        let operationPaths = Set(changeSet.operations.map(\.path))
        guard operationPaths.isSubset(of: paths) else {
            throw CollaborationError.invalidChangeSet("Every operation path needs one evaluated final file image.")
        }
        for direct in changeSet.fileMutations {
            guard values.contains(direct) else {
                throw CollaborationError.invalidChangeSet("An evaluated submission cannot replace a direct file operation.")
            }
        }
        return values.sorted { CollaborationValidation.pathLess($0.path, $1.path) }
    }

    private func resolvedTargets(
        root: CollaborationRoot,
        mutations: [CollaborationFileMutation]
    ) throws -> [CollaborationResolvedMutation] {
        try mutations.map { mutation in
            let allowMissing: Bool
            switch (mutation.precondition.existence, mutation.result) {
            case (.absent, _), (_, .remove): allowMissing = true
            case (.exact, .write): allowMissing = false
            }
            let url = try CollaborationPathResolver.resolve(
                root: root,
                relativePath: mutation.path,
                allowMissingFinal: allowMissing
            )
            return CollaborationResolvedMutation(mutation: mutation, url: url)
        }
    }

    private func resultsAreInstalled(_ targets: [CollaborationResolvedMutation]) throws -> Bool {
        for target in targets {
            switch target.mutation.result {
            case .remove:
                if Self.exists(target.url) { return false }
            case .write(let expected, _):
                guard Self.exists(target.url) else { return false }
                if try CollaborationPathResolver.kind(of: target.url) == .symbolicLink {
                    throw CollaborationError.symlinkNotAllowed(target.mutation.path)
                }
                let data = try CollaborationPathResolver.readBounded(
                    target.url,
                    maximumBytes: 128 * 1_024 * 1_024
                )
                if data != expected { return false }
            }
        }
        return true
    }

    private func verifyMutationPreconditions(
        _ targets: [CollaborationResolvedMutation],
        baseCursor: CollaborationCursor
    ) throws {
        for target in targets {
            let path = target.mutation.path
            switch target.mutation.precondition.existence {
            case .absent:
                guard baseCursor[path] == nil else {
                    throw CollaborationError.invalidChangeSet("An absent precondition conflicts with the base cursor for '\(path)'.")
                }
                guard !Self.exists(target.url) else {
                    throw CollaborationError.preconditionFailed(path: path, reason: "The target already exists.")
                }
            case .exact:
                guard let base = baseCursor[path] else {
                    throw CollaborationError.invalidChangeSet("An exact precondition is not bound by the base cursor for '\(path)'.")
                }
                let expected = target.mutation.precondition
                guard expected.wholeFileSha256 == base.wholeFileSha256,
                      expected.contentSha256.map({ $0 == base.contentSha256 }) ?? true,
                      expected.annotationRevision.map({ $0 == base.annotationRevision }) ?? true,
                      expected.annotationSha256.map({ $0 == base.annotationSha256 }) ?? true else {
                    throw CollaborationError.invalidChangeSet("The mutation precondition weakens or contradicts the base cursor for '\(path)'.")
                }
            }
        }
    }

    private func prepare(
        transactionID: String,
        changeSet: CollaborationChangeSet,
        targets: [CollaborationResolvedMutation]
    ) throws -> CollaborationTransactionJournal {
        var entries: [CollaborationTransactionJournalEntry] = []
        var materialPaths: [String] = []
        do {
            for (index, target) in targets.enumerated() {
                let original: Data?
                let originalMode: UInt16?
                if Self.exists(target.url) {
                    guard try CollaborationPathResolver.kind(of: target.url) == .regularFile else {
                        throw CollaborationError.invalidPath(target.mutation.path)
                    }
                    original = try CollaborationPathResolver.readBounded(
                        target.url,
                        maximumBytes: 128 * 1_024 * 1_024
                    )
                    originalMode = try Self.permissions(target.url)
                } else {
                    original = nil
                    originalMode = nil
                }
                let nonce = "margin-\(transactionID)-\(index)"
                let directory = target.url.deletingLastPathComponent()
                let backupURL: URL?
                if original != nil {
                    let value = directory.appendingPathComponent(".\(nonce).backup", isDirectory: false)
                    try Self.copyNewFile(from: target.url, to: value)
                    materialPaths.append(value.path)
                    backupURL = value
                } else {
                    backupURL = nil
                }
                let stagedURL: URL?
                let resultSha256: String?
                switch target.mutation.result {
                case .remove:
                    stagedURL = nil
                    resultSha256 = nil
                case .write(let data, let requestedPermissions):
                    let value = directory.appendingPathComponent(".\(nonce).stage", isDirectory: false)
                    if original != nil {
                        try Self.copyNewFile(from: target.url, to: value)
                        do {
                            try Self.replaceContents(
                                of: value,
                                with: data,
                                permissions: requestedPermissions
                            )
                        } catch {
                            _ = unlink(value.path)
                            throw error
                        }
                    } else {
                        try Self.writeNewFile(
                            data,
                            to: value,
                            permissions: requestedPermissions ?? 0o644
                        )
                    }
                    materialPaths.append(value.path)
                    stagedURL = value
                    resultSha256 = CollaborationCanonicalJSON.sha256(of: data)
                }
                entries.append(CollaborationTransactionJournalEntry(
                    path: target.mutation.path,
                    targetPath: target.url.path,
                    originalSha256: original.map(CollaborationCanonicalJSON.sha256(of:)),
                    originalPermissions: originalMode,
                    backupPath: backupURL?.path,
                    stagedPath: stagedURL?.path,
                    resultSha256: resultSha256
                ))
                try inject(.afterStagingFile, index: index, url: target.url)
            }
        } catch is CollaborationSimulatedCrash {
            // Model a process disappearing before the prepared WAL is durable.
            // Deterministically named material is intentionally left for the
            // same transaction's locked retry to validate and remove.
            throw CollaborationSimulatedCrash()
        } catch {
            for path in materialPaths { _ = unlink(path) }
            throw error
        }
        let facts = Self.contributionFacts(changeSet)
        return CollaborationTransactionJournal(
            version: 1,
            transactionID: transactionID,
            changeSetID: changeSet.id,
            requestID: changeSet.requestID,
            stageID: changeSet.stageID,
            root: changeSet.root,
            actor: changeSet.actor,
            state: .prepared,
            created: changeSet.created,
            contributionIDs: facts.ids,
            contributionKinds: facts.kinds,
            entries: entries
        )
    }

    /// Removes only this transaction's deterministic pre-WAL artifacts, after
    /// proving their bytes are exactly the expected base/result images. This
    /// closes the crash window between staging and the first durable journal
    /// without sweeping unrelated dotfiles or trusting filename ownership alone.
    private func cleanupPreJournalArtifacts(
        transactionID: String,
        changeSet: CollaborationChangeSet,
        targets: [CollaborationResolvedMutation]
    ) throws {
        var validated: [URL] = []
        for (index, target) in targets.enumerated() {
            let prefix = ".margin-\(transactionID)-\(index)"
            let directory = target.url.deletingLastPathComponent()
            let backup = directory.appendingPathComponent("\(prefix).backup", isDirectory: false)
            let staged = directory.appendingPathComponent("\(prefix).stage", isDirectory: false)
            if Self.exists(backup) {
                guard let expected = changeSet.baseCursor[target.mutation.path]?.wholeFileSha256 else {
                    throw CollaborationError.recoveryFailed(
                        "Unexpected pre-journal backup exists for newly created '\(target.mutation.path)'."
                    )
                }
                try Self.verifyRecoveryMaterial(backup, digest: expected, path: target.mutation.path)
                validated.append(backup)
            }
            if Self.exists(staged) {
                guard case .write(let expectedData, _) = target.mutation.result else {
                    throw CollaborationError.recoveryFailed(
                        "Unexpected pre-journal staged image exists for removed '\(target.mutation.path)'."
                    )
                }
                try Self.verifyRecoveryMaterial(
                    staged,
                    digest: CollaborationCanonicalJSON.sha256(of: expectedData),
                    path: target.mutation.path
                )
                validated.append(staged)
            }
        }
        guard !validated.isEmpty else { return }
        for url in validated {
            guard unlink(url.path) == 0 else {
                throw CollaborationError.recoveryFailed(
                    "Could not remove validated pre-journal material '\(url.lastPathComponent)'."
                )
            }
        }
        try synchronizeDirectories(validated.map { $0.deletingLastPathComponent() })
    }

    private static func verifyRecoveryMaterial(
        _ url: URL,
        digest expected: String,
        path: String
    ) throws {
        guard try CollaborationPathResolver.kind(of: url) == .regularFile else {
            throw CollaborationError.recoveryFailed("Recovery material for '\(path)' is not a regular file.")
        }
        let data = try CollaborationPathResolver.readBounded(url, maximumBytes: 128 * 1_024 * 1_024)
        guard CollaborationCanonicalJSON.sha256(of: data) == expected else {
            throw CollaborationError.recoveryFailed(
                "Pre-journal recovery material for '\(path)' does not match this transaction."
            )
        }
    }

    private func verifyOriginalStillCurrent(
        entry: CollaborationTransactionJournalEntry,
        target: CollaborationResolvedMutation
    ) throws {
        _ = try CollaborationPathResolver.resolve(
            root: entryRootForValidation(entry: entry, target: target),
            relativePath: target.mutation.path,
            allowMissingFinal: entry.originalSha256 == nil
        )
        if let expected = entry.originalSha256 {
            guard Self.exists(target.url) else {
                throw CollaborationError.preconditionFailed(path: entry.path, reason: "The original disappeared before install.")
            }
            let live = try CollaborationPathResolver.readBounded(target.url, maximumBytes: 128 * 1_024 * 1_024)
            guard CollaborationCanonicalJSON.sha256(of: live) == expected else {
                throw CollaborationError.preconditionFailed(path: entry.path, reason: "A non-Margin writer changed the file during staging.")
            }
        } else if Self.exists(target.url) {
            throw CollaborationError.preconditionFailed(path: entry.path, reason: "The absent target appeared during staging.")
        }
    }

    private func entryRootForValidation(
        entry: CollaborationTransactionJournalEntry,
        target: CollaborationResolvedMutation
    ) throws -> CollaborationRoot {
        // Reconstruct the already-validated boundary without deriving scope from cwd.
        if target.mutation.path == "." {
            return try CollaborationRoot(
                id: "urn:margin:root:transaction-validation",
                kind: .document,
                path: target.url.path
            )
        }
        let suffixComponents = target.mutation.path.split(separator: "/").count
        var rootURL = target.url
        for _ in 0..<suffixComponents { rootURL.deleteLastPathComponent() }
        return try CollaborationRoot(
            id: "urn:margin:root:transaction-validation",
            kind: .directory,
            path: rootURL.path
        )
    }

    private func install(
        entry: CollaborationTransactionJournalEntry,
        target: CollaborationResolvedMutation
    ) throws {
        switch target.mutation.result {
        case .remove:
            guard unlink(target.url.path) == 0 else {
                throw CollaborationError.transactionFailed(
                    "Could not remove '\(entry.path)': \(String(cString: strerror(errno)))."
                )
            }
        case .write:
            guard let stagedPath = entry.stagedPath,
                  rename(stagedPath, target.url.path) == 0 else {
                throw CollaborationError.transactionFailed(
                    "Could not install '\(entry.path)': \(String(cString: strerror(errno)))."
                )
            }
        }
    }

    private func rollback(_ journal: CollaborationTransactionJournal) throws {
        var plan: [(entry: CollaborationTransactionJournalEntry, restore: String?, remove: Bool)] = []
        for entry in journal.entries.reversed() {
            let target = URL(fileURLWithPath: entry.targetPath, isDirectory: false)
            if let backup = entry.backupPath {
                let backupURL = URL(fileURLWithPath: backup, isDirectory: false)
                guard Self.exists(backupURL), let originalDigest = entry.originalSha256 else {
                    throw CollaborationError.recoveryFailed("Backup for '\(entry.path)' is missing.")
                }
                try Self.verifyRecoveryMaterial(backupURL, digest: originalDigest, path: entry.path)
            }
            let liveDigest: String?
            if Self.exists(target) {
                guard try CollaborationPathResolver.kind(of: target) == .regularFile else {
                    throw CollaborationError.recoveryFailed(
                        "Live target '\(entry.path)' is no longer a regular file; recovery stopped without overwriting it."
                    )
                }
                let live = try CollaborationPathResolver.readBounded(
                    target,
                    maximumBytes: 128 * 1_024 * 1_024
                )
                liveDigest = CollaborationCanonicalJSON.sha256(of: live)
            } else {
                liveDigest = nil
            }
            let matchesOriginal = liveDigest == entry.originalSha256
            let matchesInstalledResult = liveDigest == entry.resultSha256
            guard matchesOriginal || matchesInstalledResult else {
                throw CollaborationError.recoveryFailed(
                    "Live target '\(entry.path)' matches neither the journaled original nor Margin's intended result; recovery preserved the external bytes and journal."
                )
            }
            if matchesOriginal {
                plan.append((entry, nil, false))
            } else if let backup = entry.backupPath {
                plan.append((entry, backup, false))
            } else {
                plan.append((entry, nil, true))
            }
        }

        // Nothing is changed until every target and backup has passed the full
        // workspace preflight above. Under the shared document locks, a conflict
        // on one path therefore cannot leave earlier paths partially rolled back.
        for item in plan {
            let entry = item.entry
            let target = URL(fileURLWithPath: entry.targetPath, isDirectory: false)
            if let backup = item.restore {
                let restore = target.deletingLastPathComponent()
                    .appendingPathComponent(".margin-restore-\(UUID().uuidString)", isDirectory: false)
                do {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: backup), to: restore)
                    if let permissions = entry.originalPermissions {
                        guard chmod(restore.path, mode_t(permissions)) == 0 else {
                            throw CollaborationError.recoveryFailed("Could not restore permissions for '\(entry.path)'.")
                        }
                    }
                    let handle = try FileHandle(forWritingTo: restore)
                    try handle.synchronize()
                    try handle.close()
                    guard rename(restore.path, target.path) == 0 else {
                        throw CollaborationError.recoveryFailed("Could not restore '\(entry.path)'.")
                    }
                } catch {
                    try? FileManager.default.removeItem(at: restore)
                    throw error
                }
            } else if item.remove, Self.exists(target) {
                guard unlink(target.path) == 0 else {
                    throw CollaborationError.recoveryFailed("Could not remove newly created '\(entry.path)'.")
                }
            }
        }
        try synchronizeDirectories(journal.entries.map {
            URL(fileURLWithPath: $0.targetPath).deletingLastPathComponent()
        })
    }

    private func cleanup(_ journal: CollaborationTransactionJournal, removeJournal: Bool) throws {
        for entry in journal.entries {
            if let path = entry.backupPath { _ = unlink(path) }
            if let path = entry.stagedPath { _ = unlink(path) }
        }
        if removeJournal { _ = unlink(journalURL(for: journal).path) }
        try synchronizeDirectories(
            journal.entries.map { URL(fileURLWithPath: $0.targetPath).deletingLastPathComponent() } +
                [journalURL(for: journal).deletingLastPathComponent()]
        )
    }

    private func receipt(
        transactionID: String,
        changeSet: CollaborationChangeSet,
        disposition: CollaborationTransactionDisposition,
        targets: [CollaborationResolvedMutation]
    ) -> CollaborationTransactionReceipt {
        CollaborationTransactionReceipt(
            transactionID: transactionID,
            changeSetID: changeSet.id,
            requestID: changeSet.requestID,
            stageID: changeSet.stageID,
            rootID: changeSet.root.id,
            disposition: disposition,
            committedAt: CollaborationTimestamp.string(),
            files: targets.map { target in
                switch target.mutation.result {
                case .remove:
                    return CollaborationTransactionFileReceipt(
                        path: target.mutation.path, removed: true, wholeFileSha256: nil
                    )
                case .write(let data, _):
                    return CollaborationTransactionFileReceipt(
                        path: target.mutation.path,
                        removed: false,
                        wholeFileSha256: CollaborationCanonicalJSON.sha256(of: data)
                    )
                }
            }
        )
    }

    private func acquireRootLock(root: CollaborationRoot) throws -> CollaborationLockSet {
        let directory = try lockDirectory(create: true)
        let identity = "root\0\(root.id)\0\(root.path)"
        let digest = CollaborationCanonicalJSON.sha256(of: Data(identity.utf8))
        let url = directory.appendingPathComponent("\(digest).lock", isDirectory: false)
        return CollaborationLockSet(descriptors: [try Self.acquireLock(at: url, timeout: lockTimeout)])
    }

    /// Acquires the exact per-document lock files used by AtomicDocumentStore.
    /// Keeping the root lock in addition to these locks serializes collaboration
    /// transactions with one another while these shared locks serialize them with
    /// ordinary app and `margin comments` writers.
    private func acquireDocumentLocks(urls: [URL]) throws -> CollaborationLockSet {
        let directory = try Self.atomicDocumentLockDirectory()
        let paths = CollaborationValidation.sortedUnique(
            urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        )
        var descriptors: [Int32] = []
        do {
            for path in paths {
                let digest = CollaborationCanonicalJSON.sha256(of: Data(path.utf8))
                let url = directory.appendingPathComponent("\(digest).lock", isDirectory: false)
                descriptors.append(try Self.acquireLock(at: url, timeout: lockTimeout))
            }
            return CollaborationLockSet(descriptors: descriptors)
        } catch {
            CollaborationLockSet(descriptors: descriptors).release()
            throw error
        }
    }

    private func lockDirectory(create: Bool) throws -> URL {
        let base = stateDirectory ?? CollaborationStateDirectories.defaultRoot()
        let directory = base.appendingPathComponent("locks", isDirectory: true)
        if create {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { throw CollaborationError.io("Could not create collaboration lock directory: \(error.localizedDescription)") }
        }
        return directory
    }

    private static func atomicDocumentLockDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base
            .appendingPathComponent("Margin", isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            throw CollaborationError.io(
                "Could not create Margin's shared document lock directory: \(error.localizedDescription)"
            )
        }
        return directory
    }

    private func journalDirectory(root: CollaborationRoot, create: Bool) throws -> URL {
        let directory: URL
        if root.isPersistentWorkspace {
            let margin = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent(".margin", isDirectory: true)
            guard try CollaborationPathResolver.kind(of: margin) == .directory else {
                throw CollaborationError.symlinkNotAllowed(margin.path)
            }
            directory = margin.appendingPathComponent("transactions", isDirectory: true)
        } else {
            let base = stateDirectory ?? CollaborationStateDirectories.defaultRoot()
            let digest = CollaborationCanonicalJSON.sha256(of: try CollaborationCanonicalJSON.encode(root))
            directory = base
                .appendingPathComponent("transactions", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
        }
        if create {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard try CollaborationPathResolver.kind(of: directory) == .directory else {
                    throw CollaborationError.symlinkNotAllowed(directory.path)
                }
            } catch let error as CollaborationError { throw error }
            catch { throw CollaborationError.io("Could not create transaction directory: \(error.localizedDescription)") }
        }
        return directory
    }

    private func journalURL(for journal: CollaborationTransactionJournal) -> URL {
        // `prepare` creates the directory before constructing a journal, so this
        // lookup cannot fail in ordinary use. The fallback remains inside state.
        let directory = (try? journalDirectory(root: journal.root, create: true)) ??
            (stateDirectory ?? CollaborationStateDirectories.defaultRoot())
        return directory.appendingPathComponent("\(journal.transactionID).json", isDirectory: false)
    }

    private func writeJournal(_ journal: CollaborationTransactionJournal) throws {
        let url = try journalDirectory(root: journal.root, create: true)
            .appendingPathComponent("\(journal.transactionID).json", isDirectory: false)
        let data = try CollaborationCanonicalJSON.encode(journal)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(journal.transactionID).\(UUID().uuidString).tmp", isDirectory: false)
        try Self.writeNewFile(data, to: temporary, permissions: 0o600)
        guard rename(temporary.path, url.path) == 0 else {
            _ = unlink(temporary.path)
            throw CollaborationError.io("Could not install transaction journal: \(String(cString: strerror(errno))).")
        }
        try synchronizeDirectories([url.deletingLastPathComponent()])
    }

    private func loadJournals(root: CollaborationRoot) throws -> [CollaborationTransactionJournal] {
        let directory = try journalDirectory(root: root, create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CollaborationError.recoveryFailed("Could not enumerate the transaction journal directory.")
        }
        var urls: [URL] = []
        var aggregateBytes = 0
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard urls.count < Self.maximumJournalCount else {
                throw CollaborationError.recoveryFailed(
                    "The transaction journal directory exceeds the supported \(Self.maximumJournalCount)-journal bound."
                )
            }
            guard try CollaborationPathResolver.kind(of: url) == .regularFile else {
                throw CollaborationError.symlinkNotAllowed(url.path)
            }
            let size = try CollaborationPathResolver.size(of: url)
            guard size <= Self.maximumJournalBytes,
                  aggregateBytes <= Self.maximumAggregateJournalBytes - size else {
                throw CollaborationError.recoveryFailed("Transaction recovery metadata exceeds its bounded byte budget.")
            }
            aggregateBytes += size
            urls.append(url)
        }
        if let enumerationError {
            throw CollaborationError.recoveryFailed(
                "Could not enumerate transaction journals: \(enumerationError.localizedDescription)"
            )
        }
        urls.sort {
            CollaborationValidation.pathLess($0.lastPathComponent, $1.lastPathComponent)
        }
        return try urls.map { url in
            let data = try CollaborationPathResolver.readBounded(url, maximumBytes: Self.maximumJournalBytes)
            let journal = try CollaborationCanonicalJSON.decode(CollaborationTransactionJournal.self, from: data)
            try journal.validate(expectedRoot: root)
            guard try CollaborationCanonicalJSON.encode(journal) == data else {
                throw CollaborationError.recoveryFailed("A recovery journal is not canonical.")
            }
            return journal
        }
    }

    private func recoverLocked(root: CollaborationRoot) throws {
        let journals = try loadJournals(root: root)
        let targetURLs = try journals.flatMap { journal in
            try journal.entries.map {
                try CollaborationPathResolver.resolve(
                    root: root,
                    relativePath: $0.path,
                    allowMissingFinal: true
                )
            }
        }
        let documentLocks = try acquireDocumentLocks(urls: targetURLs)
        defer { documentLocks.release() }
        for journal in journals {
            if journal.state == .prepared {
                try rollback(journal)
                try persistJournalActivity(journal, kind: .transactionRecovered)
            } else {
                try persistJournalActivity(journal, kind: .transactionCommitted)
            }
            try cleanup(journal, removeJournal: true)
        }
    }

    private func persistCommittedActivity(
        changeSet: CollaborationChangeSet,
        transactionID: String,
        targets: [CollaborationResolvedMutation]
    ) throws {
        let facts = Self.contributionFacts(changeSet)
        let record = try CollaborationActivityRecord(
            id: "urn:margin:activity:transaction:\(transactionID)",
            rootID: changeSet.root.id,
            actorID: changeSet.actor.id,
            occurredAt: changeSet.created,
            kind: .transactionCommitted,
            paths: targets.map { $0.mutation.path },
            contributionIDs: facts.ids,
            contributionKinds: facts.kinds,
            requestID: changeSet.requestID,
            stageID: changeSet.stageID,
            extensions: Self.activityExtensions(
                actor: changeSet.actor,
                changeSetID: changeSet.id,
                facts: facts
            )
        )
        try persistActivityIdempotently(record, root: changeSet.root)
    }

    private func persistJournalActivity(
        _ journal: CollaborationTransactionJournal,
        kind: CollaborationActivityKind
    ) throws {
        let suffix = kind == .transactionRecovered ? "recovery" : "transaction"
        let facts = (ids: journal.contributionIDs, kinds: journal.contributionKinds)
        let record = try CollaborationActivityRecord(
            id: "urn:margin:activity:\(suffix):\(journal.transactionID)",
            rootID: journal.root.id,
            actorID: journal.actor.id,
            occurredAt: journal.created,
            kind: kind,
            paths: journal.entries.map(\.path),
            contributionIDs: facts.ids,
            contributionKinds: facts.kinds,
            requestID: journal.requestID,
            stageID: journal.stageID,
            extensions: Self.activityExtensions(
                actor: journal.actor,
                changeSetID: journal.changeSetID,
                facts: facts
            )
        )
        try persistActivityIdempotently(record, root: journal.root)
    }

    /// A repeated semantic request can be rebuilt later with a fresh wall-clock
    /// timestamp while retaining the same durable transaction identity. Preserve
    /// the original fact timestamp and accept the retry only when every other
    /// immutable field is identical.
    private func persistActivityIdempotently(
        _ proposed: CollaborationActivityRecord,
        root: CollaborationRoot
    ) throws {
        if let existing = try activityStore.load(id: proposed.id, root: root) {
            let normalized = try CollaborationActivityRecord(
                id: proposed.id,
                rootID: proposed.rootID,
                actorID: proposed.actorID,
                occurredAt: existing.occurredAt,
                kind: proposed.kind,
                paths: proposed.paths,
                contributionIDs: proposed.contributionIDs,
                contributionKinds: proposed.contributionKinds,
                requestID: proposed.requestID,
                stageID: proposed.stageID,
                extensions: proposed.extensions
            )
            guard normalized == existing else {
                throw CollaborationError.preconditionFailed(
                    path: proposed.id,
                    reason: "The durable transaction activity id is already bound to different facts."
                )
            }
            return
        }
        try activityStore.record(proposed, root: root)
    }

    private static func contributionFacts(
        _ changeSet: CollaborationChangeSet
    ) -> (ids: [String], kinds: [CollaborationContributionKind]) {
        var byID: [String: CollaborationContributionKind] = [:]
        for operation in changeSet.operations {
            switch operation {
            case .contribution(_, let value):
                byID[value.contribution.id] = value.contribution.kind
            case .acceptSuggestion(_, let value):
                byID[value.contributionID] = .suggestion
            case .suggestionDisposition(_, let value):
                byID[value.contributionID] = .suggestion
            case .status, .file:
                break
            }
        }
        let ids = byID.keys.sorted(by: CollaborationValidation.pathLess)
        return (ids, ids.compactMap { byID[$0] })
    }

    private static func activityExtensions(
        actor: CollaborationActor,
        changeSetID: String,
        facts: (ids: [String], kinds: [CollaborationContributionKind])
    ) -> [String: JSONValue] {
        var kindsByID: [String: JSONValue] = [:]
        for (id, kind) in zip(facts.ids, facts.kinds) {
            kindsByID[id] = .string(kind.rawValue)
        }
        return [
            "margin:actor": .object([
                "id": .string(actor.id),
                "type": .string(actor.type.rawValue),
                "name": .string(actor.name),
            ]),
            "margin:changeSetID": .string(changeSetID),
            "margin:contributionKindsByID": .object(kindsByID),
        ]
    }

    private func synchronizeDirectories(_ urls: [URL]) throws {
        let ordered = Dictionary(grouping: urls, by: { $0.standardizedFileURL.path }).keys
            .sorted(by: CollaborationValidation.pathLess)
        for path in ordered {
            let descriptor = Darwin.open(path, O_RDONLY)
            guard descriptor >= 0 else {
                throw CollaborationError.io("Could not open '\(path)' for directory synchronization.")
            }
            defer { _ = close(descriptor) }
            guard fsync(descriptor) == 0 || errno == EINVAL else {
                throw CollaborationError.io("Could not synchronize '\(path)'.")
            }
        }
    }

    private func inject(_ phase: CollaborationTransactionPhase, index: Int, url: URL) throws {
        try faultInjector?(phase, index, url)
    }

    private static func transactionID(for changeSet: CollaborationChangeSet) -> String {
        let material = "\(changeSet.root.id)\0\(changeSet.requestID)\0\(changeSet.stageID)\0\(changeSet.id)"
        return CollaborationCanonicalJSON.sha256(of: Data(material.utf8))
    }

    private static func exists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }

    private static func permissions(_ url: URL) throws -> UInt16 {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw CollaborationError.io("Could not inspect permissions for '\(url.path)'.")
        }
        return UInt16(info.st_mode & 0o777)
    }

    /// Copies data plus stat metadata, ACLs, and extended attributes to a new
    /// transaction artifact. COPYFILE_EXCL/NOFOLLOW keep deterministic names and
    /// hostile symlinks fail closed. The destination is fsynced before its path is
    /// admitted to a durable journal.
    private static func copyNewFile(from source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            let code = errno
            if code != EEXIST { _ = unlink(destination.path) }
            throw CollaborationError.io(
                "Could not preserve metadata while staging '\(destination.path)': \(String(cString: strerror(code)))."
            )
        }
        var shouldRemove = true
        defer {
            if shouldRemove { _ = unlink(destination.path) }
        }
        guard try CollaborationPathResolver.kind(of: destination) == .regularFile else {
            throw CollaborationError.symlinkNotAllowed(destination.path)
        }
        let descriptor = Darwin.open(destination.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not open copied transaction metadata for synchronization.")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CollaborationError.io("Could not durably synchronize copied transaction metadata.")
        }
        shouldRemove = false
    }

    /// Replaces only a copied artifact's data fork. Metadata inherited from the
    /// original remains intact; an explicit mode is the sole supported override.
    private static func replaceContents(
        of url: URL,
        with data: Data,
        permissions: UInt16?
    ) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not open copied stage '\(url.path)'.")
        }
        defer { _ = close(descriptor) }
        guard ftruncate(descriptor, 0) == 0 else {
            throw CollaborationError.io("Could not truncate copied stage '\(url.path)'.")
        }
        let complete = data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return data.isEmpty }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
        guard complete else {
            throw CollaborationError.io("Could not write copied stage '\(url.path)'.")
        }
        if let permissions, fchmod(descriptor, mode_t(permissions)) != 0 {
            throw CollaborationError.io("Could not apply requested permissions to '\(url.path)'.")
        }
        guard fsync(descriptor) == 0 else {
            throw CollaborationError.io("Could not durably synchronize copied stage '\(url.path)'.")
        }
    }

    private static func writeNewFile(_ data: Data, to url: URL, permissions: UInt16) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions))
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not stage '\(url.path)': \(String(cString: strerror(errno))).")
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove { _ = unlink(url.path) }
        }
        let complete = data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return data.isEmpty }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
        guard complete, fchmod(descriptor, mode_t(permissions)) == 0, fsync(descriptor) == 0 else {
            throw CollaborationError.io("Could not durably stage '\(url.path)'.")
        }
        shouldRemove = false
    }

    private static func acquireLock(at url: URL, timeout: TimeInterval) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not open collaboration lock '\(url.path)'.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code != EWOULDBLOCK && code != EAGAIN {
                _ = close(descriptor)
                throw CollaborationError.io("Could not acquire collaboration lock: \(String(cString: strerror(code))).")
            }
            if Date() >= deadline {
                _ = close(descriptor)
                throw CollaborationError.lockTimeout(url.path)
            }
            usleep(10_000)
        }
        return descriptor
    }

    private static func transactionError(_ error: Error) -> CollaborationError {
        if let error = error as? CollaborationError { return error }
        return .transactionFailed(error.localizedDescription)
    }
}

enum CollaborationTransactionPhase: Sendable {
    case afterStagingFile
    case afterJournalPrepared
    case beforeInstall
    case afterInstall
    case beforeCommitRecord
}

typealias CollaborationTransactionFaultInjector = @Sendable (
    CollaborationTransactionPhase,
    Int,
    URL
) throws -> Void

struct CollaborationSimulatedCrash: Error {}

private struct CollaborationResolvedMutation {
    let mutation: CollaborationFileMutation
    let url: URL
}

private final class CollaborationLockSet: @unchecked Sendable {
    private var descriptors: [Int32]

    init(descriptors: [Int32]) {
        self.descriptors = descriptors
    }

    func release() {
        for descriptor in descriptors.reversed() {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        descriptors.removeAll()
    }

    deinit { release() }
}

private enum CollaborationJournalState: String, Codable {
    case prepared
    case committed
}

private struct CollaborationTransactionJournalEntry: Codable, Hashable {
    let path: String
    let targetPath: String
    let originalSha256: String?
    let originalPermissions: UInt16?
    let backupPath: String?
    let stagedPath: String?
    let resultSha256: String?
}

private struct CollaborationTransactionJournal: Codable, Hashable {
    let version: Int
    let transactionID: String
    let changeSetID: String
    let requestID: String
    let stageID: String
    let root: CollaborationRoot
    let actor: CollaborationActor
    let state: CollaborationJournalState
    let created: String
    let contributionIDs: [String]
    let contributionKinds: [CollaborationContributionKind]
    let entries: [CollaborationTransactionJournalEntry]

    func withState(_ state: CollaborationJournalState) -> CollaborationTransactionJournal {
        CollaborationTransactionJournal(
            version: version,
            transactionID: transactionID,
            changeSetID: changeSetID,
            requestID: requestID,
            stageID: stageID,
            root: root,
            actor: actor,
            state: state,
            created: created,
            contributionIDs: contributionIDs,
            contributionKinds: contributionKinds,
            entries: entries
        )
    }

    func validate(expectedRoot: CollaborationRoot) throws {
        guard version == 1, root == expectedRoot, !entries.isEmpty else {
            throw CollaborationError.recoveryFailed("A recovery journal has invalid root or version metadata.")
        }
        try CollaborationValidation.identifier(changeSetID, field: "journal change set id")
        try CollaborationValidation.identifier(requestID, field: "journal request id")
        try CollaborationValidation.identifier(stageID, field: "journal stage id")
        try actor.validate()
        try CollaborationValidation.timestamp(created, field: "journal creation time")
        guard transactionID.count == 64 else {
            throw CollaborationError.recoveryFailed("A recovery journal has an invalid transaction id.")
        }
        var paths = Set<String>()
        for entry in entries {
            try CollaborationValidation.relativePath(entry.path, allowingRootDocument: true)
            guard paths.insert(entry.path).inserted else {
                throw CollaborationError.recoveryFailed("A recovery journal repeats a target path.")
            }
            let resolved = try CollaborationPathResolver.resolve(
                root: root,
                relativePath: entry.path,
                allowMissingFinal: true
            )
            guard resolved.path == entry.targetPath else {
                throw CollaborationError.recoveryFailed("A journal target escapes its declared root.")
            }
            let directory = resolved.deletingLastPathComponent().standardizedFileURL
            for material in [entry.backupPath, entry.stagedPath].compactMap({ $0 }) {
                let url = URL(fileURLWithPath: material).standardizedFileURL
                guard url.deletingLastPathComponent() == directory,
                      url.lastPathComponent.hasPrefix(".margin-") else {
                    throw CollaborationError.recoveryFailed("Recovery material is outside the target directory.")
                }
            }
            if let digest = entry.originalSha256 {
                try CollaborationValidation.sha256(digest, field: "journal original digest")
                guard entry.backupPath != nil else {
                    throw CollaborationError.recoveryFailed("An original journal state has no backup.")
                }
            }
            if let digest = entry.resultSha256 {
                try CollaborationValidation.sha256(digest, field: "journal result digest")
                guard entry.stagedPath != nil || state == .committed else {
                    throw CollaborationError.recoveryFailed("A prepared write has no staged image.")
                }
            }
        }
    }
}
