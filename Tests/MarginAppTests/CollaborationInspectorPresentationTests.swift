import XCTest
import MarginCore
@testable import MarginApp

final class CollaborationInspectorPresentationTests: XCTestCase {
    func testTypedSuggestionAndHandoffExtensionsRemainPresentationOnly() {
        let actor = MarginActor(id: "urn:actor:agent", type: .software, name: "Agent")
        let suggestion = comment(
            id: "urn:uuid:10000000-0000-4000-8000-000000000001",
            actor: actor,
            kind: .suggestion,
            extensions: [
                "margin:suggestion": .object([
                    "expected": .string("old"),
                    "replacement": .string("new"),
                    "baseContentSha256": .string("sha256:abc"),
                    "status": .string("open"),
                ])
            ]
        )
        let handoff = comment(
            id: "urn:uuid:10000000-0000-4000-8000-000000000002",
            actor: actor,
            kind: .handoff,
            extensions: [
                "margin:handoff": .object([
                    "fromCursor": .string("mcur1:from"),
                    "toCursor": .string("mcur1:to"),
                    "touchedIDs": .array([.string(suggestion.id)]),
                    "unresolvedIDs": .array([.string("urn:uuid:open")]),
                    "audience": .array([.string("urn:actor:human")]),
                ])
            ]
        )

        XCTAssertEqual(suggestion.reviewSuggestion?.replacement, "new")
        XCTAssertEqual(suggestion.reviewSuggestion?.status, .open)
        XCTAssertEqual(handoff.reviewHandoff?.fromCursor, "mcur1:from")
        XCTAssertEqual(handoff.reviewHandoff?.unresolvedIDs, ["urn:uuid:open"])

        let canonical = comment(
            id: "urn:uuid:10000000-0000-4000-8000-000000000003",
            actor: actor,
            kind: .suggestion,
            extensions: [
                "margin:suggestion": .object([
                    "expectedText": .string("before"),
                    "replacementText": .string("after"),
                    "status": .string("proposed"),
                ])
            ]
        )
        XCTAssertEqual(canonical.reviewSuggestion?.expected, "before")
        XCTAssertEqual(canonical.reviewSuggestion?.replacement, "after")
        XCTAssertEqual(canonical.reviewSuggestion?.status, .open)

        let canonicalHandoff = comment(
            id: "urn:uuid:10000000-0000-4000-8000-000000000004",
            actor: actor,
            kind: .handoff,
            extensions: [
                "margin:handoff": .object([
                    "startingCursor": .string("mcur1:start"),
                    "finishingCursor": .string("mcur1:finish"),
                    "touchedAnnotationIDs": .array([.string(suggestion.id)]),
                    "intendedNextActors": .array([.string("urn:actor:human")]),
                ])
            ]
        )
        XCTAssertEqual(canonicalHandoff.reviewHandoff?.touchedIDs, [suggestion.id])
        XCTAssertEqual(canonicalHandoff.reviewHandoff?.audience, ["urn:actor:human"])
    }

    func testOverviewReportsDurableActivityWithoutClaimingPresence() {
        let human = MarginActor(id: "urn:actor:human", type: .person, name: "Human")
        let agent = MarginActor(id: "urn:actor:agent", type: .software, name: "Agent")
        let comments = [
            comment(id: "urn:uuid:20000000-0000-4000-8000-000000000001", actor: human, kind: .question, modified: "2026-08-16T10:00:00Z"),
            comment(id: "urn:uuid:20000000-0000-4000-8000-000000000002", actor: agent, kind: .suggestion, modified: "2026-08-16T11:00:00Z", extensions: [
                "margin:suggestion": .object([
                    "expected": .string("before"),
                    "replacement": .string("after"),
                    "status": .string("open"),
                ])
            ]),
            comment(id: "urn:uuid:20000000-0000-4000-8000-000000000003", actor: agent, kind: .handoff, modified: "2026-08-16T12:00:00Z", extensions: [
                "margin:handoff": .object(["unresolvedIDs": .array([.string("open")])])
            ]),
        ]

        let overview = CollaborationOverview(documents: [
            CollaborationDocumentActivity(relativePath: "architecture.md", comments: comments)
        ])

        XCTAssertEqual(overview.collaborators.map(\.actor.name), ["Agent", "Human"])
        XCTAssertEqual(overview.collaborators[0].contributionCount, 2)
        XCTAssertEqual(overview.collaborators[0].files, ["architecture.md"])
        XCTAssertEqual(overview.openSuggestions, 1)
        XCTAssertEqual(overview.unresolvedHandoffs, 1)
    }

    func testSuggestionActionsAreExposedOnlyWhenTheHostCanPerformThem() {
        let actor = MarginActor(id: "urn:actor:agent", type: .software, name: "Agent")
        let suggestion = comment(
            id: "urn:uuid:30000000-0000-4000-8000-000000000001",
            actor: actor,
            kind: .suggestion,
            extensions: [
                "margin:suggestion": .object([
                    "expected": .string("before"),
                    "replacement": .string("after"),
                    "status": .string("open"),
                ])
            ]
        )
        let controller = CommentsViewController()
        _ = controller.view
        controller.display(comments: [suggestion], source: "before", selectedCommentID: suggestion.id)
        XCTAssertFalse(buttonTitles(in: controller.view).contains("Accept"))

        controller.onAcceptSuggestion = { _ in }
        controller.onRejectSuggestion = { _ in }
        controller.display(comments: [suggestion], source: "before", selectedCommentID: suggestion.id)
        XCTAssertTrue(buttonTitles(in: controller.view).contains("Accept"))
        XCTAssertTrue(buttonTitles(in: controller.view).contains("Reject"))
        let text = descendantText(in: controller.view)
        XCTAssertTrue(text.contains("− before"))
        XCTAssertTrue(text.contains("+ after"))
    }

    func testSuggestionComparisonWrapsBothRowsInANarrowInspector() throws {
        let actor = MarginActor(id: "urn:actor:agent", type: .software, name: "Agent")
        let expected = "The coordinator currently submits every document independently, which can expose a partially applied collaboration state to another reader."
        let replacement = "The coordinator submits the complete staged set atomically, so every collaborator observes either the earlier state or the complete replacement."
        let suggestion = comment(
            id: "urn:uuid:30000000-0000-4000-8000-000000000002",
            actor: actor,
            kind: .suggestion,
            extensions: [
                "margin:suggestion": .object([
                    "expected": .string(expected),
                    "replacement": .string(replacement),
                    "status": .string("open"),
                ])
            ]
        )
        let controller = CommentsViewController()
        controller.display(comments: [suggestion], source: expected, selectedCommentID: suggestion.id)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        let expectedField = try XCTUnwrap(textField(
            identifiedBy: "suggestion-expected",
            in: controller.view
        ))
        let replacementField = try XCTUnwrap(textField(
            identifiedBy: "suggestion-replacement",
            in: controller.view
        ))

        for field in [expectedField, replacementField] {
            XCTAssertEqual(field.lineBreakMode, .byWordWrapping)
            XCTAssertEqual(field.cell?.wraps, true)
            XCTAssertFalse(field.usesSingleLineMode)
            XCTAssertGreaterThan(field.maximumNumberOfLines, 1)
            XCTAssertLessThanOrEqual(field.maximumNumberOfLines, 6)
            XCTAssertGreaterThan(field.frame.width, 40)
            XCTAssertLessThan(field.frame.width, 150)
            let singleLineHeight = try XCTUnwrap(field.font).boundingRectForFont.height
            XCTAssertGreaterThan(field.frame.height, singleLineHeight * 1.5)
        }
    }

    func testHandoffSummaryWrapsWithoutOverflowInANarrowInspector() throws {
        let actor = MarginActor(id: "urn:actor:agent", type: .software, name: "Agent")
        let handoff = comment(
            id: "urn:uuid:30000000-0000-4000-8000-000000000003",
            actor: actor,
            kind: .handoff,
            extensions: [
                "margin:handoff": .object([
                    "audience": .array([.string("urn:actor:human-reviewer")]),
                    "unresolvedIDs": .array([.string("open-one"), .string("open-two")]),
                    "touchedIDs": .array([.string("change-one")]),
                ])
            ]
        )
        let controller = CommentsViewController()
        controller.display(comments: [handoff], source: "# Handoff", selectedCommentID: handoff.id)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        let summary = try XCTUnwrap(textField(identifiedBy: "handoff-summary", in: controller.view))
        XCTAssertEqual(summary.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(summary.cell?.wraps, true)
        XCTAssertFalse(summary.usesSingleLineMode)
        XCTAssertEqual(summary.maximumNumberOfLines, 4)
        XCTAssertGreaterThan(summary.frame.width, 40)
        XCTAssertLessThan(summary.frame.width, 150)
        let singleLineHeight = try XCTUnwrap(summary.font).boundingRectForFont.height
        XCTAssertGreaterThan(summary.frame.height, singleLineHeight * 1.5)
    }

    private func comment(
        id: String,
        actor: MarginActor,
        kind: ReviewContributionKind,
        modified: String = "2026-08-16T12:00:00.123Z",
        extensions: [String: JSONValue] = [:]
    ) -> MarginComment {
        var extensions = extensions
        extensions["margin:kind"] = .string(kind.rawValue)
        return MarginComment(
            id: id,
            motivation: "commenting",
            creator: actor,
            created: modified,
            modified: modified,
            body: MarginCommentBody(value: "Body", purpose: "commenting"),
            target: .resource("urn:uuid:document"),
            status: .open,
            statusModified: modified,
            statusModifiedBy: actor,
            extensions: extensions
        )
    }

    private func buttonTitles(in view: NSView) -> [String] {
        var values: [String] = []
        if let button = view as? NSButton { values.append(button.title) }
        for child in view.subviews { values.append(contentsOf: buttonTitles(in: child)) }
        return values
    }

    private func descendantText(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { descendantText(in: $0) }
    }

    private func textField(identifiedBy identifier: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.identifier?.rawValue == identifier {
            return field
        }
        return view.subviews.lazy.compactMap { self.textField(identifiedBy: identifier, in: $0) }.first
    }
}
