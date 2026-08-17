import Foundation
import MarginCore

/// UI projection for typed collaboration metadata. It is built only after the
/// review surface or collaboration palette is opened.
enum ReviewContributionKind: String, CaseIterable, Sendable {
    case comment
    case question
    case issue
    case decision
    case task
    case suggestion
    case handoff
    case approval

    var title: String { rawValue.capitalized }
}

struct ReviewSuggestionPresentation: Equatable, Sendable {
    enum Status: String, Sendable {
        case open
        case accepted
        case rejected
        case superseded
    }

    let expected: String
    let replacement: String
    let baseContentSha256: String?
    let status: Status
}

struct ReviewHandoffPresentation: Equatable, Sendable {
    let fromCursor: String?
    let toCursor: String?
    let touchedIDs: [String]
    let unresolvedIDs: [String]
    let audience: [String]
}

extension MarginComment {
    var reviewContributionKind: ReviewContributionKind {
        guard motivation == "commenting",
              case .string(let raw)? = extensions["margin:kind"] else {
            return .comment
        }
        return ReviewContributionKind(rawValue: raw) ?? .comment
    }

    var reviewSuggestion: ReviewSuggestionPresentation? {
        guard reviewContributionKind == .suggestion,
              case .object(let value)? = extensions["margin:suggestion"],
              let expected = value.string("expectedText") ?? value.string("expected"),
              let replacement = value.string("replacementText") ?? value.string("replacement") else {
            return nil
        }
        let digest: String?
        if case .string(let value)? = value["baseContentSha256"] { digest = value } else { digest = nil }
        let status: ReviewSuggestionPresentation.Status
        if case .string(let raw)? = value["status"] {
            switch raw {
            case "proposed": status = .open
            case "stale": status = .superseded
            default: status = ReviewSuggestionPresentation.Status(rawValue: raw) ?? .open
            }
        } else {
            status = .open
        }
        return ReviewSuggestionPresentation(
            expected: expected,
            replacement: replacement,
            baseContentSha256: digest,
            status: status
        )
    }

    var reviewHandoff: ReviewHandoffPresentation? {
        guard reviewContributionKind == .handoff,
              case .object(let value)? = extensions["margin:handoff"] else {
            return nil
        }
        return ReviewHandoffPresentation(
            fromCursor: value.string("startingCursor") ?? value.string("fromCursor"),
            toCursor: value.string("finishingCursor") ?? value.string("toCursor"),
            touchedIDs: value.strings("touchedAnnotationIDs").isEmpty
                ? value.strings("touchedIDs")
                : value.strings("touchedAnnotationIDs"),
            unresolvedIDs: value.strings("unresolvedIDs"),
            audience: value.strings("intendedNextActors").isEmpty
                ? value.strings("audience")
                : value.strings("intendedNextActors")
        )
    }
}

struct CollaborationDocumentActivity: Sendable {
    let relativePath: String
    let comments: [MarginComment]
}

struct CollaborationOverview: Sendable {
    struct Collaborator: Sendable {
        let actor: MarginActor
        let firstActivity: Date
        let lastActivity: Date
        let contributionCount: Int
        let openAuthoredCount: Int
        let files: [String]
        let kinds: [ReviewContributionKind: Int]
    }

    let collaborators: [Collaborator]
    let openSuggestions: Int
    let unresolvedHandoffs: Int

    init(documents: [CollaborationDocumentActivity]) {
        struct Accumulator {
            var actor: MarginActor
            var first: Date
            var last: Date
            var count = 0
            var open = 0
            var files = Set<String>()
            var kinds: [ReviewContributionKind: Int] = [:]
        }

        var byActor: [String: Accumulator] = [:]
        var openSuggestions = 0
        var unresolvedHandoffs = 0
        for document in documents {
            for comment in document.comments {
                guard let date = Self.parseDate(comment.modified) ?? Self.parseDate(comment.created) else { continue }
                let kind = comment.reviewContributionKind
                var value = byActor[comment.creator.id] ?? Accumulator(
                    actor: comment.creator,
                    first: date,
                    last: date
                )
                value.actor = comment.creator
                value.first = min(value.first, date)
                value.last = max(value.last, date)
                value.count += 1
                value.files.insert(document.relativePath)
                value.kinds[kind, default: 0] += 1
                if comment.motivation == "commenting", comment.status != .resolved { value.open += 1 }
                byActor[comment.creator.id] = value

                if comment.reviewSuggestion?.status == .open { openSuggestions += 1 }
                if kind == .handoff, comment.status != .resolved { unresolvedHandoffs += 1 }
            }
        }

        collaborators = byActor.values.map { value in
            Collaborator(
                actor: value.actor,
                firstActivity: value.first,
                lastActivity: value.last,
                contributionCount: value.count,
                openAuthoredCount: value.open,
                files: value.files.sorted(),
                kinds: value.kinds
            )
        }.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.actor.name.localizedStandardCompare(rhs.actor.name) == .orderedAscending
        }
        self.openSuggestions = openSuggestions
        self.unresolvedHandoffs = unresolvedHandoffs
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) { return date }
        return ordinaryDateFormatter.date(from: value)
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let ordinaryDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func strings(_ key: String) -> [String] {
        guard case .array(let values)? = self[key] else { return [] }
        return values.compactMap { value in
            guard case .string(let string) = value else { return nil }
            return string
        }
    }
}
