import CryptoKit
import Foundation

public enum CollaborationCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw CollaborationError.io(
                "Could not canonically serialize collaboration data: \(error.localizedDescription)"
            )
        }
    }

    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as CollaborationError {
            throw error
        } catch {
            throw CollaborationError.io(
                "Could not decode collaboration data: \(error.localizedDescription)"
            )
        }
    }

    public static func sha256<T: Encodable>(of value: T) throws -> String {
        sha256(of: try encode(value))
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension CollaborationCursor {
    func token() throws -> String {
        try validate()
        let data = try CollaborationCanonicalJSON.encode(self)
        return "mcur1:\(Self.base64URLEncode(data))"
    }

    init(token: String) throws {
        guard token.hasPrefix("mcur1:") else {
            throw CollaborationError.invalidCursor("Cursor tokens must begin with 'mcur1:'.")
        }
        let encoded = String(token.dropFirst("mcur1:".count))
        guard let data = Self.base64URLDecode(encoded) else {
            throw CollaborationError.invalidCursor("The cursor payload is not canonical base64url.")
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CollaborationError.invalidCursor(error.localizedDescription)
        }
        try validate()
        guard try self.token() == token else {
            throw CollaborationError.invalidCursor("The cursor token is not canonically encoded.")
        }
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar == "-" || scalar == "_"
              }) else { return nil }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64), base64URLEncode(data) == value else {
            return nil
        }
        return data
    }
}

public extension CollaborationWorkspaceManifest {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }

        let type = try container.decode(String.self, forKey: key("type"))
        guard type == Self.type else {
            throw CollaborationError.invalidManifest("Unknown manifest type '\(type)'.")
        }
        version = try container.decode(Int.self, forKey: key("margin:version"))
        id = try container.decode(String.self, forKey: key("id"))
        created = try container.decode(String.self, forKey: key("created"))
        include = try container.decodeIfPresent([String].self, forKey: key("include")) ?? Self.defaultInclude
        exclude = try container.decodeIfPresent([String].self, forKey: key("exclude")) ?? Self.defaultExclude

        let known: Set<String> = [
            "type", "margin:version", "id", "created", "include", "exclude",
        ]
        var unknown: [String: JSONValue] = [:]
        for codingKey in container.allKeys where !known.contains(codingKey.stringValue) {
            unknown[codingKey.stringValue] = try container.decode(JSONValue.self, forKey: codingKey)
        }
        extensions = unknown
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        try container.encode(Self.type, forKey: key("type"))
        try container.encode(version, forKey: key("margin:version"))
        try container.encode(id, forKey: key("id"))
        try container.encode(created, forKey: key("created"))
        try container.encode(include, forKey: key("include"))
        try container.encode(exclude, forKey: key("exclude"))
        for (name, value) in extensions where ![
            "type", "margin:version", "id", "created", "include", "exclude",
        ].contains(name) {
            try container.encode(value, forKey: key(name))
        }
    }
}

public enum CollaborationActivity {
    public static func summarize(
        _ records: [CollaborationActivityRecord]
    ) -> [CollaborationActorActivity] {
        Dictionary(grouping: records, by: \.actorID)
            .map { actorID, values in
                let ordered = values.sorted {
                    if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                    return CollaborationValidation.pathLess($0.id, $1.id)
                }
                var counts: [String: Int] = [:]
                var counted = Set<String>()
                for value in values {
                    if case .object(let kindsByID)? = value.extensions["margin:contributionKindsByID"] {
                        for (id, encodedKind) in kindsByID {
                            guard case .string(let rawKind) = encodedKind,
                                  CollaborationContributionKind(rawValue: rawKind) != nil else { continue }
                            if counted.insert("\(id)\0\(rawKind)").inserted {
                                counts[rawKind, default: 0] += 1
                            }
                        }
                    } else {
                        for (index, kind) in value.contributionKinds.enumerated() {
                            let identity = index < value.contributionIDs.count
                                ? "\(value.contributionIDs[index])\0\(kind.rawValue)"
                                : "\(value.id)\0\(kind.rawValue)"
                            if counted.insert(identity).inserted {
                                counts[kind.rawValue, default: 0] += 1
                            }
                        }
                    }
                }
                return CollaborationActorActivity(
                    actorID: actorID,
                    firstObservedAt: ordered.first?.occurredAt ?? "",
                    lastObservedAt: ordered.last?.occurredAt ?? "",
                    contributionCounts: counts,
                    filesTouched: CollaborationValidation.sortedUnique(values.flatMap(\.paths)),
                    authoredContributionIDs: CollaborationValidation.sortedUnique(
                        values.flatMap(\.contributionIDs)
                    )
                )
            }
            .sorted { CollaborationValidation.pathLess($0.actorID, $1.actorID) }
    }
}

public enum CollaborationTimestamp {
    public static func string(from date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
