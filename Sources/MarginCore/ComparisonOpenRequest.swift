import Foundation

/// Strict, one-shot handoff between the CLI and native app. Unlike durable
/// reviews, launch requests reject unknown fields and carry no review or
/// destination path.
public struct ComparisonOpenRequest: Codable, Hashable, Sendable {
    public static let schema = "urn:margin:comparison-open-request:v1"
    public static let version = 1

    public let requestID: String
    public let created: String
    public let left: ComparisonSnapshot
    public let right: ComparisonSnapshot

    public init(
        requestID: String,
        created: String,
        left: ComparisonSnapshot,
        right: ComparisonSnapshot
    ) throws {
        try ComparisonValidation.validateIdentifier(requestID, name: "Comparison request ID")
        guard Self.date(from: created) != nil else {
            throw ComparisonError.invalidArtifact("Comparison request time is not ISO 8601.")
        }
        try Self.validateLaunchSnapshot(left)
        try Self.validateLaunchSnapshot(right)
        self.requestID = requestID
        self.created = created
        self.left = left
        self.right = right
    }

    public func snapshotPair(generation: Int = 0) throws -> ComparisonSnapshotPair {
        try ComparisonSnapshotPair(generation: generation, left: left, right: right)
    }

    /// Age is deliberately checked by the receiving app against its own clock,
    /// not during generic decoding or encoding.
    public func validateAge(
        relativeTo now: Date,
        maximumAge: TimeInterval,
        maximumFutureSkew: TimeInterval = 30
    ) throws {
        guard maximumAge >= 0, maximumFutureSkew >= 0,
              let createdDate = Self.date(from: created) else {
            throw ComparisonError.invalidArtifact("Comparison request age policy is invalid.")
        }
        let age = now.timeIntervalSince(createdDate)
        guard age >= -maximumFutureSkew, age <= maximumAge else {
            throw ComparisonError.invalidArtifact("Comparison request is expired or too far in the future.")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, version, requestID, created, left, right
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        guard dynamic.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
            let name = dynamic.allKeys.first { !known.contains($0.stringValue) }?.stringValue ?? "unknown"
            throw ComparisonError.invalidArtifact(
                "Launch request contains unknown field '\(name)'."
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(String.self, forKey: .schema)
        guard schema == Self.schema else { throw ComparisonError.unsupportedSchema(schema) }
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else {
            throw ComparisonError.unsupportedSchema("\(schema)#version=\(version)")
        }
        try self.init(
            requestID: try container.decode(String.self, forKey: .requestID),
            created: try container.decode(String.self, forKey: .created),
            left: try container.decode(ComparisonSnapshot.self, forKey: .left),
            right: try container.decode(ComparisonSnapshot.self, forKey: .right)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(Self.version, forKey: .version)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(created, forKey: .created)
        try container.encode(left, forKey: .left)
        try container.encode(right, forKey: .right)
    }

    private static func validateLaunchSnapshot(_ snapshot: ComparisonSnapshot) throws {
        guard snapshot.unknownFields.isEmpty, snapshot.extensions.isEmpty else {
            throw ComparisonError.invalidArtifact(
                "Launch-request snapshots cannot contain unknown fields or extensions."
            )
        }
        if let hint = snapshot.pathHint {
            guard !hint.contains("/"), !hint.contains("\\") else {
                throw ComparisonError.invalidPortablePath(hint)
            }
        }
        guard !snapshot.label.hasPrefix("/"),
              !snapshot.label.hasPrefix("\\"),
              !(snapshot.label.count >= 2
                && snapshot.label[snapshot.label.index(after: snapshot.label.startIndex)] == ":") else {
            throw ComparisonError.invalidArtifact(
                "Launch-request labels cannot expose absolute source paths."
            )
        }
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: value)
    }
}

public enum ComparisonOpenRequestCodec {
    public static func encode(
        _ request: ComparisonOpenRequest,
        maximumBytes: Int = ComparisonHardLimits.artifactBytes
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(request)
        } catch let error as ComparisonError {
            throw error
        } catch {
            throw ComparisonError.invalidArtifact(error.localizedDescription)
        }
        let limit = min(max(0, maximumBytes), ComparisonHardLimits.artifactBytes)
        guard data.count <= limit else {
            throw ComparisonError.resourceLimit(
                name: "comparison launch request bytes",
                limit: limit,
                actual: data.count
            )
        }
        return data
    }

    public static func decode(
        _ data: Data,
        maximumBytes: Int = ComparisonHardLimits.artifactBytes
    ) throws -> ComparisonOpenRequest {
        let limit = min(max(0, maximumBytes), ComparisonHardLimits.artifactBytes)
        try ComparisonJSONPreflight.validate(data, maximumBytes: limit)
        do {
            return try JSONDecoder().decode(ComparisonOpenRequest.self, from: data)
        } catch let error as ComparisonError {
            throw error
        } catch {
            throw ComparisonError.invalidArtifact(error.localizedDescription)
        }
    }
}

/// A bounded linear preflight used before Foundation decoding so duplicate
/// object keys cannot be silently accepted with last-value-wins semantics.
enum ComparisonJSONPreflight {
    static func validate(_ data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else {
            throw ComparisonError.resourceLimit(
                name: "JSON artifact bytes",
                limit: maximumBytes,
                actual: data.count
            )
        }
        var parser = Parser(bytes: [UInt8](data))
        try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var keyCount = 0
        let maximumDepth = 128
        let maximumKeys = 500_000

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw malformed("Trailing JSON bytes") }
        }

        mutating func parseValue(depth: Int) throws {
            guard depth <= maximumDepth, index < bytes.count else {
                throw malformed("JSON nesting is too deep or input is incomplete")
            }
            switch bytes[index] {
            case 0x7b: try parseObject(depth: depth + 1)
            case 0x5b: try parseArray(depth: depth + 1)
            case 0x22: _ = try parseString(decode: false)
            case 0x74: try consumeLiteral("true")
            case 0x66: try consumeLiteral("false")
            case 0x6e: try consumeLiteral("null")
            case 0x2d, 0x30...0x39: try parseNumber()
            default: throw malformed("Unexpected JSON token")
            }
        }

        mutating func parseObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consume(0x7d) { return }
            var keys = Set<String>()
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw malformed("JSON object key is not a string")
                }
                let key = try parseString(decode: true) ?? ""
                keyCount += 1
                guard keyCount <= maximumKeys else {
                    throw ComparisonError.resourceLimit(
                        name: "JSON object keys",
                        limit: maximumKeys,
                        actual: keyCount
                    )
                }
                guard keys.insert(key).inserted else {
                    throw ComparisonError.invalidArtifact(
                        "JSON object contains duplicate key '\(key)'."
                    )
                }
                skipWhitespace()
                guard consume(0x3a) else { throw malformed("JSON object is missing ':'") }
                skipWhitespace()
                try parseValue(depth: depth)
                skipWhitespace()
                if consume(0x7d) { return }
                guard consume(0x2c) else { throw malformed("JSON object is missing ','") }
                skipWhitespace()
            }
        }

        mutating func parseArray(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consume(0x5d) { return }
            while true {
                try parseValue(depth: depth)
                skipWhitespace()
                if consume(0x5d) { return }
                guard consume(0x2c) else { throw malformed("JSON array is missing ','") }
                skipWhitespace()
            }
        }

        mutating func parseString(decode: Bool) throws -> String? {
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte < 0x20 { throw malformed("JSON string contains a control byte") }
                index += 1
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    guard decode else { return nil }
                    let fragment = Data(bytes[start..<index])
                    do {
                        return try JSONDecoder().decode(String.self, from: fragment)
                    } catch {
                        throw malformed("JSON object key has an invalid escape")
                    }
                }
            }
            throw malformed("Unterminated JSON string")
        }

        mutating func parseNumber() throws {
            let start = index
            while index < bytes.count,
                  ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[index]) {
                index += 1
            }
            let fragment = Data(bytes[start..<index])
            guard (try? JSONSerialization.jsonObject(with: fragment, options: [.fragmentsAllowed])) is NSNumber else {
                throw malformed("Invalid JSON number")
            }
        }

        mutating func consumeLiteral(_ literal: String) throws {
            let value = Array(literal.utf8)
            guard index + value.count <= bytes.count,
                  Array(bytes[index..<(index + value.count)]) == value else {
                throw malformed("Invalid JSON literal")
            }
            index += value.count
        }

        mutating func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x09
                    || bytes[index] == 0x0a || bytes[index] == 0x0d {
                index += 1
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        func malformed(_ reason: String) -> ComparisonError {
            .invalidArtifact(reason + " at byte \(index).")
        }
    }
}
