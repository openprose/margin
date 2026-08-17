import AppKit
import XCTest
@testable import MarginApp
import MarginCore

final class EditorReviewIntegrationTests: XCTestCase {
    private let actor = MarginActor(
        id: "urn:agent:margin-app-tests",
        type: .software,
        name: "Margin App Tests"
    )

    func testReviewActionsFollowSourceOrderWrapAndAdvanceAfterResolve() throws {
        let fixture = try makeDocument("# Review\n\nfirst passage, then last passage.\n")
        let service = CommentService()
        let last = try service.add(
            at: fixture.file,
            message: "Last note",
            creator: actor,
            anchor: .quote(exact: "last passage")
        ).rootID
        let first = try service.add(
            at: fixture.file,
            message: "First note",
            creator: actor,
            anchor: .quote(exact: "first passage")
        ).rootID

        let editor = EditorViewController()
        let inspector = CommentsViewController()
        editor.connectComments(inspector)
        defer {
            editor.clearDocument()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        editor.presentDocument(at: fixture.file)
        waitUntil { editor.rootCommentIDsInSourceOrder.count == 2 }

        XCTAssertEqual(editor.rootCommentIDsInSourceOrder, [first, last])
        XCTAssertEqual(editor.openRootCommentIDsInSourceOrder, [first, last])
        let destinations = editor.commentDestinations()
        XCTAssertEqual(destinations.map(\.id), [first, last])
        XCTAssertEqual(destinations.first?.author, actor.name)
        XCTAssertEqual(destinations.first?.line, 3)
        XCTAssertEqual(destinations.first?.status, .open)
        XCTAssertEqual(destinations.first?.needsAttention, false)
        XCTAssertTrue(destinations.first?.title.contains("first passage") == true)
        XCTAssertTrue(editor.responds(to: NSSelectorFromString("selectPreviousOpenComment:")))
        XCTAssertTrue(editor.responds(to: NSSelectorFromString("selectNextOpenComment:")))
        XCTAssertTrue(editor.responds(to: NSSelectorFromString("resolveSelectedComment:")))

        editor.selectNextOpenComment(nil)
        XCTAssertEqual(editor.selectedCommentThreadID, first)
        editor.selectNextOpenComment(nil)
        XCTAssertEqual(editor.selectedCommentThreadID, last)
        editor.selectNextOpenComment(nil)
        XCTAssertEqual(editor.selectedCommentThreadID, first)
        editor.selectPreviousOpenComment(nil)
        XCTAssertEqual(editor.selectedCommentThreadID, last)
        editor.selectNextOpenComment(nil)
        XCTAssertEqual(editor.selectedCommentThreadID, first)
        var markedRead = Set<String>()
        inspector.onMarkCommentsRead = { markedRead.formUnion($0) }
        inspector.setUnreadCommentIDs([last])
        editor.revealComment(id: last)
        XCTAssertEqual(editor.selectedCommentThreadID, last)
        XCTAssertEqual(markedRead, [last])
        editor.selectNextOpenComment(nil)
        XCTAssertEqual(editor.selectedCommentThreadID, first)

        editor.resolveSelectedComment(nil)
        XCTAssertEqual(editor.openRootCommentIDsInSourceOrder, [last])
        XCTAssertEqual(editor.selectedCommentThreadID, last)
        XCTAssertEqual(try service.get(first, at: fixture.file).annotation.status, .resolved)
    }

    func testCommentsChangeDistinguishesInitialLoadFromExternalMetadata() throws {
        let fixture = try makeDocument("# Review\n\nalpha beta gamma\n")
        let service = CommentService()
        let alpha = try service.add(
            at: fixture.file,
            message: "Alpha",
            creator: actor,
            anchor: .quote(exact: "alpha")
        ).rootID
        let editor = EditorViewController()
        defer {
            editor.clearDocument()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        var changes: [EditorViewController.CommentsChange] = []
        editor.onCommentsChanged = { changes.append($0) }
        editor.presentDocument(at: fixture.file)
        waitUntil { changes.contains(where: { $0.origin == .initialLoad }) }

        let initial = try XCTUnwrap(changes.first(where: { $0.origin == .initialLoad }))
        XCTAssertEqual(initial.openRootCommentIDs, [alpha])
        XCTAssertEqual(initial.openCount, 1)
        XCTAssertTrue(initial.newOpenRootIDs.isEmpty)
        XCTAssertTrue(initial.newAnnotationIDs.isEmpty)
        XCTAssertTrue(initial.externallyChangedRootIDs.isEmpty)

        let beta = try service.add(
            at: fixture.file,
            message: "Beta",
            creator: actor,
            anchor: .quote(exact: "beta")
        ).rootID
        editor.refreshCommentsFromDisk()

        let external = try XCTUnwrap(changes.last(where: { $0.origin == .externalRefresh }))
        XCTAssertEqual(external.rootCommentIDs, [alpha, beta])
        XCTAssertEqual(external.openCount, 2)
        XCTAssertEqual(external.newOpenRootIDs, [beta])
        XCTAssertEqual(external.newAnnotationIDs, [beta])
        XCTAssertEqual(external.externallyChangedRootIDs, [beta])

        let reply = try service.reply(
            at: fixture.file,
            parentID: alpha,
            message: "External reply",
            creator: actor
        ).annotation.id
        editor.refreshCommentsFromDisk()

        let replyChange = try XCTUnwrap(changes.last(where: {
            $0.origin == .externalRefresh && $0.newAnnotationIDs.contains(reply)
        }))
        XCTAssertTrue(replyChange.newOpenRootIDs.isEmpty)
        XCTAssertEqual(replyChange.newAnnotationIDs, [reply])
        XCTAssertEqual(replyChange.externallyChangedRootIDs, [alpha])
    }

    func testContinuityRequestedDuringAsyncReaderLoadRestoresSourceSelectionAndThread() throws {
        let source = "# Reader\n\nA mapped passage remains selected.\n"
        let fixture = try makeDocument(source)
        let threadID = try CommentService().add(
            at: fixture.file,
            message: "Reader note",
            creator: actor,
            anchor: .quote(exact: "mapped passage")
        ).rootID
        let selection = (source as NSString).range(of: "mapped passage")
        let editor = EditorViewController()
        defer {
            editor.clearDocument()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        editor.presentDocument(at: fixture.file)
        editor.toggleReaderMode()
        editor.restoreContinuityState(
            EditorContinuityState(
                selectionLocation: selection.location,
                selectionLength: selection.length,
                scrollFraction: 0,
                selectedThreadID: threadID
            )
        )

        waitUntil(timeout: 4) {
            let captured = editor.captureContinuityState()
            return captured.selectionLocation == selection.location
                && captured.selectionLength == selection.length
                && captured.selectedThreadID == threadID
        }
        let captured = editor.captureContinuityState()
        XCTAssertEqual(captured.selectionLocation, selection.location)
        XCTAssertEqual(captured.selectionLength, selection.length)
        XCTAssertEqual(captured.selectedThreadID, threadID)
        XCTAssertTrue(editor.isReaderModeActive)
    }

    func testInspectorEditDeleteAndUndoRoundTripWithoutChangingMarkdown() throws {
        let source = "# Lifecycle\n\nA stable passage.\n"
        let fixture = try makeDocument(source)
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "Original note",
            creator: actor,
            anchor: .quote(exact: "stable passage")
        ).rootID
        let reply = try service.reply(
            at: fixture.file,
            parentID: root,
            message: "Nested reply",
            creator: actor
        ).annotation.id
        let editor = EditorViewController()
        let inspector = CommentsViewController()
        editor.connectComments(inspector)
        defer {
            editor.clearDocument()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        editor.presentDocument(at: fixture.file)
        waitUntil { editor.rootCommentIDsInSourceOrder == [root] }

        let displayedRevision = try XCTUnwrap(
            EmbeddedCommentCodec().decode(Data(contentsOf: fixture.file)).envelope
        ).revision
        inspector.onEditComment?(reply, "Revised reply", displayedRevision)
        XCTAssertEqual(try service.get(reply, at: fixture.file).annotation.body.value, "Revised reply")
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: fixture.file)).body, source)

        editor.refreshCommentsFromDisk()
        try XCTUnwrap(button(titled: "Undo", in: editor.view)).performClick(nil)
        XCTAssertEqual(try service.get(reply, at: fixture.file).annotation.body.value, "Nested reply")

        inspector.onDeleteComment?(root, true)
        XCTAssertThrowsError(try service.get(root, at: fixture.file))
        XCTAssertThrowsError(try service.get(reply, at: fixture.file))
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: fixture.file)).body, source)

        editor.refreshCommentsFromDisk()
        try XCTUnwrap(button(titled: "Undo", in: editor.view)).performClick(nil)
        XCTAssertEqual(try service.get(root, at: fixture.file).annotation.body.value, "Original note")
        XCTAssertEqual(try service.get(reply, at: fixture.file).annotation.body.value, "Nested reply")
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: fixture.file)).body, source)
    }

    func testInspectorRejectsStaleEditAndThreadDeleteAfterAgentChanges() throws {
        let source = "# Collaboration\n\nA shared passage.\n"
        let fixture = try makeDocument(source)
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "Human draft",
            creator: localActor,
            anchor: .quote(exact: "shared passage")
        ).rootID
        let editor = EditorViewController()
        let inspector = CommentsViewController()
        editor.connectComments(inspector)
        defer {
            editor.clearDocument()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        editor.presentDocument(at: fixture.file)
        waitUntil { editor.rootCommentIDsInSourceOrder == [root] }

        editor.revealComment(id: root)
        let editButton = try XCTUnwrap(button(titled: "Edit", in: inspector.view))
        editButton.performClick(nil)
        let composer = try XCTUnwrap(descendantTextView(in: inspector.view))
        composer.string = "Stale human revision"
        composer.didChangeText()

        _ = try service.edit(
            at: fixture.file,
            id: root,
            message: "Agent revision",
            editor: actor
        )
        editor.refreshCommentsFromDisk()
        try XCTUnwrap(button(titled: "Save", in: inspector.view)).performClick(nil)
        XCTAssertEqual(try service.get(root, at: fixture.file).annotation.body.value, "Agent revision")
        XCTAssertTrue(descendantText(in: editor.view).contains { $0.contains("Expected comment revision") })

        let reply = try service.reply(
            at: fixture.file,
            parentID: root,
            message: "Unseen agent reply",
            creator: actor
        ).annotation.id
        inspector.onDeleteComment?(root, true)
        XCTAssertEqual(try service.get(root, at: fixture.file).annotation.body.value, "Agent revision")
        XCTAssertEqual(try service.get(reply, at: fixture.file).annotation.body.value, "Unseen agent reply")
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: fixture.file)).body, source)
        XCTAssertTrue(descendantText(in: editor.view).contains { $0.contains("Could not delete comment") })
    }

    func testSelectingOneOfOverlappingThreadsDoesNotSnapToItsNeighbor() throws {
        let fixture = try makeDocument("# Overlap\n\nA shared passage.\n")
        let service = CommentService()
        _ = try service.add(
            at: fixture.file,
            message: "First",
            creator: actor,
            anchor: .quote(exact: "shared passage")
        )
        let second = try service.add(
            at: fixture.file,
            message: "Second",
            creator: actor,
            anchor: .quote(exact: "shared passage")
        ).rootID
        let editor = EditorViewController()
        defer {
            editor.clearDocument()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        editor.presentDocument(at: fixture.file)
        waitUntil { editor.rootCommentIDsInSourceOrder.count == 2 }

        editor.revealComment(id: second)
        XCTAssertEqual(editor.selectedCommentThreadID, second)
    }

    func testInspectorAcceptsAndRejectsTypedSuggestionsThroughAtomicTransactions() throws {
        let accepted = try makeSuggestedDocument(
            source: "# Copy\n\nUse the teh precise term.\n",
            expected: "teh",
            replacement: "most"
        )
        let rejected = try makeSuggestedDocument(
            source: "# Copy\n\nKeep this phrase.\n",
            expected: "this",
            replacement: "that"
        )
        defer {
            try? FileManager.default.removeItem(at: accepted.fixture.directory)
            try? FileManager.default.removeItem(at: rejected.fixture.directory)
        }

        let acceptingEditor = EditorViewController()
        let acceptingInspector = CommentsViewController()
        acceptingEditor.connectComments(acceptingInspector)
        acceptingEditor.presentDocument(at: accepted.fixture.file)
        waitUntil { acceptingEditor.rootCommentIDsInSourceOrder == [accepted.id] }
        acceptingEditor.revealComment(id: accepted.id)
        try XCTUnwrap(button(titled: "Accept", in: acceptingInspector.view)).performClick(nil)
        waitUntil(timeout: 4) {
            (try? EmbeddedCommentCodec().decode(Data(contentsOf: accepted.fixture.file)).body)
                == "# Copy\n\nUse the most precise term.\n"
        }
        let acceptedComment = try CommentService().get(accepted.id, at: accepted.fixture.file).annotation
        XCTAssertEqual(acceptedComment.reviewSuggestion?.status, .accepted)
        acceptingEditor.clearDocument()

        let rejectingEditor = EditorViewController()
        let rejectingInspector = CommentsViewController()
        rejectingEditor.connectComments(rejectingInspector)
        rejectingEditor.presentDocument(at: rejected.fixture.file)
        waitUntil { rejectingEditor.rootCommentIDsInSourceOrder == [rejected.id] }
        rejectingEditor.revealComment(id: rejected.id)
        try XCTUnwrap(button(titled: "Reject", in: rejectingInspector.view)).performClick(nil)
        waitUntil(timeout: 4) {
            (try? CommentService().get(rejected.id, at: rejected.fixture.file).annotation
                .reviewSuggestion?.status) == .rejected
        }
        XCTAssertEqual(
            try EmbeddedCommentCodec().decode(Data(contentsOf: rejected.fixture.file)).body,
            "# Copy\n\nKeep this phrase.\n"
        )
        rejectingEditor.clearDocument()
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
        wait(for: [expectation], timeout: timeout + 0.25)
    }

    private func button(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(titled: title, in: $0) }.first
    }

    private func descendantText(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(descendantText(in:))
    }

    private func descendantTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap(descendantTextView(in:)).first
    }

    private var localActor: MarginActor {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? NSUserName() : name
        let slug = displayName.lowercased().replacingOccurrences(of: " ", with: "-")
        return MarginActor(id: "urn:margin:person:\(slug)", type: .person, name: displayName)
    }

    private func makeDocument(_ source: String) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-review-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("note.md")
        try Data(source.utf8).write(to: file)
        return (directory, file)
    }

    private func makeSuggestedDocument(
        source: String,
        expected: String,
        replacement: String
    ) throws -> (fixture: (directory: URL, file: URL), id: String) {
        let fixture = try makeDocument(source)
        let root = try CollaborationRootResolver().document(at: fixture.file)
        let cursor = try CollaborationCursorService().capture(root: root, paths: ["."])
        let target = try AnchorResolver().target(
            for: .quote(exact: expected),
            documentID: "urn:margin:temporary",
            in: source
        )
        guard case .selection(let selection) = target,
              let range = selection.positionSelector else {
            throw CommentProtocolError.invalidAnchor("Expected a suggestion range.")
        }
        let collaborationActor = try CollaborationActor(actor)
        let contribution = try CollaborationContributionFactory.suggestion(
            actor: collaborationActor,
            path: ".",
            range: UnicodeScalarRange(start: range.start, end: range.end),
            message: "Replace the imprecise wording.",
            expectedText: expected,
            replacementText: replacement,
            baseCursor: cursor
        )
        let request = "urn:uuid:\(UUID().uuidString.lowercased())"
        let changeSet = try CollaborationChangeSet(
            root: root,
            baseCursor: cursor,
            actor: collaborationActor,
            requestID: request,
            stageID: "urn:margin:stage:\(request)",
            created: CollaborationTimestamp.string(),
            operations: [
                .contribution(
                    id: "urn:margin:operation:\(request)",
                    CollaborationContributionOperation(contribution: contribution)
                )
            ]
        )
        let mutations = try CollaborationChangeSetEvaluator().evaluate(changeSet)
        _ = try CollaborationTransactionEngine().submit(changeSet, evaluatedMutations: mutations)
        return (fixture, contribution.id)
    }
}
