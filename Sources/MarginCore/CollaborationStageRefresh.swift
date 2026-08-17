import Foundation

/// The durable result of deriving a new immutable stage from an older stage.
/// The original stage is intentionally retained for audit and comparison.
public struct CollaborationStageRefreshReceipt: Codable, Hashable, Sendable {
    public let priorStageID: String
    public let refreshedStageID: String
    public let priorChangeSetID: String
    public let refreshedChangeSetID: String
    public let requestID: String
    public let priorStageWasStale: Bool
    public let disposition: CollaborationStageDisposition
    public let canonicalSha256: String
    public let location: String
    public let evaluatedMutationCount: Int

    public init(
        priorStageID: String,
        refreshedStageID: String,
        priorChangeSetID: String,
        refreshedChangeSetID: String,
        requestID: String,
        priorStageWasStale: Bool,
        disposition: CollaborationStageDisposition,
        canonicalSha256: String,
        location: String,
        evaluatedMutationCount: Int
    ) {
        self.priorStageID = priorStageID
        self.refreshedStageID = refreshedStageID
        self.priorChangeSetID = priorChangeSetID
        self.refreshedChangeSetID = refreshedChangeSetID
        self.requestID = requestID
        self.priorStageWasStale = priorStageWasStale
        self.disposition = disposition
        self.canonicalSha256 = canonicalSha256
        self.location = location
        self.evaluatedMutationCount = evaluatedMutationCount
    }
}

/// Safely derives a fresh immutable stage while preserving every semantic and
/// direct operation byte-for-byte at the model level. The collaboration base
/// cursor and derived identities are replaced, and deterministic reserved
/// provenance is added without changing caller-owned extensions.
public struct CollaborationStageRefreshService: Sendable {
    private let stageStore: CollaborationStageStore
    private let cursors: CollaborationCursorService
    private let evaluator: CollaborationChangeSetEvaluator

    public init(
        stageStore: CollaborationStageStore = CollaborationStageStore(),
        cursors: CollaborationCursorService = CollaborationCursorService(),
        evaluator: CollaborationChangeSetEvaluator = CollaborationChangeSetEvaluator()
    ) {
        self.stageStore = stageStore
        self.cursors = cursors
        self.evaluator = evaluator
    }

    /// Creates (or idempotently returns) a new immutable stage derived from
    /// `stageID`. The old stage is never changed or removed.
    ///
    /// A nil `newStageID` deterministically derives the identity from the old
    /// stage and the newly captured cursor. Supplying an id makes retries stable
    /// under a caller-selected name; reusing that name for different content
    /// fails through the immutable stage store.
    public func refresh(
        stageID: String,
        root: CollaborationRoot,
        newStageID: String? = nil
    ) throws -> CollaborationStageRefreshReceipt {
        try CollaborationValidation.identifier(stageID, field: "prior stage id")
        try root.validate()
        if let newStageID {
            try CollaborationValidation.identifier(newStageID, field: "refreshed stage id")
            guard newStageID != stageID else {
                throw CollaborationError.invalidChangeSet(
                    "A refreshed stage must have a new immutable stage id."
                )
            }
        }

        let prior = try stageStore.load(stageID: stageID, root: root)
        let limits = CollaborationDiscoveryLimits(
            maxFiles: max(1, prior.baseCursor.files.count),
            maxBytes: 1_073_741_824,
            maxDepth: 256
        )
        let current = try cursors.capture(
            root: root,
            paths: prior.baseCursor.files.map(\.path),
            limits: limits
        )
        try verifySemanticTargetsDidNotDrift(prior: prior, current: current)

        let cursorDigest = try CollaborationCanonicalJSON.sha256(of: current)
        let refreshedStageID = newStageID ?? Self.derivedStageID(
            prior: prior,
            cursorDigest: cursorDigest
        )
        let refreshedChangeSetID = Self.derivedChangeSetID(
            prior: prior,
            refreshedStageID: refreshedStageID,
            cursorDigest: cursorDigest
        )
        var refreshedExtensions = prior.extensions
        refreshedExtensions["margin:stageRefresh"] = .object([
            "priorStageID": .string(prior.stageID),
            "priorChangeSetID": .string(prior.id),
            "priorBaseCursorSha256": .string(
                try CollaborationCanonicalJSON.sha256(of: prior.baseCursor)
            ),
        ])
        let refreshed = try CollaborationChangeSet(
            version: prior.version,
            id: refreshedChangeSetID,
            root: prior.root,
            baseCursor: current,
            actor: prior.actor,
            requestID: prior.requestID,
            stageID: refreshedStageID,
            created: prior.created,
            operations: prior.operations,
            extensions: refreshedExtensions
        )

        // Evaluation is deliberately before persistence. It rechecks the newly
        // captured cursor under the transaction reader's locks, validates direct
        // preconditions, and resolves all semantic anchors/expected text.
        let evaluated = try evaluator.evaluate(refreshed)
        let stored = try stageStore.stage(refreshed)
        return CollaborationStageRefreshReceipt(
            priorStageID: prior.stageID,
            refreshedStageID: stored.stageID,
            priorChangeSetID: prior.id,
            refreshedChangeSetID: stored.changeSetID,
            requestID: prior.requestID,
            priorStageWasStale: current != prior.baseCursor,
            disposition: stored.disposition,
            canonicalSha256: stored.canonicalSha256,
            location: stored.location,
            evaluatedMutationCount: evaluated.count
        )
    }

    private func verifySemanticTargetsDidNotDrift(
        prior: CollaborationChangeSet,
        current: CollaborationCursor
    ) throws {
        let semanticPaths = Set(prior.operations.compactMap { operation -> String? in
            if case .file = operation { return nil }
            return operation.path
        })
        for path in semanticPaths.sorted(by: CollaborationValidation.pathLess) {
            guard let old = prior.baseCursor[path], let live = current[path] else {
                throw CollaborationError.preconditionFailed(
                    path: path,
                    reason: "The semantic target is no longer bound by the refreshed cursor."
                )
            }
            guard old.contentSha256 == live.contentSha256 else {
                throw CollaborationError.preconditionFailed(
                    path: path,
                    reason: "The semantic target's logical Markdown changed; refresh cannot safely re-anchor the immutable operation payload."
                )
            }
        }
    }

    private static func derivedStageID(
        prior: CollaborationChangeSet,
        cursorDigest: String
    ) -> String {
        let seed = Data("stage-refresh\0\(prior.stageID)\0\(prior.id)\0\(cursorDigest)".utf8)
        return "urn:margin:stage-refresh:sha256:\(CollaborationCanonicalJSON.sha256(of: seed))"
    }

    private static func derivedChangeSetID(
        prior: CollaborationChangeSet,
        refreshedStageID: String,
        cursorDigest: String
    ) -> String {
        let seed = Data("changeset-refresh\0\(prior.id)\0\(refreshedStageID)\0\(cursorDigest)".utf8)
        return "urn:margin:changeset-refresh:sha256:\(CollaborationCanonicalJSON.sha256(of: seed))"
    }
}
