import Foundation

public struct EmbeddedCommentCodec: Sendable {
    public static let openingMarker = "<!-- margin:comments:v1\n"
    public static let closingMarker = "\n-->"

    public init() {}

    public func decode(_ data: Data) throws -> EmbeddedCommentDocument {
        let opening = Data(Self.openingMarker.utf8)
        let matches = ranges(of: opening, in: data)
        guard matches.count <= 1 else { throw CommentProtocolError.multipleCommentBlocks }

        guard let markerRange = matches.first else {
            guard let body = String(data: data, encoding: .utf8) else {
                throw CommentProtocolError.invalidUTF8
            }
            return EmbeddedCommentDocument(bodyData: data, body: body, envelope: nil)
        }

        let terminalNewline = Data("\n-->\n".utf8)
        let terminalNoNewline = Data("\n-->".utf8)
        let closingLength: Int
        if data.suffix(terminalNewline.count) == terminalNewline {
            closingLength = terminalNewline.count
        } else if data.suffix(terminalNoNewline.count) == terminalNoNewline {
            closingLength = terminalNoNewline.count
        } else {
            throw CommentProtocolError.nonterminalCommentBlock
        }

        let payloadEnd = data.count - closingLength
        guard markerRange.upperBound <= payloadEnd else {
            throw CommentProtocolError.invalidEnvelope("The comment payload is empty or truncated.")
        }
        guard markerRange.lowerBound == 0 || data[markerRange.lowerBound - 1] == 0x0A else {
            throw CommentProtocolError.invalidEnvelope("The opening marker must begin at column one.")
        }

        let payload = data.subdata(in: markerRange.upperBound..<payloadEnd)
        if containsDoubleHyphen(payload) {
            throw CommentProtocolError.invalidEnvelope("The JSON payload contains a literal double hyphen.")
        }

        let envelope: EmbeddedCommentEnvelope
        do {
            envelope = try JSONDecoder().decode(EmbeddedCommentEnvelope.self, from: payload)
        } catch let error as CommentProtocolError {
            throw error
        } catch {
            throw CommentProtocolError.invalidEnvelope(error.localizedDescription)
        }

        guard envelope.contentByteLength >= 0,
              envelope.contentByteLength <= markerRange.lowerBound else {
            throw CommentProtocolError.contentLengthMismatch(
                expected: envelope.contentByteLength,
                actualPrefix: markerRange.lowerBound
            )
        }
        let bodyData = data.prefix(envelope.contentByteLength)
        let expectedPadding = canonicalPadding(after: bodyData)
        let actualPadding = data.subdata(in: envelope.contentByteLength..<markerRange.lowerBound)
        guard expectedPadding == actualPadding else {
            throw CommentProtocolError.contentLengthMismatch(
                expected: envelope.contentByteLength,
                actualPrefix: markerRange.lowerBound - expectedPadding.count
            )
        }
        let actualHash = Self.contentHash(Data(bodyData))
        guard normalizedHash(envelope.contentSha256) == normalizedHash(actualHash) else {
            throw CommentProtocolError.contentHashMismatch(
                expected: envelope.contentSha256,
                actual: actualHash
            )
        }
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw CommentProtocolError.invalidUTF8
        }
        try validate(envelope)
        return EmbeddedCommentDocument(bodyData: Data(bodyData), body: body, envelope: envelope)
    }

    public func encode(bodyData: Data, envelope original: EmbeddedCommentEnvelope?) throws -> Data {
        guard String(data: bodyData, encoding: .utf8) != nil else {
            throw CommentProtocolError.invalidUTF8
        }
        guard var envelope = original, !envelope.items.isEmpty else { return bodyData }
        envelope.contentByteLength = bodyData.count
        envelope.contentSha256 = Self.contentHash(bodyData)
        envelope.partOf.total = envelope.items.count
        try validate(envelope)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let ordinaryJSON: Data
        do {
            ordinaryJSON = try encoder.encode(envelope)
        } catch {
            throw CommentProtocolError.invalidEnvelope(error.localizedDescription)
        }
        let safeJSON = escapeHyphensInsideJSONStrings(ordinaryJSON)
        guard !containsDoubleHyphen(safeJSON) else {
            throw CommentProtocolError.invalidEnvelope("Canonical serialization produced a double hyphen.")
        }

        var result = Data()
        result.append(bodyData)
        result.append(canonicalPadding(after: bodyData))
        result.append(Data(Self.openingMarker.utf8))
        result.append(safeJSON)
        result.append(Data("\n-->\n".utf8))
        return result
    }

    public func validate(_ envelope: EmbeddedCommentEnvelope) throws {
        guard envelope.version >= 1 else {
            throw CommentProtocolError.invalidEnvelope("Protocol version must be positive.")
        }
        guard envelope.type == "AnnotationPage" else {
            throw CommentProtocolError.invalidEnvelope("Root type must be AnnotationPage.")
        }
        guard envelope.projection == "markdown-source-v1" else {
            throw CommentProtocolError.invalidEnvelope("Unknown source projection '\(envelope.projection)'.")
        }
        guard envelope.revision >= 1 else {
            throw CommentProtocolError.invalidEnvelope("Envelope revision must be at least one.")
        }
        guard !envelope.items.isEmpty else {
            throw CommentProtocolError.invalidEnvelope("An empty annotation page must be removed.")
        }
        guard envelope.partOf.total == envelope.items.count else {
            throw CommentProtocolError.invalidEnvelope("Annotation total does not match the items array.")
        }
        guard envelope.id == "\(envelope.document.id)#comments",
              envelope.partOf.id == "\(envelope.document.id)#collection" else {
            throw CommentProtocolError.invalidEnvelope("Page and collection ids must derive from the document id.")
        }
        guard envelope.context.contains(.string("http://www.w3.org/ns/anno.jsonld")) else {
            throw CommentProtocolError.invalidEnvelope("The W3C Web Annotation context is required.")
        }

        var byID: [String: MarginComment] = [:]
        for annotation in envelope.items {
            guard byID[annotation.id] == nil else {
                throw CommentProtocolError.invalidEnvelope("Duplicate annotation id '\(annotation.id)'.")
            }
            guard annotation.type == "Annotation" else {
                throw CommentProtocolError.invalidEnvelope("Item '\(annotation.id)' is not an Annotation.")
            }
            guard !annotation.body.value.isEmpty,
                  annotation.body.type == "TextualBody",
                  annotation.body.format == "text/markdown" else {
                throw CommentProtocolError.invalidEnvelope("Item '\(annotation.id)' has an invalid body.")
            }
            byID[annotation.id] = annotation
        }

        for annotation in envelope.items {
            switch annotation.motivation {
            case "commenting":
                guard annotation.status != nil else {
                    throw CommentProtocolError.invalidEnvelope("Thread root '\(annotation.id)' has no status.")
                }
                switch annotation.target {
                case .resource(let id):
                    guard id == envelope.document.id else {
                        throw CommentProtocolError.invalidEnvelope("Document comment '\(annotation.id)' targets another resource.")
                    }
                case .selection(let target):
                    guard target.source.id == envelope.document.id,
                          let quote = target.quoteSelector,
                          !quote.exact.isEmpty else {
                        throw CommentProtocolError.invalidEnvelope("Comment '\(annotation.id)' has an invalid selection target.")
                    }
                    if let position = target.positionSelector,
                       (position.start < 0 || position.end <= position.start) {
                        throw CommentProtocolError.invalidEnvelope("Comment '\(annotation.id)' has an invalid position selector.")
                    }
                }
            case "replying":
                guard annotation.status == nil,
                      case .resource(let parentID) = annotation.target,
                      byID[parentID] != nil else {
                    throw CommentProtocolError.invalidEnvelope("Reply '\(annotation.id)' has an invalid parent target.")
                }
            default:
                throw CommentProtocolError.invalidEnvelope(
                    "Unsupported motivation '\(annotation.motivation)' on '\(annotation.id)'."
                )
            }
        }

        for annotation in envelope.items where annotation.motivation == "replying" {
            var visited: Set<String> = [annotation.id]
            var current = annotation
            while current.motivation == "replying" {
                guard case .resource(let parentID) = current.target,
                      let parent = byID[parentID] else {
                    throw CommentProtocolError.invalidEnvelope("Reply chain for '\(annotation.id)' is broken.")
                }
                guard visited.insert(parentID).inserted else {
                    throw CommentProtocolError.invalidEnvelope("Reply chain for '\(annotation.id)' contains a cycle.")
                }
                current = parent
            }
            guard current.motivation == "commenting" else {
                throw CommentProtocolError.invalidEnvelope("Reply '\(annotation.id)' does not lead to a thread root.")
            }
        }
    }

    public static func contentHash(_ data: Data) -> String {
        "sha256:\(DocumentRevision(data: data).sha256)"
    }

    private func canonicalPadding(after body: Data) -> Data {
        guard !body.isEmpty else { return Data() }
        if body.count >= 2, body.suffix(2) == Data("\n\n".utf8) { return Data() }
        if body.last == 0x0A { return Data("\n".utf8) }
        return Data("\n\n".utf8)
    }

    private func ranges(of needle: Data, in haystack: Data) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var result: [Range<Int>] = []
        var searchStart = 0
        while searchStart <= haystack.count - needle.count,
              let range = haystack.range(of: needle, options: [], in: searchStart..<haystack.count) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }

    private func containsDoubleHyphen(_ data: Data) -> Bool {
        data.range(of: Data([0x2D, 0x2D])) != nil
    }

    private func normalizedHash(_ value: String) -> String {
        value.hasPrefix("sha256:") ? String(value.dropFirst(7)).lowercased() : value.lowercased()
    }

    /// HTML comments may not contain `--`. Escaping only inside JSON strings keeps numbers untouched.
    private func escapeHyphensInsideJSONStrings(_ data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    result.append(byte)
                    escaped = false
                } else if byte == 0x5C {
                    result.append(byte)
                    escaped = true
                } else if byte == 0x22 {
                    result.append(byte)
                    inString = false
                } else if byte == 0x2D {
                    result.append(Data("\\u002d".utf8))
                } else {
                    result.append(byte)
                }
            } else {
                result.append(byte)
                if byte == 0x22 { inString = true }
            }
        }
        return result
    }
}
