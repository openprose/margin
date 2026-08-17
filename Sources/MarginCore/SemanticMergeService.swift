import Foundation

public enum SemanticMergeConflictKind: String, Codable, Sendable {
    case source
    case documentIdentity
    case annotation
    case envelopeExtension
}

public struct SemanticMergeConflict: Codable, Hashable, Sendable {
    public var kind: SemanticMergeConflictKind
    public var key: String
    public var message: String

    public init(kind: SemanticMergeConflictKind, key: String, message: String) {
        self.kind = kind
        self.key = key
        self.message = message
    }
}

public struct SemanticMergeAnchorAttention: Codable, Hashable, Sendable {
    public var id: String
    public var state: AnchorResolutionState
    public var candidates: [AnchorCandidate]

    public init(id: String, state: AnchorResolutionState, candidates: [AnchorCandidate]) {
        self.id = id
        self.state = state
        self.candidates = candidates
    }
}

public enum SemanticMergeChoice: String, Codable, Sendable {
    case base
    case ours
    case theirs
    case delete
}

public struct SemanticMergeResult: Codable, Sendable {
    /// A complete valid Margin document. Nil while any semantic conflict is unresolved.
    public var data: Data?
    public var conflicts: [SemanticMergeConflict]
    public var anchorsNeedingAttention: [SemanticMergeAnchorAttention]
    public var documentID: String?
    public var revision: Int
    public var annotationCount: Int
    public var contentSha256: String

    public init(
        data: Data?,
        conflicts: [SemanticMergeConflict],
        anchorsNeedingAttention: [SemanticMergeAnchorAttention],
        documentID: String?,
        revision: Int,
        annotationCount: Int,
        contentSha256: String
    ) {
        self.data = data
        self.conflicts = conflicts
        self.anchorsNeedingAttention = anchorsNeedingAttention
        self.documentID = documentID
        self.revision = revision
        self.annotationCount = annotationCount
        self.contentSha256 = contentSha256
    }

    public var clean: Bool { conflicts.isEmpty && data != nil }
}

/// Three-way merge for Margin's annotation graph. Markdown source follows the
/// ordinary three-way rule, or can be supplied as an explicit already-merged body.
public struct SemanticMergeService: Sendable {
    public var codec: EmbeddedCommentCodec
    public var resolver: AnchorResolver
    private let timestamp: @Sendable () -> String

    public init(
        codec: EmbeddedCommentCodec = EmbeddedCommentCodec(),
        resolver: AnchorResolver = AnchorResolver(),
        timestamp: @escaping @Sendable () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.codec = codec
        self.resolver = resolver
        self.timestamp = timestamp
    }

    public func merge(
        base: Data,
        ours: Data,
        theirs: Data,
        mergedBody: Data? = nil,
        annotationResolutions: [String: SemanticMergeChoice] = [:]
    ) throws -> SemanticMergeResult {
        let baseDocument = try codec.decode(base)
        let ourDocument = try codec.decode(ours)
        let theirDocument = try codec.decode(theirs)
        var conflicts: [SemanticMergeConflict] = []

        let bodyData: Data
        if let mergedBody {
            guard String(data: mergedBody, encoding: .utf8) != nil else {
                throw CommentProtocolError.invalidUTF8
            }
            bodyData = mergedBody
        } else if ourDocument.bodyData == theirDocument.bodyData {
            bodyData = ourDocument.bodyData
        } else if ourDocument.bodyData == baseDocument.bodyData {
            bodyData = theirDocument.bodyData
        } else if theirDocument.bodyData == baseDocument.bodyData {
            bodyData = ourDocument.bodyData
        } else {
            bodyData = ourDocument.bodyData
            conflicts.append(SemanticMergeConflict(
                kind: .source,
                key: "markdown",
                message: "Both sides changed Markdown. Supply an explicit merged body."
            ))
        }
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw CommentProtocolError.invalidUTF8
        }

        let baseDocumentID = baseDocument.envelope?.document.id
        let branchDocumentIDs = [
            ourDocument.envelope?.document.id,
            theirDocument.envelope?.document.id,
        ].compactMap { $0 }
        let documentID = baseDocumentID ?? branchDocumentIDs.sorted().first
        if let baseDocumentID,
           branchDocumentIDs.contains(where: { $0 != baseDocumentID }) {
            conflicts.append(SemanticMergeConflict(
                kind: .documentIdentity,
                key: "documentId",
                message: "The inputs belong to different Margin documents."
            ))
        }

        let baseItems = itemMap(baseDocument.envelope, normalizedTo: documentID)
        let ourItems = itemMap(ourDocument.envelope, normalizedTo: documentID)
        let theirItems = itemMap(theirDocument.envelope, normalizedTo: documentID)
        let annotationIDs = Set(baseItems.keys).union(ourItems.keys).union(theirItems.keys).sorted()
        var mergedItems: [MarginComment] = []
        var explicitlyDeletedIDs = Set<String>()

        for id in annotationIDs {
            let baseValue = baseItems[id]
            let ourValue = ourItems[id]
            let theirValue = theirItems[id]
            let resolved: MarginComment?
            var unresolvedConflict = false
            if ourValue == theirValue {
                resolved = ourValue
            } else if ourValue == baseValue {
                resolved = theirValue
            } else if theirValue == baseValue {
                resolved = ourValue
            } else if let choice = annotationResolutions[id] {
                switch choice {
                case .base: resolved = baseValue
                case .ours: resolved = ourValue
                case .theirs: resolved = theirValue
                case .delete:
                    resolved = nil
                    explicitlyDeletedIDs.insert(id)
                }
            } else {
                resolved = nil
                unresolvedConflict = true
                conflicts.append(SemanticMergeConflict(
                    kind: .annotation,
                    key: id,
                    message: "Both sides changed annotation '\(id)' differently."
                ))
            }
            if let resolved {
                mergedItems.append(resolved)
            } else if baseValue != nil, !unresolvedConflict {
                // A clean one-sided removal has the same subtree semantics as an
                // explicit conflict resolution to delete.
                explicitlyDeletedIDs.insert(id)
            }
        }

        // A root-thread deletion is a subtree operation throughout Margin. A
        // branch may independently add a reply while the other branch deletes
        // its root; honoring an explicit root deletion must not emit an orphan.
        if !explicitlyDeletedIDs.isEmpty {
            var removed = explicitlyDeletedIDs
            var changed = true
            while changed {
                changed = false
                for annotation in mergedItems where annotation.motivation == "replying" {
                    guard case .resource(let parentID) = annotation.target,
                          removed.contains(parentID),
                          removed.insert(annotation.id).inserted else { continue }
                    changed = true
                }
            }
            mergedItems.removeAll { removed.contains($0.id) }
        }

        let mergedIDs = Set(mergedItems.map(\.id))
        for annotation in mergedItems where annotation.motivation == "replying" {
            guard case .resource(let parentID) = annotation.target,
                  !mergedIDs.contains(parentID) else { continue }
            conflicts.append(SemanticMergeConflict(
                kind: .annotation,
                key: annotation.id,
                message: "Reply '\(annotation.id)' refers to missing parent '\(parentID)'."
            ))
        }

        mergedItems.sort {
            if $0.created != $1.created { return $0.created < $1.created }
            return $0.id < $1.id
        }

        let extensionMerge = mergeExtensions(
            base: baseDocument.envelope?.extensions ?? [:],
            ours: ourDocument.envelope?.extensions ?? [:],
            theirs: theirDocument.envelope?.extensions ?? [:]
        )
        conflicts.append(contentsOf: extensionMerge.conflicts)

        var attention: [SemanticMergeAnchorAttention] = []
        for index in mergedItems.indices where mergedItems[index].motivation == "commenting" {
            guard case .selection(let target) = mergedItems[index].target else { continue }
            let resolution = try resolver.resolve(target, in: body)
            if resolution.state == .anchored || resolution.state == .moved {
                mergedItems[index].target = .selection(try resolver.refreshed(target, in: body))
            } else {
                attention.append(SemanticMergeAnchorAttention(
                    id: mergedItems[index].id,
                    state: resolution.state,
                    candidates: resolution.candidates
                ))
            }
        }
        attention.sort { $0.id < $1.id }

        let nextRevision = max(
            baseDocument.envelope?.revision ?? 0,
            ourDocument.envelope?.revision ?? 0,
            theirDocument.envelope?.revision ?? 0
        ) + (mergedItems.isEmpty ? 0 : 1)
        let contentHash = EmbeddedCommentCodec.contentHash(bodyData)
        guard conflicts.isEmpty else {
            return SemanticMergeResult(
                data: nil,
                conflicts: conflicts.sorted(by: conflictOrder),
                anchorsNeedingAttention: attention,
                documentID: documentID,
                revision: nextRevision,
                annotationCount: mergedItems.count,
                contentSha256: contentHash
            )
        }

        let output: Data
        if mergedItems.isEmpty {
            output = bodyData
        } else {
            guard let documentID else {
                throw CommentProtocolError.invalidEnvelope("Merged annotations have no document identity.")
            }
            var envelope = preferredEnvelope(
                ours: ourDocument.envelope,
                theirs: theirDocument.envelope,
                base: baseDocument.envelope,
                documentID: documentID
            )
            envelope.items = mergedItems
            envelope.revision = nextRevision
            envelope.modified = timestamp()
            envelope.partOf.total = mergedItems.count
            envelope.document = MarginDocumentReference(id: documentID)
            envelope.id = "\(documentID)#comments"
            envelope.partOf.id = "\(documentID)#collection"
            envelope.extensions = extensionMerge.value
            output = try codec.encode(bodyData: bodyData, envelope: envelope)
        }
        return SemanticMergeResult(
            data: output,
            conflicts: [],
            anchorsNeedingAttention: attention,
            documentID: documentID,
            revision: nextRevision,
            annotationCount: mergedItems.count,
            contentSha256: contentHash
        )
    }

    private func itemMap(
        _ envelope: EmbeddedCommentEnvelope?,
        normalizedTo documentID: String?
    ) -> [String: MarginComment] {
        guard let envelope else { return [:] }
        let items: [MarginComment]
        if let documentID, envelope.document.id != documentID {
            items = envelope.items.map { annotation in
                var annotation = annotation
                switch annotation.target {
                case .resource(let id) where id == envelope.document.id:
                    annotation.target = .resource(documentID)
                case .selection(var target) where target.source.id == envelope.document.id:
                    target.source = MarginSourceReference(id: documentID)
                    annotation.target = .selection(target)
                default:
                    break
                }
                return annotation
            }
        } else {
            items = envelope.items
        }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    private func preferredEnvelope(
        ours: EmbeddedCommentEnvelope?,
        theirs: EmbeddedCommentEnvelope?,
        base: EmbeddedCommentEnvelope?,
        documentID: String
    ) -> EmbeddedCommentEnvelope {
        ours ?? theirs ?? base ?? EmbeddedCommentEnvelope(
            documentID: documentID,
            modified: timestamp()
        )
    }

    private func mergeExtensions(
        base: [String: JSONValue],
        ours: [String: JSONValue],
        theirs: [String: JSONValue]
    ) -> (value: [String: JSONValue], conflicts: [SemanticMergeConflict]) {
        let keys = Set(base.keys).union(ours.keys).union(theirs.keys).sorted()
        var value: [String: JSONValue] = [:]
        var conflicts: [SemanticMergeConflict] = []
        for key in keys {
            let baseValue = base[key]
            let ourValue = ours[key]
            let theirValue = theirs[key]
            let merged: JSONValue?
            if ourValue == theirValue {
                merged = ourValue
            } else if ourValue == baseValue {
                merged = theirValue
            } else if theirValue == baseValue {
                merged = ourValue
            } else {
                merged = nil
                conflicts.append(SemanticMergeConflict(
                    kind: .envelopeExtension,
                    key: key,
                    message: "Both sides changed envelope extension '\(key)' differently."
                ))
            }
            if let merged { value[key] = merged }
        }
        return (value, conflicts)
    }

    private func conflictOrder(_ lhs: SemanticMergeConflict, _ rhs: SemanticMergeConflict) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.key < rhs.key
    }
}
