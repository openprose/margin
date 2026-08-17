import Foundation
import MarginCore

struct StagedOperationPresentation: Equatable {
    let title: String
    let subtitle: String
    let detail: String
    let symbolName: String
    let searchText: String
}

/// A bounded, human-readable projection of staged work. Direct file images are
/// intentionally represented only by metadata; their bytes never become UI or
/// search strings.
enum CollaborationStageInspectorPresentation {
    static let maximumPresentedOperations = 512
    static let maximumDetailBytes = 420
    static let stageListingAggregateByteBudget = 16 * 1_024 * 1_024

    static func operation(_ operation: CollaborationOperation) -> StagedOperationPresentation {
        let path = preview(operation.path, maximumUTF8Bytes: 240)
        let id = shortReference(operation.id)
        let title: String
        let detail: String
        let symbolName: String

        switch operation {
        case .contribution(_, let value):
            let contribution = value.contribution
            title = contributionTitle(contribution)
            detail = contributionDetail(contribution)
            symbolName = contributionSymbol(contribution.kind)
        case .status(_, let value):
            title = value.status == .resolved ? "Resolve Thread" : "Reopen Thread"
            detail = "Thread \(shortReference(value.annotationID))"
            symbolName = value.status == .resolved ? "checkmark.circle" : "arrow.uturn.backward.circle"
        case .acceptSuggestion(_, let value):
            title = "Accept Suggestion"
            detail = "Suggestion \(shortReference(value.contributionID))"
            symbolName = "arrow.left.arrow.right.circle"
        case .suggestionDisposition(_, let value):
            title = value.disposition == .accept ? "Accept Suggestion" : "Reject Suggestion"
            detail = "Suggestion \(shortReference(value.contributionID))"
            symbolName = value.disposition == .accept ? "checkmark.circle" : "xmark.circle"
        case .file(_, let value):
            switch value.result {
            case .remove:
                title = "Remove File"
                detail = "Direct file removal; no document contents are displayed"
                symbolName = "trash"
            case .write(let data, let permissions):
                title = "Update File"
                var facts = [
                    "Direct file contents hidden",
                    byteDescription(data.count),
                ]
                if let permissions {
                    facts.append(String(format: "mode %04o", permissions))
                }
                detail = facts.joined(separator: "  ·  ")
                symbolName = "doc"
            }
        }

        let boundedDetail = preview(detail, maximumUTF8Bytes: maximumDetailBytes)
        return StagedOperationPresentation(
            title: title,
            subtitle: path,
            detail: boundedDetail,
            symbolName: symbolName,
            searchText: preview(
                "\(title) \(path) \(boundedDetail) \(id)",
                maximumUTF8Bytes: 900
            )
        )
    }

    static func stageStatus(_ stage: CollaborationChangeSet) -> String {
        var facts = [stage.actor.name]
        if let prior = priorStageID(in: stage) {
            facts.append("refreshed from \(shortReference(prior))")
            facts.append("earlier stage retained")
        } else {
            facts.append(stage.created)
        }
        if stage.operations.count > maximumPresentedOperations {
            facts.append("\(maximumPresentedOperations) of \(stage.operations.count) changes shown")
        }
        facts.append("all-or-none submission")
        return preview(facts.joined(separator: "  ·  "), maximumUTF8Bytes: 600)
    }

    static func stageListSubtitle(_ stage: CollaborationChangeSet) -> String {
        let allPaths = Array(Set(stage.operations.map(\.path))).sorted()
        let paths = allPaths.prefix(3)
            .map { preview($0, maximumUTF8Bytes: 96) }
        var facts = [paths.joined(separator: ", ")].filter { !$0.isEmpty }
        if allPaths.count > paths.count {
            let remaining = allPaths.count - paths.count
            facts.append("+\(remaining) \(remaining == 1 ? "file" : "files")")
        }
        if let prior = priorStageID(in: stage) {
            facts.append("refreshed from \(shortReference(prior))")
        }
        return preview(facts.joined(separator: "  ·  "), maximumUTF8Bytes: 360)
    }

    static func overviewStatus(
        rootName: String,
        fileCount: Int,
        actorCount: Int,
        stageListing: CollaborationStageListing
    ) -> String {
        let fileNoun = fileCount == 1 ? "file" : "files"
        let actorNoun = actorCount == 1 ? "collaborator" : "collaborators"
        var facts = [
            rootName,
            "\(fileCount) \(fileNoun)",
            "\(actorCount) \(actorNoun)",
        ]
        if !stageListing.stages.isEmpty || stageListing.isTruncated {
            let stageNoun = stageListing.stages.count == 1 ? "stage" : "stages"
            facts.append("\(stageListing.stages.count) \(stageNoun) shown")
        }
        if stageListing.isTruncated {
            let omittedNoun = stageListing.omittedCount == 1 ? "stage" : "stages"
            facts.append(
                "\(stageListing.omittedCount) \(omittedNoun) omitted (\(byteDescription(stageListing.omittedCanonicalBytes)))"
            )
        }
        return facts.joined(separator: "  ·  ")
    }

    static func priorStageID(in stage: CollaborationChangeSet) -> String? {
        guard case .object(let refresh)? = stage.extensions["margin:stageRefresh"],
              case .string(let prior)? = refresh["priorStageID"] else {
            return nil
        }
        return prior
    }

    static func refreshResultDescription(_ receipt: CollaborationStageRefreshReceipt) -> String {
        let result = receipt.disposition == .alreadyPresent
            ? "The refreshed stage already existed"
            : "Created refreshed stage \(shortReference(receipt.refreshedStageID))"
        let mutationNoun = receipt.evaluatedMutationCount == 1 ? "file result" : "file results"
        let currentState = receipt.priorStageWasStale
            ? "Current file checks differ from the earlier stage."
            : "The earlier stage already matched current file checks."
        return "\(result) from \(shortReference(receipt.priorStageID)); \(receipt.evaluatedMutationCount) \(mutationNoun) validated. \(currentState) The earlier stage remains available until you explicitly discard it."
    }

    static func submissionFailureOffersRefresh(_ error: Error) -> Bool {
        guard let collaborationError = error as? CollaborationError else { return false }
        if case .preconditionFailed = collaborationError { return true }
        return false
    }

    static func shortReference(_ value: String) -> String {
        guard value.count > 18 else {
            return preview(value, maximumUTF8Bytes: 160)
        }
        return "…\(value.suffix(12))"
    }

    static func preview(_ value: String, maximumUTF8Bytes: Int = 160) -> String {
        guard maximumUTF8Bytes > 3 else { return "" }
        var bytes = Array(value.utf8.prefix(maximumUTF8Bytes + 1))
        let truncated = bytes.count > maximumUTF8Bytes
        if truncated {
            bytes = Array(bytes.prefix(maximumUTF8Bytes - 3))
            while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
                bytes.removeLast()
            }
        }
        let prefix = String(bytes: bytes, encoding: .utf8) ?? ""
        let normalized = prefix
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return truncated ? normalized + "…" : normalized
    }

    private static func contributionTitle(_ contribution: CollaborationContribution) -> String {
        if case .comment(let details) = contribution.details, details.parentID != nil {
            return "Add Reply"
        }
        return "Add \(humanized(contribution.kind.rawValue))"
    }

    private static func contributionDetail(_ contribution: CollaborationContribution) -> String {
        let body = "“\(preview(contribution.body, maximumUTF8Bytes: 140))”"
        var facts: [String] = []

        switch contribution.details {
        case .comment(let details):
            if let parentID = details.parentID {
                facts.append("Reply to \(shortReference(parentID))")
            }
        case .question(let details):
            if let answerID = details.answerContributionID {
                facts.append("Answer \(shortReference(answerID))")
            } else {
                facts.append("Awaiting answer")
            }
        case .issue(let details):
            facts.append(humanized(details.state.rawValue))
        case .decision(let details):
            facts.append(humanized(details.status.rawValue))
            if let rationale = details.rationale, !rationale.isEmpty {
                facts.append("Rationale “\(preview(rationale, maximumUTF8Bytes: 100))”")
            }
        case .task(let details):
            facts.append(details.assignee.map {
                "Assignee \(preview($0, maximumUTF8Bytes: 80))"
            } ?? "Unassigned")
            facts.append("\(humanized(details.priority.rawValue)) priority")
            facts.append(humanized(details.state.rawValue))
        case .suggestion(let details):
            facts.append(
                "“\(preview(details.expectedText, maximumUTF8Bytes: 88))” → “\(preview(details.replacementText, maximumUTF8Bytes: 88))”"
            )
        case .handoff(let details):
            if !contribution.audience.isEmpty {
                facts.append(
                    "Audience \(preview(contribution.audience.joined(separator: ", "), maximumUTF8Bytes: 96))"
                )
            }
            facts.append(details.intendedNextActors.isEmpty
                ? "No next actor named"
                : "Next \(preview(details.intendedNextActors.joined(separator: ", "), maximumUTF8Bytes: 96))")
            facts.append("\(details.unresolvedIDs.count) unresolved")
            facts.append("\(details.touchedAnnotationIDs.count) touched")
        case .approval(let details):
            facts.append(humanized(details.state.rawValue))
            if let subjectID = details.subjectID {
                facts.append("Subject \(shortReference(subjectID))")
            }
        }

        facts.append(body)
        return preview(facts.joined(separator: "  ·  "), maximumUTF8Bytes: maximumDetailBytes)
    }

    private static func contributionSymbol(_ kind: CollaborationContributionKind) -> String {
        switch kind {
        case .comment: return "text.bubble"
        case .question: return "questionmark.bubble"
        case .issue: return "exclamationmark.triangle"
        case .decision: return "signpost.right"
        case .task: return "checklist"
        case .suggestion: return "arrow.left.arrow.right"
        case .handoff: return "person.line.dotted.person"
        case .approval: return "checkmark.seal"
        }
    }

    private static func humanized(_ raw: String) -> String {
        raw.split(separator: "-").map { word in
            word.prefix(1).uppercased() + String(word.dropFirst())
        }.joined(separator: " ")
    }

    private static func byteDescription(_ count: Int) -> String {
        if count >= 1_048_576 {
            return String(format: "%.1f MiB", Double(count) / 1_048_576)
        }
        if count >= 1_024 {
            return String(format: "%.1f KiB", Double(count) / 1_024)
        }
        return "\(count) bytes"
    }
}
