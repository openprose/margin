import Foundation

public enum CollaborationError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)
    case invalidRoot(String)
    case invalidManifest(String)
    case invalidPath(String)
    case pathEscapesRoot(String)
    case symlinkNotAllowed(String)
    case invalidCursor(String)
    case invalidActor(String)
    case invalidActivity(String)
    case invalidContribution(String)
    case invalidChangeSet(String)
    case stageNotFound(String)
    case duplicateTarget(String)
    case preconditionFailed(path: String, reason: String)
    case lockTimeout(String)
    case transactionFailed(String)
    case rollbackFailed(String)
    case recoveryFailed(String)
    case io(String)

    public var code: String {
        switch self {
        case .unsupportedVersion: return "UNSUPPORTED_COLLABORATION_VERSION"
        case .invalidRoot: return "INVALID_COLLABORATION_ROOT"
        case .invalidManifest: return "INVALID_WORKSPACE_MANIFEST"
        case .invalidPath: return "INVALID_COLLABORATION_PATH"
        case .pathEscapesRoot: return "PATH_ESCAPES_ROOT"
        case .symlinkNotAllowed: return "SYMLINK_NOT_ALLOWED"
        case .invalidCursor: return "INVALID_COLLABORATION_CURSOR"
        case .invalidActor: return "INVALID_COLLABORATION_ACTOR"
        case .invalidActivity: return "INVALID_COLLABORATION_ACTIVITY"
        case .invalidContribution: return "INVALID_COLLABORATION_CONTRIBUTION"
        case .invalidChangeSet: return "INVALID_COLLABORATION_CHANGE_SET"
        case .stageNotFound: return "STAGE_NOT_FOUND"
        case .duplicateTarget: return "DUPLICATE_COLLABORATION_TARGET"
        case .preconditionFailed: return "COLLABORATION_PRECONDITION_FAILED"
        case .lockTimeout: return "COLLABORATION_LOCK_TIMEOUT"
        case .transactionFailed: return "COLLABORATION_TRANSACTION_FAILED"
        case .rollbackFailed: return "COLLABORATION_ROLLBACK_FAILED"
        case .recoveryFailed: return "COLLABORATION_RECOVERY_FAILED"
        case .io: return "COLLABORATION_IO_ERROR"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Collaboration protocol version \(version) is not supported."
        case .invalidRoot(let reason):
            return "The collaboration root is invalid: \(reason)"
        case .invalidManifest(let reason):
            return "The workspace manifest is invalid: \(reason)"
        case .invalidPath(let path):
            return "The collaboration path is invalid: '\(path)'."
        case .pathEscapesRoot(let path):
            return "The path escapes the declared collaboration root: '\(path)'."
        case .symlinkNotAllowed(let path):
            return "The collaboration target crosses a symbolic link: '\(path)'."
        case .invalidCursor(let reason):
            return "The collaboration cursor is invalid: \(reason)"
        case .invalidActor(let reason):
            return "The collaboration actor is invalid: \(reason)"
        case .invalidActivity(let reason):
            return "The collaboration activity is invalid: \(reason)"
        case .invalidContribution(let reason):
            return "The collaboration contribution is invalid: \(reason)"
        case .invalidChangeSet(let reason):
            return "The collaboration change set is invalid: \(reason)"
        case .stageNotFound(let stageID):
            return "No immutable stage with id '\(stageID)' exists in this collaboration root. Run 'margin stage list ROOT' to discover pending stages."
        case .duplicateTarget(let path):
            return "The change set addresses '\(path)' more than once."
        case .preconditionFailed(let path, let reason):
            return "The precondition for '\(path)' failed: \(reason)"
        case .lockTimeout(let path):
            return "Timed out waiting for the collaboration lock for '\(path)'."
        case .transactionFailed(let reason):
            return "The collaboration transaction failed: \(reason)"
        case .rollbackFailed(let reason):
            return "The collaboration transaction could not be rolled back: \(reason)"
        case .recoveryFailed(let reason):
            return "The collaboration transaction could not be recovered: \(reason)"
        case .io(let reason):
            return reason
        }
    }
}

public enum CollaborationRootKind: String, Codable, CaseIterable, Sendable {
    case document
    case directory
}

/// A resolved, explicit collaboration boundary. Constructing a value is pure;
/// use `CollaborationRootResolver` when filesystem verification is required.
public struct CollaborationRoot: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: String
    public let kind: CollaborationRootKind
    public let path: String
    public let workspaceID: String?

    public init(
        version: Int = currentVersion,
        id: String,
        kind: CollaborationRootKind,
        path: String,
        workspaceID: String? = nil
    ) throws {
        self.version = version
        self.id = id
        self.kind = kind
        self.path = path
        self.workspaceID = workspaceID
        try validate()
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw CollaborationError.unsupportedVersion(version)
        }
        try CollaborationValidation.identifier(id, field: "root id")
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw CollaborationError.invalidRoot("The root path must be an absolute filesystem path.")
        }
        if let workspaceID {
            guard kind == .directory else {
                throw CollaborationError.invalidRoot("Only a directory root can carry a workspace id.")
            }
            try CollaborationValidation.identifier(workspaceID, field: "workspace id")
        }
    }

    public var isPersistentWorkspace: Bool {
        kind == .directory && workspaceID != nil
    }
}

public struct CollaborationWorkspaceManifest: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let type = "MarginWorkspace"
    public static let defaultInclude = ["**/*.md", "**/*.markdown"]
    public static let defaultExclude = [
        "**/.build/**", "**/.git/**", "**/.hg/**", "**/.svn/**", "**/.swiftpm/**",
        "**/DerivedData/**", "**/node_modules/**", "**/vendor/**",
    ]

    public var version: Int
    public var id: String
    public var created: String
    public var include: [String]
    public var exclude: [String]
    public var extensions: [String: JSONValue]

    public init(
        version: Int = currentVersion,
        id: String = "urn:uuid:\(UUID().uuidString.lowercased())",
        created: String,
        include: [String] = CollaborationWorkspaceManifest.defaultInclude,
        exclude: [String] = CollaborationWorkspaceManifest.defaultExclude,
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.version = version
        self.id = id
        self.created = created
        self.include = include
        self.exclude = exclude
        self.extensions = extensions
        try validate()
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw CollaborationError.unsupportedVersion(version)
        }
        try CollaborationValidation.identifier(id, field: "workspace id")
        try CollaborationValidation.timestamp(created, field: "workspace creation time")
        guard !include.isEmpty else {
            throw CollaborationError.invalidManifest("At least one include rule is required.")
        }
        let rules = include + exclude
        guard rules.count <= 256,
              rules.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw CollaborationError.invalidManifest(
                "A workspace supports at most 256 rules and 64 KiB of glob text."
            )
        }
        for rule in rules {
            guard !rule.isEmpty, rule.utf8.count <= 1_024,
                  rule.split(separator: "/", omittingEmptySubsequences: false).count <= 256,
                  !rule.contains("\0"), !rule.hasPrefix("/") else {
                throw CollaborationError.invalidManifest(
                    "Rules must be bounded, nonempty relative patterns with at most 256 components."
                )
            }
        }
        try CollaborationValidation.extensions(extensions)
    }
}

public struct CollaborationFileCursor: Codable, Hashable, Sendable {
    public let path: String
    public let documentID: String?
    public let contentSha256: String
    public let annotationRevision: Int
    public let annotationSha256: String
    public let wholeFileSha256: String

    public init(
        path: String,
        documentID: String?,
        contentSha256: String,
        annotationRevision: Int,
        annotationSha256: String,
        wholeFileSha256: String
    ) throws {
        self.path = path
        self.documentID = documentID
        self.contentSha256 = contentSha256
        self.annotationRevision = annotationRevision
        self.annotationSha256 = annotationSha256
        self.wholeFileSha256 = wholeFileSha256
        try validate()
    }

    public func validate() throws {
        try CollaborationValidation.relativePath(path, allowingRootDocument: true)
        if let documentID {
            try CollaborationValidation.identifier(documentID, field: "document id")
        }
        try CollaborationValidation.sha256(contentSha256, field: "content digest")
        try CollaborationValidation.sha256(annotationSha256, field: "annotation digest")
        try CollaborationValidation.sha256(wholeFileSha256, field: "whole-file digest")
        guard annotationRevision >= 0 else {
            throw CollaborationError.invalidCursor("Annotation revisions cannot be negative.")
        }
    }
}

public struct CollaborationCursor: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let root: CollaborationRoot
    public let files: [CollaborationFileCursor]

    public init(
        version: Int = currentVersion,
        root: CollaborationRoot,
        files: [CollaborationFileCursor]
    ) throws {
        self.version = version
        self.root = root
        self.files = files.sorted { CollaborationValidation.pathLess($0.path, $1.path) }
        try validate()
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw CollaborationError.unsupportedVersion(version)
        }
        try root.validate()
        guard !files.isEmpty else {
            throw CollaborationError.invalidCursor("A cursor must bind at least one document.")
        }
        var paths = Set<String>()
        for file in files {
            try file.validate()
            guard paths.insert(file.path).inserted else {
                throw CollaborationError.invalidCursor("Duplicate file path '\(file.path)'.")
            }
        }
        let ordered = files.sorted { CollaborationValidation.pathLess($0.path, $1.path) }
        guard ordered == files else {
            throw CollaborationError.invalidCursor("File state must be in deterministic path order.")
        }
        if root.kind == .document {
            guard files.count == 1, files[0].path == "." else {
                throw CollaborationError.invalidCursor("A document root cursor must contain exactly the root document.")
            }
        } else if files.contains(where: { $0.path == "." }) {
            throw CollaborationError.invalidCursor("A directory cursor cannot bind the root directory as a file.")
        }
    }

    public subscript(path: String) -> CollaborationFileCursor? {
        files.first { $0.path == path }
    }
}

public struct CollaborationActor: Codable, Hashable, Sendable {
    public let id: String
    public let type: MarginActorType
    public let name: String
    public let extensions: [String: JSONValue]

    public init(
        id: String,
        type: MarginActorType,
        name: String,
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.id = id
        self.type = type
        self.name = name
        self.extensions = extensions
        try validate()
    }

    public init(_ actor: MarginActor) throws {
        try self.init(id: actor.id, type: actor.type, name: actor.name)
    }

    public var marginActor: MarginActor {
        MarginActor(id: id, type: type, name: name)
    }

    public func validate() throws {
        try CollaborationValidation.identifier(id, field: "actor id")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 1_024 else {
            throw CollaborationError.invalidActor("The actor name must be nonempty and bounded.")
        }
        try CollaborationValidation.extensions(extensions)
    }
}

public enum CollaborationContributionKind: String, Codable, CaseIterable, Sendable {
    case comment
    case question
    case issue
    case decision
    case task
    case suggestion
    case handoff
    case approval
}

public enum CollaborationPriority: String, Codable, CaseIterable, Sendable {
    case low
    case normal
    case high
    case urgent
}

public enum CollaborationTaskState: String, Codable, CaseIterable, Sendable {
    case open
    case inProgress = "in-progress"
    case blocked
    case complete
    case cancelled
}

public enum CollaborationSuggestionStatus: String, Codable, CaseIterable, Sendable {
    case proposed
    case accepted
    case rejected
    case stale
}

public enum CollaborationDecisionStatus: String, Codable, CaseIterable, Sendable {
    case proposed
    case accepted
    case superseded
}

public enum CollaborationIssueState: String, Codable, CaseIterable, Sendable {
    case open
    case resolved
    case wontFix = "wont-fix"
}

public enum CollaborationApprovalState: String, Codable, CaseIterable, Sendable {
    case requested
    case approved
    case changesRequested = "changes-requested"
}

public struct CollaborationTarget: Codable, Hashable, Sendable {
    public let path: String
    public let annotationID: String?
    public let range: UnicodeScalarRange?

    public init(
        path: String,
        annotationID: String? = nil,
        range: UnicodeScalarRange? = nil
    ) throws {
        self.path = path
        self.annotationID = annotationID
        self.range = range
        try validate()
    }

    public func validate() throws {
        try CollaborationValidation.relativePath(path, allowingRootDocument: true)
        if let annotationID {
            try CollaborationValidation.identifier(annotationID, field: "annotation id")
        }
        if let range, range.start < 0 || range.end <= range.start {
            throw CollaborationError.invalidContribution("A target range must be positive and nonempty.")
        }
    }
}

public struct CollaborationCommentDetails: Codable, Hashable, Sendable {
    public let parentID: String?

    public init(parentID: String? = nil) {
        self.parentID = parentID
    }
}

public struct CollaborationQuestionDetails: Codable, Hashable, Sendable {
    public let answerContributionID: String?

    public init(answerContributionID: String? = nil) {
        self.answerContributionID = answerContributionID
    }
}

public struct CollaborationIssueDetails: Codable, Hashable, Sendable {
    public let state: CollaborationIssueState

    public init(state: CollaborationIssueState = .open) {
        self.state = state
    }
}

public struct CollaborationDecisionDetails: Codable, Hashable, Sendable {
    public let status: CollaborationDecisionStatus
    public let rationale: String?

    public init(
        status: CollaborationDecisionStatus = .proposed,
        rationale: String? = nil
    ) {
        self.status = status
        self.rationale = rationale
    }
}

public struct CollaborationTaskDetails: Codable, Hashable, Sendable {
    public let state: CollaborationTaskState
    public let assignee: String?
    public let priority: CollaborationPriority

    public init(
        state: CollaborationTaskState = .open,
        assignee: String? = nil,
        priority: CollaborationPriority = .normal
    ) {
        self.state = state
        self.assignee = assignee
        self.priority = priority
    }
}

public struct CollaborationSuggestionDetails: Codable, Hashable, Sendable {
    public let expectedText: String
    public let replacementText: String
    public let baseContentSha256: String
    public let status: CollaborationSuggestionStatus

    public init(
        expectedText: String,
        replacementText: String,
        baseContentSha256: String,
        status: CollaborationSuggestionStatus = .proposed
    ) {
        self.expectedText = expectedText
        self.replacementText = replacementText
        self.baseContentSha256 = baseContentSha256
        self.status = status
    }
}

public struct CollaborationHandoffDetails: Codable, Hashable, Sendable {
    public let startingCursor: String
    public let finishingCursor: String?
    public let touchedAnnotationIDs: [String]
    public let unresolvedIDs: [String]
    public let intendedNextActors: [String]

    public init(
        startingCursor: String,
        finishingCursor: String? = nil,
        touchedAnnotationIDs: [String] = [],
        unresolvedIDs: [String] = [],
        intendedNextActors: [String] = []
    ) {
        self.startingCursor = startingCursor
        self.finishingCursor = finishingCursor
        self.touchedAnnotationIDs = CollaborationValidation.sortedUnique(touchedAnnotationIDs)
        self.unresolvedIDs = CollaborationValidation.sortedUnique(unresolvedIDs)
        self.intendedNextActors = CollaborationValidation.sortedUnique(intendedNextActors)
    }
}

public struct CollaborationApprovalDetails: Codable, Hashable, Sendable {
    public let state: CollaborationApprovalState
    public let subjectID: String?

    public init(
        state: CollaborationApprovalState = .requested,
        subjectID: String? = nil
    ) {
        self.state = state
        self.subjectID = subjectID
    }
}

public enum CollaborationContributionDetails: Hashable, Sendable {
    case comment(CollaborationCommentDetails)
    case question(CollaborationQuestionDetails)
    case issue(CollaborationIssueDetails)
    case decision(CollaborationDecisionDetails)
    case task(CollaborationTaskDetails)
    case suggestion(CollaborationSuggestionDetails)
    case handoff(CollaborationHandoffDetails)
    case approval(CollaborationApprovalDetails)

    public var kind: CollaborationContributionKind {
        switch self {
        case .comment: return .comment
        case .question: return .question
        case .issue: return .issue
        case .decision: return .decision
        case .task: return .task
        case .suggestion: return .suggestion
        case .handoff: return .handoff
        case .approval: return .approval
        }
    }
}

extension CollaborationContributionDetails: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(CollaborationContributionKind.self, forKey: .kind)
        switch kind {
        case .comment:
            self = .comment(try container.decode(CollaborationCommentDetails.self, forKey: .value))
        case .question:
            self = .question(try container.decode(CollaborationQuestionDetails.self, forKey: .value))
        case .issue:
            self = .issue(try container.decode(CollaborationIssueDetails.self, forKey: .value))
        case .decision:
            self = .decision(try container.decode(CollaborationDecisionDetails.self, forKey: .value))
        case .task:
            self = .task(try container.decode(CollaborationTaskDetails.self, forKey: .value))
        case .suggestion:
            self = .suggestion(try container.decode(CollaborationSuggestionDetails.self, forKey: .value))
        case .handoff:
            self = .handoff(try container.decode(CollaborationHandoffDetails.self, forKey: .value))
        case .approval:
            self = .approval(try container.decode(CollaborationApprovalDetails.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .comment(let value): try container.encode(value, forKey: .value)
        case .question(let value): try container.encode(value, forKey: .value)
        case .issue(let value): try container.encode(value, forKey: .value)
        case .decision(let value): try container.encode(value, forKey: .value)
        case .task(let value): try container.encode(value, forKey: .value)
        case .suggestion(let value): try container.encode(value, forKey: .value)
        case .handoff(let value): try container.encode(value, forKey: .value)
        case .approval(let value): try container.encode(value, forKey: .value)
        }
    }
}

public struct CollaborationContribution: Codable, Hashable, Sendable {
    public let id: String
    public let actorID: String
    public let created: String
    public let modified: String
    public let body: String
    public let target: CollaborationTarget
    public let audience: [String]
    public let details: CollaborationContributionDetails
    public let extensions: [String: JSONValue]

    public init(
        id: String = "urn:uuid:\(UUID().uuidString.lowercased())",
        actorID: String,
        created: String,
        modified: String? = nil,
        body: String,
        target: CollaborationTarget,
        audience: [String] = [],
        details: CollaborationContributionDetails,
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.id = id
        self.actorID = actorID
        self.created = created
        self.modified = modified ?? created
        self.body = body
        self.target = target
        self.audience = CollaborationValidation.sortedUnique(audience)
        self.details = details
        self.extensions = extensions
        try validate()
    }

    public var kind: CollaborationContributionKind { details.kind }

    public func validate() throws {
        try CollaborationValidation.identifier(id, field: "contribution id")
        try CollaborationValidation.identifier(actorID, field: "contribution actor id")
        try CollaborationValidation.timestamp(created, field: "contribution creation time")
        try CollaborationValidation.timestamp(modified, field: "contribution modification time")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= 1_048_576 else {
            throw CollaborationError.invalidContribution("The body must be nonempty and no larger than 1 MiB.")
        }
        try target.validate()
        for actorID in audience {
            try CollaborationValidation.identifier(actorID, field: "audience actor id")
        }
        guard audience == CollaborationValidation.sortedUnique(audience) else {
            throw CollaborationError.invalidContribution("Audience ids must be unique and ordered.")
        }
        try CollaborationValidation.extensions(
            extensions,
            reservedKeys: [
                "margin:kind", "margin:audience", "margin:assignee", "margin:priority",
                "margin:suggestion", "margin:handoff", "margin:transaction",
                "margin:parent", "margin:question", "margin:issue", "margin:decision",
                "margin:task", "margin:approval", "margin:contributionPayload",
                "margin:lastTransaction",
            ]
        )

        switch details {
        case .comment(let value):
            if let parentID = value.parentID {
                try CollaborationValidation.identifier(parentID, field: "parent annotation id")
            }
            guard target.annotationID == value.parentID else {
                throw CollaborationError.invalidContribution(
                    "A comment reply target and its parent detail must identify the same annotation."
                )
            }
            if value.parentID != nil, target.range != nil {
                throw CollaborationError.invalidContribution("A reply target cannot also carry a source range.")
            }
        case .question(let value):
            guard target.annotationID == nil else {
                throw CollaborationError.invalidContribution("Only comment replies can target an annotation id.")
            }
            if let answerID = value.answerContributionID {
                try CollaborationValidation.identifier(answerID, field: "answer contribution id")
            }
        case .issue:
            guard target.annotationID == nil else {
                throw CollaborationError.invalidContribution("Only comment replies can target an annotation id.")
            }
        case .decision(let value):
            guard target.annotationID == nil else {
                throw CollaborationError.invalidContribution("Only comment replies can target an annotation id.")
            }
            if let rationale = value.rationale, rationale.utf8.count > 1_048_576 {
                throw CollaborationError.invalidContribution("Decision rationale exceeds 1 MiB.")
            }
        case .task(let value):
            guard target.annotationID == nil else {
                throw CollaborationError.invalidContribution("Only comment replies can target an annotation id.")
            }
            if let assignee = value.assignee {
                try CollaborationValidation.identifier(assignee, field: "task assignee")
            }
        case .suggestion(let value):
            guard target.annotationID == nil, target.range != nil,
                  !value.expectedText.isEmpty, value.status == .proposed else {
                throw CollaborationError.invalidContribution(
                    "A new suggestion needs a nonempty expected selection range, proposed status, and no annotation target."
                )
            }
            try CollaborationValidation.sha256(value.baseContentSha256, field: "suggestion base digest")
            guard value.expectedText.utf8.count <= 4_194_304,
                  value.replacementText.utf8.count <= 4_194_304 else {
                throw CollaborationError.invalidContribution("Suggestion text exceeds 4 MiB.")
            }
        case .handoff(let value):
            guard target.annotationID == nil,
                  value.startingCursor.utf8.count <= 8 * 1_024 * 1_024,
                  (value.finishingCursor?.utf8.count ?? 0) <= 8 * 1_024 * 1_024 else {
                throw CollaborationError.invalidContribution("Handoff targets and cursor tokens must be bounded.")
            }
            let starting = try CollaborationCursor(token: value.startingCursor)
            let finishing = try value.finishingCursor.map(CollaborationCursor.init(token:))
            guard starting[target.path] != nil,
                  finishing.map({ $0.root == starting.root }) ?? true else {
                throw CollaborationError.invalidContribution(
                    "Handoff cursors must share a root and bind the handoff target path."
                )
            }
            guard value.touchedAnnotationIDs == CollaborationValidation.sortedUnique(value.touchedAnnotationIDs),
                  value.unresolvedIDs == CollaborationValidation.sortedUnique(value.unresolvedIDs),
                  value.intendedNextActors == CollaborationValidation.sortedUnique(value.intendedNextActors) else {
                throw CollaborationError.invalidContribution("Handoff references must be sorted and unique.")
            }
            for id in value.touchedAnnotationIDs + value.unresolvedIDs + value.intendedNextActors {
                try CollaborationValidation.identifier(id, field: "handoff reference")
            }
        case .approval(let value):
            guard target.annotationID == nil else {
                throw CollaborationError.invalidContribution("Only comment replies can target an annotation id.")
            }
            if let subjectID = value.subjectID {
                try CollaborationValidation.identifier(subjectID, field: "approval subject")
            }
        }
    }

    /// Namespaced fields suitable for merging into a W3C Annotation. The body,
    /// target, creator, and timestamps remain the annotation's ordinary fields.
    public func annotationExtensions(
        requestID: String? = nil,
        stageID: String? = nil
    ) -> [String: JSONValue] {
        var result = extensions
        result["margin:kind"] = .string(kind.rawValue)
        if !audience.isEmpty {
            result["margin:audience"] = .array(audience.map(JSONValue.string))
        }
        switch details {
        case .comment(let value):
            if let parentID = value.parentID {
                result["margin:parent"] = .string(parentID)
            }
        case .question(let value):
            if let answerID = value.answerContributionID {
                result["margin:question"] = .object(["answer": .string(answerID)])
            }
        case .issue(let value):
            result["margin:issue"] = .object(["state": .string(value.state.rawValue)])
        case .decision(let value):
            var decision: [String: JSONValue] = ["status": .string(value.status.rawValue)]
            if let rationale = value.rationale { decision["rationale"] = .string(rationale) }
            result["margin:decision"] = .object(decision)
        case .task(let value):
            result["margin:priority"] = .string(value.priority.rawValue)
            var task: [String: JSONValue] = ["state": .string(value.state.rawValue)]
            if let assignee = value.assignee {
                result["margin:assignee"] = .string(assignee)
                task["assignee"] = .string(assignee)
            }
            result["margin:task"] = .object(task)
        case .suggestion(let value):
            result["margin:suggestion"] = .object([
                "expectedText": .string(value.expectedText),
                "replacementText": .string(value.replacementText),
                "baseContentSha256": .string(value.baseContentSha256),
                "status": .string(value.status.rawValue),
            ])
        case .handoff(let value):
            var handoff: [String: JSONValue] = [
                "startingCursor": .string(value.startingCursor),
                "touchedAnnotationIDs": .array(value.touchedAnnotationIDs.map(JSONValue.string)),
                "unresolvedIDs": .array(value.unresolvedIDs.map(JSONValue.string)),
                "intendedNextActors": .array(value.intendedNextActors.map(JSONValue.string)),
            ]
            if let finishing = value.finishingCursor {
                handoff["finishingCursor"] = .string(finishing)
            }
            result["margin:handoff"] = .object(handoff)
        case .approval(let value):
            var approval: [String: JSONValue] = ["state": .string(value.state.rawValue)]
            if let subjectID = value.subjectID { approval["subject"] = .string(subjectID) }
            result["margin:approval"] = .object(approval)
        }
        if requestID != nil || stageID != nil {
            var transaction: [String: JSONValue] = [:]
            if let requestID { transaction["requestID"] = .string(requestID) }
            if let stageID { transaction["stageID"] = .string(stageID) }
            result["margin:transaction"] = .object(transaction)
        }
        return result
    }
}

public enum CollaborationActivityKind: String, Codable, CaseIterable, Sendable {
    case contributionObserved = "contribution-observed"
    case transactionCommitted = "transaction-committed"
    case transactionRecovered = "transaction-recovered"
}

/// Durable facts only. This type intentionally has no online/presence state.
public struct CollaborationActivityRecord: Codable, Hashable, Sendable {
    public let id: String
    public let rootID: String
    public let actorID: String
    public let occurredAt: String
    public let kind: CollaborationActivityKind
    public let paths: [String]
    public let contributionIDs: [String]
    public let contributionKinds: [CollaborationContributionKind]
    public let requestID: String?
    public let stageID: String?
    public let extensions: [String: JSONValue]

    public init(
        id: String,
        rootID: String,
        actorID: String,
        occurredAt: String,
        kind: CollaborationActivityKind,
        paths: [String],
        contributionIDs: [String] = [],
        contributionKinds: [CollaborationContributionKind] = [],
        requestID: String? = nil,
        stageID: String? = nil,
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.id = id
        self.rootID = rootID
        self.actorID = actorID
        self.occurredAt = occurredAt
        self.kind = kind
        self.paths = CollaborationValidation.sortedUnique(paths)
        self.contributionIDs = CollaborationValidation.sortedUnique(contributionIDs)
        self.contributionKinds = Array(Set(contributionKinds)).sorted { $0.rawValue < $1.rawValue }
        self.requestID = requestID
        self.stageID = stageID
        self.extensions = extensions
        try validate()
    }

    public func validate() throws {
        try CollaborationValidation.identifier(id, field: "activity id")
        try CollaborationValidation.identifier(rootID, field: "activity root id")
        try CollaborationValidation.identifier(actorID, field: "activity actor id")
        try CollaborationValidation.timestamp(occurredAt, field: "activity time")
        guard !paths.isEmpty else {
            throw CollaborationError.invalidActivity("An activity must identify at least one file.")
        }
        for path in paths {
            try CollaborationValidation.relativePath(path, allowingRootDocument: true)
        }
        for id in contributionIDs {
            try CollaborationValidation.identifier(id, field: "activity contribution id")
        }
        if let requestID { try CollaborationValidation.identifier(requestID, field: "request id") }
        if let stageID { try CollaborationValidation.identifier(stageID, field: "stage id") }
        try CollaborationValidation.extensions(extensions)
    }
}

public struct CollaborationActorActivity: Codable, Hashable, Sendable {
    public let actorID: String
    public let firstObservedAt: String
    public let lastObservedAt: String
    public let contributionCounts: [String: Int]
    public let filesTouched: [String]
    public let authoredContributionIDs: [String]
    public let openAuthoredContributionIDs: [String]
    public let assignedOpenContributionIDs: [String]

    public init(
        actorID: String,
        firstObservedAt: String,
        lastObservedAt: String,
        contributionCounts: [String: Int],
        filesTouched: [String],
        authoredContributionIDs: [String],
        openAuthoredContributionIDs: [String] = [],
        assignedOpenContributionIDs: [String] = []
    ) {
        self.actorID = actorID
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.contributionCounts = contributionCounts
        self.filesTouched = CollaborationValidation.sortedUnique(filesTouched)
        self.authoredContributionIDs = CollaborationValidation.sortedUnique(authoredContributionIDs)
        self.openAuthoredContributionIDs = CollaborationValidation.sortedUnique(openAuthoredContributionIDs)
        self.assignedOpenContributionIDs = CollaborationValidation.sortedUnique(assignedOpenContributionIDs)
    }
}

public enum CollaborationFileExistence: String, Codable, Sendable {
    case absent
    case exact
}

public struct CollaborationFilePrecondition: Codable, Hashable, Sendable {
    public let existence: CollaborationFileExistence
    public let wholeFileSha256: String?
    public let contentSha256: String?
    public let annotationRevision: Int?
    public let annotationSha256: String?

    public init(
        existence: CollaborationFileExistence,
        wholeFileSha256: String? = nil,
        contentSha256: String? = nil,
        annotationRevision: Int? = nil,
        annotationSha256: String? = nil
    ) throws {
        self.existence = existence
        self.wholeFileSha256 = wholeFileSha256
        self.contentSha256 = contentSha256
        self.annotationRevision = annotationRevision
        self.annotationSha256 = annotationSha256
        try validate()
    }

    public static var absent: CollaborationFilePrecondition {
        // This construction is statically valid.
        try! CollaborationFilePrecondition(existence: .absent)
    }

    public static func exact(_ cursor: CollaborationFileCursor) -> CollaborationFilePrecondition {
        try! CollaborationFilePrecondition(
            existence: .exact,
            wholeFileSha256: cursor.wholeFileSha256,
            contentSha256: cursor.contentSha256,
            annotationRevision: cursor.annotationRevision,
            annotationSha256: cursor.annotationSha256
        )
    }

    public func validate() throws {
        switch existence {
        case .absent:
            guard wholeFileSha256 == nil,
                  contentSha256 == nil,
                  annotationRevision == nil,
                  annotationSha256 == nil else {
                throw CollaborationError.invalidChangeSet("An absent-file precondition cannot include state digests.")
            }
        case .exact:
            guard let wholeFileSha256 else {
                throw CollaborationError.invalidChangeSet("An exact precondition requires a whole-file digest.")
            }
            try CollaborationValidation.sha256(wholeFileSha256, field: "expected whole-file digest")
            if let contentSha256 {
                try CollaborationValidation.sha256(contentSha256, field: "expected content digest")
            }
            if let annotationSha256 {
                try CollaborationValidation.sha256(annotationSha256, field: "expected annotation digest")
            }
            if let annotationRevision, annotationRevision < 0 {
                throw CollaborationError.invalidChangeSet("Expected annotation revision cannot be negative.")
            }
        }
    }
}

public enum CollaborationFileResult: Hashable, Sendable {
    case write(data: Data, permissions: UInt16?)
    case remove
}

extension CollaborationFileResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case data
        case permissions
    }

    private enum Kind: String, Codable {
        case write
        case remove
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .write:
            self = .write(
                data: try container.decode(Data.self, forKey: .data),
                permissions: try container.decodeIfPresent(UInt16.self, forKey: .permissions)
            )
        case .remove:
            self = .remove
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .write(let data, let permissions):
            try container.encode(Kind.write, forKey: .kind)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(permissions, forKey: .permissions)
        case .remove:
            try container.encode(Kind.remove, forKey: .kind)
        }
    }
}

/// A fully evaluated file mutation. Semantic contribution operations are
/// converted into these values in memory before the transaction engine runs.
public struct CollaborationFileMutation: Codable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let precondition: CollaborationFilePrecondition
    public let result: CollaborationFileResult

    public init(
        id: String,
        path: String,
        precondition: CollaborationFilePrecondition,
        result: CollaborationFileResult
    ) throws {
        self.id = id
        self.path = path
        self.precondition = precondition
        self.result = result
        try validate()
    }

    public func validate() throws {
        try CollaborationValidation.identifier(id, field: "file mutation id")
        try CollaborationValidation.relativePath(path, allowingRootDocument: true)
        try precondition.validate()
        if case .remove = result, precondition.existence == .absent {
            throw CollaborationError.invalidChangeSet("Removing an already-absent file is not a valid staged mutation.")
        }
        if case .write(let data, let permissions) = result {
            guard data.count <= 128 * 1_024 * 1_024 else {
                throw CollaborationError.invalidChangeSet("A staged file exceeds 128 MiB.")
            }
            if let permissions, permissions & 0o7000 != 0 {
                throw CollaborationError.invalidChangeSet("Special permission bits are not supported.")
            }
        }
    }
}

public struct CollaborationContributionOperation: Codable, Hashable, Sendable {
    public let contribution: CollaborationContribution

    public init(contribution: CollaborationContribution) {
        self.contribution = contribution
    }
}

public struct CollaborationStatusOperation: Codable, Hashable, Sendable {
    public let path: String
    public let annotationID: String
    public let status: MarginCommentStatus

    public init(path: String, annotationID: String, status: MarginCommentStatus) {
        self.path = path
        self.annotationID = annotationID
        self.status = status
    }
}

public struct CollaborationSuggestionAcceptanceOperation: Codable, Hashable, Sendable {
    public let path: String
    public let contributionID: String

    public init(path: String, contributionID: String) {
        self.path = path
        self.contributionID = contributionID
    }
}

public enum CollaborationSuggestionDisposition: String, Codable, CaseIterable, Sendable {
    case accept
    case reject
}

public struct CollaborationSuggestionDispositionOperation: Codable, Hashable, Sendable {
    public let path: String
    public let contributionID: String
    public let disposition: CollaborationSuggestionDisposition

    public init(
        path: String,
        contributionID: String,
        disposition: CollaborationSuggestionDisposition
    ) {
        self.path = path
        self.contributionID = contributionID
        self.disposition = disposition
    }
}

public enum CollaborationOperation: Hashable, Sendable {
    case contribution(id: String, CollaborationContributionOperation)
    case status(id: String, CollaborationStatusOperation)
    case acceptSuggestion(id: String, CollaborationSuggestionAcceptanceOperation)
    case suggestionDisposition(id: String, CollaborationSuggestionDispositionOperation)
    case file(id: String, CollaborationFileMutation)

    public var id: String {
        switch self {
        case .contribution(let id, _), .status(let id, _),
             .acceptSuggestion(let id, _), .suggestionDisposition(let id, _),
             .file(let id, _):
            return id
        }
    }

    public var path: String {
        switch self {
        case .contribution(_, let value): return value.contribution.target.path
        case .status(_, let value): return value.path
        case .acceptSuggestion(_, let value): return value.path
        case .suggestionDisposition(_, let value): return value.path
        case .file(_, let value): return value.path
        }
    }
}

extension CollaborationOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case contribution
        case status
        case acceptSuggestion = "accept-suggestion"
        case suggestionDisposition = "suggestion-disposition"
        case file
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .contribution:
            self = .contribution(id: id, try container.decode(CollaborationContributionOperation.self, forKey: .value))
        case .status:
            self = .status(id: id, try container.decode(CollaborationStatusOperation.self, forKey: .value))
        case .acceptSuggestion:
            self = .acceptSuggestion(
                id: id,
                try container.decode(CollaborationSuggestionAcceptanceOperation.self, forKey: .value)
            )
        case .suggestionDisposition:
            self = .suggestionDisposition(
                id: id,
                try container.decode(CollaborationSuggestionDispositionOperation.self, forKey: .value)
            )
        case .file:
            self = .file(id: id, try container.decode(CollaborationFileMutation.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch self {
        case .contribution(_, let value):
            try container.encode(Kind.contribution, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .status(_, let value):
            try container.encode(Kind.status, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .acceptSuggestion(_, let value):
            try container.encode(Kind.acceptSuggestion, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .suggestionDisposition(_, let value):
            try container.encode(Kind.suggestionDisposition, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .file(_, let value):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct CollaborationChangeSet: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maximumPayloadBytes = 32 * 1_024 * 1_024

    public let version: Int
    public let id: String
    public let root: CollaborationRoot
    public let baseCursor: CollaborationCursor
    public let actor: CollaborationActor
    public let requestID: String
    public let stageID: String
    public let created: String
    public let operations: [CollaborationOperation]
    public let extensions: [String: JSONValue]

    public init(
        version: Int = currentVersion,
        id: String = "urn:uuid:\(UUID().uuidString.lowercased())",
        root: CollaborationRoot,
        baseCursor: CollaborationCursor,
        actor: CollaborationActor,
        requestID: String,
        stageID: String,
        created: String,
        operations: [CollaborationOperation],
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.version = version
        self.id = id
        self.root = root
        self.baseCursor = baseCursor
        self.actor = actor
        self.requestID = requestID
        self.stageID = stageID
        self.created = created
        self.operations = operations
        self.extensions = extensions
        try validate()
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw CollaborationError.unsupportedVersion(version)
        }
        try CollaborationValidation.identifier(id, field: "change set id")
        try root.validate()
        try baseCursor.validate()
        guard root == baseCursor.root else {
            throw CollaborationError.invalidChangeSet("The base cursor belongs to a different root.")
        }
        try actor.validate()
        try CollaborationValidation.identifier(requestID, field: "request id")
        try CollaborationValidation.identifier(stageID, field: "stage id")
        try CollaborationValidation.timestamp(created, field: "change set creation time")
        guard !operations.isEmpty, operations.count <= 4_096 else {
            throw CollaborationError.invalidChangeSet("A change set needs between 1 and 4,096 operations.")
        }
        var operationIDs = Set<String>()
        var directFilePaths = Set<String>()
        var payloadBytes = 0
        func addPayload(_ count: Int) throws {
            guard count >= 0, payloadBytes <= Self.maximumPayloadBytes - min(count, Self.maximumPayloadBytes) else {
                throw CollaborationError.invalidChangeSet("The aggregate staged payload exceeds 32 MiB.")
            }
            payloadBytes += count
            guard payloadBytes <= Self.maximumPayloadBytes else {
                throw CollaborationError.invalidChangeSet("The aggregate staged payload exceeds 32 MiB.")
            }
        }
        for operation in operations {
            try CollaborationValidation.identifier(operation.id, field: "operation id")
            guard operationIDs.insert(operation.id).inserted else {
                throw CollaborationError.invalidChangeSet("Duplicate operation id '\(operation.id)'.")
            }
            try CollaborationValidation.relativePath(operation.path, allowingRootDocument: true)
            if root.kind == .document, operation.path != "." {
                throw CollaborationError.invalidChangeSet("Document-root operations must target '.'.")
            }
            if root.kind == .directory, operation.path == "." {
                throw CollaborationError.invalidChangeSet("Directory-root operations must target a relative file path.")
            }
            switch operation {
            case .contribution(_, let value):
                try value.contribution.validate()
                guard baseCursor[value.contribution.target.path] != nil else {
                    throw CollaborationError.invalidChangeSet(
                        "Contribution '\(value.contribution.id)' targets a path outside the base cursor."
                    )
                }
                try addPayload(value.contribution.body.utf8.count)
                switch value.contribution.details {
                case .suggestion(let details):
                    guard details.baseContentSha256 == baseCursor[value.contribution.target.path]?.contentSha256 else {
                        throw CollaborationError.invalidChangeSet(
                            "Suggestion '\(value.contribution.id)' is not bound to the base cursor's logical source."
                        )
                    }
                    try addPayload(details.expectedText.utf8.count)
                    try addPayload(details.replacementText.utf8.count)
                case .decision(let details):
                    try addPayload(details.rationale?.utf8.count ?? 0)
                case .handoff(let details):
                    let starting = try CollaborationCursor(token: details.startingCursor)
                    let finishing = try details.finishingCursor.map(CollaborationCursor.init(token:))
                    guard starting.root == root,
                          finishing.map({ $0.root == root }) ?? true else {
                        throw CollaborationError.invalidChangeSet(
                            "Handoff cursors must belong to the change set root."
                        )
                    }
                    try addPayload(details.startingCursor.utf8.count)
                    try addPayload(details.finishingCursor?.utf8.count ?? 0)
                default:
                    break
                }
                guard value.contribution.actorID == actor.id else {
                    throw CollaborationError.invalidChangeSet(
                        "Contribution '\(value.contribution.id)' is attributed to another actor."
                    )
                }
            case .status(_, let value):
                try CollaborationValidation.identifier(value.annotationID, field: "status annotation id")
            case .acceptSuggestion(_, let value):
                try CollaborationValidation.identifier(value.contributionID, field: "suggestion contribution id")
            case .suggestionDisposition(_, let value):
                try CollaborationValidation.identifier(value.contributionID, field: "suggestion contribution id")
            case .file(_, let value):
                try value.validate()
                if case .write(let data, _) = value.result { try addPayload(data.count) }
                guard directFilePaths.insert(value.path).inserted else {
                    throw CollaborationError.duplicateTarget(value.path)
                }
            }
        }
        try CollaborationValidation.extensions(extensions)
    }

    public var fileMutations: [CollaborationFileMutation] {
        operations.compactMap {
            guard case .file(_, let mutation) = $0 else { return nil }
            return mutation
        }
    }
}

enum CollaborationValidation {
    static func identifier(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value, value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CollaborationError.invalidContribution("The \(field) is empty, unbounded, or contains control characters.")
        }
    }

    static func timestamp(_ value: String, field: String) throws {
        guard value.utf8.count <= 128 else {
            throw CollaborationError.invalidActivity("The \(field) is unbounded.")
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        guard fractional.date(from: value) != nil || ordinary.date(from: value) != nil else {
            throw CollaborationError.invalidActivity("The \(field) is not an ISO-8601 timestamp.")
        }
    }

    static func sha256(_ value: String, field: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw CollaborationError.invalidCursor("The \(field) is not a lowercase SHA-256 digest.")
        }
    }

    static func relativePath(_ value: String, allowingRootDocument: Bool) throws {
        guard !value.isEmpty, !value.contains("\0"), !value.hasPrefix("/"),
              value.utf8.count <= 4_096 else {
            throw CollaborationError.invalidPath(value)
        }
        if value == "." {
            guard allowingRootDocument else { throw CollaborationError.invalidPath(value) }
            return
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CollaborationError.invalidPath(value)
        }
    }

    static func extensions(
        _ values: [String: JSONValue],
        reservedKeys: Set<String> = []
    ) throws {
        for (key, value) in values {
            guard !key.isEmpty, key.utf8.count <= 1_024, !reservedKeys.contains(key) else {
                throw CollaborationError.invalidContribution("Extension keys must be bounded and cannot replace a known field.")
            }
            guard finite(value) else {
                throw CollaborationError.invalidContribution("Extension '\(key)' contains a non-finite number.")
            }
        }
    }

    static func finite(_ value: JSONValue) -> Bool {
        switch value {
        case .number(let number): return number.isFinite
        case .array(let values): return values.allSatisfy(finite)
        case .object(let values): return values.values.allSatisfy(finite)
        case .null, .bool, .string: return true
        }
    }

    static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted(by: pathLess)
    }

    static func pathLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
