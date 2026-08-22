import AppKit
import XCTest
@testable import MarginApp
import MarginCore

final class ComparisonAppTests: XCTestCase {
    func testComparisonWorkIsLazyUntilWindowIsShown() throws {
        let pair = try makePair(left: "alpha\n", right: "beta\n")
        let loader = CountingComparisonLoader(base: CoreComparisonLoader())
        let controller = ComparisonWindowController(
            request: .snapshots(pair),
            loader: loader
        )
        defer { controller.close() }

        _ = controller.window
        _ = controller.comparisonViewController.view
        XCTAssertEqual(loader.count, 0, "Constructing ordinary AppKit objects must not start comparison work")

        controller.showWindow(nil)
        waitUntil { controller.comparisonViewController.stateForTesting == .loaded }
        XCTAssertEqual(loader.count, 1)
        XCTAssertTrue(controller.comparisonViewController.canNavigateChanges)
    }

    func testEmptyComparisonReviewStartsWithInspectorHidden() throws {
        let pair = try makePair(left: "alpha\n", right: "beta\n")
        let controller = ComparisonWindowController(request: .snapshots(pair))
        defer { controller.close() }

        controller.showWindow(nil)
        waitUntil { controller.comparisonViewController.stateForTesting == .loaded }

        XCTAssertFalse(controller.isCommentsVisible)
        XCTAssertTrue(controller.canShowComments)
    }

    func testCancelledOperationCanRestoreComparisonSummary() throws {
        let pair = try makePair(left: "alpha\n", right: "beta\n")
        let controller = ComparisonWindowController(request: .snapshots(pair))
        defer { controller.close() }
        controller.showWindow(nil)
        waitUntil { controller.comparisonViewController.stateForTesting == .loaded }

        let comparison = controller.comparisonViewController
        let expected = comparison.snapshotStatusForTesting
        comparison.showOperationStatus("Preparing verified change set…")
        XCTAssertEqual(comparison.snapshotStatusForTesting, "Preparing verified change set…")

        comparison.restoreSnapshotStatus()
        XCTAssertEqual(comparison.snapshotStatusForTesting, expected)
        XCTAssertTrue(expected.contains("1 change"))
    }

    func testPresentationCollapsesLongUnchangedRegionsAndAdaptsNarrowLayout() throws {
        let prefix = (1...18).map { "unchanged \($0)" }.joined(separator: "\n")
        let suffix = (19...36).map { "unchanged \($0)" }.joined(separator: "\n")
        let pair = try makePair(
            left: "\(prefix)\nold\n\(suffix)\n",
            right: "\(prefix)\nnew\n\(suffix)\n"
        )
        let presentation = try CoreComparisonLoader().load(
            .snapshots(pair),
            cancellation: ComparisonCancellationToken()
        )

        XCTAssertFalse(presentation.collapsedRows.isEmpty)
        XCTAssertTrue(presentation.rows.contains {
            if case .collapsed(let count) = $0.kind { return count > 0 }
            return false
        })
        XCTAssertEqual(
            ComparisonPresentationLayout.effective(preferred: .sideBySide, width: 700),
            .inline
        )
        XCTAssertEqual(
            ComparisonPresentationLayout.effective(preferred: .sideBySide, width: 1_100),
            .sideBySide
        )
    }

    func testCollapsedPassageExpandsWithKeyboardReturn() throws {
        let prefix = (1...18).map { "unchanged \($0)" }.joined(separator: "\n")
        let suffix = (19...36).map { "unchanged \($0)" }.joined(separator: "\n")
        let pair = try makePair(
            left: "\(prefix)\nold\n\(suffix)\n",
            right: "\(prefix)\nnew\n\(suffix)\n"
        )
        let controller = ComparisonWindowController(request: .snapshots(pair))
        defer { controller.close() }
        controller.showWindow(nil)
        waitUntil { controller.comparisonViewController.stateForTesting == .loaded }
        let comparison = controller.comparisonViewController
        let collapsed = try XCTUnwrap(comparison.firstCollapsedRowIndexForTesting)
        let initialCount = comparison.rowCountForTesting
        let table = try XCTUnwrap(
            descendants(of: NSTableView.self, in: controller.window?.contentView)
                .first { $0.accessibilityLabel() == "Comparison passages" }
        )
        table.selectRowIndexes(IndexSet(integer: collapsed), byExtendingSelection: false)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        table.keyDown(with: event)
        XCTAssertGreaterThan(comparison.rowCountForTesting, initialCount)
    }

    func testIdenticalComparisonUsesDedicatedQuietState() throws {
        let pair = try makePair(left: "same\n", right: "same\n")
        let controller = ComparisonWindowController(request: .snapshots(pair))
        defer { controller.close() }
        controller.showWindow(nil)

        waitUntil { controller.comparisonViewController.stateForTesting == .identical }
        XCTAssertFalse(controller.comparisonViewController.canNavigateChanges)
        XCTAssertTrue(descendantText(in: controller.window?.contentView).contains("snapshots are identical"))
    }

    func testOpenRequestIsOwnerOnlyAgeCheckedAndConsumedAfterDecode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("handoff.margincompare-request")
        let pair = try makePair(left: "left\n", right: "right\n")
        let now = Date()
        let request = try ComparisonOpenRequest(
            requestID: "urn:uuid:\(UUID().uuidString.lowercased())",
            created: ISO8601DateFormatter().string(from: now),
            left: pair.left,
            right: pair.right
        )
        try ComparisonOpenRequestCodec.encode(request).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let decoded = try ComparisonOpenRequestReader.consume(url, now: now)
        XCTAssertEqual(decoded, request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnsafeOpenRequestIsRejectedWithoutCleanup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real.margincompare-request")
        let link = directory.appendingPathComponent("link.margincompare-request")
        let pair = try makePair(left: "left\n", right: "right\n")
        let request = try ComparisonOpenRequest(
            requestID: "urn:uuid:\(UUID().uuidString.lowercased())",
            created: ISO8601DateFormatter().string(from: Date()),
            left: pair.left,
            right: pair.right
        )
        try ComparisonOpenRequestCodec.encode(request).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: real.path)

        XCTAssertThrowsError(try ComparisonOpenRequestReader.consume(real))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try ComparisonOpenRequestReader.consume(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testComparisonMenuUsesDocumentedKeyboardCommands() {
        AppMenu.install(for: NSApplication.shared, delegate: AppDelegate())

        let compare = menuItem(named: "Compare Active Tab With…")
        XCTAssertEqual(compare?.keyEquivalent, "c")
        XCTAssertEqual(compare?.keyEquivalentModifierMask, [.command, .control])
        XCTAssertNotNil(menuItem(named: "Compare Files…"))

        let previous = menuItem(named: "Previous Change")
        XCTAssertEqual(previous?.keyEquivalent, "\u{F700}")
        XCTAssertEqual(previous?.keyEquivalentModifierMask, [.command, .option])
        let next = menuItem(named: "Next Change")
        XCTAssertEqual(next?.keyEquivalent, "\u{F701}")
        XCTAssertEqual(next?.keyEquivalentModifierMask, [.command, .option])

        let refresh = menuItem(named: "Refresh Comparison")
        XCTAssertEqual(refresh?.keyEquivalent, "r")
        XCTAssertEqual(refresh?.keyEquivalentModifierMask, [.command])
        XCTAssertNotNil(menuItem(named: "Side-by-Side Comparison"))
        XCTAssertNotNil(menuItem(named: "Show Comparison Whitespace"))
        XCTAssertNotNil(menuItem(named: "Swap Comparison Sides"))
        XCTAssertNotNil(menuItem(named: "Apply Comparison"))

        let controlCommandC = allMenuItems().filter {
            $0.keyEquivalent == "c"
                && $0.keyEquivalentModifierMask == [.command, .control]
        }
        XCTAssertEqual(
            controlCommandC.map(\.title),
            ["Compare Active Tab With…"],
            "A duplicate main-menu key equivalent makes one command unreachable"
        )
    }

    func testOpenTabComparisonValidationAndPickerStayMetadataOnlyUntilSelection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leftURL = directory.appendingPathComponent("left.md")
        let rightURL = directory.appendingPathComponent("right.md")
        try "left body\n".write(to: leftURL, atomically: true, encoding: .utf8)
        try "right body\n".write(to: rightURL, atomically: true, encoding: .utf8)

        let suite = "margin-comparison-picker-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recentStore = RecentWorkspaceStore(defaults: defaults, key: "recent")
        let leftEditor = CountingComparisonSourceEditor()
        let rightEditor = CountingComparisonSourceEditor()
        var editors = [leftEditor, rightEditor]
        WorkspacePaneFactory.makeEditor = { editors.removeFirst() }
        WorkspacePaneFactory.makeComments = { CommentsViewController() }
        defer {
            WorkspacePaneFactory.makeEditor = { EditorViewController() }
            WorkspacePaneFactory.makeComments = { CommentsViewController() }
        }

        let left = WorkspaceWindowController(
            workspaceURL: leftURL,
            recentWorkspaceStore: recentStore
        )
        let right = WorkspaceWindowController(
            workspaceURL: rightURL,
            recentWorkspaceStore: recentStore
        )
        defer {
            left.close()
            right.close()
        }

        XCTAssertTrue(OpenTabComparisonPickerModel.isAvailable(active: left, windows: [left, right]))
        var chosenLabels: [String] = []
        let items = OpenTabComparisonPickerModel.items(active: left, windows: [left, right]) {
            active, candidate in
            guard let leftSource = active.comparisonSource,
                  let rightSource = candidate.comparisonSource else { return }
            chosenLabels = [leftSource.label, rightSource.label]
        }

        XCTAssertEqual(items.map(\.title), ["right.md"])
        XCTAssertEqual(leftEditor.sourceReadCount, 0)
        XCTAssertEqual(rightEditor.sourceReadCount, 0)

        items[0].action()
        XCTAssertEqual(chosenLabels, ["left.md", "right.md"])
        XCTAssertEqual(leftEditor.sourceReadCount, 1)
        XCTAssertEqual(rightEditor.sourceReadCount, 1)
    }

    func testURLClassificationNeverTreatsReviewOrOneShotRequestAsMarkdown() {
        XCTAssertEqual(
            ComparisonURLClassifier.classify(URL(fileURLWithPath: "/tmp/a.marginreview")),
            .review
        )
        XCTAssertEqual(
            ComparisonURLClassifier.classify(URL(fileURLWithPath: "/tmp/a.margin-review.json")),
            .review
        )
        XCTAssertEqual(
            ComparisonURLClassifier.classify(URL(fileURLWithPath: "/tmp/a.margincompare-request")),
            .openRequest
        )
        XCTAssertEqual(
            ComparisonURLClassifier.classify(URL(fileURLWithPath: "/tmp/a.md")),
            .document
        )
    }

    func testOpenEditorApplyReanchorsEverySelectionAnnotationAndIsUndoable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinationURL = directory.appendingPathComponent("destination.md")
        try "alpha beta\n".write(to: destinationURL, atomically: true, encoding: .utf8)

        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        editor.presentDocument(at: destinationURL)
        waitUntil { editor.comparisonSource()?.markdown == "alpha beta\n" }

        let documentID = "urn:margin:test:all-selection-annotations"
        let target = try AnchorResolver().target(
            for: .quote(exact: "beta"),
            documentID: documentID,
            in: "alpha beta\n"
        )
        let annotation = MarginComment(
            id: "urn:margin:test:suggestion",
            motivation: "suggesting",
            creator: MarginActor(id: "urn:agent:test", type: .software, name: "Test Agent"),
            created: ISO8601DateFormatter().string(from: Date()),
            modified: ISO8601DateFormatter().string(from: Date()),
            body: MarginCommentBody(value: "Consider this word."),
            target: target
        )
        let resourceAnnotation = MarginComment(
            id: "urn:margin:test:document-comment",
            motivation: "commenting",
            creator: MarginActor(id: "urn:person:test", type: .person, name: "Test Person"),
            created: ISO8601DateFormatter().string(from: Date()),
            modified: ISO8601DateFormatter().string(from: Date()),
            body: MarginCommentBody(value: "Document-level note."),
            target: .resource(documentID),
            status: .open
        )
        let originalAnnotations = [annotation, resourceAnnotation]
        editor.installComparisonAnnotationsForTesting(originalAnnotations)
        let originalSelection = NSRange(location: 6, length: 4)
        editor.setComparisonSelectionForTesting(originalSelection)

        let pair = try makePair(left: "intro alpha beta\n", right: "alpha beta\n")
        let result = try ComparisonEngine().compare(pair)
        let plan = try ComparisonApplyService().plan(
            pair: pair,
            result: result,
            direction: .leftToRight
        )
        try editor.applyComparisonPlan(plan)

        XCTAssertEqual(editor.comparisonSource()?.markdown, "intro alpha beta\n")
        XCTAssertEqual(editor.comparisonAnnotationRevisionForTesting, 1)
        guard case .selection(let refreshed) = editor.comparisonAnnotationsForTesting.first?.target,
              let position = refreshed.positionSelector else {
            return XCTFail("Expected the non-commenting selection target to remain anchored")
        }
        XCTAssertEqual(refreshed.quoteSelector?.exact, "beta")
        XCTAssertGreaterThan(position.start, 6)
        let refreshedAnnotations = editor.comparisonAnnotationsForTesting
        XCTAssertEqual(refreshedAnnotations.last, resourceAnnotation)
        XCTAssertEqual(editor.comparisonSelectionForTesting, originalSelection)

        editor.setComparisonSelectionForTesting(NSRange(location: 0, length: 5))
        window.undoManager?.undo()
        XCTAssertEqual(editor.comparisonSource()?.markdown, "alpha beta\n")
        XCTAssertEqual(editor.comparisonAnnotationRevisionForTesting, 0)
        XCTAssertEqual(editor.comparisonAnnotationsForTesting, originalAnnotations)
        XCTAssertEqual(editor.comparisonSelectionForTesting, originalSelection)
        editor.setComparisonSelectionForTesting(NSRange(location: 1, length: 2))
        window.undoManager?.redo()
        XCTAssertEqual(editor.comparisonSource()?.markdown, "intro alpha beta\n")
        XCTAssertEqual(editor.comparisonAnnotationRevisionForTesting, 1)
        XCTAssertEqual(editor.comparisonAnnotationsForTesting, refreshedAnnotations)
        XCTAssertEqual(editor.comparisonSelectionForTesting, originalSelection)
    }

    func testOpenEditorApplyBudgetFailureLeavesLargeDocumentAnnotationsAndUndoUntouched() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinationURL = directory.appendingPathComponent("bounded.md")
        let originalBody = String(repeating: "x", count: 256_000) + " target\n"
        try originalBody.write(to: destinationURL, atomically: true, encoding: .utf8)

        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.close() }
        editor.presentDocument(at: destinationURL)
        waitUntil { editor.comparisonSource()?.markdown == originalBody }
        let target = try AnchorResolver().target(
            for: .quote(exact: "target"),
            documentID: "urn:margin:test:bounded-apply",
            in: originalBody
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let annotations = (0..<64).map { index in
            MarginComment(
                id: "urn:margin:test:bounded-\(index)",
                motivation: "suggesting",
                creator: MarginActor(id: "urn:agent:test", type: .software, name: "Test Agent"),
                created: timestamp,
                modified: timestamp,
                body: MarginCommentBody(value: "Bounded annotation \(index)."),
                target: target
            )
        }
        editor.installComparisonAnnotationsForTesting(annotations, revision: 7)
        editor.setComparisonAnchorScalarComparisonLimitForTesting(32)
        window.undoManager?.removeAllActions()
        let originalSelection = editor.comparisonSelectionForTesting
        let pair = try makePair(left: "prefix " + originalBody, right: originalBody)
        let plan = try ComparisonApplyService().plan(
            pair: pair,
            result: ComparisonEngine().compare(pair),
            direction: .leftToRight
        )

        XCTAssertThrowsError(try editor.applyComparisonPlan(plan)) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }
        XCTAssertEqual(editor.comparisonSource()?.markdown, originalBody)
        XCTAssertEqual(editor.comparisonAnnotationsForTesting, annotations)
        XCTAssertEqual(editor.comparisonAnnotationRevisionForTesting, 7)
        XCTAssertEqual(editor.comparisonSelectionForTesting, originalSelection)
        XCTAssertFalse(window.undoManager?.canUndo ?? false)
    }

    func testSavedReviewCommentReplyAndStatusFlowPersistsOptimistically() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("flow.marginreview")
        let pair = try makePair(left: "alpha\n", right: "beta\n")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let review = try ComparisonReview(
            id: MarginID.annotation(),
            created: timestamp,
            modified: timestamp,
            snapshots: pair
        )
        _ = try ComparisonReviewStore().create(review, at: reviewURL)

        let controller = ComparisonWindowController(request: .review(reviewURL))
        defer { controller.close() }
        controller.showWindow(nil)
        waitUntil { controller.currentReviewForTesting != nil }
        XCTAssertFalse(controller.isCommentsVisible)

        let diff = try ComparisonEngine().compare(pair)
        let selection = ComparisonSelectionRequest(
            side: .right,
            pairID: pair.id,
            snapshotSHA256: pair.right.sha256,
            blockID: diff.changedBlocks.first?.id,
            unicodeScalarRange: UnicodeScalarRange(start: 0, end: 4),
            quote: "beta"
        )
        controller.beginCommentForTesting(selection)
        XCTAssertTrue(controller.isCommentsVisible)
        controller.submitCommentForTesting(
            target: .selection(selection),
            body: "Is this the clearest term?"
        )
        waitUntil { controller.currentReviewForTesting?.threads.count == 1 }

        guard let threadID = controller.currentReviewForTesting?.threads.first?.id else {
            return XCTFail("Expected saved comparison thread")
        }
        controller.submitCommentForTesting(
            target: .reply(threadID: threadID, parentID: threadID),
            body: "Yes, after checking the surrounding paragraph."
        )
        waitUntil {
            controller.currentReviewForTesting?.threads.first?.comments.count == 2
        }
        controller.nextOpenComment(nil)
        XCTAssertTrue(controller.canResolveCurrentComment)
        controller.resolveCurrentComment(nil)
        waitUntil {
            controller.currentReviewForTesting?.threads.first?.status == .resolved
        }

        let persisted = try ComparisonReviewStore().load(at: reviewURL)
        XCTAssertEqual(persisted.threads.first?.comments.count, 2)
        XCTAssertEqual(persisted.threads.first?.status, .resolved)
        XCTAssertEqual(persisted.revision, 3)
        controller.window?.displayIfNeeded()
        let labels = accessibilityLabels(in: controller.window?.contentView)
        XCTAssertTrue(labels.contains { $0.contains("Thread by") && $0.contains("resolved") })
        XCTAssertTrue(labels.contains { $0.contains("Reply by") && $0.contains("resolved") })
    }

    func testCommentComposerPreservesReturnForTextAndUsesCommandReturnToSubmit() throws {
        let pair = try makePair(left: "alpha\n", right: "beta\n")
        let controller = ComparisonWindowController(request: .snapshots(pair))
        defer { controller.close() }
        controller.showWindow(nil)
        waitUntil { controller.comparisonViewController.stateForTesting == .loaded }

        let selection = ComparisonSelectionRequest(
            side: .right,
            pairID: pair.id,
            snapshotSHA256: pair.right.sha256,
            blockID: nil,
            unicodeScalarRange: UnicodeScalarRange(start: 0, end: 4),
            quote: "beta"
        )
        controller.beginCommentForTesting(selection)

        let buttons = descendants(of: NSButton.self, in: controller.window?.contentView)
        let submit = try XCTUnwrap(buttons.first { $0.title == "Add Comment" })
        XCTAssertEqual(submit.keyEquivalent, "\r")
        XCTAssertEqual(submit.keyEquivalentModifierMask, [.command])
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
    }

    func testLiveResizeFallsBackWithoutCrowdingLowPriorityHeaderControls() throws {
        let pair = try makePair(left: "old\n", right: "new\n")
        let controller = ComparisonWindowController(request: .snapshots(pair))
        defer { controller.close() }
        controller.showWindow(nil)
        waitUntil { controller.comparisonViewController.stateForTesting == .loaded }

        let comparison = controller.comparisonViewController
        comparison.toggleSideBySide(nil)
        comparison.updateAdaptiveLayoutForTesting(width: 1_000)
        XCTAssertEqual(comparison.effectiveLayoutForTesting, .sideBySide)
        XCTAssertEqual(comparison.headerVisibilityForTesting.refresh, true)
        XCTAssertEqual(comparison.headerVisibilityForTesting.whitespace, true)
        XCTAssertEqual(comparison.headerVisibilityForTesting.layout, true)

        comparison.updateAdaptiveLayoutForTesting(width: 430)
        XCTAssertEqual(comparison.effectiveLayoutForTesting, .inline)
        XCTAssertEqual(comparison.headerVisibilityForTesting.refresh, false)
        XCTAssertEqual(comparison.headerVisibilityForTesting.whitespace, false)
        XCTAssertEqual(comparison.headerVisibilityForTesting.layout, false)
    }

    func testComparisonUsesTextSymbolsAndAccessibleMeaningBeyondColor() throws {
        let pair = try makePair(left: "old phrase\n", right: "new phrase\n")
        let controller = ComparisonWindowController(request: .snapshots(pair))
        defer { controller.close() }
        controller.showWindow(nil)
        waitUntil { controller.comparisonViewController.stateForTesting == .loaded }
        controller.window?.displayIfNeeded()

        let rendered = descendantText(in: controller.window?.contentView)
        XCTAssertTrue(rendered.contains("+"), "Insertions need a visible non-color marker")
        XCTAssertTrue(rendered.contains("−"), "Deletions need a visible non-color marker")

        let labels = accessibilityLabels(in: controller.window?.contentView)
        XCTAssertTrue(labels.contains("Swap comparison sides"))
        XCTAssertTrue(labels.contains("Refresh comparison"))
        XCTAssertTrue(labels.contains("Show comparison whitespace"))
        XCTAssertTrue(labels.contains("Comparison layout"))
        XCTAssertTrue(labels.contains("Apply comparison changes"))
        XCTAssertTrue(labels.contains { $0.contains("replaced original") })
        XCTAssertTrue(labels.contains { $0.contains("replacement") })
    }

    func testSwapKeepsCommentAnchorsAndApplyDirectionBoundToOriginalSnapshots() throws {
        let pair = try makePair(left: "old phrase\n", right: "new phrase\n")
        let controller = ComparisonWindowController(request: .snapshots(pair))
        defer { controller.close() }
        var applyDirection: ComparisonApplyDirection?
        controller.onApplyRequest = { direction, _, _ in applyDirection = direction }
        controller.showWindow(nil)
        waitUntil { controller.comparisonViewController.stateForTesting == .loaded }

        controller.swapSides(nil)
        let presentation = try CoreComparisonLoader().load(
            .snapshots(pair),
            cancellation: ComparisonCancellationToken()
        )
        let changedRow = try XCTUnwrap(presentation.rows.first { $0.isChanged })
        let commentRequest = ComparisonSelectionMapping.request(
            row: changedRow,
            pair: pair,
            swapped: true,
            visualSide: .left,
            selection: UnicodeScalarRange(start: 0, end: 3)
        )

        XCTAssertEqual(commentRequest?.side, .right)
        XCTAssertEqual(commentRequest?.snapshotSHA256, pair.right.sha256)
        XCTAssertEqual(commentRequest?.quote, "new")

        controller.apply(visualDirection: .leftToRight, selectedOnly: false)
        XCTAssertEqual(applyDirection, .rightToLeft)
    }

    func testSavedReviewRefreshReloadsArtifactWithoutRereadingSourceHints() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("refresh.marginreview")
        let original = try makePair(left: "alpha\n", right: "beta\n")
        let changedSources = try makePair(left: "alpha\n", right: "intro beta\n")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let review = try ComparisonReview(
            id: MarginID.annotation(),
            created: timestamp,
            modified: timestamp,
            snapshots: original
        )
        _ = try ComparisonReviewStore().create(review, at: reviewURL)

        var sourceRefreshCalls = 0
        let controller = ComparisonWindowController(
            request: .review(reviewURL),
            refreshRequestProvider: {
                sourceRefreshCalls += 1
                return .snapshots(changedSources)
            }
        )
        defer { controller.close() }
        controller.showWindow(nil)
        waitUntil { controller.currentReviewForTesting?.snapshots.id == original.id }
        XCTAssertTrue(controller.canRefresh)

        _ = try ComparisonReviewStore().update(
            at: reviewURL,
            expectedRevision: 0,
            modified: ISO8601DateFormatter().string(from: Date())
        ) { value in
            value.display.layout = .sideBySide
            let anchor = try ComparisonReviewAnchor(
                snapshot: value.snapshots.right,
                input: .range(start: 0, end: 4, expectedExact: "beta")
            )
            let target = try ComparisonReviewTarget(side: .right, right: anchor)
            let id = MarginID.annotation()
            let actor = MarginActor(
                id: "urn:agent:external-reviewer",
                type: .software,
                name: "External Reviewer"
            )
            let comment = try ComparisonReviewComment(
                id: id,
                creator: actor,
                created: timestamp,
                modified: timestamp,
                body: MarginCommentBody(value: "Added outside the app.")
            )
            _ = try value.addThread(ComparisonReviewThread(
                id: id,
                target: target,
                statusModified: timestamp,
                statusModifiedBy: actor,
                comments: [comment]
            ))
        }

        controller.refreshComparison(nil)
        waitUntil(timeout: 3) {
            controller.currentReviewForTesting?.revision == 1
        }
        let persisted = try ComparisonReviewStore().load(at: reviewURL)
        XCTAssertEqual(sourceRefreshCalls, 0)
        XCTAssertEqual(controller.currentReviewForTesting?.snapshots.id, original.id)
        XCTAssertEqual(controller.currentReviewForTesting?.threads.count, 1)
        XCTAssertEqual(persisted.snapshots.id, original.id)
        XCTAssertEqual(persisted.revision, 1)
        XCTAssertTrue(controller.isSideBySidePreferred)
        XCTAssertTrue(controller.isCommentsVisible)

        controller.toggleComments(nil)
        waitUntil { !controller.isCommentsVisible }
        _ = try ComparisonReviewStore().update(
            at: reviewURL,
            expectedRevision: 1,
            modified: ISO8601DateFormatter().string(from: Date())
        ) { value in
            value.display.showWhitespace = true
        }
        controller.refreshComparison(nil)
        waitUntil(timeout: 3) {
            controller.currentReviewForTesting?.revision == 2
        }
        XCTAssertFalse(
            controller.isCommentsVisible,
            "An explicit Hide Review choice should survive a later artifact refresh"
        )
    }

    func testPostApplyRefreshIsLimitedToExplicitMutableSources() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leftURL = directory.appendingPathComponent("left.md")
        let rightURL = directory.appendingPathComponent("right.md")
        try "left\n".write(to: leftURL, atomically: true, encoding: .utf8)
        try "right\n".write(to: rightURL, atomically: true, encoding: .utf8)

        let filesLoader = CountingComparisonLoader(base: CoreComparisonLoader())
        let files = ComparisonWindowController(
            request: .files(left: leftURL, right: rightURL),
            loader: filesLoader
        )
        defer { files.close() }
        files.showWindow(nil)
        waitUntil { files.comparisonViewController.stateForTesting == .loaded }
        XCTAssertTrue(files.canRefreshAfterSuccessfulApply)
        try "left\n".write(to: rightURL, atomically: true, encoding: .utf8)
        files.refreshAfterSuccessfulApplyIfSafe()
        waitUntil { filesLoader.count == 2 }

        let pair = try makePair(left: "left\n", right: "right\n")
        var liveRefreshCalls = 0
        let liveLoader = CountingComparisonLoader(base: CoreComparisonLoader())
        let live = ComparisonWindowController(
            request: .sources(
                left: WorkspaceComparisonSource(
                    markdown: pair.left.content,
                    label: pair.left.label,
                    sourceURL: leftURL
                ),
                right: WorkspaceComparisonSource(
                    markdown: pair.right.content,
                    label: pair.right.label,
                    sourceURL: rightURL
                )
            ),
            loader: liveLoader,
            refreshRequestProvider: {
                liveRefreshCalls += 1
                return .snapshots(pair)
            }
        )
        defer { live.close() }
        live.showWindow(nil)
        waitUntil { live.comparisonViewController.stateForTesting == .loaded }
        XCTAssertTrue(live.canRefreshAfterSuccessfulApply)
        live.refreshAfterSuccessfulApplyIfSafe()
        waitUntil { liveLoader.count == 2 }
        XCTAssertEqual(liveRefreshCalls, 1)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let review = try ComparisonReview(
            id: MarginID.annotation(),
            created: timestamp,
            modified: timestamp,
            snapshots: pair
        )
        let reviewURL = directory.appendingPathComponent("portable.marginreview")
        _ = try ComparisonReviewStore().create(review, at: reviewURL)
        let portableLoader = CountingComparisonLoader(base: CoreComparisonLoader())
        let portable = ComparisonWindowController(
            request: .review(reviewURL),
            loader: portableLoader
        )
        defer { portable.close() }
        portable.showWindow(nil)
        waitUntil { portable.comparisonViewController.stateForTesting == .loaded }
        XCTAssertFalse(
            portable.canRefreshAfterSuccessfulApply,
            "Portable review hints must never become inferred write/read authority"
        )
        portable.refreshAfterSuccessfulApplyIfSafe()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(portableLoader.count, 1)

        let oneShot = ComparisonWindowController(request: .snapshots(pair))
        defer { oneShot.close() }
        oneShot.showWindow(nil)
        waitUntil { oneShot.comparisonViewController.stateForTesting == .loaded }
        XCTAssertFalse(oneShot.canRefreshAfterSuccessfulApply)
    }

    func testReviewMutationRetriesOneConcurrentRevisionWithoutLosingExternalChange() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("concurrent.marginreview")
        let pair = try makePair(left: "alpha\n", right: "beta\n")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let review = try ComparisonReview(
            id: MarginID.annotation(),
            created: timestamp,
            modified: timestamp,
            snapshots: pair
        )
        let store = ComparisonReviewStore()
        _ = try store.create(review, at: reviewURL)

        let controller = ComparisonWindowController(request: .review(reviewURL))
        defer { controller.close() }
        controller.showWindow(nil)
        waitUntil { controller.currentReviewForTesting?.revision == 0 }

        _ = try store.update(
            at: reviewURL,
            expectedRevision: 0,
            modified: ISO8601DateFormatter().string(from: Date())
        ) { value in
            value.display.layout = .sideBySide
        }
        let selection = ComparisonSelectionRequest(
            side: .right,
            pairID: pair.id,
            snapshotSHA256: pair.right.sha256,
            blockID: nil,
            unicodeScalarRange: UnicodeScalarRange(start: 0, end: 4),
            quote: "beta"
        )
        controller.submitCommentForTesting(
            target: .selection(selection),
            body: "Concurrent review note"
        )
        waitUntil { controller.currentReviewForTesting?.revision == 2 }

        let persisted = try store.load(at: reviewURL)
        XCTAssertEqual(persisted.display.layout, .sideBySide)
        XCTAssertEqual(persisted.threads.count, 1)
        XCTAssertEqual(persisted.revision, 2)
    }

    func testOpenEditorApplyFailsClosedOnAnnotationRevisionOverflow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinationURL = directory.appendingPathComponent("overflow.md")
        try "alpha beta\n".write(to: destinationURL, atomically: true, encoding: .utf8)

        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.close() }
        editor.presentDocument(at: destinationURL)
        waitUntil { editor.comparisonSource()?.markdown == "alpha beta\n" }
        let target = try AnchorResolver().target(
            for: .quote(exact: "beta"),
            documentID: "urn:margin:test:overflow",
            in: "alpha beta\n"
        )
        let annotation = MarginComment(
            id: "urn:margin:test:overflow-comment",
            motivation: "suggesting",
            creator: MarginActor(id: "urn:agent:test", type: .software, name: "Test Agent"),
            created: ISO8601DateFormatter().string(from: Date()),
            modified: ISO8601DateFormatter().string(from: Date()),
            body: MarginCommentBody(value: "Keep this anchored."),
            target: target
        )
        editor.installComparisonAnnotationsForTesting([annotation], revision: .max)
        let pair = try makePair(left: "intro alpha beta\n", right: "alpha beta\n")
        let result = try ComparisonEngine().compare(pair)
        let plan = try ComparisonApplyService().plan(
            pair: pair,
            result: result,
            direction: .leftToRight
        )

        XCTAssertThrowsError(try editor.applyComparisonPlan(plan))
        XCTAssertEqual(editor.comparisonSource()?.markdown, "alpha beta\n")
        XCTAssertEqual(editor.comparisonAnnotationRevisionForTesting, .max)
        XCTAssertEqual(editor.comparisonAnnotationsForTesting, [annotation])
    }

    private func makePair(left: String, right: String) throws -> ComparisonSnapshotPair {
        try ComparisonSnapshotPair(
            left: ComparisonSnapshot(markdownBody: left, label: "Before", pathHint: "before.md"),
            right: ComparisonSnapshot(markdownBody: right, label: "After", pathHint: "after.md")
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-comparison-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func menuItem(
        named title: String,
        in menu: NSMenu? = NSApplication.shared.mainMenu
    ) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title == title { return item }
            if let nested = menuItem(named: title, in: item.submenu) { return nested }
        }
        return nil
    }

    private func allMenuItems(in menu: NSMenu? = NSApplication.shared.mainMenu) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items + menu.items.flatMap { allMenuItems(in: $0.submenu) }
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func accessibilityLabels(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = view.accessibilityLabel().map { [$0] } ?? []
        return own + view.subviews.flatMap(accessibilityLabels(in:))
    }

    private func descendantText(in view: NSView?) -> String {
        guard let view else { return "" }
        let own: String
        if let field = view as? NSTextField {
            own = field.stringValue
        } else if let text = view as? NSTextView {
            own = text.string
        } else {
            own = ""
        }
        return ([own] + view.subviews.map { descendantText(in: $0) })
            .joined(separator: " ")
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) {
        let expectation = expectation(description: "Condition became true")
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() {
                expectation.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
            }
        }
        poll()
        wait(for: [expectation], timeout: timeout + 0.25)
    }
}

private final class CountingComparisonLoader: ComparisonLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private let base: any ComparisonLoading

    init(base: any ComparisonLoading) { self.base = base }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func load(
        _ request: AppComparisonRequest,
        cancellation: ComparisonCancellationToken
    ) throws -> ComparisonPresentation {
        lock.lock()
        _count += 1
        lock.unlock()
        return try base.load(request, cancellation: cancellation)
    }
}

private final class CountingComparisonSourceEditor: NSViewController,
    WorkspaceDocumentPresenting,
    WorkspaceComparisonSourceProviding
{
    private var documentURL: URL?
    private(set) var sourceReadCount = 0

    func presentDocument(at url: URL) {
        documentURL = url.standardizedFileURL
    }

    func clearDocument() {
        documentURL = nil
    }

    var comparisonSourceMetadata: WorkspaceComparisonSourceMetadata? {
        guard let documentURL else { return nil }
        return WorkspaceComparisonSourceMetadata(
            label: documentURL.lastPathComponent,
            sourceURL: documentURL
        )
    }

    func comparisonSource() -> WorkspaceComparisonSource? {
        sourceReadCount += 1
        guard let metadata = comparisonSourceMetadata,
              let sourceURL = metadata.sourceURL,
              let markdown = try? String(contentsOf: sourceURL, encoding: .utf8) else { return nil }
        return WorkspaceComparisonSource(
            markdown: markdown,
            label: metadata.label,
            sourceURL: sourceURL
        )
    }
}
