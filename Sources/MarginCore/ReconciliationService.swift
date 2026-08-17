import Foundation

public enum ReconciliationPolicy: String, Codable, Sendable {
    /// Write only when every anchored contribution can be placed uniquely.
    case requireAllAnchored
    /// Refresh unique anchors and preserve unresolved selectors for explicit human review.
    case preserveUnresolved
}

public struct ReconciledAnchor: Codable, Hashable, Sendable {
    public var id: String
    public var state: AnchorResolutionState
    public var range: UnicodeScalarRange?
    public var candidates: [AnchorCandidate]

    public init(
        id: String,
        state: AnchorResolutionState,
        range: UnicodeScalarRange?,
        candidates: [AnchorCandidate]
    ) {
        self.id = id
        self.state = state
        self.range = range
        self.candidates = candidates
    }
}

public struct ReconciliationAnalysis: Codable, Sendable {
    public var documentID: String
    public var previousRevision: Int
    public var previousContentSha256: String
    public var currentContentSha256: String
    public var anchors: [ReconciledAnchor]

    public init(
        documentID: String,
        previousRevision: Int,
        previousContentSha256: String,
        currentContentSha256: String,
        anchors: [ReconciledAnchor]
    ) {
        self.documentID = documentID
        self.previousRevision = previousRevision
        self.previousContentSha256 = previousContentSha256
        self.currentContentSha256 = currentContentSha256
        self.anchors = anchors
    }

    public var ambiguousCount: Int { anchors.filter { $0.state == .ambiguous }.count }
    public var orphanedCount: Int { anchors.filter { $0.state == .orphaned }.count }
    public var movedCount: Int { anchors.filter { $0.state == .moved }.count }
    public var canApplyStrictly: Bool { ambiguousCount == 0 && orphanedCount == 0 }
}

public struct ReconciliationReceipt: Codable, Sendable {
    public var changed: Bool
    public var documentID: String
    public var revision: Int
    public var contentSha256: String
    public var refreshedAnchorIDs: [String]
    public var unresolvedAnchorIDs: [String]
}

public enum ReconciliationError: Error, LocalizedError, Sendable {
    case baseHasNoAnnotations
    case currentAlreadyValid
    case envelopeSuffixChanged
    case invalidCurrentUTF8
    case unresolvedAnchors([String])

    public var code: String {
        switch self {
        case .baseHasNoAnnotations: return "RECONCILE_BASE_HAS_NO_ANNOTATIONS"
        case .currentAlreadyValid: return "RECONCILE_NOT_NEEDED"
        case .envelopeSuffixChanged: return "RECONCILE_ENVELOPE_CHANGED"
        case .invalidCurrentUTF8: return "INVALID_UTF8"
        case .unresolvedAnchors: return "RECONCILE_NEEDS_ATTENTION"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .baseHasNoAnnotations:
            return "The previous source has no Margin annotation envelope."
        case .currentAlreadyValid:
            return "The current document is already valid; reconciliation is not needed."
        case .envelopeSuffixChanged:
            return "The annotation envelope or its separator changed. Reconciliation refuses to guess document boundaries."
        case .invalidCurrentUTF8:
            return "The current Markdown body is not valid UTF-8."
        case .unresolvedAnchors(let ids):
            return "Reconciliation left \(ids.count) ambiguous or orphaned anchor(s): \(ids.joined(separator: ", "))."
        }
    }
}

/// Repairs a stale terminal annotation envelope after an out-of-band Markdown edit.
///
/// A known-good previous copy is required so the logical body/envelope boundary is
/// provable. This intentionally refuses heuristic delimiter recovery.
public struct ReconciliationService: Sendable {
    public var codec: EmbeddedCommentCodec
    public var resolver: AnchorResolver
    public var store: AtomicDocumentStore
    private let timestamp: @Sendable () -> String

    public init(
        codec: EmbeddedCommentCodec = EmbeddedCommentCodec(),
        resolver: AnchorResolver = AnchorResolver(),
        store: AtomicDocumentStore = AtomicDocumentStore(),
        timestamp: @escaping @Sendable () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.codec = codec
        self.resolver = resolver
        self.store = store
        self.timestamp = timestamp
    }

    public func analyze(at currentURL: URL, from previousURL: URL) throws -> ReconciliationAnalysis {
        let current = try store.read(at: currentURL)
        let previous = try store.read(at: previousURL)
        return try prepare(current: current, previous: previous).analysis
    }

    public func apply(
        at currentURL: URL,
        from previousURL: URL,
        policy: ReconciliationPolicy
    ) throws -> ReconciliationReceipt {
        let previous = try store.read(at: previousURL)
        return try store.transaction(at: currentURL) { current in
            let prepared = try prepare(current: current, previous: previous)
            let unresolved = prepared.analysis.anchors.filter {
                $0.state == .ambiguous || $0.state == .orphaned
            }.map(\.id)
            if policy == .requireAllAnchored, !unresolved.isEmpty {
                throw ReconciliationError.unresolvedAnchors(unresolved)
            }

            var envelope = prepared.envelope
            var refreshed: [String] = []
            for index in envelope.items.indices where envelope.items[index].motivation == "commenting" {
                guard case .selection(let target) = envelope.items[index].target else { continue }
                let resolution = try resolver.resolve(target, in: prepared.body)
                guard resolution.state == .anchored || resolution.state == .moved else { continue }
                envelope.items[index].target = .selection(try resolver.refreshed(target, in: prepared.body))
                refreshed.append(envelope.items[index].id)
            }
            envelope.revision += 1
            envelope.modified = timestamp()
            let replacement = try codec.encode(bodyData: prepared.bodyData, envelope: envelope)
            let receipt = ReconciliationReceipt(
                changed: replacement != current,
                documentID: envelope.document.id,
                revision: envelope.revision,
                contentSha256: EmbeddedCommentCodec.contentHash(prepared.bodyData),
                refreshedAnchorIDs: refreshed.sorted(),
                unresolvedAnchorIDs: unresolved.sorted()
            )
            return AtomicDocumentMutation(data: replacement, result: receipt)
        }
    }

    private func prepare(current: Data, previous: Data) throws -> PreparedReconciliation {
        if (try? codec.decode(current)) != nil {
            throw ReconciliationError.currentAlreadyValid
        }
        let oldDocument = try codec.decode(previous)
        guard let envelope = oldDocument.envelope else {
            throw ReconciliationError.baseHasNoAnnotations
        }

        let suffix = previous.dropFirst(oldDocument.bodyData.count)
        guard !suffix.isEmpty,
              current.count >= suffix.count,
              current.suffix(suffix.count).elementsEqual(suffix) else {
            throw ReconciliationError.envelopeSuffixChanged
        }
        let bodyData = Data(current.dropLast(suffix.count))
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw ReconciliationError.invalidCurrentUTF8
        }

        var anchors: [ReconciledAnchor] = []
        for annotation in envelope.items where annotation.motivation == "commenting" {
            guard case .selection(let target) = annotation.target else { continue }
            let resolution = try resolver.resolve(target, in: body)
            anchors.append(ReconciledAnchor(
                id: annotation.id,
                state: resolution.state,
                range: resolution.range,
                candidates: resolution.candidates
            ))
        }
        anchors.sort { $0.id < $1.id }
        return PreparedReconciliation(
            envelope: envelope,
            bodyData: bodyData,
            body: body,
            analysis: ReconciliationAnalysis(
                documentID: envelope.document.id,
                previousRevision: envelope.revision,
                previousContentSha256: EmbeddedCommentCodec.contentHash(oldDocument.bodyData),
                currentContentSha256: EmbeddedCommentCodec.contentHash(bodyData),
                anchors: anchors
            )
        )
    }
}

private struct PreparedReconciliation {
    var envelope: EmbeddedCommentEnvelope
    var bodyData: Data
    var body: String
    var analysis: ReconciliationAnalysis
}
