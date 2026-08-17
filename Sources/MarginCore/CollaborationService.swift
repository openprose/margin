import Darwin
import Foundation

public struct CollaborationContextLimits: Codable, Hashable, Sendable {
    public static let `default` = CollaborationContextLimits()
    public static let maximumSerializedBytes = 8 * 1_024 * 1_024

    public let discovery: CollaborationDiscoveryLimits
    public let maxHeadingsPerFile: Int
    public let maxContributionsPerFile: Int
    public let maxBodyPreviewBytes: Int
    public let maxActivityRecords: Int
    public let maxSerializedBytes: Int

    public init(
        discovery: CollaborationDiscoveryLimits = .default,
        maxHeadingsPerFile: Int = 32,
        maxContributionsPerFile: Int = 64,
        maxBodyPreviewBytes: Int = 240,
        maxActivityRecords: Int = 1_024,
        maxSerializedBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.discovery = discovery
        self.maxHeadingsPerFile = maxHeadingsPerFile
        self.maxContributionsPerFile = maxContributionsPerFile
        self.maxBodyPreviewBytes = maxBodyPreviewBytes
        self.maxActivityRecords = maxActivityRecords
        self.maxSerializedBytes = maxSerializedBytes
    }

    public func validate() throws {
        try discovery.validate()
        guard (0...4_096).contains(maxHeadingsPerFile),
              (0...16_384).contains(maxContributionsPerFile),
              (0...65_536).contains(maxBodyPreviewBytes),
              (0...CollaborationActivityStore.maximumSupportedRecords).contains(maxActivityRecords),
              (1_048_576...Self.maximumSerializedBytes).contains(maxSerializedBytes) else {
            throw CollaborationError.invalidRoot("Context result limits are outside their supported bounds.")
        }
    }
}

public struct CollaborationContextContribution: Codable, Hashable, Sendable {
    public let reference: String
    public let id: String
    public let rootID: String
    public let parentID: String?
    public let path: String
    public let kind: CollaborationContributionKind
    public let actorID: String
    public let actorName: String
    public let bodyPreview: String
    public let created: String
    public let modified: String
    public let threadStatus: MarginCommentStatus
    public let range: UnicodeScalarRange?
    public let anchorState: AnchorResolutionState?
    public let assigneeID: String?
    public let priority: CollaborationPriority?
}

public struct CollaborationContextFile: Codable, Hashable, Sendable {
    public let path: String
    public let cursor: CollaborationFileCursor
    public let bytes: Int
    public let characters: Int
    public let lines: Int
    public let words: Int
    public let outline: [MarkdownHeading]
    public let contributions: [CollaborationContextContribution]
    public let omittedHeadingCount: Int
    public let omittedContributionCount: Int
}

public struct CollaborationContextTruncation: Codable, Hashable, Sendable {
    public let discovery: CollaborationDiscoveryResult
    public let omittedHeadingCount: Int
    public let omittedContributionCount: Int
    public let omittedActivityCount: Int
    public let hitOutputByteLimit: Bool

    public var isTruncated: Bool {
        discovery.isTruncated || omittedHeadingCount > 0 || omittedContributionCount > 0
            || omittedActivityCount > 0 || hitOutputByteLimit
    }
}

public enum CollaborationAvailableAction: String, Codable, CaseIterable, Sendable {
    case addContribution = "add-contribution"
    case stageChangeSet = "stage-change-set"
    case submitChangeSet = "submit-change-set"
    case acceptSuggestion = "accept-suggestion"
    case createHandoff = "create-handoff"
    case reconcile
}

public struct CollaborationContextSnapshot: Codable, Hashable, Sendable {
    public let root: CollaborationRoot
    public let cursor: CollaborationCursor
    public let files: [CollaborationContextFile]
    public let actors: [CollaborationActor]
    public let activity: [CollaborationActorActivity]
    public let truncation: CollaborationContextTruncation
    public let availableActions: [CollaborationAvailableAction]
}

public struct CollaborationContextService: Sendable {
    private let codec: EmbeddedCommentCodec
    private let comments: CommentService
    private let cursors: CollaborationCursorService
    private let activityStore: CollaborationActivityStore
    private let reader: CollaborationTransactionEngine

    public init(
        codec: EmbeddedCommentCodec = EmbeddedCommentCodec(),
        comments: CommentService = CommentService(),
        cursors: CollaborationCursorService = CollaborationCursorService(),
        activityStore: CollaborationActivityStore = CollaborationActivityStore(),
        reader: CollaborationTransactionEngine = CollaborationTransactionEngine()
    ) {
        self.codec = codec
        self.comments = comments
        self.cursors = cursors
        self.activityStore = activityStore
        self.reader = reader
    }

    /// Produces the complete bounded collaboration context on demand. Each selected
    /// document is physically read once during this call.
    public func context(
        root: CollaborationRoot,
        paths: [String]? = nil,
        limits: CollaborationContextLimits = .default
    ) throws -> CollaborationContextSnapshot {
        try reader.withLockedRoot(root: root) {
            try contextWhileLocked(root: root, paths: paths, limits: limits)
        }
    }

    private func contextWhileLocked(
        root: CollaborationRoot,
        paths: [String]?,
        limits: CollaborationContextLimits
    ) throws -> CollaborationContextSnapshot {
        try limits.validate()
        let discovery = try cursors.discover(root: root, paths: paths, limits: limits.discovery)
        guard !discovery.paths.isEmpty else {
            throw CollaborationError.invalidCursor("The collaboration context contains no selected Markdown document.")
        }

        var files: [CollaborationContextFile] = []
        var actorsByID: [String: CollaborationActor] = [:]
        var activityRecords: [CollaborationActivityRecord] = []
        var openAuthored: [String: Set<String>] = [:]
        var assignedOpen: [String: Set<String>] = [:]
        var assignmentTimes: [String: [String]] = [:]
        var usedReferences = Set<String>()
        var omittedHeadings = 0
        var omittedContributions = 0

        for path in discovery.paths {
            let url = try CollaborationPathResolver.resolve(root: root, relativePath: path, allowMissingFinal: false)
            let data = try CollaborationPathResolver.readBounded(
                url,
                maximumBytes: limits.discovery.maxBytes
            )
            let decoded: EmbeddedCommentDocument
            do {
                decoded = try codec.decode(data)
            } catch {
                throw CollaborationError.invalidCursor("Could not decode '\(path)': \(error.localizedDescription)")
            }
            let fileCursor = try CollaborationFileCursor(
                path: path,
                documentID: decoded.envelope?.document.id,
                contentSha256: DocumentRevision(data: decoded.bodyData).sha256,
                annotationRevision: decoded.envelope?.revision ?? 0,
                annotationSha256: try CollaborationCanonicalJSON.sha256(of: decoded.envelope?.items ?? []),
                wholeFileSha256: CollaborationCanonicalJSON.sha256(of: data)
            )
            let outline = MarkdownOutline(markdown: decoded.body).headings
            omittedHeadings += max(0, outline.count - limits.maxHeadingsPerFile)

            let snapshot = try comments.snapshot(from: decoded)
            let selected = Array(snapshot.comments.prefix(limits.maxContributionsPerFile))
            omittedContributions += max(0, snapshot.comments.count - selected.count)
            let contextContributions = try selected.map { listed in
                let annotation = listed.annotation
                let actor = try CollaborationActor(annotation.creator)
                actorsByID[actor.id] = actor
                if let modifier = annotation.statusModifiedBy {
                    let statusActor = try CollaborationActor(modifier)
                    actorsByID[statusActor.id] = statusActor
                }
                let kind = Self.kind(from: annotation)
                let range = listed.anchor?.range
                let reference = CollaborationShortReference.make(
                    path: path,
                    annotationID: annotation.id,
                    used: &usedReferences
                )
                if listed.threadStatus == .open {
                    openAuthored[annotation.creator.id, default: []].insert(annotation.id)
                    if let assignee = Self.stringExtension("margin:assignee", in: annotation.extensions) {
                        assignedOpen[assignee, default: []].insert(annotation.id)
                        assignmentTimes[assignee, default: []].append(annotation.modified)
                    }
                }
                let contribution = CollaborationContextContribution(
                    reference: reference,
                    id: annotation.id,
                    rootID: listed.rootID,
                    parentID: listed.parentID,
                    path: path,
                    kind: kind,
                    actorID: annotation.creator.id,
                    actorName: annotation.creator.name,
                    bodyPreview: Self.preview(annotation.body.value, maximumBytes: limits.maxBodyPreviewBytes),
                    created: annotation.created,
                    modified: annotation.modified,
                    threadStatus: listed.threadStatus,
                    range: range,
                    anchorState: listed.anchor?.state,
                    assigneeID: Self.stringExtension("margin:assignee", in: annotation.extensions),
                    priority: Self.priority(from: annotation.extensions)
                )
                activityRecords.append(try CollaborationActivityRecord(
                    id: "urn:margin:activity:sha256:\(CollaborationCanonicalJSON.sha256(of: Data("\(root.id)\0\(path)\0\(annotation.id)\0\(annotation.modified)".utf8)))",
                    rootID: root.id,
                    actorID: annotation.creator.id,
                    occurredAt: annotation.modified,
                    kind: .contributionObserved,
                    paths: [path],
                    contributionIDs: [annotation.id],
                    contributionKinds: [kind],
                    extensions: [
                        "margin:contributionKindsByID": .object([
                            annotation.id: .string(kind.rawValue),
                        ]),
                    ]
                ))
                return contribution
            }
            // The outline above is the only structural Markdown parse needed by
            // context. Compute the remaining scalar statistics directly instead
            // of constructing DocumentInspection, which would parse it again.
            let characters = decoded.body.count
            let lines = TextCoordinates.lineCount(in: decoded.body)
            let words = decoded.body.split(whereSeparator: { $0.isWhitespace }).count
            files.append(CollaborationContextFile(
                path: path,
                cursor: fileCursor,
                bytes: data.count,
                characters: characters,
                lines: lines,
                words: words,
                outline: Array(outline.prefix(limits.maxHeadingsPerFile)),
                contributions: contextContributions,
                omittedHeadingCount: max(0, outline.count - limits.maxHeadingsPerFile),
                omittedContributionCount: max(0, snapshot.comments.count - selected.count)
            ))
        }

        let cursor = try CollaborationCursor(root: root, files: files.map(\.cursor))
        let selectedPaths = Set(discovery.paths)
        let durableListing = try activityStore.list(
            root: root,
            limit: limits.maxActivityRecords
        )
        let durableActivity = durableListing.records.filter {
            !$0.paths.allSatisfy { !selectedPaths.contains($0) }
        }
        for record in durableActivity {
            if case .object(let actorValue)? = record.extensions["margin:actor"],
               case .string(let id)? = actorValue["id"],
               case .string(let rawType)? = actorValue["type"],
               case .string(let name)? = actorValue["name"],
               let type = MarginActorType(rawValue: rawType),
               actorsByID[id] == nil,
               let actor = try? CollaborationActor(id: id, type: type, name: name) {
                actorsByID[id] = actor
            }
        }
        activityRecords.append(contentsOf: durableActivity)
        let baseActivity = CollaborationActivity.summarize(activityRecords)
        let activityByID = Dictionary(uniqueKeysWithValues: baseActivity.map { ($0.actorID, $0) })
        let activityIDs = Set(activityByID.keys).union(openAuthored.keys).union(assignedOpen.keys)
        let activity = activityIDs.map { actorID -> CollaborationActorActivity in
            let base = activityByID[actorID]
            let observedTimes = assignmentTimes[actorID, default: []].sorted()
            return CollaborationActorActivity(
                actorID: actorID,
                firstObservedAt: base?.firstObservedAt ?? observedTimes.first ?? "",
                lastObservedAt: base?.lastObservedAt ?? observedTimes.last ?? "",
                contributionCounts: base?.contributionCounts ?? [:],
                filesTouched: base?.filesTouched ?? [],
                authoredContributionIDs: base?.authoredContributionIDs ?? [],
                openAuthoredContributionIDs: Array(openAuthored[actorID] ?? []).sorted(by: CollaborationValidation.pathLess),
                assignedOpenContributionIDs: Array(assignedOpen[actorID] ?? []).sorted(by: CollaborationValidation.pathLess)
            )
        }.sorted { CollaborationValidation.pathLess($0.actorID, $1.actorID) }
        let snapshot = CollaborationContextSnapshot(
            root: root,
            cursor: cursor,
            files: files,
            actors: actorsByID.values.sorted { CollaborationValidation.pathLess($0.id, $1.id) },
            activity: activity,
            truncation: CollaborationContextTruncation(
                discovery: discovery,
                omittedHeadingCount: omittedHeadings,
                omittedContributionCount: omittedContributions,
                omittedActivityCount: durableListing.omittedCount,
                hitOutputByteLimit: false
            ),
            availableActions: CollaborationAvailableAction.allCases
        )
        return try Self.enforceOutputBudget(snapshot, maximumBytes: limits.maxSerializedBytes)
    }

    private static func enforceOutputBudget(
        _ initial: CollaborationContextSnapshot,
        maximumBytes: Int
    ) throws -> CollaborationContextSnapshot {
        var files = initial.files
        var actors = initial.actors
        var activity = initial.activity
        var omittedFiles = initial.truncation.discovery.omittedFileCount
        var omittedHeadings = initial.truncation.omittedHeadingCount
        var omittedContributions = initial.truncation.omittedContributionCount
        var omittedActivity = initial.truncation.omittedActivityCount
        var hitOutputLimit = false

        func makeSnapshot() throws -> CollaborationContextSnapshot {
            let retainedPaths = files.map(\.path)
            let discovery = CollaborationDiscoveryResult(
                paths: retainedPaths,
                bytes: files.reduce(0) { $0 + $1.bytes },
                omittedFileCount: omittedFiles,
                hitFileLimit: initial.truncation.discovery.hitFileLimit,
                hitByteLimit: initial.truncation.discovery.hitByteLimit,
                hitDepthLimit: initial.truncation.discovery.hitDepthLimit
            )
            return CollaborationContextSnapshot(
                root: initial.root,
                cursor: try CollaborationCursor(root: initial.root, files: files.map(\.cursor)),
                files: files,
                actors: actors,
                activity: activity,
                truncation: CollaborationContextTruncation(
                    discovery: discovery,
                    omittedHeadingCount: omittedHeadings,
                    omittedContributionCount: omittedContributions,
                    omittedActivityCount: omittedActivity,
                    hitOutputByteLimit: hitOutputLimit
                ),
                availableActions: initial.availableActions
            )
        }

        func encodedSize(_ snapshot: CollaborationContextSnapshot) throws -> Int {
            try CollaborationCanonicalJSON.encode(snapshot).count
        }

        var snapshot = try makeSnapshot()
        guard try encodedSize(snapshot) > maximumBytes else { return snapshot }
        hitOutputLimit = true
        snapshot = try makeSnapshot()

        while try encodedSize(snapshot) > maximumBytes,
              files.contains(where: { !$0.contributions.isEmpty }) {
            files = files.map { file in
                let keep = file.contributions.count / 2
                let removed = file.contributions.count - keep
                omittedContributions += removed
                return CollaborationContextFile(
                    path: file.path,
                    cursor: file.cursor,
                    bytes: file.bytes,
                    characters: file.characters,
                    lines: file.lines,
                    words: file.words,
                    outline: file.outline,
                    contributions: Array(file.contributions.prefix(keep)),
                    omittedHeadingCount: file.omittedHeadingCount,
                    omittedContributionCount: file.omittedContributionCount + removed
                )
            }
            snapshot = try makeSnapshot()
        }

        while try encodedSize(snapshot) > maximumBytes,
              files.contains(where: { !$0.outline.isEmpty }) {
            files = files.map { file in
                let keep = file.outline.count / 2
                let removed = file.outline.count - keep
                omittedHeadings += removed
                return CollaborationContextFile(
                    path: file.path,
                    cursor: file.cursor,
                    bytes: file.bytes,
                    characters: file.characters,
                    lines: file.lines,
                    words: file.words,
                    outline: Array(file.outline.prefix(keep)),
                    contributions: file.contributions,
                    omittedHeadingCount: file.omittedHeadingCount + removed,
                    omittedContributionCount: file.omittedContributionCount
                )
            }
            snapshot = try makeSnapshot()
        }

        while try encodedSize(snapshot) > maximumBytes, !activity.isEmpty {
            let keep = activity.count / 2
            omittedActivity += activity.count - keep
            activity = Array(activity.prefix(keep))
            snapshot = try makeSnapshot()
        }
        while try encodedSize(snapshot) > maximumBytes, !actors.isEmpty {
            actors = Array(actors.prefix(actors.count / 2))
            snapshot = try makeSnapshot()
        }
        while try encodedSize(snapshot) > maximumBytes, files.count > 1 {
            let keep = max(1, files.count / 2)
            let removed = Array(files.dropFirst(keep))
            omittedFiles += removed.count
            omittedHeadings += removed.reduce(0) { $0 + $1.outline.count }
            omittedContributions += removed.reduce(0) { $0 + $1.contributions.count }
            files = Array(files.prefix(keep))
            snapshot = try makeSnapshot()
        }
        guard try encodedSize(snapshot) <= maximumBytes else {
            throw CollaborationError.invalidRoot(
                "The minimum collaboration context metadata exceeds the \(maximumBytes)-byte output budget."
            )
        }
        return snapshot
    }

    private static func kind(from annotation: MarginComment) -> CollaborationContributionKind {
        if case .string(let raw)? = annotation.extensions["margin:kind"],
           let kind = CollaborationContributionKind(rawValue: raw) {
            return kind
        }
        return .comment
    }

    private static func stringExtension(_ key: String, in values: [String: JSONValue]) -> String? {
        guard case .string(let value)? = values[key] else { return nil }
        return value
    }

    private static func priority(from values: [String: JSONValue]) -> CollaborationPriority? {
        guard let raw = stringExtension("margin:priority", in: values) else { return nil }
        return CollaborationPriority(rawValue: raw)
    }

    private static func preview(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        guard maximumBytes > 0 else { return "" }
        var end = value.startIndex
        var bytes = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let nextBytes = value[end..<next].utf8.count
            if bytes + nextBytes > maximumBytes { break }
            bytes += nextBytes
            end = next
        }
        return String(value[..<end]) + "…"
    }
}

enum CollaborationShortReference {
    static func make(path: String, annotationID: String, used: inout Set<String>) -> String {
        let stem: String
        if path == "." {
            stem = "document"
        } else {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            stem = name.isEmpty ? "document" : name
        }
        let digest = CollaborationCanonicalJSON.sha256(of: Data(annotationID.utf8))
        for length in stride(from: 8, through: 64, by: 4) {
            let candidate = "\(stem)#\(digest.prefix(length))"
            if used.insert(candidate).inserted { return candidate }
        }
        let secondary = CollaborationCanonicalJSON.sha256(of: Data("\(path)\0\(annotationID)".utf8))
        var length = 8
        while true {
            let candidate = "\(stem)#\(digest)-\(secondary.prefix(length))"
            if used.insert(candidate).inserted { return candidate }
            length = min(64, length + 4)
            if length == 64 {
                var ordinal = 2
                while !used.insert("\(candidate)-\(ordinal)").inserted { ordinal += 1 }
                return "\(candidate)-\(ordinal)"
            }
        }
    }
}

public enum CollaborationContributionFactory {
    public static func suggestion(
        actor: CollaborationActor,
        path: String,
        range: UnicodeScalarRange,
        message: String,
        expectedText: String,
        replacementText: String,
        baseCursor: CollaborationCursor,
        created: String = CollaborationTimestamp.string(),
        id: String = "urn:uuid:\(UUID().uuidString.lowercased())",
        audience: [String] = []
    ) throws -> CollaborationContribution {
        try actor.validate()
        guard let base = baseCursor[path] else {
            throw CollaborationError.invalidContribution("The suggestion path is not bound by its base cursor.")
        }
        return try CollaborationContribution(
            id: id,
            actorID: actor.id,
            created: created,
            body: message,
            target: CollaborationTarget(path: path, range: range),
            audience: audience,
            details: .suggestion(CollaborationSuggestionDetails(
                expectedText: expectedText,
                replacementText: replacementText,
                baseContentSha256: base.contentSha256
            ))
        )
    }

    public static func handoff(
        actor: CollaborationActor,
        path: String,
        message: String,
        startingCursor: CollaborationCursor,
        finishingCursor: CollaborationCursor? = nil,
        touchedAnnotationIDs: [String] = [],
        unresolvedIDs: [String] = [],
        intendedNextActors: [String] = [],
        created: String = CollaborationTimestamp.string(),
        id: String = "urn:uuid:\(UUID().uuidString.lowercased())",
        audience: [String] = []
    ) throws -> CollaborationContribution {
        try actor.validate()
        try startingCursor.validate()
        if let finishingCursor {
            try finishingCursor.validate()
            guard finishingCursor.root == startingCursor.root else {
                throw CollaborationError.invalidContribution("Handoff cursors must belong to the same root.")
            }
        }
        guard startingCursor[path] != nil else {
            throw CollaborationError.invalidContribution("The handoff path is not bound by its starting cursor.")
        }
        return try CollaborationContribution(
            id: id,
            actorID: actor.id,
            created: created,
            body: message,
            target: CollaborationTarget(path: path),
            audience: audience,
            details: .handoff(CollaborationHandoffDetails(
                startingCursor: try startingCursor.token(),
                finishingCursor: try finishingCursor?.token(),
                touchedAnnotationIDs: touchedAnnotationIDs,
                unresolvedIDs: unresolvedIDs,
                intendedNextActors: intendedNextActors
            ))
        )
    }

    public static func annotation(
        from contribution: CollaborationContribution,
        documentID: String,
        source: String,
        requestID: String? = nil,
        stageID: String? = nil
    ) throws -> MarginComment {
        let fallback = try CollaborationActor(
            id: contribution.actorID,
            type: .person,
            name: contribution.actorID
        )
        return try annotation(
            from: contribution,
            actor: fallback,
            documentID: documentID,
            source: source,
            requestID: requestID,
            stageID: stageID
        )
    }

    /// Preferred conversion when a contribution is part of a change set. This
    /// preserves the actor's exact type and display name in the W3C annotation.
    public static func annotation(
        from contribution: CollaborationContribution,
        actor: CollaborationActor,
        documentID: String,
        source: String,
        requestID: String? = nil,
        stageID: String? = nil
    ) throws -> MarginComment {
        try contribution.validate()
        try actor.validate()
        guard actor.id == contribution.actorID else {
            throw CollaborationError.invalidContribution(
                "The annotation actor does not match the contribution actor."
            )
        }
        try CollaborationValidation.identifier(documentID, field: "document id")
        let target: CommentTarget
        if case .comment(let details) = contribution.details, let parentID = details.parentID {
            target = .resource(parentID)
        } else if let range = contribution.target.range {
            target = try AnchorResolver().target(
                for: .range(start: range.start, end: range.end),
                documentID: documentID,
                in: source
            )
        } else {
            target = .resource(documentID)
        }
        let isReply: Bool
        if case .comment(let details) = contribution.details, details.parentID != nil {
            isReply = true
        } else {
            isReply = false
        }
        var annotationExtensions = contribution.annotationExtensions(
            requestID: requestID,
            stageID: stageID
        )
        let payloadData = try CollaborationCanonicalJSON.encode(contribution)
        annotationExtensions["margin:contributionPayload"] = try CollaborationCanonicalJSON.decode(
            JSONValue.self,
            from: payloadData
        )
        return MarginComment(
            id: contribution.id,
            motivation: isReply ? "replying" : "commenting",
            creator: actor.marginActor,
            created: contribution.created,
            modified: contribution.modified,
            body: MarginCommentBody(value: contribution.body),
            target: target,
            status: isReply ? nil : .open,
            extensions: annotationExtensions
        )
    }
}

public struct CollaborationSuggestionApplication: Codable, Hashable, Sendable {
    public let contributionID: String
    public let originalRange: UnicodeScalarRange
    public let resultingRange: UnicodeScalarRange
    public let originalContentSha256: String
    public let resultingContentSha256: String
    public let body: String
}

public struct CollaborationSuggestionService: Sendable {
    public init() {}

    /// Applies a suggestion to a logical Markdown body only after both the stored
    /// content digest and the exact Unicode-scalar selection still match.
    public func accepting(
        _ contribution: CollaborationContribution,
        in body: String
    ) throws -> CollaborationSuggestionApplication {
        try contribution.validate()
        guard case .suggestion(let suggestion) = contribution.details,
              suggestion.status == .proposed,
              let range = contribution.target.range else {
            throw CollaborationError.invalidContribution("Only a proposed, range-bound suggestion can be accepted.")
        }
        let liveDigest = DocumentRevision(data: Data(body.utf8)).sha256
        guard liveDigest == suggestion.baseContentSha256 else {
            throw CollaborationError.preconditionFailed(
                path: contribution.target.path,
                reason: "The suggestion's logical Markdown base has changed."
            )
        }
        let scalars = Array(body.unicodeScalars)
        guard range.start >= 0, range.end > range.start, range.end <= scalars.count else {
            throw CollaborationError.invalidContribution("The suggestion range is outside the logical Markdown body.")
        }
        let exact = String(String.UnicodeScalarView(scalars[range.start..<range.end]))
        guard exact == suggestion.expectedText else {
            throw CollaborationError.preconditionFailed(
                path: contribution.target.path,
                reason: "The live selection no longer equals the suggestion's expected text."
            )
        }
        var resultingScalars = scalars
        resultingScalars.replaceSubrange(
            range.start..<range.end,
            with: suggestion.replacementText.unicodeScalars
        )
        let result = String(String.UnicodeScalarView(resultingScalars))
        let resultingEnd = range.start + suggestion.replacementText.unicodeScalars.count
        return CollaborationSuggestionApplication(
            contributionID: contribution.id,
            originalRange: range,
            resultingRange: UnicodeScalarRange(start: range.start, end: resultingEnd),
            originalContentSha256: liveDigest,
            resultingContentSha256: DocumentRevision(data: Data(result.utf8)).sha256,
            body: result
        )
    }
}

public enum CollaborationStageDisposition: String, Codable, Sendable {
    case created
    case alreadyPresent = "already-present"
}

public struct CollaborationStageReceipt: Codable, Hashable, Sendable {
    public let stageID: String
    public let changeSetID: String
    public let canonicalSha256: String
    public let disposition: CollaborationStageDisposition
    public let location: String
}

public struct CollaborationStageListing: Codable, Hashable, Sendable {
    public let stages: [CollaborationChangeSet]
    public let omittedCount: Int
    public let selectedCanonicalBytes: Int
    public let omittedCanonicalBytes: Int

    public var isTruncated: Bool { omittedCount > 0 }
}

public struct CollaborationStageStore: Sendable {
    public static let maximumCanonicalBytes = 224 * 1_024 * 1_024
    public static let maximumLegacyListCount = 4_096
    public static let defaultListAggregateBytes = 64 * 1_024 * 1_024
    public static let maximumListAggregateBytes = 256 * 1_024 * 1_024
    private static let maximumDirectoryEntries = 8_192
    private let stateDirectory: URL?

    public init(stateDirectory: URL? = nil) {
        self.stateDirectory = stateDirectory
    }

    public func stage(_ changeSet: CollaborationChangeSet) throws -> CollaborationStageReceipt {
        try changeSet.validate()
        let data = try CollaborationCanonicalJSON.encode(changeSet)
        guard data.count <= Self.maximumCanonicalBytes else {
            throw CollaborationError.invalidChangeSet("The canonical staged change set exceeds 224 MiB.")
        }
        let digest = CollaborationCanonicalJSON.sha256(of: data)
        let destination = try stageURL(id: changeSet.stageID, root: changeSet.root, createDirectory: true)
        let disposition = try writeImmutable(data, to: destination)
        return CollaborationStageReceipt(
            stageID: changeSet.stageID,
            changeSetID: changeSet.id,
            canonicalSha256: digest,
            disposition: disposition,
            location: destination.path
        )
    }

    public func load(stageID: String, root: CollaborationRoot) throws -> CollaborationChangeSet {
        try CollaborationValidation.identifier(stageID, field: "stage id")
        let url = try stageURL(id: stageID, root: root, createDirectory: false)
        let data = try CollaborationPathResolver.readBounded(url, maximumBytes: Self.maximumCanonicalBytes)
        let changeSet = try CollaborationCanonicalJSON.decode(CollaborationChangeSet.self, from: data)
        try changeSet.validate()
        guard changeSet.root == root, changeSet.stageID == stageID,
              try CollaborationCanonicalJSON.encode(changeSet) == data else {
            throw CollaborationError.invalidChangeSet("The staged change set is noncanonical or belongs to another root.")
        }
        return changeSet
    }

    public func list(root: CollaborationRoot) throws -> [CollaborationChangeSet] {
        let listing = try list(root: root, limit: Self.maximumLegacyListCount)
        guard !listing.isTruncated else {
            throw CollaborationError.invalidChangeSet(
                "The stage directory exceeds the legacy complete-list count or byte safety bound; use list(root:limit:maximumAggregateBytes:) for bounded access."
            )
        }
        return listing.stages
    }

    public func list(
        root: CollaborationRoot,
        limit: Int
    ) throws -> CollaborationStageListing {
        try list(
            root: root,
            limit: limit,
            maximumAggregateBytes: Self.defaultListAggregateBytes
        )
    }

    public func list(
        root: CollaborationRoot,
        limit: Int,
        maximumAggregateBytes: Int
    ) throws -> CollaborationStageListing {
        guard (0...Self.maximumLegacyListCount).contains(limit) else {
            throw CollaborationError.invalidChangeSet("Stage listing limit must be between 0 and 4,096.")
        }
        guard (0...Self.maximumListAggregateBytes).contains(maximumAggregateBytes) else {
            throw CollaborationError.invalidChangeSet(
                "The aggregate stage listing budget must be between 0 and 256 MiB."
            )
        }
        let directory = try stageDirectory(root: root, create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return CollaborationStageListing(
                stages: [],
                omittedCount: 0,
                selectedCanonicalBytes: 0,
                omittedCanonicalBytes: 0
            )
        }
        let selection = try Self.boundedStageData(
            in: directory,
            limit: limit,
            maximumAggregateBytes: maximumAggregateBytes
        )
        let stages = try selection.entries.map { entry in
            let data = entry.data
            let value = try CollaborationCanonicalJSON.decode(CollaborationChangeSet.self, from: data)
            guard value.root == root, try CollaborationCanonicalJSON.encode(value) == data else {
                throw CollaborationError.invalidChangeSet("A staged file is noncanonical or belongs to another root.")
            }
            return value
        }
        return CollaborationStageListing(
            stages: stages,
            omittedCount: selection.omittedCount,
            selectedCanonicalBytes: selection.selectedBytes,
            omittedCanonicalBytes: selection.omittedBytes
        )
    }

    public func remove(stageID: String, root: CollaborationRoot) throws {
        let url = try stageURL(id: stageID, root: root, createDirectory: false)
        do {
            try FileManager.default.removeItem(at: url)
            try Self.syncDirectory(url.deletingLastPathComponent())
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw CollaborationError.io("Could not remove stage '\(stageID)': \(error.localizedDescription)")
        }
    }

    private func stageURL(id: String, root: CollaborationRoot, createDirectory: Bool) throws -> URL {
        try CollaborationValidation.identifier(id, field: "stage id")
        let digest = CollaborationCanonicalJSON.sha256(of: Data(id.utf8))
        return try stageDirectory(root: root, create: createDirectory)
            .appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private func stageDirectory(root: CollaborationRoot, create: Bool) throws -> URL {
        try root.validate()
        let directory: URL
        if root.isPersistentWorkspace {
            let margin = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent(".margin", isDirectory: true)
            guard try CollaborationPathResolver.kind(of: margin) == .directory else {
                throw CollaborationError.invalidRoot("The workspace metadata path must be a real directory.")
            }
            directory = margin.appendingPathComponent("stages", isDirectory: true)
        } else {
            let base = stateDirectory ?? CollaborationStateDirectories.defaultRoot()
            let rootDigest = CollaborationCanonicalJSON.sha256(of: try CollaborationCanonicalJSON.encode(root))
            directory = base
                .appendingPathComponent("stages", isDirectory: true)
                .appendingPathComponent(rootDigest, isDirectory: true)
        }
        if create {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard try CollaborationPathResolver.kind(of: directory) == .directory else {
                    throw CollaborationError.symlinkNotAllowed(directory.path)
                }
            } catch let error as CollaborationError {
                throw error
            } catch {
                throw CollaborationError.io("Could not create the stage directory: \(error.localizedDescription)")
            }
        }
        return directory
    }

    private func writeImmutable(_ data: Data, to url: URL) throws -> CollaborationStageDisposition {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not create temporary stage: \(String(cString: strerror(errno))).")
        }
        defer {
            _ = close(descriptor)
            _ = unlink(temporary.path)
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard var base = buffer.baseAddress else { return data.isEmpty }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, base, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= count
                base = base.advanced(by: count)
            }
            return true
        }
        guard written, fsync(descriptor) == 0 else {
            throw CollaborationError.io("Could not durably write stage '\(temporary.path)'.")
        }
        if link(temporary.path, url.path) != 0 {
            let code = errno
            guard code == EEXIST else {
                throw CollaborationError.io("Could not install immutable stage: \(String(cString: strerror(code))).")
            }
            let existing = try CollaborationPathResolver.readBounded(
                url,
                maximumBytes: Self.maximumCanonicalBytes
            )
            guard existing == data else {
                throw CollaborationError.preconditionFailed(
                    path: url.path,
                    reason: "The immutable stage id is already bound to different content."
                )
            }
            return .alreadyPresent
        }
        try Self.syncDirectory(url.deletingLastPathComponent())
        return .created
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not open directory '\(url.path)' for synchronization.")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 || errno == EINVAL else {
            throw CollaborationError.io("Could not synchronize directory '\(url.path)'.")
        }
    }

    private static func boundedStageData(
        in directory: URL,
        limit: Int,
        maximumAggregateBytes: Int
    ) throws -> (
        entries: [(url: URL, data: Data)],
        omittedCount: Int,
        selectedBytes: Int,
        omittedBytes: Int
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw CollaborationError.io("Could not enumerate the stage directory.")
        }
        struct Candidate {
            let url: URL
            let bytes: Int
            let modified: Date
        }
        var candidates: [Candidate] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard candidates.count < Self.maximumDirectoryEntries else {
                throw CollaborationError.invalidChangeSet(
                    "The stage directory exceeds the supported 8,192-entry safety bound."
                )
            }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  let bytes = values.fileSize, bytes >= 0 else {
                throw CollaborationError.invalidChangeSet(
                    "A stage directory entry is not a bounded regular file: '\(url.lastPathComponent)'."
                )
            }
            guard bytes <= Self.maximumCanonicalBytes else {
                throw CollaborationError.invalidChangeSet(
                    "A stage directory entry exceeds the 224 MiB canonical safety bound."
                )
            }
            candidates.append(Candidate(
                url: url,
                bytes: bytes,
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        candidates.sort { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return CollaborationValidation.pathLess(
                lhs.url.lastPathComponent,
                rhs.url.lastPathComponent
            )
        }

        var entries: [(url: URL, data: Data)] = []
        var selectedBytes = 0
        var omittedBytes = 0
        for candidate in candidates {
            let fitsCount = entries.count < limit
            let fitsBytes = candidate.bytes <= maximumAggregateBytes - selectedBytes
            guard fitsCount, fitsBytes else {
                omittedBytes = Self.saturatingAdd(omittedBytes, candidate.bytes)
                continue
            }
            let data = try CollaborationPathResolver.readBounded(
                candidate.url,
                maximumBytes: min(Self.maximumCanonicalBytes, maximumAggregateBytes - selectedBytes)
            )
            selectedBytes += data.count
            entries.append((candidate.url, data))
        }
        return (
            entries,
            max(0, candidates.count - entries.count),
            selectedBytes,
            omittedBytes
        )
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

public enum CollaborationWorkspaceInitializationDisposition: String, Codable, Sendable {
    case created
    case alreadyPresent = "already-present"
}

public struct CollaborationWorkspaceInitializationReceipt: Codable, Hashable, Sendable {
    public let root: CollaborationRoot
    public let manifest: CollaborationWorkspaceManifest
    public let disposition: CollaborationWorkspaceInitializationDisposition
    public let location: String
}

public struct CollaborationWorkspaceService: Sendable {
    public init() {}

    /// Creates a canonical workspace manifest without replacing an existing one.
    /// Concurrent identical initialization is idempotent; an explicit conflicting
    /// id or rule set fails closed.
    public func initialize(
        at directory: URL,
        id requestedID: String? = nil,
        created: String = CollaborationTimestamp.string(),
        include: [String] = CollaborationWorkspaceManifest.defaultInclude,
        exclude: [String] = CollaborationWorkspaceManifest.defaultExclude,
        extensions: [String: JSONValue] = [:]
    ) throws -> CollaborationWorkspaceInitializationReceipt {
        let canonical = try CollaborationPathResolver.canonicalExistingURL(directory)
        guard try CollaborationPathResolver.kind(of: canonical) == .directory else {
            throw CollaborationError.invalidRoot("A workspace can only be initialized in a directory.")
        }
        let initializationLock = try Self.acquireInitializationLock(for: canonical)
        defer {
            _ = flock(initializationLock, LOCK_UN)
            _ = close(initializationLock)
        }
        let marginDirectory = canonical.appendingPathComponent(".margin", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: marginDirectory, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            guard try CollaborationPathResolver.kind(of: marginDirectory) == .directory else {
                throw CollaborationError.symlinkNotAllowed(marginDirectory.path)
            }
        } catch {
            throw CollaborationError.io("Could not create workspace metadata: \(error.localizedDescription)")
        }
        guard try CollaborationPathResolver.kind(of: marginDirectory) == .directory else {
            throw CollaborationError.symlinkNotAllowed(marginDirectory.path)
        }

        let manifest = try CollaborationWorkspaceManifest(
            id: requestedID ?? "urn:uuid:\(UUID().uuidString.lowercased())",
            created: created,
            include: include,
            exclude: exclude,
            extensions: extensions
        )
        let data = try CollaborationCanonicalJSON.encode(manifest)
        let destination = marginDirectory.appendingPathComponent("workspace.json", isDirectory: false)
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        if descriptor < 0 {
            guard errno == EEXIST else {
                throw CollaborationError.io("Could not create workspace manifest: \(String(cString: strerror(errno))).")
            }
            guard try CollaborationPathResolver.kind(of: destination) == .regularFile else {
                throw CollaborationError.symlinkNotAllowed(destination.path)
            }
            let existingData = try CollaborationPathResolver.readBounded(destination, maximumBytes: 1_048_576)
            let existing = try CollaborationCanonicalJSON.decode(
                CollaborationWorkspaceManifest.self,
                from: existingData
            )
            guard try CollaborationCanonicalJSON.encode(existing) == existingData else {
                throw CollaborationError.invalidManifest("The existing workspace manifest is not canonical JSON.")
            }
            guard requestedID.map({ $0 == existing.id }) ?? true,
                  include == existing.include,
                  exclude == existing.exclude,
                  extensions == existing.extensions else {
                throw CollaborationError.preconditionFailed(
                    path: destination.path,
                    reason: "The workspace is already initialized with different metadata."
                )
            }
            let root = try CollaborationRoot(
                id: existing.id,
                kind: .directory,
                path: canonical.path,
                workspaceID: existing.id
            )
            return CollaborationWorkspaceInitializationReceipt(
                root: root,
                manifest: existing,
                disposition: .alreadyPresent,
                location: destination.path
            )
        }

        var success = false
        defer {
            _ = close(descriptor)
            if !success { _ = unlink(destination.path) }
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
        guard complete, fsync(descriptor) == 0 else {
            throw CollaborationError.io("Could not durably write the workspace manifest.")
        }
        success = true
        try Self.syncDirectory(marginDirectory)
        try Self.syncDirectory(canonical)
        let root = try CollaborationRoot(
            id: manifest.id,
            kind: .directory,
            path: canonical.path,
            workspaceID: manifest.id
        )
        return CollaborationWorkspaceInitializationReceipt(
            root: root,
            manifest: manifest,
            disposition: .created,
            location: destination.path
        )
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not open '\(url.path)' for synchronization.")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 || errno == EINVAL else {
            throw CollaborationError.io("Could not synchronize '\(url.path)'.")
        }
    }

    private static func acquireInitializationLock(for directory: URL) throws -> Int32 {
        let lockDirectory = CollaborationStateDirectories.defaultRoot()
            .appendingPathComponent("workspace-init-locks", isDirectory: true)
        do { try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true) }
        catch { throw CollaborationError.io("Could not create workspace initialization locks: \(error.localizedDescription)") }
        let digest = CollaborationCanonicalJSON.sha256(of: Data(directory.path.utf8))
        let lockURL = lockDirectory.appendingPathComponent("\(digest).lock", isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not open workspace initialization lock.")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let code = errno
            _ = close(descriptor)
            throw CollaborationError.io("Could not acquire workspace initialization lock: \(String(cString: strerror(code))).")
        }
        return descriptor
    }
}

enum CollaborationStateDirectories {
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ??
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Margin/collaboration", isDirectory: true)
    }
}
