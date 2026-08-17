import Foundation

public struct CollaborationChangeSetEvaluator: Sendable {
    private let codec: EmbeddedCommentCodec
    private let resolver: AnchorResolver
    private let reader: CollaborationTransactionEngine

    public init(
        codec: EmbeddedCommentCodec = EmbeddedCommentCodec(),
        resolver: AnchorResolver = AnchorResolver(),
        reader: CollaborationTransactionEngine = CollaborationTransactionEngine()
    ) {
        self.codec = codec
        self.resolver = resolver
        self.reader = reader
    }

    /// Evaluates ordered semantic operations against one locked base snapshot and
    /// returns exactly one final file image per touched path. No filesystem write
    /// occurs; pass the result to `CollaborationTransactionEngine.submit`.
    public func evaluate(_ changeSet: CollaborationChangeSet) throws -> [CollaborationFileMutation] {
        try changeSet.validate()
        let requestedPaths = CollaborationValidation.sortedUnique(
            changeSet.baseCursor.files.map(\.path) + changeSet.operations.map(\.path)
        )
        let locked = try reader.readState(
            root: changeSet.root,
            paths: requestedPaths
        )
        let stateByPath = Dictionary(uniqueKeysWithValues: locked.map { ($0.path, $0) })
        let baseData = Dictionary(uniqueKeysWithValues: locked.compactMap { state in
            state.data.map { (state.path, $0) }
        })
        do {
            try verifyBaseCursor(changeSet.baseCursor, dataByPath: baseData)
        } catch {
            if let replay = try replayImagesIfAlreadyApplied(
                changeSet,
                stateByPath: stateByPath
            ) {
                return replay
            }
            throw error
        }

        let grouped = Dictionary(grouping: changeSet.operations, by: \.path)
        var results: [CollaborationFileMutation] = []
        for path in grouped.keys.sorted(by: CollaborationValidation.pathLess) {
            guard let operations = grouped[path] else { continue }
            let direct = operations.compactMap { operation -> CollaborationFileMutation? in
                guard case .file(_, let mutation) = operation else { return nil }
                return mutation
            }
            let semanticCount = operations.count - direct.count
            if !direct.isEmpty {
                guard semanticCount == 0, direct.count == 1, let mutation = direct.first else {
                    throw CollaborationError.invalidChangeSet(
                        "A path cannot mix a direct final image with semantic operations."
                    )
                }
                guard let state = stateByPath[path] else {
                    throw CollaborationError.preconditionFailed(
                        path: path,
                        reason: "The direct-file target was not included in the locked read."
                    )
                }
                try verifyDirectPreconditionOrReplay(mutation, state: state)
                results.append(mutation)
                continue
            }
            guard let original = baseData[path], let base = changeSet.baseCursor[path] else {
                throw CollaborationError.invalidChangeSet(
                    "Semantic operations require an existing document in the base cursor."
                )
            }
            let output = try evaluateSemanticOperations(
                operations,
                original: original,
                base: base,
                changeSet: changeSet
            )
            results.append(try CollaborationFileMutation(
                id: "urn:margin:mutation:sha256:\(CollaborationCanonicalJSON.sha256(of: Data("\(changeSet.id)\0\(path)".utf8)))",
                path: path,
                precondition: .exact(base),
                result: .write(data: output, permissions: nil)
            ))
        }
        return results
    }

    private func evaluateSemanticOperations(
        _ operations: [CollaborationOperation],
        original: Data,
        base: CollaborationFileCursor,
        changeSet: CollaborationChangeSet
    ) throws -> Data {
        let decoded: EmbeddedCommentDocument
        do { decoded = try codec.decode(original) }
        catch {
            throw CollaborationError.invalidChangeSet(
                "Could not decode semantic target '\(base.path)': \(error.localizedDescription)"
            )
        }
        var body = decoded.body
        var envelope = decoded.envelope
        var changed = false
        let documentID = envelope?.document.id ?? Self.documentID(root: changeSet.root, path: base.path)

        for operation in operations {
            switch operation {
            case .contribution(_, let value):
                if envelope == nil {
                    envelope = EmbeddedCommentEnvelope(
                        documentID: documentID,
                        modified: changeSet.created
                    )
                }
                guard var current = envelope else { preconditionFailure() }
                try Self.validateInsertionPreconditions(value.contribution, source: body)
                let annotation = try CollaborationContributionFactory.annotation(
                    from: value.contribution,
                    actor: changeSet.actor,
                    documentID: documentID,
                    source: body,
                    requestID: changeSet.requestID,
                    stageID: changeSet.stageID
                )
                if let existing = current.items.first(where: { $0.id == annotation.id }) {
                    guard Self.isSameContribution(existing, annotation),
                          Self.transactionMatches(
                            existing.extensions["margin:transaction"],
                            changeSet: changeSet
                          ) else {
                        throw CollaborationError.invalidChangeSet(
                            "Contribution id '\(annotation.id)' already identifies different content."
                        )
                    }
                    continue
                }
                if annotation.motivation == "replying", case .resource(let parentID) = annotation.target {
                    let index = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
                    let rootID = try Self.rootID(for: parentID, in: index)
                    guard index[rootID]?.status == .open else {
                        throw CollaborationError.invalidChangeSet("Cannot reply to resolved thread '\(rootID)'.")
                    }
                }
                current.items.append(annotation)
                envelope = current
                changed = true

            case .status(let operationID, let value):
                guard var current = envelope else {
                    throw CollaborationError.invalidChangeSet("Status target '\(value.annotationID)' does not exist.")
                }
                let index = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
                let rootID = try Self.rootID(for: MarginID.annotation(value.annotationID), in: index)
                guard let rootIndex = current.items.firstIndex(where: { $0.id == rootID }) else {
                    throw CollaborationError.invalidChangeSet("Status root '\(rootID)' does not exist.")
                }
                let markerMatches = Self.transactionMatches(
                    current.items[rootIndex].extensions["margin:lastTransaction"],
                    changeSet: changeSet,
                    operationID: operationID
                )
                if current.items[rootIndex].status != value.status || !markerMatches {
                    current.items[rootIndex].status = value.status
                    current.items[rootIndex].statusModified = changeSet.created
                    current.items[rootIndex].statusModifiedBy = changeSet.actor.marginActor
                    current.items[rootIndex].modified = changeSet.created
                    current.items[rootIndex].extensions["margin:lastTransaction"] = Self.transactionValue(
                        changeSet: changeSet,
                        operationID: operationID
                    )
                    envelope = current
                    changed = true
                }

            case .acceptSuggestion(let operationID, let legacy):
                guard var current = envelope else {
                    throw CollaborationError.invalidChangeSet("Suggestion '\(legacy.contributionID)' does not exist.")
                }
                let outcome = try applySuggestion(
                    id: legacy.contributionID,
                    disposition: .accept,
                    operationID: operationID,
                    body: body,
                    envelope: &current,
                    base: base,
                    changeSet: changeSet
                )
                body = outcome.body
                envelope = current
                changed = changed || outcome.changed

            case .suggestionDisposition(let operationID, let value):
                guard var current = envelope else {
                    throw CollaborationError.invalidChangeSet("Suggestion '\(value.contributionID)' does not exist.")
                }
                let outcome = try applySuggestion(
                    id: value.contributionID,
                    disposition: value.disposition,
                    operationID: operationID,
                    body: body,
                    envelope: &current,
                    base: base,
                    changeSet: changeSet
                )
                body = outcome.body
                envelope = current
                changed = changed || outcome.changed

            case .file:
                preconditionFailure("Direct file operations are handled outside semantic evaluation.")
            }
        }

        guard changed else { return original }
        guard var finalEnvelope = envelope else {
            throw CollaborationError.invalidChangeSet("A semantic operation produced no annotation envelope.")
        }
        finalEnvelope.revision = max(1, (decoded.envelope?.revision ?? 0) + 1)
        finalEnvelope.modified = changeSet.created
        finalEnvelope.partOf.total = finalEnvelope.items.count
        do {
            return try codec.encode(bodyData: Data(body.utf8), envelope: finalEnvelope)
        } catch {
            throw CollaborationError.invalidChangeSet(
                "Semantic operations produced an invalid document: \(error.localizedDescription)"
            )
        }
    }

    private func verifyDirectPreconditionOrReplay(
        _ mutation: CollaborationFileMutation,
        state: CollaborationLockedPathState
    ) throws {
        switch mutation.result {
        case .remove where state.data == nil:
            return
        case .write(let expected, _) where state.data == expected:
            return
        default:
            break
        }

        switch mutation.precondition.existence {
        case .absent:
            guard state.data == nil else {
                throw CollaborationError.preconditionFailed(
                    path: mutation.path,
                    reason: "The direct-file target was created after the staged precondition was captured."
                )
            }
        case .exact:
            guard let data = state.data else {
                throw CollaborationError.preconditionFailed(
                    path: mutation.path,
                    reason: "The direct-file target no longer exists."
                )
            }
            guard CollaborationCanonicalJSON.sha256(of: data) == mutation.precondition.wholeFileSha256 else {
                throw CollaborationError.preconditionFailed(
                    path: mutation.path,
                    reason: "The direct-file target changed after its staged precondition was captured."
                )
            }
            if mutation.precondition.contentSha256 != nil ||
                mutation.precondition.annotationRevision != nil ||
                mutation.precondition.annotationSha256 != nil {
                let decoded: EmbeddedCommentDocument
                do { decoded = try codec.decode(data) }
                catch {
                    throw CollaborationError.preconditionFailed(
                        path: mutation.path,
                        reason: "The direct-file target can no longer be decoded for its semantic precondition."
                    )
                }
                if let expected = mutation.precondition.contentSha256,
                   DocumentRevision(data: decoded.bodyData).sha256 != expected {
                    throw CollaborationError.preconditionFailed(
                        path: mutation.path,
                        reason: "The direct-file target's logical Markdown changed."
                    )
                }
                if let expected = mutation.precondition.annotationRevision,
                   (decoded.envelope?.revision ?? 0) != expected {
                    throw CollaborationError.preconditionFailed(
                        path: mutation.path,
                        reason: "The direct-file target's annotation revision changed."
                    )
                }
                if let expected = mutation.precondition.annotationSha256,
                   (try CollaborationCanonicalJSON.sha256(of: decoded.envelope?.items ?? [])) != expected {
                    throw CollaborationError.preconditionFailed(
                        path: mutation.path,
                        reason: "The direct-file target's annotation state changed."
                    )
                }
            }
        }
    }

    private static func validateInsertionPreconditions(
        _ contribution: CollaborationContribution,
        source: String
    ) throws {
        guard case .suggestion(let details) = contribution.details,
              let range = contribution.target.range else { return }
        let scalars = Array(source.unicodeScalars)
        guard range.start >= 0, range.end > range.start, range.end <= scalars.count else {
            throw CollaborationError.preconditionFailed(
                path: contribution.target.path,
                reason: "Suggestion '\(contribution.id)' has no valid live selection."
            )
        }
        let exact = String(String.UnicodeScalarView(scalars[range.start..<range.end]))
        guard exact == details.expectedText else {
            throw CollaborationError.preconditionFailed(
                path: contribution.target.path,
                reason: "Suggestion '\(contribution.id)' no longer selects its expected text."
            )
        }
    }

    private func applySuggestion(
        id requestedID: String,
        disposition: CollaborationSuggestionDisposition,
        operationID: String,
        body: String,
        envelope: inout EmbeddedCommentEnvelope,
        base: CollaborationFileCursor,
        changeSet: CollaborationChangeSet
    ) throws -> (body: String, changed: Bool) {
        let id = MarginID.annotation(requestedID)
        guard let index = envelope.items.firstIndex(where: { $0.id == id }) else {
            throw CollaborationError.invalidChangeSet("Suggestion '\(id)' does not exist.")
        }
        var annotation = envelope.items[index]
        guard case .object(var metadata)? = annotation.extensions["margin:suggestion"],
              let expected = Self.string(in: metadata, keys: ["expectedText", "expected"]),
              let replacement = Self.string(in: metadata, keys: ["replacementText", "replacement"]),
              let storedBase = Self.string(in: metadata, keys: ["baseContentSha256", "base"]),
              let rawStatus = Self.string(in: metadata, keys: ["status"]) else {
            throw CollaborationError.invalidChangeSet("Annotation '\(id)' is not a well-formed suggestion.")
        }
        let status = Self.normalizedSuggestionStatus(rawStatus)
        let requestedStatus: CollaborationSuggestionStatus = disposition == .accept ? .accepted : .rejected
        if status == requestedStatus {
            guard Self.transactionMatches(
                annotation.extensions["margin:lastTransaction"],
                changeSet: changeSet,
                operationID: operationID
            ) else {
                throw CollaborationError.invalidChangeSet(
                    "Suggestion '\(id)' already has that disposition from another transaction."
                )
            }
            return (body, false)
        }
        guard status == .proposed else {
            throw CollaborationError.invalidChangeSet(
                "Suggestion '\(id)' is already \(status?.rawValue ?? rawStatus), not proposed."
            )
        }
        let normalizedBase = storedBase.hasPrefix("sha256:") ? String(storedBase.dropFirst(7)) : storedBase
        metadata["status"] = .string(requestedStatus.rawValue)
        metadata["expectedText"] = .string(expected)
        metadata["replacementText"] = .string(replacement)
        metadata["baseContentSha256"] = .string(normalizedBase)
        metadata[disposition == .accept ? "acceptedAt" : "rejectedAt"] = .string(changeSet.created)
        metadata[disposition == .accept ? "acceptedBy" : "rejectedBy"] = .object([
            "id": .string(changeSet.actor.id),
            "type": .string(changeSet.actor.type.rawValue),
            "name": .string(changeSet.actor.name),
        ])
        annotation.modified = changeSet.created
        annotation.extensions["margin:lastTransaction"] = Self.transactionValue(
            changeSet: changeSet,
            operationID: operationID
        )

        guard disposition == .accept else {
            annotation.extensions["margin:suggestion"] = .object(metadata)
            envelope.items[index] = annotation
            return (body, true)
        }
        guard normalizedBase == base.contentSha256 else {
            throw CollaborationError.preconditionFailed(
                path: base.path,
                reason: "Suggestion '\(id)' was authored against another logical Markdown base."
            )
        }
        guard case .selection(let target) = annotation.target else {
            throw CollaborationError.invalidChangeSet("Suggestion '\(id)' has no selection target.")
        }
        let resolution = try resolver.resolve(target, in: body)
        guard let range = resolution.range,
              resolution.state == .anchored || resolution.state == .moved else {
            throw CollaborationError.preconditionFailed(
                path: base.path,
                reason: "Suggestion '\(id)' has no unique live anchor."
            )
        }
        let scalars = Array(body.unicodeScalars)
        guard range.start >= 0, range.end <= scalars.count, range.end > range.start else {
            throw CollaborationError.invalidChangeSet("Suggestion '\(id)' has an invalid live range.")
        }
        let liveExact = String(String.UnicodeScalarView(scalars[range.start..<range.end]))
        guard liveExact == expected else {
            throw CollaborationError.preconditionFailed(
                path: base.path,
                reason: "Suggestion '\(id)' no longer selects its expected text."
            )
        }
        var updatedScalars = scalars
        updatedScalars.replaceSubrange(range.start..<range.end, with: replacement.unicodeScalars)
        let updatedBody = String(String.UnicodeScalarView(updatedScalars))
        let resultingRange = UnicodeScalarRange(
            start: range.start,
            end: range.start + replacement.unicodeScalars.count
        )
        annotation.target = replacement.isEmpty
            ? .resource(envelope.document.id)
            : try resolver.target(
                for: .range(start: resultingRange.start, end: resultingRange.end),
                documentID: envelope.document.id,
                in: updatedBody
            )
        metadata["appliedRange"] = .object([
            "start": .number(Double(resultingRange.start)),
            "end": .number(Double(resultingRange.end)),
        ])
        metadata["resultingContentSha256"] = .string(DocumentRevision(data: Data(updatedBody.utf8)).sha256)
        annotation.extensions["margin:suggestion"] = .object(metadata)
        envelope.items[index] = annotation
        try refreshSurvivingSelectors(
            in: &envelope,
            source: updatedBody,
            excluding: id
        )
        return (updatedBody, true)
    }

    private func refreshSurvivingSelectors(
        in envelope: inout EmbeddedCommentEnvelope,
        source: String,
        excluding excludedID: String
    ) throws {
        for index in envelope.items.indices where envelope.items[index].id != excludedID {
            guard envelope.items[index].motivation == "commenting",
                  case .selection(let target) = envelope.items[index].target else { continue }
            do {
                envelope.items[index].target = .selection(try resolver.refreshed(target, in: source))
            } catch CommentProtocolError.anchorNotFound {
                continue
            } catch CommentProtocolError.anchorAmbiguous {
                continue
            }
        }
    }

    private func verifyBaseCursor(
        _ cursor: CollaborationCursor,
        dataByPath: [String: Data]
    ) throws {
        guard dataByPath.count == cursor.files.count else {
            throw CollaborationError.preconditionFailed(
                path: cursor.root.path,
                reason: "The locked read did not return the complete base cursor."
            )
        }
        for expected in cursor.files {
            guard let data = dataByPath[expected.path] else {
                throw CollaborationError.preconditionFailed(path: expected.path, reason: "The base document is missing.")
            }
            let decoded = try codec.decode(data)
            let actual = try CollaborationFileCursor(
                path: expected.path,
                documentID: decoded.envelope?.document.id,
                contentSha256: DocumentRevision(data: decoded.bodyData).sha256,
                annotationRevision: decoded.envelope?.revision ?? 0,
                annotationSha256: try CollaborationCanonicalJSON.sha256(of: decoded.envelope?.items ?? []),
                wholeFileSha256: CollaborationCanonicalJSON.sha256(of: data)
            )
            guard actual == expected else {
                throw CollaborationError.preconditionFailed(
                    path: expected.path,
                    reason: "The complete base cursor no longer matches disk state."
                )
            }
        }
    }

    private func replayImagesIfAlreadyApplied(
        _ changeSet: CollaborationChangeSet,
        stateByPath: [String: CollaborationLockedPathState]
    ) throws -> [CollaborationFileMutation]? {
        let grouped = Dictionary(grouping: changeSet.operations, by: \.path)
        var results: [CollaborationFileMutation] = []
        for path in grouped.keys.sorted(by: CollaborationValidation.pathLess) {
            guard let operations = grouped[path] else { return nil }
            let direct = operations.compactMap { operation -> CollaborationFileMutation? in
                guard case .file(_, let mutation) = operation else { return nil }
                return mutation
            }
            if !direct.isEmpty {
                guard direct.count == 1, direct.count == operations.count,
                      let mutation = direct.first,
                      let state = stateByPath[path] else { return nil }
                switch mutation.result {
                case .remove:
                    guard state.data == nil else { return nil }
                case .write(let expected, _):
                    guard state.data == expected else { return nil }
                }
                results.append(mutation)
                continue
            }
            guard let data = stateByPath[path]?.data,
                  let base = changeSet.baseCursor[path] else { return nil }
            let decoded: EmbeddedCommentDocument
            do { decoded = try codec.decode(data) } catch { return nil }
            guard let envelope = decoded.envelope else { return nil }
            let index = Dictionary(uniqueKeysWithValues: envelope.items.map { ($0.id, $0) })
            for operation in operations {
                switch operation {
                case .contribution(_, let value):
                    guard let existing = index[value.contribution.id],
                          let expected = try? CollaborationContributionFactory.annotation(
                            from: value.contribution,
                            actor: changeSet.actor,
                            documentID: envelope.document.id,
                            source: decoded.body,
                            requestID: changeSet.requestID,
                            stageID: changeSet.stageID
                          ),
                          Self.isSameContribution(existing, expected),
                          Self.transactionMatches(
                            existing.extensions["margin:transaction"],
                            changeSet: changeSet
                          ) else { return nil }
                case .status(let operationID, let value):
                    guard let rootID = try? Self.rootID(for: MarginID.annotation(value.annotationID), in: index),
                          let root = index[rootID], root.status == value.status,
                          Self.transactionMatches(
                            root.extensions["margin:lastTransaction"],
                            changeSet: changeSet,
                            operationID: operationID
                          ) else { return nil }
                case .acceptSuggestion(let operationID, let value):
                    guard Self.suggestionDispositionMatches(
                        id: value.contributionID,
                        disposition: .accept,
                        operationID: operationID,
                        index: index,
                        changeSet: changeSet
                    ) else { return nil }
                case .suggestionDisposition(let operationID, let value):
                    guard Self.suggestionDispositionMatches(
                        id: value.contributionID,
                        disposition: value.disposition,
                        operationID: operationID,
                        index: index,
                        changeSet: changeSet
                    ) else { return nil }
                case .file:
                    return nil
                }
            }
            results.append(try CollaborationFileMutation(
                id: "urn:margin:mutation:sha256:\(CollaborationCanonicalJSON.sha256(of: Data("\(changeSet.id)\0\(path)".utf8)))",
                path: path,
                precondition: .exact(base),
                result: .write(data: data, permissions: nil)
            ))
        }
        return results.isEmpty ? nil : results
    }

    private static func rootID(
        for id: String,
        in index: [String: MarginComment]
    ) throws -> String {
        guard var current = index[id] else {
            throw CollaborationError.invalidChangeSet("Annotation '\(id)' does not exist.")
        }
        var visited = Set([id])
        while current.motivation == "replying" {
            guard case .resource(let parentID) = current.target,
                  let parent = index[parentID], visited.insert(parentID).inserted else {
                throw CollaborationError.invalidChangeSet("Annotation '\(id)' has a broken reply lineage.")
            }
            current = parent
        }
        guard current.motivation == "commenting", current.status != nil else {
            throw CollaborationError.invalidChangeSet("Annotation '\(id)' has no valid thread root.")
        }
        return current.id
    }

    private static func isSameContribution(_ lhs: MarginComment, _ rhs: MarginComment) -> Bool {
        guard lhs.id == rhs.id,
              lhs.type == rhs.type,
              lhs.motivation == rhs.motivation,
              lhs.creator == rhs.creator,
              lhs.body == rhs.body,
              lhs.extensions["margin:kind"] == rhs.extensions["margin:kind"] else {
            return false
        }
        if let lhsPayload = lhs.extensions["margin:contributionPayload"],
           let rhsPayload = rhs.extensions["margin:contributionPayload"] {
            return lhsPayload == rhsPayload
        }
        guard immutableTarget(lhs.target, matches: rhs.target, kind: lhs.extensions["margin:kind"]) else {
            return false
        }
        return immutableLegacyExtensions(lhs.extensions) == immutableLegacyExtensions(rhs.extensions)
    }

    private static func immutableTarget(
        _ lhs: CommentTarget,
        matches rhs: CommentTarget,
        kind: JSONValue?
    ) -> Bool {
        if kind == .string(CollaborationContributionKind.suggestion.rawValue) { return true }
        switch (lhs, rhs) {
        case (.resource(let left), .resource(let right)):
            return left == right
        case (.selection(let left), .selection(let right)):
            return left.source == right.source && left.quoteSelector?.exact == right.quoteSelector?.exact
        default:
            return false
        }
    }

    private static func immutableLegacyExtensions(
        _ values: [String: JSONValue]
    ) -> [String: JSONValue] {
        var result = values
        result.removeValue(forKey: "margin:transaction")
        result.removeValue(forKey: "margin:lastTransaction")
        result.removeValue(forKey: "margin:contributionPayload")
        if case .object(var suggestion)? = result["margin:suggestion"] {
            for key in [
                "status", "acceptedAt", "acceptedBy", "rejectedAt", "rejectedBy",
                "appliedRange", "resultingContentSha256",
            ] {
                suggestion.removeValue(forKey: key)
            }
            result["margin:suggestion"] = .object(suggestion)
        }
        return result
    }

    private static func string(in values: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = values[key] { return value }
        }
        return nil
    }

    private static func normalizedSuggestionStatus(_ raw: String) -> CollaborationSuggestionStatus? {
        if raw == "open" { return .proposed }
        return CollaborationSuggestionStatus(rawValue: raw)
    }

    private static func suggestionDispositionMatches(
        id: String,
        disposition: CollaborationSuggestionDisposition,
        operationID: String,
        index: [String: MarginComment],
        changeSet: CollaborationChangeSet
    ) -> Bool {
        guard let annotation = index[MarginID.annotation(id)],
              case .object(let metadata)? = annotation.extensions["margin:suggestion"],
              let raw = string(in: metadata, keys: ["status"]),
              normalizedSuggestionStatus(raw) == (disposition == .accept ? .accepted : .rejected) else {
            return false
        }
        return transactionMatches(
            annotation.extensions["margin:lastTransaction"],
            changeSet: changeSet,
            operationID: operationID
        )
    }

    private static func transactionValue(
        changeSet: CollaborationChangeSet,
        operationID: String? = nil
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "requestID": .string(changeSet.requestID),
            "stageID": .string(changeSet.stageID),
            "changeSetID": .string(changeSet.id),
        ]
        if let operationID { value["operationID"] = .string(operationID) }
        return .object(value)
    }

    private static func transactionMatches(
        _ value: JSONValue?,
        changeSet: CollaborationChangeSet,
        operationID: String? = nil
    ) -> Bool {
        guard case .object(let object)? = value,
              object["requestID"] == .string(changeSet.requestID),
              object["stageID"] == .string(changeSet.stageID) else { return false }
        if let operationID {
            return object["operationID"] == .string(operationID)
        }
        return true
    }

    private static func documentID(root: CollaborationRoot, path: String) -> String {
        let digest = CollaborationCanonicalJSON.sha256(of: Data("\(root.id)\0\(path)".utf8))
        return "urn:margin:document:sha256:\(digest)"
    }
}
