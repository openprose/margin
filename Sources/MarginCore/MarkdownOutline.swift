import Foundation

public struct MarkdownHeading: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let level: Int
    public let line: Int
    public let sectionEndLine: Int

    public init(id: String, title: String, level: Int, line: Int, sectionEndLine: Int) {
        self.id = id
        self.title = title
        self.level = level
        self.line = line
        self.sectionEndLine = sectionEndLine
    }
}

public struct MarkdownOutline: Codable, Hashable, Sendable {
    public let headings: [MarkdownHeading]

    public init(markdown: String) {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \ .isNewline).map(String.init)
        var discovered: [(title: String, level: Int, line: Int)] = []
        var inFence = false
        var fenceCharacter: Character?
        var previousCandidate: (text: String, line: Int)?

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.drop(while: { $0 == " " || $0 == "\t" })

            if let marker = fenceMarker(in: trimmed) {
                if inFence, marker == fenceCharacter {
                    inFence = false
                    fenceCharacter = nil
                } else if !inFence {
                    inFence = true
                    fenceCharacter = marker
                }
                previousCandidate = nil
                continue
            }

            guard !inFence else { continue }

            if let atx = atxHeading(in: trimmed) {
                discovered.append((atx.title, atx.level, lineNumber))
                previousCandidate = nil
                continue
            }

            if let candidate = previousCandidate,
               let setextLevel = setextHeadingLevel(in: trimmed),
               !candidate.text.trimmingCharacters(in: .whitespaces).isEmpty {
                discovered.append((candidate.text.trimmingCharacters(in: .whitespaces), setextLevel, candidate.line))
                previousCandidate = nil
                continue
            }

            previousCandidate = trimmed.isEmpty ? nil : (rawLine, lineNumber)
        }

        var slugCounts: [String: Int] = [:]
        var headings: [MarkdownHeading] = []
        for (index, item) in discovered.enumerated() {
            let baseSlug = Self.slug(item.title)
            let count = (slugCounts[baseSlug] ?? 0) + 1
            slugCounts[baseSlug] = count
            let id = count == 1 ? baseSlug : "\(baseSlug)-\(count)"
            let nextBoundary = discovered.dropFirst(index + 1).first(where: { $0.level <= item.level })?.line
            let endLine = max(item.line, (nextBoundary ?? (lines.count + 1)) - 1)
            headings.append(MarkdownHeading(id: id, title: item.title, level: item.level, line: item.line, sectionEndLine: endLine))
        }
        self.headings = headings
    }

    public func heading(matching query: String) -> MarkdownHeading? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return headings.first(where: { $0.id == normalized })
            ?? headings.first(where: { $0.title.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
    }

    private static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return result.isEmpty ? "section" : result
    }
}

private func fenceMarker(in line: Substring) -> Character? {
    guard let first = line.first, first == "`" || first == "~" else { return nil }
    let count = line.prefix(while: { $0 == first }).count
    return count >= 3 ? first : nil
}

private func atxHeading(in line: Substring) -> (title: String, level: Int)? {
    let markers = line.prefix(while: { $0 == "#" })
    guard (1...6).contains(markers.count) else { return nil }
    let rest = line.dropFirst(markers.count)
    guard rest.first == " " || rest.first == "\t" else { return nil }
    var title = rest.drop(while: { $0 == " " || $0 == "\t" })
    while title.last == "#" { title = title.dropLast() }
    title = title.drop(while: { $0 == " " || $0 == "\t" })
    while title.last == " " || title.last == "\t" { title = title.dropLast() }
    guard !title.isEmpty else { return nil }
    return (String(title), markers.count)
}

private func setextHeadingLevel(in line: Substring) -> Int? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 1, let first = trimmed.first, first == "=" || first == "-" else { return nil }
    guard trimmed.allSatisfy({ $0 == first }) else { return nil }
    return first == "=" ? 1 : 2
}
