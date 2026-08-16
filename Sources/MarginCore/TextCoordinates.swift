import Foundation

public struct TextPoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "\(line):\(column)" }
}

public struct TextSpan: Codable, Hashable, Sendable, CustomStringConvertible {
    public var start: TextPoint
    public var end: TextPoint

    public init(start: TextPoint, end: TextPoint) {
        self.start = start
        self.end = end
    }

    public var description: String { "\(start)-\(end)" }

    public init(parsing value: String) throws {
        let parts = value.split(separator: "-", maxSplits: 1).map(String.init)
        guard let first = try Self.parsePoint(parts[0]) else {
            throw TextCoordinateError.invalidRange(value)
        }
        let second: TextPoint
        if parts.count == 2, let parsed = try Self.parsePoint(parts[1]) {
            second = parsed
        } else if parts.count == 1 {
            second = first
        } else {
            throw TextCoordinateError.invalidRange(value)
        }
        self.init(start: first, end: second)
    }

    private static func parsePoint(_ value: String) throws -> TextPoint? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let line = Int(parts[0]),
              let column = Int(parts[1]),
              line > 0,
              column > 0 else {
            return nil
        }
        return TextPoint(line: line, column: column)
    }
}

public enum TextCoordinateError: Error, LocalizedError, Equatable {
    case invalidRange(String)
    case lineOutOfBounds(Int)
    case columnOutOfBounds(line: Int, column: Int)
    case reversedRange
    case indexOutOfBounds

    public var errorDescription: String? {
        switch self {
        case .invalidRange(let value):
            return "Invalid range '\(value)'. Expected START_LINE:START_COLUMN-END_LINE:END_COLUMN."
        case .lineOutOfBounds(let line):
            return "Line \(line) is outside the document."
        case .columnOutOfBounds(let line, let column):
            return "Column \(column) is outside line \(line)."
        case .reversedRange:
            return "The range ends before it starts."
        case .indexOutOfBounds:
            return "The text index is outside the document."
        }
    }
}

public enum TextCoordinates {
    public static func range(for span: TextSpan, in text: String) throws -> Range<String.Index> {
        let start = try index(for: span.start, in: text)
        let end = try index(for: span.end, in: text)
        guard start <= end else { throw TextCoordinateError.reversedRange }
        return start..<end
    }

    public static func span(for range: Range<String.Index>, in text: String) throws -> TextSpan {
        guard range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else {
            throw TextCoordinateError.indexOutOfBounds
        }
        return TextSpan(
            start: try point(for: range.lowerBound, in: text),
            end: try point(for: range.upperBound, in: text)
        )
    }

    public static func index(for point: TextPoint, in text: String) throws -> String.Index {
        guard point.line > 0 else { throw TextCoordinateError.lineOutOfBounds(point.line) }
        guard point.column > 0 else {
            throw TextCoordinateError.columnOutOfBounds(line: point.line, column: point.column)
        }

        let bounds = lineBounds(in: text)
        guard point.line <= bounds.count else { throw TextCoordinateError.lineOutOfBounds(point.line) }
        let line = bounds[point.line - 1]
        var index = line.lowerBound
        var column = 1
        while column < point.column, index < line.upperBound {
            index = text.index(after: index)
            column += 1
        }
        guard column == point.column else {
            throw TextCoordinateError.columnOutOfBounds(line: point.line, column: point.column)
        }
        return index
    }

    public static func point(for target: String.Index, in text: String) throws -> TextPoint {
        guard target >= text.startIndex, target <= text.endIndex else {
            throw TextCoordinateError.indexOutOfBounds
        }
        let bounds = lineBounds(in: text)
        for (offset, line) in bounds.enumerated() where target >= line.lowerBound && target <= line.upperBound {
            let column = text.distance(from: line.lowerBound, to: target) + 1
            return TextPoint(line: offset + 1, column: column)
        }
        if target == text.endIndex, let last = bounds.last {
            return TextPoint(line: bounds.count, column: text.distance(from: last.lowerBound, to: target) + 1)
        }
        throw TextCoordinateError.indexOutOfBounds
    }

    public static func unicodeScalarOffset(of index: String.Index, in text: String) -> Int {
        text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
    }

    public static func index(atUnicodeScalarOffset offset: Int, in text: String) -> String.Index? {
        guard offset >= 0,
              let scalarIndex = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: offset, limitedBy: text.unicodeScalars.endIndex) else {
            return nil
        }
        return scalarIndex.samePosition(in: text)
    }

    public static func lineCount(in text: String) -> Int {
        lineBounds(in: text).count
    }

    private static func lineBounds(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isNewline {
                result.append(start..<index)
                index = text.index(after: index)
                start = index
            } else {
                index = text.index(after: index)
            }
        }
        result.append(start..<text.endIndex)
        return result
    }
}
