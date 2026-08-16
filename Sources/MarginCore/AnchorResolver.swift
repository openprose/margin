import Foundation

public enum AnchorResolutionState: String, Codable, Sendable {
    case anchored
    case moved
    case ambiguous
    case orphaned
}

public struct UnicodeScalarRange: Codable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct AnchorCandidate: Codable, Hashable, Sendable {
    public var range: UnicodeScalarRange
    public var prefixScore: Int
    public var suffixScore: Int

    public init(range: UnicodeScalarRange, prefixScore: Int = 0, suffixScore: Int = 0) {
        self.range = range
        self.prefixScore = prefixScore
        self.suffixScore = suffixScore
    }

    public var score: Int { prefixScore + suffixScore }
}

public struct AnchorResolution: Codable, Hashable, Sendable {
    public var state: AnchorResolutionState
    public var range: UnicodeScalarRange?
    public var candidates: [AnchorCandidate]

    public init(
        state: AnchorResolutionState,
        range: UnicodeScalarRange? = nil,
        candidates: [AnchorCandidate] = []
    ) {
        self.state = state
        self.range = range
        self.candidates = candidates
    }
}

public struct AnchorResolver: Sendable {
    public let contextLength: Int
    public let minimumDisambiguatingContext: Int

    public init(contextLength: Int = 32, minimumDisambiguatingContext: Int = 8) {
        self.contextLength = max(0, contextLength)
        self.minimumDisambiguatingContext = max(0, minimumDisambiguatingContext)
    }

    /// The v1 source projection: literal Markdown with line endings normalized to LF.
    public static func normalizedProjection(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    public func resolve(_ target: CommentSelectionTarget, in source: String) throws -> AnchorResolution {
        guard let quote = target.quoteSelector else {
            throw CommentProtocolError.invalidAnchor("A TextQuoteSelector is required.")
        }
        guard !quote.exact.isEmpty else {
            throw CommentProtocolError.invalidAnchor("A range comment cannot have an empty quote.")
        }

        let text = Self.normalizedProjection(source)
        let scalars = Array(text.unicodeScalars)
        let exact = Array(Self.normalizedProjection(quote.exact).unicodeScalars)
        let prefix = Array(Self.normalizedProjection(quote.prefix).unicodeScalars)
        let suffix = Array(Self.normalizedProjection(quote.suffix).unicodeScalars)

        if let position = target.positionSelector,
           position.start >= 0,
           position.end >= position.start,
           position.end <= scalars.count,
           Array(scalars[position.start..<position.end]) == exact {
            return AnchorResolution(
                state: .anchored,
                range: UnicodeScalarRange(start: position.start, end: position.end)
            )
        }

        let offsets = allOccurrences(of: exact, in: scalars)
        guard !offsets.isEmpty else {
            return AnchorResolution(state: .orphaned)
        }
        if offsets.count == 1, let start = offsets.first {
            let range = UnicodeScalarRange(start: start, end: start + exact.count)
            return AnchorResolution(state: .moved, range: range)
        }

        let candidates = offsets.map { start -> AnchorCandidate in
            let end = start + exact.count
            return AnchorCandidate(
                range: UnicodeScalarRange(start: start, end: end),
                prefixScore: matchingPrefixContext(prefix, before: start, in: scalars),
                suffixScore: matchingSuffixContext(suffix, after: end, in: scalars)
            )
        }
        let bestScore = candidates.map(\.score).max() ?? 0
        let best = candidates.filter { $0.score == bestScore }
        let threshold = min(minimumDisambiguatingContext, prefix.count + suffix.count)
        if best.count == 1, bestScore >= threshold, threshold > 0 {
            return AnchorResolution(state: .moved, range: best[0].range, candidates: candidates)
        }
        return AnchorResolution(state: .ambiguous, candidates: candidates)
    }

    public func target(
        for input: CommentAnchorInput,
        documentID: String,
        in source: String
    ) throws -> CommentTarget {
        let text = Self.normalizedProjection(source)
        switch input {
        case .document:
            return .resource(documentID)
        case .range(let start, let end, let expectedExact):
            return .selection(try selectionTarget(
                documentID: documentID,
                text: text,
                start: start,
                end: end,
                expectedExact: expectedExact
            ))
        case .quote(let exact, let requestedPrefix, let requestedSuffix, let occurrence):
            let normalizedExact = Self.normalizedProjection(exact)
            guard !normalizedExact.isEmpty else {
                throw CommentProtocolError.invalidAnchor("The quote cannot be empty.")
            }
            let textScalars = Array(text.unicodeScalars)
            let exactScalars = Array(normalizedExact.unicodeScalars)
            var offsets = allOccurrences(of: exactScalars, in: textScalars)
            if let requestedPrefix {
                let prefix = Array(Self.normalizedProjection(requestedPrefix).unicodeScalars)
                offsets = offsets.filter { start in
                    start >= prefix.count && Array(textScalars[(start - prefix.count)..<start]) == prefix
                }
            }
            if let requestedSuffix {
                let suffix = Array(Self.normalizedProjection(requestedSuffix).unicodeScalars)
                offsets = offsets.filter { start in
                    let end = start + exactScalars.count
                    return end + suffix.count <= textScalars.count &&
                        Array(textScalars[end..<(end + suffix.count)]) == suffix
                }
            }
            guard !offsets.isEmpty else { throw CommentProtocolError.anchorNotFound }
            let start: Int
            if let occurrence {
                guard occurrence > 0, occurrence <= offsets.count else {
                    throw CommentProtocolError.invalidAnchor(
                        "Occurrence \(occurrence) is outside the \(offsets.count) matches."
                    )
                }
                start = offsets[occurrence - 1]
            } else if offsets.count == 1 {
                start = offsets[0]
            } else {
                let candidates = offsets.map {
                    AnchorCandidate(range: UnicodeScalarRange(start: $0, end: $0 + exactScalars.count))
                }
                throw CommentProtocolError.anchorAmbiguous(candidates)
            }
            return .selection(try selectionTarget(
                documentID: documentID,
                text: text,
                start: start,
                end: start + exactScalars.count,
                expectedExact: normalizedExact
            ))
        }
    }

    public func refreshed(
        _ target: CommentSelectionTarget,
        in source: String
    ) throws -> CommentSelectionTarget {
        let resolution = try resolve(target, in: source)
        switch resolution.state {
        case .anchored, .moved:
            guard let range = resolution.range else {
                throw CommentProtocolError.invalidAnchor("Resolved anchor has no range.")
            }
            return try selectionTarget(
                documentID: target.source.id,
                text: Self.normalizedProjection(source),
                start: range.start,
                end: range.end,
                expectedExact: nil
            )
        case .ambiguous:
            throw CommentProtocolError.anchorAmbiguous(resolution.candidates)
        case .orphaned:
            throw CommentProtocolError.anchorNotFound
        }
    }

    private func selectionTarget(
        documentID: String,
        text: String,
        start: Int,
        end: Int,
        expectedExact: String?
    ) throws -> CommentSelectionTarget {
        let scalars = Array(text.unicodeScalars)
        guard start >= 0, end > start, end <= scalars.count else {
            throw CommentProtocolError.invalidAnchor(
                "Expected a non-empty half-open scalar range inside 0...\(scalars.count)."
            )
        }
        guard isGraphemeBoundary(start, in: text), isGraphemeBoundary(end, in: text) else {
            throw CommentProtocolError.invalidAnchor("The range splits an extended grapheme cluster.")
        }
        let exact = string(scalars[start..<end])
        if let expectedExact,
           Self.normalizedProjection(expectedExact) != exact {
            throw CommentProtocolError.invalidAnchor("The range does not equal the expected quote.")
        }
        let prefixStart = max(0, start - contextLength)
        let suffixEnd = min(scalars.count, end + contextLength)
        let prefix = string(scalars[prefixStart..<start])
        let suffix = string(scalars[end..<suffixEnd])
        return CommentSelectionTarget(
            source: MarginSourceReference(id: documentID),
            selector: [
                .position(TextPositionSelector(start: start, end: end)),
                .quote(TextQuoteSelector(exact: exact, prefix: prefix, suffix: suffix))
            ]
        )
    }

    private func allOccurrences(
        of needle: [Unicode.Scalar],
        in haystack: [Unicode.Scalar]
    ) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var result: [Int] = []
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                result.append(start)
            }
        }
        return result
    }

    private func matchingPrefixContext(
        _ prefix: [Unicode.Scalar],
        before start: Int,
        in text: [Unicode.Scalar]
    ) -> Int {
        let possible = min(prefix.count, start)
        guard possible > 0 else { return 0 }
        for length in stride(from: possible, through: 1, by: -1) {
            if Array(prefix.suffix(length)) == Array(text[(start - length)..<start]) { return length }
        }
        return 0
    }

    private func matchingSuffixContext(
        _ suffix: [Unicode.Scalar],
        after end: Int,
        in text: [Unicode.Scalar]
    ) -> Int {
        let possible = min(suffix.count, text.count - end)
        guard possible > 0 else { return 0 }
        for length in stride(from: possible, through: 1, by: -1) {
            if Array(suffix.prefix(length)) == Array(text[end..<(end + length)]) { return length }
        }
        return 0
    }

    private func isGraphemeBoundary(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0,
              let scalar = text.unicodeScalars.index(
                text.unicodeScalars.startIndex,
                offsetBy: offset,
                limitedBy: text.unicodeScalars.endIndex
              ) else { return false }
        return scalar.samePosition(in: text) != nil
    }

    private func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars)
        return String(result)
    }
}
