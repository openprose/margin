import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Non-negotiable ceilings for source-agnostic comparison work. Callers may
/// choose smaller limits, but cannot raise these values.
public enum ComparisonHardLimits {
    public static let rawDocumentBytes = 16 * 1_024 * 1_024
    public static let snapshotUTF8Bytes = 8 * 1_024 * 1_024
    public static let lines = 100_000
    public static let lineUTF8Bytes = 1_024 * 1_024
    public static let artifactBytes = 64 * 1_024 * 1_024
    public static let blocks = 20_000
    public static let threads = 2_000
    public static let commentsPerThread = 256
    public static let totalComments = 10_000
    public static let commentBodyUTF8Bytes = 64 * 1_024
    public static let extensionJSONBytes = 1_024 * 1_024
    public static let extensionKeys = 256
    public static let extensionNestingDepth = 16
    public static let lineMatrixCells = 2_000_000
    public static let wordMatrixCells = 250_000
    public static let wordTokensPerLine = 16_000
    public static let wordDiffLineUTF8Bytes = 32 * 1_024
    public static let labelUTF8Bytes = 512
    public static let pathHintUTF8Bytes = 4_096
    public static let identifierUTF8Bytes = 512
    public static let actorNameUTF8Bytes = 512
    public static let replyDepth = 32
    /// Explicit review refresh may search for moved quotes, but it may not
    /// perform unbounded snapshot-by-anchor work. Exact-at-position checks are
    /// charged too so unusually large selections remain bounded.
    public static let anchorRefreshScalarComparisons = 32_000_000
    /// Margin-generated quote context is 32 scalars on each side. A wider
    /// interoperability allowance remains bounded for untrusted artifacts.
    public static let anchorContextUnicodeScalars = 256
}

/// A single bounded policy shared by file readers, the diff engine, and review
/// artifacts. Its initializer clamps every value to Margin's hard ceiling.
public struct ComparisonLimits: Codable, Hashable, Sendable {
    public var maxRawDocumentBytes: Int
    public var maxSnapshotUTF8Bytes: Int
    public var maxLines: Int
    public var maxLineUTF8Bytes: Int
    public var maxArtifactBytes: Int
    public var maxBlocks: Int
    public var maxThreads: Int
    public var maxCommentsPerThread: Int
    public var maxTotalComments: Int
    public var maxCommentBodyUTF8Bytes: Int
    public var maxExtensionJSONBytes: Int
    public var maxExtensionKeys: Int
    public var maxExtensionNestingDepth: Int
    public var maxLineMatrixCells: Int
    public var maxWordMatrixCells: Int
    public var maxWordTokensPerLine: Int

    public init(
        maxRawDocumentBytes: Int = ComparisonHardLimits.rawDocumentBytes,
        maxSnapshotUTF8Bytes: Int = ComparisonHardLimits.snapshotUTF8Bytes,
        maxLines: Int = ComparisonHardLimits.lines,
        maxLineUTF8Bytes: Int = ComparisonHardLimits.lineUTF8Bytes,
        maxArtifactBytes: Int = ComparisonHardLimits.artifactBytes,
        maxBlocks: Int = ComparisonHardLimits.blocks,
        maxThreads: Int = ComparisonHardLimits.threads,
        maxCommentsPerThread: Int = ComparisonHardLimits.commentsPerThread,
        maxTotalComments: Int = ComparisonHardLimits.totalComments,
        maxCommentBodyUTF8Bytes: Int = ComparisonHardLimits.commentBodyUTF8Bytes,
        maxExtensionJSONBytes: Int = ComparisonHardLimits.extensionJSONBytes,
        maxExtensionKeys: Int = ComparisonHardLimits.extensionKeys,
        maxExtensionNestingDepth: Int = ComparisonHardLimits.extensionNestingDepth,
        maxLineMatrixCells: Int = ComparisonHardLimits.lineMatrixCells,
        maxWordMatrixCells: Int = ComparisonHardLimits.wordMatrixCells,
        maxWordTokensPerLine: Int = ComparisonHardLimits.wordTokensPerLine
    ) {
        self.maxRawDocumentBytes = Self.clamp(maxRawDocumentBytes, to: ComparisonHardLimits.rawDocumentBytes)
        self.maxSnapshotUTF8Bytes = Self.clamp(maxSnapshotUTF8Bytes, to: ComparisonHardLimits.snapshotUTF8Bytes)
        self.maxLines = Self.clamp(maxLines, to: ComparisonHardLimits.lines)
        self.maxLineUTF8Bytes = Self.clamp(maxLineUTF8Bytes, to: ComparisonHardLimits.lineUTF8Bytes)
        self.maxArtifactBytes = Self.clamp(maxArtifactBytes, to: ComparisonHardLimits.artifactBytes)
        self.maxBlocks = Self.clamp(maxBlocks, to: ComparisonHardLimits.blocks)
        self.maxThreads = Self.clamp(maxThreads, to: ComparisonHardLimits.threads)
        self.maxCommentsPerThread = Self.clamp(maxCommentsPerThread, to: ComparisonHardLimits.commentsPerThread)
        self.maxTotalComments = Self.clamp(maxTotalComments, to: ComparisonHardLimits.totalComments)
        self.maxCommentBodyUTF8Bytes = Self.clamp(maxCommentBodyUTF8Bytes, to: ComparisonHardLimits.commentBodyUTF8Bytes)
        self.maxExtensionJSONBytes = Self.clamp(maxExtensionJSONBytes, to: ComparisonHardLimits.extensionJSONBytes)
        self.maxExtensionKeys = Self.clamp(maxExtensionKeys, to: ComparisonHardLimits.extensionKeys)
        self.maxExtensionNestingDepth = Self.clamp(
            maxExtensionNestingDepth,
            to: ComparisonHardLimits.extensionNestingDepth
        )
        self.maxLineMatrixCells = Self.clamp(maxLineMatrixCells, to: ComparisonHardLimits.lineMatrixCells)
        self.maxWordMatrixCells = Self.clamp(maxWordMatrixCells, to: ComparisonHardLimits.wordMatrixCells)
        self.maxWordTokensPerLine = Self.clamp(maxWordTokensPerLine, to: ComparisonHardLimits.wordTokensPerLine)
    }

    public static let `default` = ComparisonLimits()

    private static func clamp(_ value: Int, to maximum: Int) -> Int {
        min(max(0, value), maximum)
    }
}

public enum ComparisonError: Error, LocalizedError, Sendable {
    case invalidUTF8
    case embeddedCommentEnvelope
    case notRegularFile(String)
    case inputNotFound(String)
    case inputChanged(String)
    case symbolicLink(String)
    case invalidPortablePath(String)
    case resourceLimit(name: String, limit: Int, actual: Int)
    case cancelled
    case invalidSnapshot(String)
    case invalidArtifact(String)
    case unsupportedSchema(String)
    case revisionConflict(expected: Int, actual: Int)
    case immutableSnapshots
    case idConflict(String)
    case reviewAlreadyExists(String)
    case reviewNotFound(String)
    case concurrentModification
    case io(String)

    public var code: String {
        switch self {
        case .invalidUTF8: return "INVALID_UTF8"
        case .embeddedCommentEnvelope: return "EMBEDDED_COMMENT_ENVELOPE"
        case .notRegularFile: return "NOT_REGULAR_FILE"
        case .inputNotFound: return "INPUT_NOT_FOUND"
        case .inputChanged: return "INPUT_CHANGED"
        case .symbolicLink: return "SYMBOLIC_LINK"
        case .invalidPortablePath: return "INVALID_PORTABLE_PATH"
        case .resourceLimit: return "RESOURCE_LIMIT"
        case .cancelled: return "COMPARISON_CANCELLED"
        case .invalidSnapshot: return "INVALID_SNAPSHOT"
        case .invalidArtifact: return "INVALID_COMPARISON_REVIEW"
        case .unsupportedSchema: return "UNSUPPORTED_COMPARISON_SCHEMA"
        case .revisionConflict: return "REVISION_CONFLICT"
        case .immutableSnapshots: return "IMMUTABLE_SNAPSHOTS"
        case .idConflict: return "ID_CONFLICT"
        case .reviewAlreadyExists: return "REVIEW_ALREADY_EXISTS"
        case .reviewNotFound: return "REVIEW_NOT_FOUND"
        case .concurrentModification: return "CONCURRENT_MODIFICATION"
        case .io: return "IO_ERROR"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Comparison input must be valid UTF-8."
        case .embeddedCommentEnvelope:
            return "A comparison snapshot must contain the logical Markdown body, not Margin's terminal comment envelope."
        case .notRegularFile(let path):
            return "Comparison input is not a regular file: \(path)"
        case .inputNotFound(let path):
            return "Comparison input does not exist: \(path)"
        case .inputChanged(let path):
            return "Comparison input changed while it was being read: \(path)"
        case .symbolicLink(let path):
            return "Comparison refuses to follow the symbolic link: \(path)"
        case .invalidPortablePath(let path):
            return "The snapshot path hint is not a portable relative path: \(path)"
        case .resourceLimit(let name, let limit, let actual):
            return "Comparison \(name) exceeds its limit of \(limit) (actual: \(actual))."
        case .cancelled:
            return "The comparison was cancelled."
        case .invalidSnapshot(let reason):
            return "The comparison snapshot is invalid: \(reason)"
        case .invalidArtifact(let reason):
            return "The comparison review is invalid: \(reason)"
        case .unsupportedSchema(let schema):
            return "Unsupported comparison-review schema '\(schema)'."
        case .revisionConflict(let expected, let actual):
            return "The comparison review changed (expected revision \(expected), actual \(actual))."
        case .immutableSnapshots:
            return "Snapshot content can change only through an explicit comparison refresh."
        case .idConflict(let id):
            return "The identifier '\(id)' already names different comparison-review content."
        case .reviewAlreadyExists(let path):
            return "A comparison review already exists at '\(path)'."
        case .reviewNotFound(let path):
            return "No comparison review exists at '\(path)'."
        case .concurrentModification:
            return "The comparison review changed during the atomic write."
        case .io(let message):
            return message
        }
    }
}

/// A cooperative cancellation primitive. Cancellation never produces a
/// partial diff; the engine throws `ComparisonError.cancelled` at a checkpoint.
public final class ComparisonCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// An inert, content-only precondition. It carries no destination path and
/// therefore cannot authorize a write by itself.
public struct ComparisonApplyPrecondition: Codable, Hashable, Sendable {
    public let expectedBodySHA256: String

    public init(expectedBodySHA256: String) throws {
        guard ComparisonValidation.isSHA256(expectedBodySHA256) else {
            throw ComparisonError.invalidSnapshot("The apply precondition is not a SHA-256 digest.")
        }
        self.expectedBodySHA256 = expectedBodySHA256
    }
}

/// An immutable logical Markdown body. When initialized from a document, an
/// existing terminal Margin comment envelope is decoded and excluded.
public struct ComparisonSnapshot: Codable, Hashable, Sendable {
    public let label: String
    public let mediaType: String
    public let content: String
    public let utf8ByteCount: Int
    public let unicodeScalarCount: Int
    public let sha256: String
    public let pathHint: String?
    public let applyPrecondition: ComparisonApplyPrecondition?
    public let extensions: [String: JSONValue]
    public let unknownFields: [String: JSONValue]

    public init(
        markdownDocumentData data: Data,
        label: String,
        mediaType: String = "text/markdown",
        pathHint: String? = nil,
        includeApplyPrecondition: Bool = false,
        extensions: [String: JSONValue] = [:],
        limits: ComparisonLimits = .default
    ) throws {
        guard data.count <= limits.maxRawDocumentBytes else {
            throw ComparisonError.resourceLimit(
                name: "raw document bytes",
                limit: limits.maxRawDocumentBytes,
                actual: data.count
            )
        }
        let decoded: EmbeddedCommentDocument
        do {
            decoded = try EmbeddedCommentCodec().decode(data)
        } catch CommentProtocolError.invalidUTF8 {
            throw ComparisonError.invalidUTF8
        } catch {
            throw ComparisonError.invalidSnapshot(error.localizedDescription)
        }
        try self.init(
            logicalBodyData: Self.normalizedLogicalBody(decoded.bodyData),
            label: label,
            mediaType: mediaType,
            pathHint: pathHint,
            applyPreconditionDigest: includeApplyPrecondition
                ? MarginSHA256.hexDigest(of: Self.normalizedLogicalBody(decoded.bodyData))
                : nil,
            extensions: extensions,
            unknownFields: [:],
            limits: limits
        )
    }

    public init(
        markdownBody: String,
        label: String,
        mediaType: String = "text/markdown",
        pathHint: String? = nil,
        includeApplyPrecondition: Bool = false,
        extensions: [String: JSONValue] = [:],
        limits: ComparisonLimits = .default
    ) throws {
        let data = Data(markdownBody.utf8)
        let decoded = try EmbeddedCommentCodec().decode(data)
        guard decoded.envelope == nil else {
            throw ComparisonError.embeddedCommentEnvelope
        }
        try self.init(
            logicalBodyData: Self.normalizedLogicalBody(data),
            label: label,
            mediaType: mediaType,
            pathHint: pathHint,
            applyPreconditionDigest: includeApplyPrecondition
                ? MarginSHA256.hexDigest(of: Self.normalizedLogicalBody(data))
                : nil,
            extensions: extensions,
            unknownFields: [:],
            limits: limits
        )
    }

    public static func readMarkdownFile(
        at url: URL,
        label: String? = nil,
        mediaType: String = "text/markdown",
        pathHint: String? = nil,
        includeApplyPrecondition: Bool = true,
        extensions: [String: JSONValue] = [:],
        limits: ComparisonLimits = .default
    ) throws -> ComparisonSnapshot {
        let data = try ComparisonRegularFile.read(
            at: url,
            maximumBytes: limits.maxRawDocumentBytes
        )
        return try ComparisonSnapshot(
            markdownDocumentData: data,
            label: label ?? url.lastPathComponent,
            mediaType: mediaType,
            pathHint: pathHint,
            includeApplyPrecondition: includeApplyPrecondition,
            extensions: extensions,
            limits: limits
        )
    }

    public var bodyData: Data { Data(content.utf8) }

    private init(
        logicalBodyData data: Data,
        label: String,
        mediaType: String,
        pathHint: String?,
        applyPreconditionDigest: String?,
        extensions: [String: JSONValue],
        unknownFields: [String: JSONValue],
        limits: ComparisonLimits
    ) throws {
        let data = Self.normalizedLogicalBody(data)
        let decoded = try EmbeddedCommentCodec().decode(data)
        guard decoded.envelope == nil else {
            throw ComparisonError.embeddedCommentEnvelope
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw ComparisonError.invalidUTF8
        }
        guard !data.contains(0) else {
            throw ComparisonError.invalidSnapshot("Logical Markdown bodies cannot contain NUL bytes.")
        }
        guard !label.isEmpty,
              label.utf8.count <= ComparisonHardLimits.labelUTF8Bytes else {
            throw ComparisonError.invalidSnapshot("The label is empty or too long.")
        }
        guard !mediaType.isEmpty,
              mediaType.utf8.count <= ComparisonHardLimits.labelUTF8Bytes else {
            throw ComparisonError.invalidSnapshot("The media type is empty or too long.")
        }
        if let pathHint { try ComparisonValidation.validatePortablePath(pathHint) }
        guard data.count <= limits.maxSnapshotUTF8Bytes else {
            throw ComparisonError.resourceLimit(
                name: "snapshot UTF-8 bytes",
                limit: limits.maxSnapshotUTF8Bytes,
                actual: data.count
            )
        }
        _ = try ComparisonTextParser.parse(data, limits: limits, cancellation: nil)
        try ComparisonValidation.validateExtensionBytes(
            extensions,
            maximum: limits.maxExtensionJSONBytes,
            maximumKeys: limits.maxExtensionKeys,
            maximumDepth: limits.maxExtensionNestingDepth
        )
        try ComparisonValidation.validateExtensionBytes(
            unknownFields,
            maximum: limits.maxExtensionJSONBytes,
            maximumKeys: limits.maxExtensionKeys,
            maximumDepth: limits.maxExtensionNestingDepth
        )
        let digest = MarginSHA256.hexDigest(of: data)
        self.label = label
        self.mediaType = mediaType
        self.content = content
        utf8ByteCount = data.count
        unicodeScalarCount = content.unicodeScalars.count
        sha256 = digest
        self.pathHint = pathHint
        applyPrecondition = try applyPreconditionDigest.map(ComparisonApplyPrecondition.init)
        self.extensions = extensions
        self.unknownFields = unknownFields
    }

    public func validate(limits: ComparisonLimits = .default) throws {
        let data = bodyData
        guard data.count == utf8ByteCount,
              content.unicodeScalars.count == unicodeScalarCount,
              MarginSHA256.hexDigest(of: data) == sha256 else {
            throw ComparisonError.invalidSnapshot("Snapshot counts or digest do not match its body.")
        }
        guard data.count <= limits.maxSnapshotUTF8Bytes else {
            throw ComparisonError.resourceLimit(
                name: "snapshot UTF-8 bytes",
                limit: limits.maxSnapshotUTF8Bytes,
                actual: data.count
            )
        }
        _ = try ComparisonTextParser.parse(data, limits: limits, cancellation: nil)
        if let pathHint { try ComparisonValidation.validatePortablePath(pathHint) }
        if let applyPrecondition,
           applyPrecondition.expectedBodySHA256 != sha256 {
            throw ComparisonError.invalidSnapshot(
                "The apply precondition does not match the logical body digest."
            )
        }
        try ComparisonValidation.validateExtensionBytes(
            extensions,
            maximum: limits.maxExtensionJSONBytes,
            maximumKeys: limits.maxExtensionKeys,
            maximumDepth: limits.maxExtensionNestingDepth
        )
        try ComparisonValidation.validateExtensionBytes(
            unknownFields,
            maximum: limits.maxExtensionJSONBytes,
            maximumKeys: limits.maxExtensionKeys,
            maximumDepth: limits.maxExtensionNestingDepth
        )
    }

    private static func normalizedLogicalBody(_ data: Data) -> Data {
        if data.starts(with: [0xef, 0xbb, 0xbf]) {
            return Data(data.dropFirst(3))
        }
        return data
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case label, mediaType, content, utf8ByteCount, unicodeScalarCount, sha256
        case pathHint, applyPrecondition, extensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        let label = try container.decode(String.self, forKey: key("label"))
        let mediaType = try container.decode(String.self, forKey: key("mediaType"))
        let content = try container.decode(String.self, forKey: key("content"))
        let byteCount = try container.decode(Int.self, forKey: key("utf8ByteCount"))
        let scalarCount = try container.decode(Int.self, forKey: key("unicodeScalarCount"))
        let digest = try container.decode(String.self, forKey: key("sha256"))
        let pathHint = try container.decodeIfPresent(String.self, forKey: key("pathHint"))
        let precondition = try container.decodeIfPresent(
            ComparisonApplyPrecondition.self,
            forKey: key("applyPrecondition")
        )
        let extensions = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: key("extensions")
        ) ?? [:]
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        var unknown: [String: JSONValue] = [:]
        for codingKey in container.allKeys where !known.contains(codingKey.stringValue) {
            unknown[codingKey.stringValue] = try container.decode(JSONValue.self, forKey: codingKey)
        }
        do {
            try self.init(
                logicalBodyData: Data(content.utf8),
                label: label,
                mediaType: mediaType,
                pathHint: pathHint,
                applyPreconditionDigest: precondition?.expectedBodySHA256,
                extensions: extensions,
                unknownFields: unknown,
                limits: .default
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: key("content"),
                in: container,
                debugDescription: error.localizedDescription
            )
        }
        guard utf8ByteCount == byteCount,
              unicodeScalarCount == scalarCount,
              sha256 == digest else {
            throw DecodingError.dataCorruptedError(
                forKey: key("sha256"),
                in: container,
                debugDescription: "Snapshot counts or digest do not match its logical body."
            )
        }
        if precondition != nil && precondition?.expectedBodySHA256 != sha256 {
            throw DecodingError.dataCorruptedError(
                forKey: key("applyPrecondition"),
                in: container,
                debugDescription: "The apply precondition does not match the snapshot body."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        try container.encode(label, forKey: key("label"))
        try container.encode(mediaType, forKey: key("mediaType"))
        try container.encode(content, forKey: key("content"))
        try container.encode(utf8ByteCount, forKey: key("utf8ByteCount"))
        try container.encode(unicodeScalarCount, forKey: key("unicodeScalarCount"))
        try container.encode(sha256, forKey: key("sha256"))
        try container.encodeIfPresent(pathHint, forKey: key("pathHint"))
        try container.encodeIfPresent(applyPrecondition, forKey: key("applyPrecondition"))
        if !extensions.isEmpty { try container.encode(extensions, forKey: key("extensions")) }
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        for (name, value) in unknownFields where !known.contains(name) {
            try container.encode(value, forKey: key(name))
        }
    }
}

public struct ComparisonSnapshotPair: Codable, Hashable, Sendable {
    public let id: String
    public let generation: Int
    public let left: ComparisonSnapshot
    public let right: ComparisonSnapshot
    public let extensions: [String: JSONValue]

    public init(
        generation: Int = 0,
        left: ComparisonSnapshot,
        right: ComparisonSnapshot,
        extensions: [String: JSONValue] = [:]
    ) throws {
        guard generation >= 0 else {
            throw ComparisonError.invalidSnapshot("Snapshot generation cannot be negative.")
        }
        self.generation = generation
        self.left = left
        self.right = right
        self.extensions = extensions
        id = Self.identifier(
            generation: generation,
            leftDigest: left.sha256,
            rightDigest: right.sha256
        )
        try ComparisonValidation.validateExtensionBytes(
            extensions,
            maximum: ComparisonHardLimits.extensionJSONBytes,
            maximumKeys: ComparisonHardLimits.extensionKeys,
            maximumDepth: ComparisonHardLimits.extensionNestingDepth
        )
    }

    public static func identifier(
        generation: Int,
        leftDigest: String,
        rightDigest: String
    ) -> String {
        let seed = Data(
            "margin-comparison-pair-v1\0\(generation)\0\(leftDigest)\0\(rightDigest)".utf8
        )
        return "urn:margin:comparison-pair:\(MarginSHA256.hexDigest(of: seed))"
    }

    private enum CodingKeys: String, CodingKey {
        case id, generation, left, right, extensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let claimedID = try container.decode(String.self, forKey: .id)
        do {
            try self.init(
                generation: try container.decode(Int.self, forKey: .generation),
                left: try container.decode(ComparisonSnapshot.self, forKey: .left),
                right: try container.decode(ComparisonSnapshot.self, forKey: .right),
                extensions: try container.decodeIfPresent(
                    [String: JSONValue].self,
                    forKey: .extensions
                ) ?? [:]
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
        guard id == claimedID else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Snapshot-pair ID does not match the snapshot digests."
            )
        }
    }
}

/// All coordinate systems are named explicitly. Line offsets are zero-based;
/// scalar and UTF-8 intervals are half-open and refer to the original logical
/// snapshot body, including its original line-ending bytes/scalars.
public struct ComparisonTextRange: Codable, Hashable, Sendable {
    public let lineStart: Int
    public let lineCount: Int
    public let unicodeScalarStart: Int
    public let unicodeScalarLength: Int
    public let utf8ByteStart: Int
    public let utf8ByteLength: Int

    public init(
        lineStart: Int,
        lineCount: Int,
        unicodeScalarStart: Int,
        unicodeScalarLength: Int,
        utf8ByteStart: Int,
        utf8ByteLength: Int
    ) throws {
        guard lineStart >= 0, lineCount >= 0,
              unicodeScalarStart >= 0, unicodeScalarLength >= 0,
              utf8ByteStart >= 0, utf8ByteLength >= 0 else {
            throw ComparisonError.invalidSnapshot("Comparison ranges cannot be negative.")
        }
        self.lineStart = lineStart
        self.lineCount = lineCount
        self.unicodeScalarStart = unicodeScalarStart
        self.unicodeScalarLength = unicodeScalarLength
        self.utf8ByteStart = utf8ByteStart
        self.utf8ByteLength = utf8ByteLength
    }
}

public enum ComparisonBlockKind: String, Codable, Sendable {
    case unchanged
    case insertion
    case deletion
    case replacement
}

public enum ComparisonWordSegmentKind: String, Codable, Sendable {
    case unchanged
    case insertion
    case deletion
}

public struct ComparisonWordSegment: Codable, Hashable, Sendable {
    public let kind: ComparisonWordSegmentKind
    public let leftUnicodeScalars: UnicodeScalarRange?
    public let rightUnicodeScalars: UnicodeScalarRange?
    public let leftUTF8Bytes: RangeValue?
    public let rightUTF8Bytes: RangeValue?

    public struct RangeValue: Codable, Hashable, Sendable {
        public let start: Int
        public let length: Int

        public init(start: Int, length: Int) {
            self.start = max(0, start)
            self.length = max(0, length)
        }
    }
}

public struct ComparisonWordDiff: Codable, Hashable, Sendable {
    public let leftLine: Int
    public let rightLine: Int
    public let segments: [ComparisonWordSegment]
    public let isCoarse: Bool
}

public struct ComparisonBlock: Codable, Hashable, Sendable {
    /// Present only for changed blocks; derived from the exact pair ID and the
    /// two source ranges, so an ID is meaningful only inside that pair.
    public let id: String?
    public let kind: ComparisonBlockKind
    public let left: ComparisonTextRange
    public let right: ComparisonTextRange
    public let wordDiffs: [ComparisonWordDiff]
}

public enum ComparisonCoarseReason: String, Codable, Sendable {
    case lineWorkBudget
    case wordWorkBudget
    case wordTokenLimit
}

public struct ComparisonDiffResult: Codable, Hashable, Sendable {
    public let pairID: String
    public let snapshotGeneration: Int
    public let leftSHA256: String
    public let rightSHA256: String
    public let blocks: [ComparisonBlock]
    public let isCoarse: Bool
    public let coarseReasons: [ComparisonCoarseReason]

    public var changedBlocks: [ComparisonBlock] {
        blocks.filter { $0.kind != .unchanged }
    }
}

public struct ComparisonEngine: Sendable {
    public var limits: ComparisonLimits

    public init(limits: ComparisonLimits = .default) {
        self.limits = limits
    }

    public func compare(
        _ pair: ComparisonSnapshotPair,
        cancellation: ComparisonCancellationToken? = nil
    ) throws -> ComparisonDiffResult {
        try Self.checkCancellation(cancellation)
        let leftData = pair.left.bodyData
        let rightData = pair.right.bodyData
        let leftLines = try ComparisonTextParser.parse(
            leftData,
            limits: limits,
            cancellation: cancellation
        )
        let rightLines = try ComparisonTextParser.parse(
            rightData,
            limits: limits,
            cancellation: cancellation
        )
        var reasons = Set<ComparisonCoarseReason>()
        let lineDiff = try Self.sequenceOperations(
            left: leftLines.map(\.comparisonKey),
            right: rightLines.map(\.comparisonKey),
            maximumCells: limits.maxLineMatrixCells,
            cancellation: cancellation
        )
        if lineDiff.coarse { reasons.insert(.lineWorkBudget) }

        var blocks: [ComparisonBlock] = []
        var changedBlockCount = 0
        var operationIndex = 0
        while operationIndex < lineDiff.operations.count {
            try Self.checkCancellation(cancellation)
            let isEqual = lineDiff.operations[operationIndex].isEqual
            let start = operationIndex
            while operationIndex < lineDiff.operations.count,
                  lineDiff.operations[operationIndex].isEqual == isEqual {
                operationIndex += 1
            }
            let operations = lineDiff.operations[start..<operationIndex]
            let leftIndexes = operations.compactMap(\.leftIndex)
            let rightIndexes = operations.compactMap(\.rightIndex)
            let leftStart = leftIndexes.min() ?? Self.insertionIndex(
                before: operations,
                in: lineDiff.operations,
                sliceStart: start,
                side: .left
            )
            let rightStart = rightIndexes.min() ?? Self.insertionIndex(
                before: operations,
                in: lineDiff.operations,
                sliceStart: start,
                side: .right
            )
            let leftCount = leftIndexes.count
            let rightCount = rightIndexes.count
            let kind: ComparisonBlockKind
            if isEqual {
                kind = .unchanged
            } else if leftCount == 0 {
                kind = .insertion
            } else if rightCount == 0 {
                kind = .deletion
            } else {
                kind = .replacement
            }
            let leftRange = try Self.range(
                lines: leftLines,
                start: leftStart,
                count: leftCount,
                totalBytes: leftData.count,
                totalScalars: pair.left.unicodeScalarCount
            )
            let rightRange = try Self.range(
                lines: rightLines,
                start: rightStart,
                count: rightCount,
                totalBytes: rightData.count,
                totalScalars: pair.right.unicodeScalarCount
            )
            var wordDiffs: [ComparisonWordDiff] = []
            if kind == .replacement, !lineDiff.coarse {
                let paired = min(leftCount, rightCount)
                for offset in 0..<paired {
                    let leftLine = leftLines[leftStart + offset]
                    let rightLine = rightLines[rightStart + offset]
                    guard leftLine.utf8End - leftLine.utf8Start
                            <= ComparisonHardLimits.wordDiffLineUTF8Bytes,
                          rightLine.utf8End - rightLine.utf8Start
                            <= ComparisonHardLimits.wordDiffLineUTF8Bytes else {
                        // Long replacements retain the exact line-level block.
                        // They are intentionally not reported as a coarse
                        // comparison because no line-level work was omitted.
                        continue
                    }
                    let word = try Self.wordDiff(
                        left: leftLine,
                        right: rightLine,
                        leftLine: leftStart + offset,
                        rightLine: rightStart + offset,
                        limits: limits,
                        cancellation: cancellation
                    )
                    if word.reason != nil { reasons.insert(word.reason!) }
                    wordDiffs.append(word.diff)
                }
            }
            let id = kind == .unchanged ? nil : Self.blockIdentifier(
                pairID: pair.id,
                left: leftRange,
                right: rightRange
            )
            blocks.append(ComparisonBlock(
                id: id,
                kind: kind,
                left: leftRange,
                right: rightRange,
                wordDiffs: wordDiffs
            ))
            if kind != .unchanged { changedBlockCount += 1 }
            if changedBlockCount > limits.maxBlocks {
                throw ComparisonError.resourceLimit(
                    name: "changed diff blocks",
                    limit: limits.maxBlocks,
                    actual: changedBlockCount
                )
            }
        }

        return ComparisonDiffResult(
            pairID: pair.id,
            snapshotGeneration: pair.generation,
            leftSHA256: pair.left.sha256,
            rightSHA256: pair.right.sha256,
            blocks: blocks,
            isCoarse: !reasons.isEmpty,
            coarseReasons: reasons.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private enum Side { case left, right }

    private static func insertionIndex(
        before slice: ArraySlice<SequenceOperation>,
        in all: [SequenceOperation],
        sliceStart: Int,
        side: Side
    ) -> Int {
        if sliceStart > 0 {
            for operation in all[..<sliceStart].reversed() {
                let value = side == .left ? operation.leftIndex : operation.rightIndex
                if let value { return value + 1 }
            }
        }
        for operation in slice {
            let value = side == .left ? operation.leftIndex : operation.rightIndex
            if let value { return value }
        }
        return 0
    }

    private static func range(
        lines: [ParsedComparisonLine],
        start: Int,
        count: Int,
        totalBytes: Int,
        totalScalars: Int
    ) throws -> ComparisonTextRange {
        let boundedStart = min(max(0, start), lines.count)
        let byteStart = boundedStart < lines.count ? lines[boundedStart].utf8Start : totalBytes
        let scalarStart = boundedStart < lines.count ? lines[boundedStart].scalarStart : totalScalars
        let byteEnd: Int
        let scalarEnd: Int
        if count > 0, boundedStart + count - 1 < lines.count {
            byteEnd = lines[boundedStart + count - 1].utf8End
            scalarEnd = lines[boundedStart + count - 1].scalarEnd
        } else {
            byteEnd = byteStart
            scalarEnd = scalarStart
        }
        return try ComparisonTextRange(
            lineStart: boundedStart,
            lineCount: count,
            unicodeScalarStart: scalarStart,
            unicodeScalarLength: scalarEnd - scalarStart,
            utf8ByteStart: byteStart,
            utf8ByteLength: byteEnd - byteStart
        )
    }

    private static func blockIdentifier(
        pairID: String,
        left: ComparisonTextRange,
        right: ComparisonTextRange
    ) -> String {
        let seed = [
            "margin-comparison-block-v1", pairID,
            String(left.lineStart), String(left.lineCount),
            String(left.unicodeScalarStart), String(left.unicodeScalarLength),
            String(left.utf8ByteStart), String(left.utf8ByteLength),
            String(right.lineStart), String(right.lineCount),
            String(right.unicodeScalarStart), String(right.unicodeScalarLength),
            String(right.utf8ByteStart), String(right.utf8ByteLength),
        ].joined(separator: "\0")
        return "urn:margin:comparison-block:\(MarginSHA256.hexDigest(of: Data(seed.utf8)))"
    }

    private static func wordDiff(
        left: ParsedComparisonLine,
        right: ParsedComparisonLine,
        leftLine: Int,
        rightLine: Int,
        limits: ComparisonLimits,
        cancellation: ComparisonCancellationToken?
    ) throws -> (diff: ComparisonWordDiff, reason: ComparisonCoarseReason?) {
        let leftTokens = try ComparisonWordTokenizer.tokens(
            in: left,
            maximum: limits.maxWordTokensPerLine,
            cancellation: cancellation
        )
        let rightTokens = try ComparisonWordTokenizer.tokens(
            in: right,
            maximum: limits.maxWordTokensPerLine,
            cancellation: cancellation
        )
        guard !leftTokens.truncated, !rightTokens.truncated else {
            return (
                ComparisonWordDiff(
                    leftLine: leftLine,
                    rightLine: rightLine,
                    segments: [],
                    isCoarse: true
                ),
                .wordTokenLimit
            )
        }
        let operations = try sequenceOperations(
            left: leftTokens.tokens.map(\.text),
            right: rightTokens.tokens.map(\.text),
            maximumCells: limits.maxWordMatrixCells,
            cancellation: cancellation
        )
        if operations.coarse {
            return (
                ComparisonWordDiff(
                    leftLine: leftLine,
                    rightLine: rightLine,
                    segments: [],
                    isCoarse: true
                ),
                .wordWorkBudget
            )
        }

        var segments: [ComparisonWordSegment] = []
        var index = 0
        while index < operations.operations.count {
            let equal = operations.operations[index].isEqual
            let start = index
            while index < operations.operations.count,
                  operations.operations[index].isEqual == equal {
                index += 1
            }
            let group = operations.operations[start..<index]
            if equal {
                let leftIndexes = group.compactMap(\.leftIndex)
                let rightIndexes = group.compactMap(\.rightIndex)
                if let leftFirst = leftIndexes.first,
                   let leftLast = leftIndexes.last,
                   let rightFirst = rightIndexes.first,
                   let rightLast = rightIndexes.last {
                    segments.append(segment(
                        kind: .unchanged,
                        leftFirst: leftTokens.tokens[leftFirst],
                        leftLast: leftTokens.tokens[leftLast],
                        rightFirst: rightTokens.tokens[rightFirst],
                        rightLast: rightTokens.tokens[rightLast]
                    ))
                }
            } else {
                let leftIndexes = group.compactMap(\.leftIndex)
                if let first = leftIndexes.first, let last = leftIndexes.last {
                    segments.append(segment(
                        kind: .deletion,
                        leftFirst: leftTokens.tokens[first],
                        leftLast: leftTokens.tokens[last],
                        rightFirst: nil,
                        rightLast: nil
                    ))
                }
                let rightIndexes = group.compactMap(\.rightIndex)
                if let first = rightIndexes.first, let last = rightIndexes.last {
                    segments.append(segment(
                        kind: .insertion,
                        leftFirst: nil,
                        leftLast: nil,
                        rightFirst: rightTokens.tokens[first],
                        rightLast: rightTokens.tokens[last]
                    ))
                }
            }
        }
        return (
            ComparisonWordDiff(
                leftLine: leftLine,
                rightLine: rightLine,
                segments: segments,
                isCoarse: false
            ),
            nil
        )
    }

    private static func segment(
        kind: ComparisonWordSegmentKind,
        leftFirst: ComparisonWordToken?,
        leftLast: ComparisonWordToken?,
        rightFirst: ComparisonWordToken?,
        rightLast: ComparisonWordToken?
    ) -> ComparisonWordSegment {
        let leftScalar = scalarRange(first: leftFirst, last: leftLast)
        let rightScalar = scalarRange(first: rightFirst, last: rightLast)
        let leftBytes = byteRange(first: leftFirst, last: leftLast)
        let rightBytes = byteRange(first: rightFirst, last: rightLast)
        return ComparisonWordSegment(
            kind: kind,
            leftUnicodeScalars: leftScalar,
            rightUnicodeScalars: rightScalar,
            leftUTF8Bytes: leftBytes,
            rightUTF8Bytes: rightBytes
        )
    }

    private static func scalarRange(
        first: ComparisonWordToken?,
        last: ComparisonWordToken?
    ) -> UnicodeScalarRange? {
        guard let first, let last else { return nil }
        return UnicodeScalarRange(
            start: first.scalarStart,
            end: last.scalarEnd
        )
    }

    private static func byteRange(
        first: ComparisonWordToken?,
        last: ComparisonWordToken?
    ) -> ComparisonWordSegment.RangeValue? {
        guard let first, let last else { return nil }
        return ComparisonWordSegment.RangeValue(
            start: first.utf8Start,
            length: last.utf8End - first.utf8Start
        )
    }

    private struct SequenceDiff {
        let operations: [SequenceOperation]
        let coarse: Bool
    }

    private enum SequenceOperation {
        case equal(left: Int, right: Int)
        case delete(left: Int)
        case insert(right: Int)

        var isEqual: Bool {
            if case .equal = self { return true }
            return false
        }

        var leftIndex: Int? {
            switch self {
            case .equal(let left, _), .delete(let left): return left
            case .insert: return nil
            }
        }

        var rightIndex: Int? {
            switch self {
            case .equal(_, let right), .insert(let right): return right
            case .delete: return nil
            }
        }
    }

    /// Deterministic bounded LCS. Equal-cost ties prefer deletion, which keeps
    /// repeated-line results stable. If the interior exceeds the work budget,
    /// it becomes one coarse delete/insert run rather than consuming unbounded
    /// CPU or producing elapsed-time-dependent partial output.
    private static func sequenceOperations(
        left: [String],
        right: [String],
        maximumCells: Int,
        cancellation: ComparisonCancellationToken?
    ) throws -> SequenceDiff {
        try checkCancellation(cancellation)
        var prefix = 0
        while prefix < left.count,
              prefix < right.count,
              left[prefix] == right[prefix] {
            prefix += 1
            if prefix & 0x3ff == 0 { try checkCancellation(cancellation) }
        }
        var suffix = 0
        while suffix < left.count - prefix,
              suffix < right.count - prefix,
              left[left.count - 1 - suffix] == right[right.count - 1 - suffix] {
            suffix += 1
            if suffix & 0x3ff == 0 { try checkCancellation(cancellation) }
        }
        let leftInterior = left.count - prefix - suffix
        let rightInterior = right.count - prefix - suffix
        let (cells, overflow) = leftInterior.multipliedReportingOverflow(by: rightInterior)
        var output = (0..<prefix).map { SequenceOperation.equal(left: $0, right: $0) }
        if overflow || cells > maximumCells {
            output.append(contentsOf: (0..<leftInterior).map {
                .delete(left: prefix + $0)
            })
            output.append(contentsOf: (0..<rightInterior).map {
                .insert(right: prefix + $0)
            })
            output.append(contentsOf: (0..<suffix).map {
                .equal(
                    left: left.count - suffix + $0,
                    right: right.count - suffix + $0
                )
            })
            return SequenceDiff(operations: output, coarse: true)
        }

        if leftInterior == 0 {
            output.append(contentsOf: (0..<rightInterior).map { .insert(right: prefix + $0) })
        } else if rightInterior == 0 {
            output.append(contentsOf: (0..<leftInterior).map { .delete(left: prefix + $0) })
        } else {
            let columns = rightInterior + 1
            var matrix = [Int32](repeating: 0, count: (leftInterior + 1) * columns)
            var work = 0
            for leftIndex in stride(from: leftInterior - 1, through: 0, by: -1) {
                for rightIndex in stride(from: rightInterior - 1, through: 0, by: -1) {
                    let index = leftIndex * columns + rightIndex
                    if left[prefix + leftIndex] == right[prefix + rightIndex] {
                        matrix[index] = 1 + matrix[(leftIndex + 1) * columns + rightIndex + 1]
                    } else {
                        matrix[index] = max(
                            matrix[(leftIndex + 1) * columns + rightIndex],
                            matrix[leftIndex * columns + rightIndex + 1]
                        )
                    }
                    work += 1
                    if work & 0x3ff == 0 { try checkCancellation(cancellation) }
                }
            }
            var leftIndex = 0
            var rightIndex = 0
            while leftIndex < leftInterior || rightIndex < rightInterior {
                try checkCancellation(cancellation)
                if leftIndex < leftInterior,
                   rightIndex < rightInterior,
                   left[prefix + leftIndex] == right[prefix + rightIndex] {
                    output.append(.equal(
                        left: prefix + leftIndex,
                        right: prefix + rightIndex
                    ))
                    leftIndex += 1
                    rightIndex += 1
                } else if rightIndex == rightInterior || (
                    leftIndex < leftInterior
                    && matrix[(leftIndex + 1) * columns + rightIndex]
                        >= matrix[leftIndex * columns + rightIndex + 1]
                ) {
                    output.append(.delete(left: prefix + leftIndex))
                    leftIndex += 1
                } else {
                    output.append(.insert(right: prefix + rightIndex))
                    rightIndex += 1
                }
            }
        }
        output.append(contentsOf: (0..<suffix).map {
            .equal(
                left: left.count - suffix + $0,
                right: right.count - suffix + $0
            )
        })
        return SequenceDiff(operations: output, coarse: false)
    }

    private static func checkCancellation(
        _ cancellation: ComparisonCancellationToken?
    ) throws {
        if cancellation?.isCancelled == true { throw ComparisonError.cancelled }
    }
}

private struct ParsedComparisonLine {
    let text: String
    let terminated: Bool
    let utf8Start: Int
    let utf8ContentEnd: Int
    let utf8End: Int
    let scalarStart: Int
    let scalarContentEnd: Int
    let scalarEnd: Int

    var comparisonKey: String {
        // The exact line-ending spelling is normalized, but the presence of a
        // final boundary remains meaningful.
        text + (terminated ? "\u{0}" : "\u{1}")
    }
}

private enum ComparisonTextParser {
    static func parse(
        _ data: Data,
        limits: ComparisonLimits,
        cancellation: ComparisonCancellationToken?
    ) throws -> [ParsedComparisonLine] {
        guard data.count <= limits.maxSnapshotUTF8Bytes else {
            throw ComparisonError.resourceLimit(
                name: "snapshot UTF-8 bytes",
                limit: limits.maxSnapshotUTF8Bytes,
                actual: data.count
            )
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ComparisonError.invalidUTF8
        }
        let bytes = [UInt8](data)
        var lines: [ParsedComparisonLine] = []
        lines.reserveCapacity(min(limits.maxLines, max(1, bytes.count / 32)))
        var byteStart = 0
        var scalarStart = 0
        var index = 0
        while index < bytes.count {
            if index & 0xfff == 0, cancellation?.isCancelled == true {
                throw ComparisonError.cancelled
            }
            let byte = bytes[index]
            guard byte == 0x0a || byte == 0x0d else {
                index += 1
                continue
            }
            let terminatorLength = byte == 0x0d
                && index + 1 < bytes.count
                && bytes[index + 1] == 0x0a ? 2 : 1
            let contentData = Data(bytes[byteStart..<index])
            guard contentData.count + terminatorLength <= limits.maxLineUTF8Bytes else {
                throw ComparisonError.resourceLimit(
                    name: "line UTF-8 bytes",
                    limit: limits.maxLineUTF8Bytes,
                    actual: contentData.count + terminatorLength
                )
            }
            let text = String(decoding: contentData, as: UTF8.self)
            let contentScalars = text.unicodeScalars.count
            lines.append(ParsedComparisonLine(
                text: text,
                terminated: true,
                utf8Start: byteStart,
                utf8ContentEnd: index,
                utf8End: index + terminatorLength,
                scalarStart: scalarStart,
                scalarContentEnd: scalarStart + contentScalars,
                scalarEnd: scalarStart + contentScalars + terminatorLength
            ))
            if lines.count > limits.maxLines {
                throw ComparisonError.resourceLimit(
                    name: "lines",
                    limit: limits.maxLines,
                    actual: lines.count
                )
            }
            index += terminatorLength
            byteStart = index
            scalarStart += contentScalars + terminatorLength
        }
        if byteStart < bytes.count {
            let contentData = Data(bytes[byteStart..<bytes.count])
            guard contentData.count <= limits.maxLineUTF8Bytes else {
                throw ComparisonError.resourceLimit(
                    name: "line UTF-8 bytes",
                    limit: limits.maxLineUTF8Bytes,
                    actual: contentData.count
                )
            }
            let text = String(decoding: contentData, as: UTF8.self)
            let contentScalars = text.unicodeScalars.count
            lines.append(ParsedComparisonLine(
                text: text,
                terminated: false,
                utf8Start: byteStart,
                utf8ContentEnd: bytes.count,
                utf8End: bytes.count,
                scalarStart: scalarStart,
                scalarContentEnd: scalarStart + contentScalars,
                scalarEnd: scalarStart + contentScalars
            ))
        }
        if lines.count > limits.maxLines {
            throw ComparisonError.resourceLimit(
                name: "lines",
                limit: limits.maxLines,
                actual: lines.count
            )
        }
        return lines
    }
}

private struct ComparisonWordToken {
    let text: String
    let utf8Start: Int
    let utf8End: Int
    let scalarStart: Int
    let scalarEnd: Int
}

private enum ComparisonWordTokenizer {
    private enum Category { case whitespace, word, punctuation }

    static func tokens(
        in line: ParsedComparisonLine,
        maximum: Int,
        cancellation: ComparisonCancellationToken?
    ) throws -> (tokens: [ComparisonWordToken], truncated: Bool) {
        var tokens: [ComparisonWordToken] = []
        var currentText = ""
        var currentCategory: Category?
        var byteOffset = line.utf8Start
        var scalarOffset = line.scalarStart
        var tokenByteStart = byteOffset
        var tokenScalarStart = scalarOffset

        func flush() {
            guard !currentText.isEmpty else { return }
            tokens.append(ComparisonWordToken(
                text: currentText,
                utf8Start: tokenByteStart,
                utf8End: byteOffset,
                scalarStart: tokenScalarStart,
                scalarEnd: scalarOffset
            ))
            currentText = ""
        }

        for (index, scalar) in line.text.unicodeScalars.enumerated() {
            if index & 0xfff == 0, cancellation?.isCancelled == true {
                throw ComparisonError.cancelled
            }
            let category = category(of: scalar)
            if currentCategory != nil, currentCategory != category {
                flush()
                if tokens.count > maximum { return ([], true) }
                tokenByteStart = byteOffset
                tokenScalarStart = scalarOffset
            }
            currentCategory = category
            currentText.unicodeScalars.append(scalar)
            byteOffset += scalar.utf8.count
            scalarOffset += 1
        }
        flush()
        return tokens.count > maximum ? ([], true) : (tokens, false)
    }

    private static func category(of scalar: UnicodeScalar) -> Category {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .whitespace }
        if CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
            || scalar == "_" {
            return .word
        }
        return .punctuation
    }
}

enum ComparisonValidation {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    static func validatePortablePath(_ path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= ComparisonHardLimits.pathHintUTF8Bytes,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.contains("\0") else {
            throw ComparisonError.invalidPortablePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !(components.first?.contains(":") ?? false) else {
            throw ComparisonError.invalidPortablePath(path)
        }
    }

    static func validateIdentifier(_ value: String, name: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= ComparisonHardLimits.identifierUTF8Bytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ComparisonError.invalidArtifact("\(name) is empty, too long, or contains controls.")
        }
    }

    static func validateActor(_ actor: MarginActor, name: String) throws {
        try validateIdentifier(actor.id, name: "\(name) actor ID")
        guard !actor.name.isEmpty,
              actor.name.utf8.count <= ComparisonHardLimits.actorNameUTF8Bytes,
              !actor.name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ComparisonError.invalidArtifact("\(name) actor name is empty, too long, or contains controls.")
        }
    }

    static func isTimestamp(_ value: String) -> Bool {
        guard value.utf8.count <= 128 else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: value) != nil
    }

    static func validateExtensionBytes(
        _ extensions: [String: JSONValue],
        maximum: Int,
        maximumKeys: Int = ComparisonHardLimits.extensionKeys,
        maximumDepth: Int = ComparisonHardLimits.extensionNestingDepth
    ) throws {
        guard !extensions.keys.contains(where: { $0.isEmpty || $0.utf8.count > 512 }) else {
            throw ComparisonError.invalidArtifact("An extension name is empty or too long.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(extensions)
        guard data.count <= maximum else {
            throw ComparisonError.resourceLimit(
                name: "extension JSON bytes",
                limit: maximum,
                actual: data.count
            )
        }
        var keyCount = extensions.count
        var deepest = extensions.isEmpty ? 0 : 1
        for value in extensions.values {
            let measurement = extensionMeasurement(value, depth: 1)
            keyCount += measurement.keys
            deepest = max(deepest, measurement.depth)
        }
        guard keyCount <= maximumKeys else {
            throw ComparisonError.resourceLimit(
                name: "extension keys",
                limit: maximumKeys,
                actual: keyCount
            )
        }
        guard deepest <= maximumDepth else {
            throw ComparisonError.resourceLimit(
                name: "extension nesting depth",
                limit: maximumDepth,
                actual: deepest
            )
        }
    }

    private static func extensionMeasurement(
        _ value: JSONValue,
        depth: Int
    ) -> (keys: Int, depth: Int) {
        switch value {
        case .array(let values):
            return values.reduce(into: (keys: 0, depth: depth + 1)) { result, item in
                let nested = extensionMeasurement(item, depth: depth + 1)
                result.keys += nested.keys
                result.depth = max(result.depth, nested.depth)
            }
        case .object(let values):
            return values.values.reduce(into: (keys: values.count, depth: depth + 1)) { result, item in
                let nested = extensionMeasurement(item, depth: depth + 1)
                result.keys += nested.keys
                result.depth = max(result.depth, nested.depth)
            }
        default:
            return (0, depth)
        }
    }
}

enum ComparisonRegularFile {
    static func read(
        at url: URL,
        maximumBytes: Int,
        afterReadChunk: ((Int) -> Void)? = nil
    ) throws -> Data {
        guard url.isFileURL else {
            throw ComparisonError.notRegularFile(url.absoluteString)
        }
        // Do not use `standardizedFileURL` here. On Linux it resolves symbolic
        // links, defeating the `lstat` and `O_NOFOLLOW` checks below.
        let path = url.path
        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0 else {
            if errno == ENOENT { throw ComparisonError.inputNotFound(path) }
            throw ComparisonError.io("Could not inspect '\(path)': \(String(cString: strerror(errno))).")
        }
        if (pathInfo.st_mode & S_IFMT) == S_IFLNK {
            throw ComparisonError.symbolicLink(path)
        }
        guard (pathInfo.st_mode & S_IFMT) == S_IFREG else {
            throw ComparisonError.notRegularFile(path)
        }
        guard pathInfo.st_size >= 0,
              UInt64(pathInfo.st_size) <= UInt64(maximumBytes) else {
            throw ComparisonError.resourceLimit(
                name: "file bytes",
                limit: maximumBytes,
                actual: Int(clamping: pathInfo.st_size)
            )
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ComparisonError.symbolicLink(path) }
            throw ComparisonError.io("Could not open '\(path)': \(String(cString: strerror(errno))).")
        }
        defer { _ = close(descriptor) }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG else {
            throw ComparisonError.notRegularFile(path)
        }
        var result = Data()
        result.reserveCapacity(min(maximumBytes, max(0, Int(openedInfo.st_size))))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
#if canImport(Darwin)
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
#else
                Glibc.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
#endif
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ComparisonError.io("Could not read '\(path)': \(String(cString: strerror(errno))).")
            }
            result.append(contentsOf: buffer.prefix(count))
            afterReadChunk?(result.count)
            if result.count > maximumBytes {
                throw ComparisonError.resourceLimit(
                    name: "file bytes",
                    limit: maximumBytes,
                    actual: result.count
                )
            }
        }
        var completedInfo = stat()
        guard fstat(descriptor, &completedInfo) == 0 else {
            throw ComparisonError.io("Could not verify '\(path)' after reading it.")
        }
        var completedPathInfo = stat()
        guard lstat(path, &completedPathInfo) == 0,
              (completedPathInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_dev == completedInfo.st_dev,
              openedInfo.st_ino == completedInfo.st_ino,
              openedInfo.st_dev == completedPathInfo.st_dev,
              openedInfo.st_ino == completedPathInfo.st_ino,
              openedInfo.st_size == completedInfo.st_size,
              result.count == Int(completedInfo.st_size),
              sameModificationTime(openedInfo, completedInfo),
              sameChangeTime(openedInfo, completedInfo) else {
            throw ComparisonError.inputChanged(path)
        }
        return result
    }

    private static func sameModificationTime(_ lhs: stat, _ rhs: stat) -> Bool {
#if canImport(Darwin)
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
#else
        lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec
            && lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec
#endif
    }

    private static func sameChangeTime(_ lhs: stat, _ rhs: stat) -> Bool {
#if canImport(Darwin)
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
#else
        lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec
            && lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec
#endif
    }
}
