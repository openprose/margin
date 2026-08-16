import CryptoKit
import Foundation

public struct DocumentRevision: Codable, Hashable, Sendable, CustomStringConvertible {
    public let sha256: String

    public init(data: Data) {
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public init(text: String) {
        self.init(data: Data(text.utf8))
    }

    public var description: String { sha256 }
}

public struct DocumentInspection: Codable, Sendable {
    public let path: String
    public let revision: DocumentRevision
    public let bytes: Int
    public let characters: Int
    public let lines: Int
    public let words: Int
    public let outline: MarkdownOutline

    public init(path: String, body: String) {
        let data = Data(body.utf8)
        self.path = path
        self.revision = DocumentRevision(data: data)
        self.bytes = data.count
        self.characters = body.count
        self.lines = TextCoordinates.lineCount(in: body)
        self.words = body.split(whereSeparator: { $0.isWhitespace }).count
        self.outline = MarkdownOutline(markdown: body)
    }
}

public struct DocumentSlice: Codable, Sendable {
    public let range: TextSpan
    public let text: String
    public let revision: DocumentRevision

    public init(body: String, range: TextSpan) throws {
        let resolved = try TextCoordinates.range(for: range, in: body)
        self.range = range
        self.text = String(body[resolved])
        self.revision = DocumentRevision(text: body)
    }

    public init(body: String, heading: MarkdownHeading, contextLines: Int = 0) throws {
        let startLine = max(1, heading.line - contextLines)
        let lastLine = min(TextCoordinates.lineCount(in: body), heading.sectionEndLine + contextLines)
        let endColumn = try Self.endColumn(forLine: lastLine, in: body)
        let range = TextSpan(
            start: TextPoint(line: startLine, column: 1),
            end: TextPoint(line: lastLine, column: endColumn)
        )
        try self.init(body: body, range: range)
    }

    private static func endColumn(forLine line: Int, in body: String) throws -> Int {
        let start = try TextCoordinates.index(for: TextPoint(line: line, column: 1), in: body)
        var index = start
        while index < body.endIndex, !body[index].isNewline {
            index = body.index(after: index)
        }
        return body.distance(from: start, to: index) + 1
    }
}
