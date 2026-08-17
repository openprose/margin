import AppKit
import XCTest
@testable import MarginApp
@testable import MarginCore

final class CollaborationStageInspectorPresentationTests: XCTestCase {
    func testSemanticStageRowsShowBoundedBodyAndTypedFacts() throws {
        let fixture = try makeFixture()
        let longBody = String(repeating: "A precise collaboration note with context. ", count: 30)
        let suggestion = try CollaborationContribution(
            id: "urn:contribution:suggestion",
            actorID: fixture.actor.id,
            created: fixture.timestamp,
            body: longBody,
            target: CollaborationTarget(
                path: ".",
                range: UnicodeScalarRange(start: 0, end: 6)
            ),
            details: .suggestion(CollaborationSuggestionDetails(
                expectedText: "Before the architectural boundary",
                replacementText: "After the precise architectural boundary",
                baseContentSha256: fixture.file.contentSha256
            ))
        )
        let task = try CollaborationContribution(
            id: "urn:contribution:task",
            actorID: fixture.actor.id,
            created: fixture.timestamp,
            body: "Validate the cross-file transaction before handoff.",
            target: CollaborationTarget(path: "."),
            details: .task(CollaborationTaskDetails(
                state: .inProgress,
                assignee: "urn:actor:reviewer",
                priority: .high
            ))
        )
        let handoff = try CollaborationContribution(
            id: "urn:contribution:handoff",
            actorID: fixture.actor.id,
            created: fixture.timestamp,
            body: "Continue with the unresolved review boundary.",
            target: CollaborationTarget(path: "."),
            audience: ["urn:actor:human"],
            details: .handoff(CollaborationHandoffDetails(
                startingCursor: try fixture.cursor.token(),
                touchedAnnotationIDs: ["urn:annotation:one", "urn:annotation:two"],
                unresolvedIDs: ["urn:issue:one"],
                intendedNextActors: ["urn:actor:next"]
            ))
        )

        let suggestionRow = presentation(for: suggestion, id: "urn:operation:suggestion")
        XCTAssertEqual(suggestionRow.title, "Add Suggestion")
        XCTAssertTrue(suggestionRow.detail.contains("Before the architectural boundary"))
        XCTAssertTrue(suggestionRow.detail.contains("→"))
        XCTAssertTrue(suggestionRow.detail.contains("A precise collaboration note"))
        XCTAssertLessThanOrEqual(
            suggestionRow.detail.utf8.count,
            CollaborationStageInspectorPresentation.maximumDetailBytes
        )

        let taskRow = presentation(for: task, id: "urn:operation:task")
        XCTAssertTrue(taskRow.detail.contains("Assignee urn:actor:reviewer"))
        XCTAssertTrue(taskRow.detail.contains("High priority"))
        XCTAssertTrue(taskRow.detail.contains("In Progress"))
        XCTAssertTrue(taskRow.detail.contains("Validate the cross-file transaction"))

        let handoffRow = presentation(for: handoff, id: "urn:operation:handoff")
        XCTAssertTrue(handoffRow.detail.contains("Audience urn:actor:human"))
        XCTAssertTrue(handoffRow.detail.contains("Next urn:actor:next"))
        XCTAssertTrue(handoffRow.detail.contains("1 unresolved"))
        XCTAssertTrue(handoffRow.detail.contains("2 touched"))
        XCTAssertTrue(handoffRow.detail.contains("Continue with the unresolved review"))
    }

    func testDirectFileRowsNeverRenderOrIndexTheirImage() throws {
        let fixture = try makeFixture()
        let rawImage = "UE9QX1NFQ1JFVF9GSUxFX0lNQUdF"
        let data = Data(rawImage.utf8)
        let mutation = try CollaborationFileMutation(
            id: "urn:mutation:direct",
            path: ".",
            precondition: .exact(fixture.file),
            result: .write(data: data, permissions: 0o640)
        )
        let row = CollaborationStageInspectorPresentation.operation(
            .file(id: "urn:operation:direct", mutation)
        )
        let surfaced = [row.title, row.subtitle, row.detail, row.searchText].joined(separator: " ")

        XCTAssertEqual(row.title, "Update File")
        XCTAssertTrue(row.detail.contains("Direct file contents hidden"))
        XCTAssertTrue(row.detail.contains("\(data.count) bytes"))
        XCTAssertTrue(row.detail.contains("mode 0640"))
        XCTAssertFalse(surfaced.contains(rawImage))
    }

    func testStageActionsLineageAndBoundedListingFactsAreExplicit() throws {
        XCTAssertEqual(
            CollaborationStageInspectorPresentation.stageListingAggregateByteBudget,
            16 * 1_024 * 1_024
        )
        let fixture = try makeFixture()
        let task = try CollaborationContribution(
            id: "urn:contribution:stage-task",
            actorID: fixture.actor.id,
            created: fixture.timestamp,
            body: "Review the staged operation.",
            target: CollaborationTarget(path: "."),
            details: .task(CollaborationTaskDetails(
                assignee: "urn:actor:reviewer",
                priority: .urgent
            ))
        )
        let stage = try CollaborationChangeSet(
            id: "urn:changeset:refreshed",
            root: fixture.root,
            baseCursor: fixture.cursor,
            actor: fixture.actor,
            requestID: "urn:request:refreshed",
            stageID: "urn:stage:refreshed",
            created: fixture.timestamp,
            operations: [
                .contribution(
                    id: "urn:operation:stage-task",
                    CollaborationContributionOperation(contribution: task)
                )
            ],
            extensions: [
                "margin:stageRefresh": .object([
                    "priorStageID": .string("urn:stage:earlier"),
                ])
            ]
        )
        let controller = WorkspaceWindowController(workspaceURL: nil)
        defer { controller.close() }
        let items = controller.makeStageDetailItems(stage)

        XCTAssertEqual(Array(items.prefix(3).map(\.title)), [
            "Submit All 1 Change",
            "Refresh Against Current Files",
            "Discard This Stage…",
        ])
        XCTAssertEqual(items[3].title, "Add Task")
        XCTAssertTrue(items[3].detail.contains("Urgent priority"))
        let status = CollaborationStageInspectorPresentation.stageStatus(stage)
        XCTAssertTrue(status.contains("refreshed from urn:stage:earlier"))
        XCTAssertTrue(status.contains("earlier stage retained"))

        let listing = CollaborationStageListing(
            stages: [stage],
            omittedCount: 2,
            selectedCanonicalBytes: 1_024,
            omittedCanonicalBytes: 4_096
        )
        let overview = CollaborationStageInspectorPresentation.overviewStatus(
            rootName: "workspace",
            fileCount: 1,
            actorCount: 1,
            stageListing: listing
        )
        XCTAssertTrue(overview.contains("1 file"))
        XCTAssertTrue(overview.contains("1 collaborator"))
        XCTAssertTrue(overview.contains("1 stage shown"))
        XCTAssertTrue(overview.contains("2 stages omitted (4.0 KiB)"))
    }

    func testStaleSubmissionOffersRefreshAndReceiptNamesRetainedLineage() {
        XCTAssertTrue(CollaborationStageInspectorPresentation.submissionFailureOffersRefresh(
            CollaborationError.preconditionFailed(path: "draft.md", reason: "changed")
        ))
        XCTAssertFalse(CollaborationStageInspectorPresentation.submissionFailureOffersRefresh(
            CollaborationError.io("offline")
        ))

        let receipt = CollaborationStageRefreshReceipt(
            priorStageID: "urn:stage:earlier",
            refreshedStageID: "urn:stage:current",
            priorChangeSetID: "urn:changeset:earlier",
            refreshedChangeSetID: "urn:changeset:current",
            requestID: "urn:request:one",
            priorStageWasStale: true,
            disposition: .created,
            canonicalSha256: DocumentRevision(text: "stage").sha256,
            location: "/tmp/stage.json",
            evaluatedMutationCount: 2
        )
        let result = CollaborationStageInspectorPresentation.refreshResultDescription(receipt)
        XCTAssertTrue(result.contains("urn:stage:current"))
        XCTAssertTrue(result.contains("from urn:stage:earlier"))
        XCTAssertTrue(result.contains("earlier stage remains available"))
    }

    func testStageDetailProjectionCapsLargeOperationSetsAndReportsTheBound() throws {
        let fixture = try makeFixture()
        let operationCount = CollaborationStageInspectorPresentation.maximumPresentedOperations + 1
        let operations: [CollaborationOperation] = (0..<operationCount).map { index in
            .status(
                id: "urn:operation:status:\(index)",
                CollaborationStatusOperation(
                    path: ".",
                    annotationID: "urn:annotation:status",
                    status: .resolved
                )
            )
        }
        let stage = try CollaborationChangeSet(
            id: "urn:changeset:bounded-ui",
            root: fixture.root,
            baseCursor: fixture.cursor,
            actor: fixture.actor,
            requestID: "urn:request:bounded-ui",
            stageID: "urn:stage:bounded-ui",
            created: fixture.timestamp,
            operations: operations
        )
        let controller = WorkspaceWindowController(workspaceURL: nil)
        defer { controller.close() }

        XCTAssertEqual(
            controller.makeStageDetailItems(stage).count,
            CollaborationStageInspectorPresentation.maximumPresentedOperations + 3
        )
        XCTAssertTrue(
            CollaborationStageInspectorPresentation.stageStatus(stage)
                .contains("512 of 513 changes shown")
        )
    }

    func testStaleSubmitRefreshRetainsEarlierStageUntilConfirmedDiscard() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-stage-app-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = directory.appendingPathComponent("draft.md")
        let context = directory.appendingPathComponent("context.md")
        try Data("Draft body\n".utf8).write(to: draft)
        try Data("Context one\n".utf8).write(to: context)
        let initialized = try CollaborationWorkspaceService().initialize(
            at: directory,
            id: "urn:workspace:stage-app-flow",
            created: "2026-08-16T12:00:00Z"
        )
        let cursor = try CollaborationCursorService().capture(
            root: initialized.root,
            paths: ["context.md", "draft.md"],
            limits: CollaborationDiscoveryLimits(maxFiles: 2, maxBytes: 1_024, maxDepth: 2)
        )
        let actor = try CollaborationActor(
            id: "urn:actor:stage-app-flow",
            type: .software,
            name: "Stage Flow Agent"
        )
        let contribution = try CollaborationContribution(
            id: "urn:contribution:stage-app-flow",
            actorID: actor.id,
            created: "2026-08-16T12:00:00Z",
            body: "Review the draft after context changes.",
            target: CollaborationTarget(path: "draft.md"),
            details: .comment(CollaborationCommentDetails())
        )
        let original = try CollaborationChangeSet(
            id: "urn:changeset:stage-app-flow",
            root: initialized.root,
            baseCursor: cursor,
            actor: actor,
            requestID: "urn:request:stage-app-flow",
            stageID: "urn:stage:stage-app-flow",
            created: "2026-08-16T12:00:00Z",
            operations: [
                .contribution(
                    id: "urn:operation:stage-app-flow",
                    CollaborationContributionOperation(contribution: contribution)
                )
            ]
        )
        let store = CollaborationStageStore()
        _ = try store.stage(original)
        try Data("Context two\n".utf8).write(to: context)

        let controller = WorkspaceWindowController(workspaceURL: directory)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.makeStageDetailItems(original)[0].action()

        waitUntil {
            self.button(named: "Submit All", in: controller.window?.sheets.first?.contentView) != nil
        }
        button(named: "Submit All", in: controller.window?.sheets.first?.contentView)?
            .performClick(nil)
        waitUntil(timeout: 4) {
            self.button(
                named: "Refresh Against Current Files",
                in: controller.window?.sheets.first?.contentView
            ) != nil
        }
        let staleText = descendantText(in: controller.window?.sheets.first?.contentView)
            .joined(separator: " ")
        XCTAssertTrue(staleText.contains("Nothing was submitted"))
        XCTAssertFalse(staleText.localizedCaseInsensitiveContains("retry"))
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), "Draft body\n")
        button(
            named: "Refresh Against Current Files",
            in: controller.window?.sheets.first?.contentView
        )?.performClick(nil)

        waitUntil(timeout: 4) {
            (try? store.list(root: initialized.root, limit: 4).stages.count) == 2
                && self.button(named: "Discard Earlier Stage…", in: controller.window?.sheets.first?.contentView) != nil
        }
        let listing = try store.list(root: initialized.root, limit: 4)
        let refreshed = try XCTUnwrap(listing.stages.first { $0.stageID != original.stageID })
        XCTAssertEqual(
            CollaborationStageInspectorPresentation.priorStageID(in: refreshed),
            original.stageID
        )
        XCTAssertNoThrow(try store.load(stageID: original.stageID, root: initialized.root))

        button(
            named: "Discard Earlier Stage…",
            in: controller.window?.sheets.first?.contentView
        )?.performClick(nil)
        waitUntil {
            self.button(named: "Discard Stage", in: controller.window?.sheets.first?.contentView) != nil
        }
        XCTAssertNoThrow(try store.load(stageID: original.stageID, root: initialized.root))
        let discard = try XCTUnwrap(button(
            named: "Discard Stage",
            in: controller.window?.sheets.first?.contentView
        ))
        XCTAssertTrue(discard.hasDestructiveAction)
        discard.performClick(nil)

        waitUntil(timeout: 4) {
            guard let stages = try? store.list(root: initialized.root, limit: 4).stages else {
                return false
            }
            return stages.map(\.stageID) == [refreshed.stageID]
        }
        XCTAssertEqual(
            try store.load(stageID: refreshed.stageID, root: initialized.root),
            refreshed
        )
    }

    func testDetailedPaletteRowWrapsAndKeepsCompleteAccessibilityAtNarrowWidth() throws {
        let detail = "Expected a long architectural boundary to remain readable while a precise replacement and its collaboration context wrap naturally."
        let item = NavigationPaletteItem(
            title: "Add Suggestion",
            subtitle: "architecture/decision-record.md",
            detail: detail,
            symbolName: "arrow.left.arrow.right"
        ) {}
        let controller = NavigationPaletteController(
            title: "Staged Change Set",
            placeholder: "Inspect staged changes",
            items: [item],
            emptyMessage: "No staged changes"
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 300, height: 410))
        window.contentView?.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendant(of: NSTableView.self, in: window.contentView))
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let detailField = try XCTUnwrap(textField(
            identifiedBy: "NavigationPaletteDetail",
            in: cell
        ))

        XCTAssertGreaterThanOrEqual(table.rect(ofRow: 0).height, 86)
        XCTAssertLessThan(table.rect(ofRow: 0).height, 88)
        XCTAssertEqual(detailField.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(detailField.maximumNumberOfLines, 3)
        let singleLineHeight = try XCTUnwrap(detailField.font).boundingRectForFont.height
        XCTAssertGreaterThan(detailField.frame.height, singleLineHeight * 1.5)
        XCTAssertEqual(
            cell.accessibilityLabel(),
            "Add Suggestion, architecture/decision-record.md, \(detail)"
        )
    }

    private func presentation(
        for contribution: CollaborationContribution,
        id: String
    ) -> StagedOperationPresentation {
        CollaborationStageInspectorPresentation.operation(
            .contribution(
                id: id,
                CollaborationContributionOperation(contribution: contribution)
            )
        )
    }

    private func makeFixture() throws -> (
        root: CollaborationRoot,
        file: CollaborationFileCursor,
        cursor: CollaborationCursor,
        actor: CollaborationActor,
        timestamp: String
    ) {
        let root = try CollaborationRoot(
            id: "urn:root:stage-ui",
            kind: .document,
            path: "/tmp/stage-ui.md"
        )
        let file = try CollaborationFileCursor(
            path: ".",
            documentID: "urn:document:stage-ui",
            contentSha256: DocumentRevision(text: "source").sha256,
            annotationRevision: 1,
            annotationSha256: DocumentRevision(text: "annotations").sha256,
            wholeFileSha256: DocumentRevision(text: "whole").sha256
        )
        let cursor = try CollaborationCursor(root: root, files: [file])
        let actor = try CollaborationActor(
            id: "urn:actor:stage-agent",
            type: .software,
            name: "Stage Agent"
        )
        return (root, file, cursor, actor, "2026-08-16T12:00:00Z")
    }

    private func descendant<T: NSView>(of type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
    }

    private func textField(identifiedBy identifier: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.identifier?.rawValue == identifier {
            return field
        }
        return view.subviews.lazy.compactMap {
            self.textField(identifiedBy: identifier, in: $0)
        }.first
    }

    private func button(named title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(named: title, in: $0) }.first
    }

    private func descendantText(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { self.descendantText(in: $0) }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @escaping () -> Bool
    ) {
        let expectation = expectation(description: "Condition became true")
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if predicate() {
                expectation.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
            }
        }
        poll()
        wait(for: [expectation], timeout: timeout + 0.2)
    }
}
