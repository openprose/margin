import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct DynamicCodingKey: CodingKey, Hashable {
    public let stringValue: String
    public let intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

public enum MarginActorType: String, Codable, CaseIterable, Sendable {
    case person = "Person"
    case software = "Software"
    case organization = "Organization"
}

public struct MarginActor: Codable, Hashable, Sendable {
    public var id: String
    public var type: MarginActorType
    public var name: String

    public init(id: String, type: MarginActorType, name: String) {
        self.id = id
        self.type = type
        self.name = name
    }
}

public struct MarginGenerator: Codable, Hashable, Sendable {
    public var id: String
    public var type: MarginActorType
    public var name: String

    public init(
        id: String = "urn:margin:app",
        type: MarginActorType = .software,
        name: String = "Margin"
    ) {
        self.id = id
        self.type = type
        self.name = name
    }
}

public struct MarginCommentBody: Codable, Hashable, Sendable {
    public var type: String
    public var value: String
    public var format: String
    public var purpose: String?

    public init(
        value: String,
        purpose: String? = nil,
        type: String = "TextualBody",
        format: String = "text/markdown"
    ) {
        self.type = type
        self.value = value
        self.format = format
        self.purpose = purpose
    }
}

public struct MarginSourceReference: Codable, Hashable, Sendable {
    public var id: String
    public var format: String

    public init(id: String, format: String = "text/markdown") {
        self.id = id
        self.format = format
    }
}

public struct TextPositionSelector: Codable, Hashable, Sendable {
    public var type: String
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int, type: String = "TextPositionSelector") {
        self.type = type
        self.start = start
        self.end = end
    }
}

public struct TextQuoteSelector: Codable, Hashable, Sendable {
    public var type: String
    public var exact: String
    public var prefix: String
    public var suffix: String

    public init(
        exact: String,
        prefix: String = "",
        suffix: String = "",
        type: String = "TextQuoteSelector"
    ) {
        self.type = type
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
    }
}

public enum CommentSelector: Codable, Hashable, Sendable {
    case position(TextPositionSelector)
    case quote(TextQuoteSelector)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "TextPositionSelector":
            self = .position(try TextPositionSelector(from: decoder))
        case "TextQuoteSelector":
            self = .quote(try TextQuoteSelector(from: decoder))
        case let type:
            throw CommentProtocolError.invalidEnvelope("Unsupported selector type '\(type)'.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .position(let selector): try selector.encode(to: encoder)
        case .quote(let selector): try selector.encode(to: encoder)
        }
    }
}

public struct CommentSelectionTarget: Codable, Hashable, Sendable {
    public var type: String
    public var source: MarginSourceReference
    public var selector: [CommentSelector]

    public init(
        source: MarginSourceReference,
        selector: [CommentSelector],
        type: String = "SpecificResource"
    ) {
        self.type = type
        self.source = source
        self.selector = selector
    }

    public var positionSelector: TextPositionSelector? {
        selector.compactMap {
            if case .position(let value) = $0 { return value }
            return nil
        }.first
    }

    public var quoteSelector: TextQuoteSelector? {
        selector.compactMap {
            if case .quote(let value) = $0 { return value }
            return nil
        }.first
    }
}

public enum CommentTarget: Codable, Hashable, Sendable {
    case resource(String)
    case selection(CommentSelectionTarget)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .resource(value)
        } else {
            self = .selection(try container.decode(CommentSelectionTarget.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .resource(let value): try container.encode(value)
        case .selection(let value): try container.encode(value)
        }
    }
}

public enum MarginCommentStatus: String, Codable, Sendable {
    case open
    case resolved
}

public struct MarginComment: Codable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var motivation: String
    public var creator: MarginActor
    public var generator: MarginGenerator
    public var created: String
    public var modified: String
    public var body: MarginCommentBody
    public var target: CommentTarget
    public var status: MarginCommentStatus?
    public var statusModified: String?
    public var statusModifiedBy: MarginActor?
    public var extensions: [String: JSONValue]

    public init(
        id: String,
        motivation: String,
        creator: MarginActor,
        created: String,
        modified: String,
        body: MarginCommentBody,
        target: CommentTarget,
        status: MarginCommentStatus? = nil,
        statusModified: String? = nil,
        statusModifiedBy: MarginActor? = nil,
        generator: MarginGenerator = MarginGenerator(),
        type: String = "Annotation",
        extensions: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.type = type
        self.motivation = motivation
        self.creator = creator
        self.generator = generator
        self.created = created
        self.modified = modified
        self.body = body
        self.target = target
        self.status = status
        self.statusModified = statusModified
        self.statusModifiedBy = statusModifiedBy
        self.extensions = extensions
    }

    private static let knownKeys: Set<String> = [
        "id", "type", "motivation", "creator", "generator", "created", "modified",
        "body", "target", "margin:status", "margin:statusModified", "margin:statusModifiedBy"
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        id = try container.decode(String.self, forKey: key("id"))
        type = try container.decode(String.self, forKey: key("type"))
        motivation = try container.decode(String.self, forKey: key("motivation"))
        creator = try container.decode(MarginActor.self, forKey: key("creator"))
        generator = try container.decodeIfPresent(MarginGenerator.self, forKey: key("generator")) ?? MarginGenerator()
        created = try container.decode(String.self, forKey: key("created"))
        modified = try container.decode(String.self, forKey: key("modified"))
        body = try container.decode(MarginCommentBody.self, forKey: key("body"))
        target = try container.decode(CommentTarget.self, forKey: key("target"))
        status = try container.decodeIfPresent(MarginCommentStatus.self, forKey: key("margin:status"))
        statusModified = try container.decodeIfPresent(String.self, forKey: key("margin:statusModified"))
        statusModifiedBy = try container.decodeIfPresent(MarginActor.self, forKey: key("margin:statusModifiedBy"))
        var unknown: [String: JSONValue] = [:]
        for codingKey in container.allKeys where !Self.knownKeys.contains(codingKey.stringValue) {
            unknown[codingKey.stringValue] = try container.decode(JSONValue.self, forKey: codingKey)
        }
        extensions = unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        try container.encode(id, forKey: key("id"))
        try container.encode(type, forKey: key("type"))
        try container.encode(motivation, forKey: key("motivation"))
        try container.encode(creator, forKey: key("creator"))
        try container.encode(generator, forKey: key("generator"))
        try container.encode(created, forKey: key("created"))
        try container.encode(modified, forKey: key("modified"))
        try container.encode(body, forKey: key("body"))
        try container.encode(target, forKey: key("target"))
        try container.encodeIfPresent(status, forKey: key("margin:status"))
        try container.encodeIfPresent(statusModified, forKey: key("margin:statusModified"))
        try container.encodeIfPresent(statusModifiedBy, forKey: key("margin:statusModifiedBy"))
        for (name, value) in extensions where !Self.knownKeys.contains(name) {
            try container.encode(value, forKey: key(name))
        }
    }
}

public struct AnnotationCollectionReference: Codable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var total: Int

    public init(id: String, total: Int, type: String = "AnnotationCollection") {
        self.id = id
        self.type = type
        self.total = total
    }
}

public struct MarginDocumentReference: Codable, Hashable, Sendable {
    public var id: String
    public var format: String

    public init(id: String, format: String = "text/markdown") {
        self.id = id
        self.format = format
    }
}

public struct EmbeddedCommentEnvelope: Codable, Hashable, Sendable {
    public var context: [JSONValue]
    public var id: String
    public var type: String
    public var partOf: AnnotationCollectionReference
    public var modified: String
    public var items: [MarginComment]
    public var version: Int
    public var revision: Int
    public var document: MarginDocumentReference
    public var projection: String
    public var contentByteLength: Int
    public var contentSha256: String
    public var extensions: [String: JSONValue]

    public init(
        documentID: String,
        modified: String,
        items: [MarginComment] = [],
        revision: Int = 0,
        contentByteLength: Int = 0,
        contentSha256: String = "",
        extensions: [String: JSONValue] = [:]
    ) {
        context = [
            .string("http://www.w3.org/ns/anno.jsonld"),
            .object(["margin": .string("urn:margin:comments:v1:")])
        ]
        id = "\(documentID)#comments"
        type = "AnnotationPage"
        partOf = AnnotationCollectionReference(id: "\(documentID)#collection", total: items.count)
        self.modified = modified
        self.items = items
        version = 1
        self.revision = revision
        document = MarginDocumentReference(id: documentID)
        projection = "markdown-source-v1"
        self.contentByteLength = contentByteLength
        self.contentSha256 = contentSha256
        self.extensions = extensions
    }

    private static let knownKeys: Set<String> = [
        "@context", "id", "type", "partOf", "modified", "items", "margin:version",
        "margin:revision", "margin:document", "margin:projection", "margin:contentByteLength",
        "margin:contentSha256"
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        context = try container.decode([JSONValue].self, forKey: key("@context"))
        id = try container.decode(String.self, forKey: key("id"))
        type = try container.decode(String.self, forKey: key("type"))
        partOf = try container.decode(AnnotationCollectionReference.self, forKey: key("partOf"))
        modified = try container.decode(String.self, forKey: key("modified"))
        items = try container.decode([MarginComment].self, forKey: key("items"))
        version = try container.decode(Int.self, forKey: key("margin:version"))
        revision = try container.decode(Int.self, forKey: key("margin:revision"))
        document = try container.decode(MarginDocumentReference.self, forKey: key("margin:document"))
        projection = try container.decode(String.self, forKey: key("margin:projection"))
        contentByteLength = try container.decode(Int.self, forKey: key("margin:contentByteLength"))
        contentSha256 = try container.decode(String.self, forKey: key("margin:contentSha256"))
        var unknown: [String: JSONValue] = [:]
        for codingKey in container.allKeys where !Self.knownKeys.contains(codingKey.stringValue) {
            unknown[codingKey.stringValue] = try container.decode(JSONValue.self, forKey: codingKey)
        }
        extensions = unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        try container.encode(context, forKey: key("@context"))
        try container.encode(id, forKey: key("id"))
        try container.encode(type, forKey: key("type"))
        try container.encode(partOf, forKey: key("partOf"))
        try container.encode(modified, forKey: key("modified"))
        try container.encode(items, forKey: key("items"))
        try container.encode(version, forKey: key("margin:version"))
        try container.encode(revision, forKey: key("margin:revision"))
        try container.encode(document, forKey: key("margin:document"))
        try container.encode(projection, forKey: key("margin:projection"))
        try container.encode(contentByteLength, forKey: key("margin:contentByteLength"))
        try container.encode(contentSha256, forKey: key("margin:contentSha256"))
        for (name, value) in extensions where !Self.knownKeys.contains(name) {
            try container.encode(value, forKey: key(name))
        }
    }
}

public struct EmbeddedCommentDocument: Sendable {
    public var bodyData: Data
    public var body: String
    public var envelope: EmbeddedCommentEnvelope?

    public init(bodyData: Data, body: String, envelope: EmbeddedCommentEnvelope?) {
        self.bodyData = bodyData
        self.body = body
        self.envelope = envelope
    }
}

public enum CommentAnchorInput: Hashable, Sendable {
    case document
    case range(start: Int, end: Int, expectedExact: String? = nil)
    case quote(exact: String, prefix: String? = nil, suffix: String? = nil, occurrence: Int? = nil)
}

public struct CommentMutationPreconditions: Hashable, Sendable {
    public var revision: Int?
    public var contentSha256: String?

    public init(revision: Int? = nil, contentSha256: String? = nil) {
        self.revision = revision
        self.contentSha256 = contentSha256
    }
}

public enum CommentProtocolError: Error, LocalizedError, Sendable {
    case invalidUTF8
    case multipleCommentBlocks
    case nonterminalCommentBlock
    case invalidEnvelope(String)
    case unsupportedVersion(Int)
    case contentLengthMismatch(expected: Int, actualPrefix: Int)
    case contentHashMismatch(expected: String, actual: String)
    case invalidAnchor(String)
    case anchorNotFound
    case anchorAmbiguous([AnchorCandidate])
    case commentNotFound(String)
    case resolvedThread(String)
    case idConflict(String)
    case revisionConflict(expected: Int, actual: Int)
    case contentConflict(expected: String, actual: String)
    case lockTimeout
    case concurrentModification
    case io(String)

    public var code: String {
        switch self {
        case .invalidUTF8: return "INVALID_UTF8"
        case .multipleCommentBlocks: return "MULTIPLE_COMMENT_BLOCKS"
        case .nonterminalCommentBlock: return "NONTERMINAL_COMMENT_BLOCK"
        case .invalidEnvelope: return "INVALID_COMMENT_ENVELOPE"
        case .unsupportedVersion: return "UNSUPPORTED_PROTOCOL_VERSION"
        case .contentLengthMismatch: return "CONTENT_LENGTH_MISMATCH"
        case .contentHashMismatch: return "CONTENT_HASH_MISMATCH"
        case .invalidAnchor: return "INVALID_ANCHOR"
        case .anchorNotFound: return "ANCHOR_NOT_FOUND"
        case .anchorAmbiguous: return "ANCHOR_AMBIGUOUS"
        case .commentNotFound: return "COMMENT_NOT_FOUND"
        case .resolvedThread: return "THREAD_RESOLVED"
        case .idConflict: return "ID_CONFLICT"
        case .revisionConflict: return "REVISION_CONFLICT"
        case .contentConflict: return "CONTENT_CONFLICT"
        case .lockTimeout: return "LOCK_TIMEOUT"
        case .concurrentModification: return "CONCURRENT_MODIFICATION"
        case .io: return "IO_ERROR"
        }
    }

    public var suggestedExitCode: Int32 {
        switch self {
        case .invalidAnchor, .anchorNotFound, .anchorAmbiguous, .invalidEnvelope,
             .invalidUTF8, .multipleCommentBlocks, .nonterminalCommentBlock,
             .unsupportedVersion, .contentLengthMismatch, .contentHashMismatch,
             .resolvedThread, .idConflict:
            return 65
        case .commentNotFound:
            return 66
        case .revisionConflict, .contentConflict, .lockTimeout, .concurrentModification:
            return 75
        case .io:
            return 74
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The Markdown document is not valid UTF-8."
        case .multipleCommentBlocks:
            return "The document contains more than one Margin comment block."
        case .nonterminalCommentBlock:
            return "The Margin comment block is not the terminal block in the document."
        case .invalidEnvelope(let reason):
            return "The Margin comment envelope is invalid: \(reason)"
        case .unsupportedVersion(let version):
            return "Margin comment protocol version \(version) is not supported for mutation."
        case .contentLengthMismatch(let expected, let actual):
            return "The envelope records \(expected) Markdown bytes, but its position implies \(actual)."
        case .contentHashMismatch(let expected, let actual):
            return "The Markdown hash does not match the envelope (expected \(expected), found \(actual))."
        case .invalidAnchor(let reason):
            return "The comment anchor is invalid: \(reason)"
        case .anchorNotFound:
            return "The quoted text was not found in the Markdown source."
        case .anchorAmbiguous(let candidates):
            return "The quoted text matches \(candidates.count) possible locations."
        case .commentNotFound(let id):
            return "No comment with id '\(id)' exists in this document."
        case .resolvedThread(let id):
            return "Thread '\(id)' is resolved. Reopen it before replying."
        case .idConflict(let id):
            return "Comment id '\(id)' already exists with different content."
        case .revisionConflict(let expected, let actual):
            return "Expected comment revision \(expected), found \(actual)."
        case .contentConflict(let expected, let actual):
            return "Expected content hash \(expected), found \(actual)."
        case .lockTimeout:
            return "Timed out waiting for another Margin writer."
        case .concurrentModification:
            return "The document changed while Margin was preparing the write."
        case .io(let message):
            return message
        }
    }
}

public enum MarginID {
    public static func annotation(_ value: String? = nil) -> String {
        guard let value, !value.isEmpty else {
            return "urn:uuid:\(UUID().uuidString.lowercased())"
        }
        if value.hasPrefix("urn:") || value.contains("://") { return value }
        if UUID(uuidString: value) != nil { return "urn:uuid:\(value.lowercased())" }
        return value
    }

    public static func document(_ uuid: UUID = UUID()) -> String {
        "urn:uuid:\(uuid.uuidString.lowercased())"
    }
}
