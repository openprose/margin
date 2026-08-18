import Foundation

public struct CommentMutationReceipt: Codable, Sendable {
    public var changed: Bool
    public var documentID: String
    public var revision: Int
    public var contentSha256: String
    public var rootID: String
    public var threadStatus: MarginCommentStatus
    public var annotation: MarginComment

    public init(
        changed: Bool,
        documentID: String,
        revision: Int,
        contentSha256: String,
        rootID: String,
        threadStatus: MarginCommentStatus = .open,
        annotation: MarginComment
    ) {
        self.changed = changed
        self.documentID = documentID
        self.revision = revision
        self.contentSha256 = contentSha256
        self.rootID = rootID
        self.threadStatus = threadStatus
        self.annotation = annotation
    }
}

public struct CommentEditUndo: Codable, Sendable {
    public var id: String
    public var message: String
    public var ifRevision: Int

    public init(id: String, message: String, ifRevision: Int) {
        self.id = id
        self.message = message
        self.ifRevision = ifRevision
    }
}

public struct CommentEditReceipt: Codable, Sendable {
    public var changed: Bool
    public var documentID: String
    public var revision: Int
    public var contentSha256: String
    public var rootID: String
    public var editor: MarginActor
    public var annotation: MarginComment
    public var previousAnnotation: MarginComment?
    public var undo: CommentEditUndo
}

public struct DeletedCommentRecord: Codable, Sendable {
    public var index: Int
    public var annotation: MarginComment

    public init(index: Int, annotation: MarginComment) {
        self.index = index
        self.annotation = annotation
    }
}

public struct CommentDeleteUndo: Codable, Sendable {
    public var ifRevision: Int
    public var expectedDocumentSha256: String
    public var records: [DeletedCommentRecord]
    public var envelopeTemplate: EmbeddedCommentEnvelope?

    public init(
        ifRevision: Int,
        records: [DeletedCommentRecord],
        expectedDocumentSha256: String = "",
        envelopeTemplate: EmbeddedCommentEnvelope? = nil
    ) {
        self.ifRevision = ifRevision
        self.expectedDocumentSha256 = expectedDocumentSha256
        self.records = records
        self.envelopeTemplate = envelopeTemplate
    }
}

public struct CommentDeleteReceipt: Codable, Sendable {
    public var changed: Bool
    public var documentID: String
    public var revision: Int
    public var contentSha256: String
    public var rootID: String
    public var deletedID: String
    public var subtree: Bool
    public var deletedCount: Int
    public var deletedIDs: [String]
    public var undo: CommentDeleteUndo
}

public struct CommentRestoreReceipt: Codable, Sendable {
    public var changed: Bool
    public var documentID: String
    public var revision: Int
    public var contentSha256: String
    public var restoredCount: Int
    public var restoredIDs: [String]
    public var annotations: [MarginComment]
}

public struct ListedComment: Codable, Sendable {
    public var annotation: MarginComment
    public var parentID: String?
    public var rootID: String
    public var depth: Int
    public var threadStatus: MarginCommentStatus
    public var anchor: AnchorResolution?

    public init(
        annotation: MarginComment,
        parentID: String?,
        rootID: String,
        depth: Int,
        threadStatus: MarginCommentStatus,
        anchor: AnchorResolution?
    ) {
        self.annotation = annotation
        self.parentID = parentID
        self.rootID = rootID
        self.depth = depth
        self.threadStatus = threadStatus
        self.anchor = anchor
    }
}

public struct CommentDocumentSnapshot: Codable, Sendable {
    public var documentID: String?
    public var version: Int?
    public var revision: Int
    public var contentSha256: String
    public var comments: [ListedComment]

    public init(
        documentID: String?,
        version: Int?,
        revision: Int,
        contentSha256: String,
        comments: [ListedComment]
    ) {
        self.documentID = documentID
        self.version = version
        self.revision = revision
        self.contentSha256 = contentSha256
        self.comments = comments
    }
}

public struct CommentValidationResult: Codable, Sendable {
    public var valid: Bool
    public var hasCommentEnvelope: Bool
    public var version: Int?
    public var revision: Int
    public var annotationCount: Int
    public var contentSha256: String

    public init(
        valid: Bool,
        hasCommentEnvelope: Bool,
        version: Int?,
        revision: Int,
        annotationCount: Int,
        contentSha256: String
    ) {
        self.valid = valid
        self.hasCommentEnvelope = hasCommentEnvelope
        self.version = version
        self.revision = revision
        self.annotationCount = annotationCount
        self.contentSha256 = contentSha256
    }
}

public struct CommentService: Sendable {
    public var codec: EmbeddedCommentCodec
    public var resolver: AnchorResolver
    public var store: AtomicDocumentStore

    public init(
        codec: EmbeddedCommentCodec = EmbeddedCommentCodec(),
        resolver: AnchorResolver = AnchorResolver(),
        store: AtomicDocumentStore = AtomicDocumentStore()
    ) {
        self.codec = codec
        self.resolver = resolver
        self.store = store
    }

    public func list(at url: URL) throws -> CommentDocumentSnapshot {
        try snapshot(from: codec.decode(store.read(at: url)))
    }

    /// Builds a comment snapshot from an already-decoded document so callers can
    /// derive several consistent views from one physical file read.
    public func snapshot(from decoded: EmbeddedCommentDocument) throws -> CommentDocumentSnapshot {
        let contentHash = EmbeddedCommentCodec.contentHash(decoded.bodyData)
        guard let envelope = decoded.envelope else {
            return CommentDocumentSnapshot(
                documentID: nil,
                version: nil,
                revision: 0,
                contentSha256: contentHash,
                comments: []
            )
        }

        let index = Dictionary(uniqueKeysWithValues: envelope.items.map { ($0.id, $0) })
        var anchorByRoot: [String: AnchorResolution?] = [:]
        var result: [ListedComment] = []
        result.reserveCapacity(envelope.items.count)
        for annotation in envelope.items {
            let lineage = try lineage(for: annotation.id, in: index)
            guard let rootID = lineage.last, let root = index[rootID], let status = root.status else {
                throw CommentProtocolError.invalidEnvelope("Comment '\(annotation.id)' has no valid root.")
            }
            let anchor: AnchorResolution?
            if let cached = anchorByRoot[rootID] {
                anchor = cached
            } else {
                switch root.target {
                case .selection(let target): anchor = try resolver.resolve(target, in: decoded.body)
                case .resource: anchor = nil
                }
                anchorByRoot[rootID] = anchor
            }
            let parentID: String?
            if annotation.motivation == "replying", case .resource(let parent) = annotation.target {
                parentID = parent
            } else {
                parentID = nil
            }
            result.append(ListedComment(
                annotation: annotation,
                parentID: parentID,
                rootID: rootID,
                depth: lineage.count - 1,
                threadStatus: status,
                anchor: anchor
            ))
        }
        return CommentDocumentSnapshot(
            documentID: envelope.document.id,
            version: envelope.version,
            revision: envelope.revision,
            contentSha256: contentHash,
            comments: result
        )
    }

    public func get(_ id: String, at url: URL) throws -> ListedComment {
        let canonicalID = MarginID.annotation(id)
        guard let value = try list(at: url).comments.first(where: { $0.annotation.id == canonicalID }) else {
            throw CommentProtocolError.commentNotFound(canonicalID)
        }
        return value
    }

    public func validate(at url: URL) throws -> CommentValidationResult {
        let decoded = try codec.decode(store.read(at: url))
        return CommentValidationResult(
            valid: true,
            hasCommentEnvelope: decoded.envelope != nil,
            version: decoded.envelope?.version,
            revision: decoded.envelope?.revision ?? 0,
            annotationCount: decoded.envelope?.items.count ?? 0,
            contentSha256: EmbeddedCommentCodec.contentHash(decoded.bodyData)
        )
    }

    public func exportJSONLD(at url: URL, prettyPrinted: Bool = true) throws -> Data? {
        let decoded = try codec.decode(store.read(at: url))
        guard let envelope = decoded.envelope else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    public func add(
        at url: URL,
        message: String,
        creator: MarginActor,
        anchor: CommentAnchorInput,
        annotationID: String? = nil,
        preconditions: CommentMutationPreconditions = CommentMutationPreconditions()
    ) throws -> CommentMutationReceipt {
        try validateMessage(message)
        try validateActor(creator)
        let id = MarginID.annotation(annotationID)
        let fallbackDocumentID = MarginID.document()
        let timestamp = Self.timestamp()

        return try store.transaction(at: url) { data in
            let decoded = try codec.decode(data)
            var envelope = try mutableEnvelope(
                decoded.envelope,
                fallbackDocumentID: fallbackDocumentID,
                timestamp: timestamp
            )
            let target = try resolver.target(
                for: anchor,
                documentID: envelope.document.id,
                in: decoded.body
            )
            let annotation = MarginComment(
                id: id,
                motivation: "commenting",
                creator: creator,
                created: timestamp,
                modified: timestamp,
                body: MarginCommentBody(value: message, purpose: "commenting"),
                target: target,
                status: .open,
                statusModified: timestamp,
                statusModifiedBy: creator
            )
            if let existing = envelope.items.first(where: { $0.id == id }) {
                guard semanticallyEquivalent(existing, annotation) else {
                    throw CommentProtocolError.idConflict(id)
                }
                return AtomicDocumentMutation(
                    data: data,
                    result: receipt(existing, rootID: existing.id, changed: false, envelope: envelope, bodyData: decoded.bodyData)
                )
            }
            try check(preconditions, envelope: decoded.envelope, bodyData: decoded.bodyData)
            envelope.items.append(annotation)
            advance(&envelope, timestamp: timestamp)
            let output = try codec.encode(bodyData: decoded.bodyData, envelope: envelope)
            return AtomicDocumentMutation(
                data: output,
                result: receipt(annotation, rootID: annotation.id, changed: true, envelope: envelope, bodyData: decoded.bodyData)
            )
        }
    }

    public func reply(
        at url: URL,
        parentID: String,
        message: String,
        creator: MarginActor,
        annotationID: String? = nil,
        reopen: Bool = false,
        preconditions: CommentMutationPreconditions = CommentMutationPreconditions()
    ) throws -> CommentMutationReceipt {
        try validateMessage(message)
        try validateActor(creator)
        let parentID = MarginID.annotation(parentID)
        let id = MarginID.annotation(annotationID)
        let timestamp = Self.timestamp()

        return try store.transaction(at: url) { data in
            let decoded = try codec.decode(data)
            guard var envelope = decoded.envelope else {
                throw CommentProtocolError.commentNotFound(parentID)
            }
            try requireV1(envelope)
            var index = Dictionary(uniqueKeysWithValues: envelope.items.map { ($0.id, $0) })
            guard index[parentID] != nil else { throw CommentProtocolError.commentNotFound(parentID) }
            let rootID = try rootID(for: parentID, in: index)
            guard let root = index[rootID] else { throw CommentProtocolError.commentNotFound(rootID) }
            let annotation = MarginComment(
                id: id,
                motivation: "replying",
                creator: creator,
                created: timestamp,
                modified: timestamp,
                body: MarginCommentBody(value: message),
                target: .resource(parentID)
            )
            if let existing = index[id] {
                guard semanticallyEquivalent(existing, annotation) else {
                    throw CommentProtocolError.idConflict(id)
                }
                return AtomicDocumentMutation(
                    data: data,
                    result: receipt(existing, rootID: rootID, changed: false, envelope: envelope, bodyData: decoded.bodyData)
                )
            }
            try check(preconditions, envelope: envelope, bodyData: decoded.bodyData)
            if root.status == .resolved && !reopen {
                throw CommentProtocolError.resolvedThread(rootID)
            }
            if root.status == .resolved {
                guard let rootIndex = envelope.items.firstIndex(where: { $0.id == rootID }) else {
                    throw CommentProtocolError.commentNotFound(rootID)
                }
                envelope.items[rootIndex].status = .open
                envelope.items[rootIndex].statusModified = timestamp
                envelope.items[rootIndex].statusModifiedBy = creator
                envelope.items[rootIndex].modified = timestamp
                index[rootID] = envelope.items[rootIndex]
            }
            envelope.items.append(annotation)
            advance(&envelope, timestamp: timestamp)
            let output = try codec.encode(bodyData: decoded.bodyData, envelope: envelope)
            return AtomicDocumentMutation(
                data: output,
                result: receipt(annotation, rootID: rootID, changed: true, envelope: envelope, bodyData: decoded.bodyData)
            )
        }
    }

    public func edit(
        at url: URL,
        id: String,
        message: String,
        editor: MarginActor,
        preconditions: CommentMutationPreconditions = CommentMutationPreconditions()
    ) throws -> CommentEditReceipt {
        try validateMessage(message)
        try validateActor(editor)
        let id = MarginID.annotation(id)
        let timestamp = Self.timestamp()
        return try store.transaction(at: url) { data in
            let decoded = try codec.decode(data)
            guard var envelope = decoded.envelope else { throw CommentProtocolError.commentNotFound(id) }
            try requireV1(envelope)
            try check(preconditions, envelope: envelope, bodyData: decoded.bodyData)
            let index = Dictionary(uniqueKeysWithValues: envelope.items.map { ($0.id, $0) })
            guard let original = index[id],
                  let annotationIndex = envelope.items.firstIndex(where: { $0.id == id }) else {
                throw CommentProtocolError.commentNotFound(id)
            }
            let rootID = try rootID(for: id, in: index)
            if original.body.value == message {
                return AtomicDocumentMutation(
                    data: data,
                    result: CommentEditReceipt(
                        changed: false,
                        documentID: envelope.document.id,
                        revision: envelope.revision,
                        contentSha256: EmbeddedCommentCodec.contentHash(decoded.bodyData),
                        rootID: rootID,
                        editor: editor,
                        annotation: original,
                        previousAnnotation: nil,
                        undo: CommentEditUndo(id: id, message: original.body.value, ifRevision: envelope.revision)
                    )
                )
            }
            envelope.items[annotationIndex].body.value = message
            envelope.items[annotationIndex].modified = timestamp
            envelope.items[annotationIndex].extensions["margin:lastModifiedBy"] = .object([
                "id": .string(editor.id),
                "type": .string(editor.type.rawValue),
                "name": .string(editor.name),
            ])
            advance(&envelope, timestamp: timestamp)
            let updated = envelope.items[annotationIndex]
            let output = try codec.encode(bodyData: decoded.bodyData, envelope: envelope)
            return AtomicDocumentMutation(
                data: output,
                result: CommentEditReceipt(
                    changed: true,
                    documentID: envelope.document.id,
                    revision: envelope.revision,
                    contentSha256: EmbeddedCommentCodec.contentHash(decoded.bodyData),
                    rootID: rootID,
                    editor: editor,
                    annotation: updated,
                    previousAnnotation: original,
                    undo: CommentEditUndo(id: id, message: original.body.value, ifRevision: envelope.revision)
                )
            )
        }
    }

    /// Deletes one leaf annotation, or the target and every descendant when
    /// `subtree` is explicitly true. Removing a non-leaf without `subtree`
    /// fails closed so replies can never be orphaned.
    public func delete(
        at url: URL,
        id: String,
        subtree: Bool = false,
        preconditions: CommentMutationPreconditions = CommentMutationPreconditions()
    ) throws -> CommentDeleteReceipt {
        let id = MarginID.annotation(id)
        let timestamp = Self.timestamp()
        return try store.transaction(at: url) { data in
            let decoded = try codec.decode(data)
            guard var envelope = decoded.envelope else { throw CommentProtocolError.commentNotFound(id) }
            try requireV1(envelope)
            try check(preconditions, envelope: envelope, bodyData: decoded.bodyData)
            let index = Dictionary(uniqueKeysWithValues: envelope.items.map { ($0.id, $0) })
            guard index[id] != nil else { throw CommentProtocolError.commentNotFound(id) }
            let rootID = try rootID(for: id, in: index)
            let descendants = descendantIDs(of: id, in: envelope.items)
            if !subtree, !descendants.isEmpty {
                throw CommentProtocolError.commentHasReplies(id: id, count: descendants.count)
            }
            let deletedIDs = Set([id] + (subtree ? Array(descendants) : []))
            let records = envelope.items.enumerated().compactMap { offset, annotation in
                deletedIDs.contains(annotation.id)
                    ? DeletedCommentRecord(index: offset, annotation: annotation)
                    : nil
            }
            envelope.items.removeAll { deletedIDs.contains($0.id) }
            advance(&envelope, timestamp: timestamp)
            let output = try codec.encode(bodyData: decoded.bodyData, envelope: envelope)
            var envelopeTemplate: EmbeddedCommentEnvelope?
            if envelope.items.isEmpty {
                envelope.contentByteLength = decoded.bodyData.count
                envelope.contentSha256 = EmbeddedCommentCodec.contentHash(decoded.bodyData)
                envelopeTemplate = envelope
            }
            return AtomicDocumentMutation(
                data: output,
                result: CommentDeleteReceipt(
                    changed: true,
                    documentID: envelope.document.id,
                    revision: envelope.revision,
                    contentSha256: EmbeddedCommentCodec.contentHash(decoded.bodyData),
                    rootID: rootID,
                    deletedID: id,
                    subtree: subtree,
                    deletedCount: records.count,
                    deletedIDs: records.map { $0.annotation.id },
                    undo: CommentDeleteUndo(
                        ifRevision: envelope.revision,
                        records: records,
                        expectedDocumentSha256: Self.documentHash(output),
                        envelopeTemplate: envelopeTemplate
                    )
                )
            )
        }
    }

    /// Restores an exact deletion receipt only while the document is still in
    /// the state produced by that delete. The full-file digest closes the gap
    /// left when deleting the final thread removes the envelope (and therefore
    /// its persisted revision) entirely.
    public func restoreDeletion(
        at url: URL,
        undo: CommentDeleteUndo
    ) throws -> CommentRestoreReceipt {
        guard !undo.records.isEmpty else {
            throw CommentProtocolError.invalidEnvelope("A deletion undo token has no annotations.")
        }
        guard !undo.expectedDocumentSha256.isEmpty else {
            throw CommentProtocolError.invalidEnvelope("A deletion undo token has no document-state digest.")
        }
        let timestamp = Self.timestamp()
        return try store.transaction(at: url) { data in
            let actualDocumentHash = Self.documentHash(data)
            guard normalizedHash(undo.expectedDocumentSha256) == normalizedHash(actualDocumentHash) else {
                throw CommentProtocolError.undoConflict(
                    expected: undo.expectedDocumentSha256,
                    actual: actualDocumentHash
                )
            }
            let decoded = try codec.decode(data)
            var envelope: EmbeddedCommentEnvelope
            if let existing = decoded.envelope {
                try requireV1(existing)
                guard existing.revision == undo.ifRevision else {
                    throw CommentProtocolError.revisionConflict(
                        expected: undo.ifRevision,
                        actual: existing.revision
                    )
                }
                envelope = existing
            } else {
                guard var template = undo.envelopeTemplate else {
                    throw CommentProtocolError.invalidEnvelope(
                        "Restoring a removed comment envelope requires its undo template."
                    )
                }
                try requireV1(template)
                guard template.revision == undo.ifRevision else {
                    throw CommentProtocolError.revisionConflict(
                        expected: undo.ifRevision,
                        actual: template.revision
                    )
                }
                guard template.items.isEmpty else {
                    throw CommentProtocolError.invalidEnvelope("A deletion undo template must not contain annotations.")
                }
                guard normalizedHash(template.contentSha256) ==
                        normalizedHash(EmbeddedCommentCodec.contentHash(decoded.bodyData)) else {
                    throw CommentProtocolError.contentConflict(
                        expected: template.contentSha256,
                        actual: EmbeddedCommentCodec.contentHash(decoded.bodyData)
                    )
                }
                template.contentByteLength = decoded.bodyData.count
                envelope = template
            }

            let sortedRecords = undo.records.sorted { lhs, rhs in
                if lhs.index != rhs.index { return lhs.index < rhs.index }
                return lhs.annotation.id < rhs.annotation.id
            }
            guard Set(sortedRecords.map(\.index)).count == sortedRecords.count,
                  Set(sortedRecords.map { $0.annotation.id }).count == sortedRecords.count else {
                throw CommentProtocolError.invalidEnvelope("A deletion undo token has duplicate indexes or ids.")
            }
            let existingIDs = Set(envelope.items.map(\.id))
            if let conflict = sortedRecords.first(where: { existingIDs.contains($0.annotation.id) }) {
                throw CommentProtocolError.idConflict(conflict.annotation.id)
            }
            for record in sortedRecords {
                guard record.index >= 0, record.index <= envelope.items.count else {
                    throw CommentProtocolError.invalidEnvelope(
                        "Undo index \(record.index) is outside 0...\(envelope.items.count)."
                    )
                }
                envelope.items.insert(record.annotation, at: record.index)
            }
            envelope.partOf.total = envelope.items.count
            try codec.validate(envelope)
            advance(&envelope, timestamp: timestamp)
            let output = try codec.encode(bodyData: decoded.bodyData, envelope: envelope)
            return AtomicDocumentMutation(
                data: output,
                result: CommentRestoreReceipt(
                    changed: true,
                    documentID: envelope.document.id,
                    revision: envelope.revision,
                    contentSha256: EmbeddedCommentCodec.contentHash(decoded.bodyData),
                    restoredCount: sortedRecords.count,
                    restoredIDs: sortedRecords.map { $0.annotation.id },
                    annotations: sortedRecords.map(\.annotation)
                )
            )
        }
    }

    public func resolve(
        at url: URL,
        id: String,
        actor: MarginActor,
        preconditions: CommentMutationPreconditions = CommentMutationPreconditions()
    ) throws -> CommentMutationReceipt {
        try setStatus(.resolved, at: url, id: id, actor: actor, preconditions: preconditions)
    }

    public func reopen(
        at url: URL,
        id: String,
        actor: MarginActor,
        preconditions: CommentMutationPreconditions = CommentMutationPreconditions()
    ) throws -> CommentMutationReceipt {
        try setStatus(.open, at: url, id: id, actor: actor, preconditions: preconditions)
    }

    public func reanchor(
        at url: URL,
        id: String,
        anchor: CommentAnchorInput,
        preconditions: CommentMutationPreconditions = CommentMutationPreconditions()
    ) throws -> CommentMutationReceipt {
        let id = MarginID.annotation(id)
        let timestamp = Self.timestamp()
        return try store.transaction(at: url) { data in
            let decoded = try codec.decode(data)
            guard var envelope = decoded.envelope else { throw CommentProtocolError.commentNotFound(id) }
            try requireV1(envelope)
            try check(preconditions, envelope: envelope, bodyData: decoded.bodyData)
            let index = Dictionary(uniqueKeysWithValues: envelope.items.map { ($0.id, $0) })
            guard index[id] != nil else { throw CommentProtocolError.commentNotFound(id) }
            let rootID = try rootID(for: id, in: index)
            guard let rootIndex = envelope.items.firstIndex(where: { $0.id == rootID }) else {
                throw CommentProtocolError.commentNotFound(rootID)
            }
            let target = try resolver.target(
                for: anchor,
                documentID: envelope.document.id,
                in: decoded.body
            )
            if envelope.items[rootIndex].target == target {
                return AtomicDocumentMutation(
                    data: data,
                    result: receipt(envelope.items[rootIndex], rootID: rootID, changed: false, envelope: envelope, bodyData: decoded.bodyData)
                )
            }
            envelope.items[rootIndex].target = target
            envelope.items[rootIndex].modified = timestamp
            advance(&envelope, timestamp: timestamp)
            let output = try codec.encode(bodyData: decoded.bodyData, envelope: envelope)
            return AtomicDocumentMutation(
                data: output,
                result: receipt(envelope.items[rootIndex], rootID: rootID, changed: true, envelope: envelope, bodyData: decoded.bodyData)
            )
        }
    }

    public func autoReanchor(
        at url: URL,
        id: String,
        preconditions: CommentMutationPreconditions = CommentMutationPreconditions()
    ) throws -> CommentMutationReceipt {
        let listed = try get(id, at: url)
        guard case .selection(let selection) = listed.annotation.target else {
            throw CommentProtocolError.invalidAnchor("Document-level comments do not need reanchoring.")
        }
        let decoded = try codec.decode(store.read(at: url))
        let refreshed = try resolver.refreshed(selection, in: decoded.body)
        guard let position = refreshed.positionSelector else {
            throw CommentProtocolError.invalidAnchor("Refreshed anchor has no position.")
        }
        return try reanchor(
            at: url,
            id: id,
            anchor: .range(start: position.start, end: position.end, expectedExact: refreshed.quoteSelector?.exact),
            preconditions: preconditions
        )
    }

    private func setStatus(
        _ status: MarginCommentStatus,
        at url: URL,
        id: String,
        actor: MarginActor,
        preconditions: CommentMutationPreconditions
    ) throws -> CommentMutationReceipt {
        try validateActor(actor)
        let id = MarginID.annotation(id)
        let timestamp = Self.timestamp()
        return try store.transaction(at: url) { data in
            let decoded = try codec.decode(data)
            guard var envelope = decoded.envelope else { throw CommentProtocolError.commentNotFound(id) }
            try requireV1(envelope)
            try check(preconditions, envelope: envelope, bodyData: decoded.bodyData)
            let index = Dictionary(uniqueKeysWithValues: envelope.items.map { ($0.id, $0) })
            guard index[id] != nil else { throw CommentProtocolError.commentNotFound(id) }
            let rootID = try rootID(for: id, in: index)
            guard let rootIndex = envelope.items.firstIndex(where: { $0.id == rootID }) else {
                throw CommentProtocolError.commentNotFound(rootID)
            }
            if envelope.items[rootIndex].status == status {
                return AtomicDocumentMutation(
                    data: data,
                    result: receipt(envelope.items[rootIndex], rootID: rootID, changed: false, envelope: envelope, bodyData: decoded.bodyData)
                )
            }
            envelope.items[rootIndex].status = status
            envelope.items[rootIndex].statusModified = timestamp
            envelope.items[rootIndex].statusModifiedBy = actor
            envelope.items[rootIndex].modified = timestamp
            advance(&envelope, timestamp: timestamp)
            let output = try codec.encode(bodyData: decoded.bodyData, envelope: envelope)
            return AtomicDocumentMutation(
                data: output,
                result: receipt(envelope.items[rootIndex], rootID: rootID, changed: true, envelope: envelope, bodyData: decoded.bodyData)
            )
        }
    }

    private func mutableEnvelope(
        _ existing: EmbeddedCommentEnvelope?,
        fallbackDocumentID: String,
        timestamp: String
    ) throws -> EmbeddedCommentEnvelope {
        if let existing {
            try requireV1(existing)
            return existing
        }
        return EmbeddedCommentEnvelope(documentID: fallbackDocumentID, modified: timestamp)
    }

    private func requireV1(_ envelope: EmbeddedCommentEnvelope) throws {
        guard envelope.version == 1 else { throw CommentProtocolError.unsupportedVersion(envelope.version) }
    }

    private func check(
        _ preconditions: CommentMutationPreconditions,
        envelope: EmbeddedCommentEnvelope?,
        bodyData: Data
    ) throws {
        let actualRevision = envelope?.revision ?? 0
        if let expected = preconditions.revision, expected != actualRevision {
            throw CommentProtocolError.revisionConflict(expected: expected, actual: actualRevision)
        }
        let actualHash = EmbeddedCommentCodec.contentHash(bodyData)
        if let expected = preconditions.contentSha256,
           normalizedHash(expected) != normalizedHash(actualHash) {
            throw CommentProtocolError.contentConflict(expected: expected, actual: actualHash)
        }
    }

    private func advance(_ envelope: inout EmbeddedCommentEnvelope, timestamp: String) {
        envelope.revision += 1
        envelope.modified = timestamp
        envelope.partOf.total = envelope.items.count
    }

    private func rootID(for id: String, in index: [String: MarginComment]) throws -> String {
        guard index[id] != nil else { throw CommentProtocolError.commentNotFound(id) }
        guard let root = try lineage(for: id, in: index).last else {
            throw CommentProtocolError.invalidEnvelope("Comment '\(id)' has no root.")
        }
        return root
    }

    private func descendantIDs(of id: String, in annotations: [MarginComment]) -> Set<String> {
        var children: [String: [String]] = [:]
        for annotation in annotations where annotation.motivation == "replying" {
            if case .resource(let parentID) = annotation.target {
                children[parentID, default: []].append(annotation.id)
            }
        }
        var result: Set<String> = []
        var pending = children[id] ?? []
        while let current = pending.popLast() {
            if result.insert(current).inserted {
                pending.append(contentsOf: children[current] ?? [])
            }
        }
        return result
    }

    /// Returns self, parent, ... root.
    private func lineage(for id: String, in index: [String: MarginComment]) throws -> [String] {
        guard var current = index[id] else { throw CommentProtocolError.commentNotFound(id) }
        var result = [id]
        var visited: Set<String> = [id]
        while current.motivation == "replying" {
            guard case .resource(let parentID) = current.target,
                  let parent = index[parentID] else {
                throw CommentProtocolError.invalidEnvelope("Reply '\(current.id)' has no parent.")
            }
            guard visited.insert(parentID).inserted else {
                throw CommentProtocolError.invalidEnvelope("Thread containing '\(id)' has a cycle.")
            }
            result.append(parentID)
            current = parent
        }
        return result
    }

    private func receipt(
        _ annotation: MarginComment,
        rootID: String,
        changed: Bool,
        envelope: EmbeddedCommentEnvelope,
        bodyData: Data
    ) -> CommentMutationReceipt {
        CommentMutationReceipt(
            changed: changed,
            documentID: envelope.document.id,
            revision: envelope.revision,
            contentSha256: EmbeddedCommentCodec.contentHash(bodyData),
            rootID: rootID,
            threadStatus: envelope.items.first(where: { $0.id == rootID })?.status ?? .open,
            annotation: annotation
        )
    }

    private func semanticallyEquivalent(_ lhs: MarginComment, _ rhs: MarginComment) -> Bool {
        lhs.id == rhs.id &&
            lhs.motivation == rhs.motivation &&
            lhs.creator == rhs.creator &&
            lhs.body == rhs.body &&
            equivalentTarget(lhs.target, rhs.target)
    }

    private func equivalentTarget(_ lhs: CommentTarget, _ rhs: CommentTarget) -> Bool {
        switch (lhs, rhs) {
        case (.resource(let left), .resource(let right)):
            return left == right
        case (.selection(let left), .selection(let right)):
            return left.source == right.source && left.quoteSelector?.exact == right.quoteSelector?.exact
        default:
            return false
        }
    }

    private func validateMessage(_ message: String) throws {
        guard !message.isEmpty else {
            throw CommentProtocolError.invalidEnvelope("A comment body cannot be empty.")
        }
        guard message.utf8.count <= 1_048_576 else {
            throw CommentProtocolError.invalidEnvelope("A comment body cannot exceed one MiB.")
        }
    }

    private func validateActor(_ actor: MarginActor) throws {
        guard !actor.id.isEmpty, !actor.name.isEmpty else {
            throw CommentProtocolError.invalidEnvelope("A comment creator needs an id and name.")
        }
    }

    private func normalizedHash(_ value: String) -> String {
        value.hasPrefix("sha256:") ? String(value.dropFirst(7)).lowercased() : value.lowercased()
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    private static func documentHash(_ data: Data) -> String {
        "sha256:\(DocumentRevision(data: data).sha256)"
    }
}
