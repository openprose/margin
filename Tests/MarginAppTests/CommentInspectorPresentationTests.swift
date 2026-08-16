import AppKit
import MarginCore
import XCTest
@testable import MarginApp

final class CommentInspectorPresentationTests: XCTestCase {
    func testIndexFlattensReplyTreeAndCapsVisibleIndentationAtTwoLevels() throws {
        let root = makeRoot(id: "root", author: "Root")
        let first = makeReply(id: "one", parentID: root.id, author: "One", createdOffset: 1)
        let second = makeReply(id: "two", parentID: first.id, author: "Two", createdOffset: 2)
        let third = makeReply(id: "three", parentID: second.id, author: "Three", createdOffset: 3)

        let thread = try XCTUnwrap(
            CommentInspectorIndex(comments: [third, root, second, first]).threadsByRootID[root.id]
        )

        XCTAssertEqual(thread.replies.map(\.comment.id), ["one", "two", "three"])
        XCTAssertEqual(thread.replies.map(\.depth), [1, 2, 3])
        XCTAssertEqual(thread.replies.map(\.visualDepth), [1, 2, 2])
        XCTAssertEqual(thread.replies.map(\.hasReplies), [true, true, false])
        XCTAssertFalse(thread.replies[1].needsLineageLabel)
        XCTAssertTrue(thread.replies[2].needsLineageLabel)
        XCTAssertEqual(thread.replies[2].parentAuthor, "Two")
    }

    func testLongThreadVisibilityPreservesSelectedAndUnreadContext() throws {
        let root = makeRoot(id: "root")
        let replies = (0..<10).map {
            makeReply(
                id: "reply-\($0)",
                parentID: root.id,
                author: "Reviewer \($0)",
                createdOffset: $0 + 1
            )
        }
        let thread = try XCTUnwrap(
            CommentInspectorIndex(comments: [root] + replies).threadsByRootID[root.id]
        )

        let visibility = thread.visibility(
            isActive: true,
            isExpanded: false,
            selectedCommentID: "reply-4",
            unreadCommentIDs: ["reply-7"]
        )

        XCTAssertTrue(visibility.visibleIndices.starts(with: [0, 1]))
        XCTAssertTrue(visibility.visibleIndices.suffix(2).elementsEqual([8, 9]))
        XCTAssertTrue(visibility.visibleIndices.contains(4))
        XCTAssertTrue(visibility.visibleIndices.contains(7))
        XCTAssertGreaterThan(visibility.hiddenCount, 0)
        XCTAssertEqual(
            Set(visibility.visibleIndices).count + visibility.hiddenCount,
            replies.count
        )
    }

    func testResolvedThreadStartsWithRepliesCollapsed() throws {
        let root = makeRoot(id: "root", status: .resolved)
        let reply = makeReply(id: "reply", parentID: root.id, createdOffset: 1)
        let thread = try XCTUnwrap(
            CommentInspectorIndex(comments: [root, reply]).threadsByRootID[root.id]
        )

        let collapsed = thread.visibility(
            isActive: true,
            isExpanded: false,
            selectedCommentID: root.id
        )
        XCTAssertEqual(collapsed.visibleIndices, [])
        XCTAssertEqual(collapsed.hiddenRanges, [0..<1])

        let expanded = thread.visibility(
            isActive: true,
            isExpanded: true,
            selectedCommentID: root.id
        )
        XCTAssertEqual(expanded.visibleIndices, [0])
        XCTAssertTrue(expanded.canCollapse)
    }

    func testNativeCommentMarkdownRendererRemovesSyntaxAndPreservesSemantics() throws {
        let rendered = CommentMarkdownRenderer.render(
            "# Note\n\nA **bold** word, `code`, and [link](https://example.com)."
        )
        let text = rendered.string as NSString

        XCTAssertFalse(rendered.string.contains("# "))
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertFalse(rendered.string.contains("`"))
        XCTAssertTrue(rendered.string.contains("bold"))
        XCTAssertTrue(rendered.string.contains("code"))

        let boldRange = text.range(of: "bold")
        let boldFont = try XCTUnwrap(rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        let linkRange = text.range(of: "link")
        XCTAssertNotNil(rendered.attribute(.link, at: linkRange.location, effectiveRange: nil))
    }

    func testInspectorOrdersRootsReportsProgressAndOnlyActiveThreadShowsActions() {
        let source = "alpha beta gamma"
        let alpha = makeRoot(
            id: "alpha",
            body: "Alpha note",
            createdOffset: 3,
            target: selectionTarget(exact: "alpha", start: 0)
        )
        let beta = makeRoot(
            id: "beta",
            body: "Beta note",
            createdOffset: 2,
            target: selectionTarget(exact: "beta", start: 6)
        )
        let gamma = makeRoot(
            id: "gamma",
            body: "Gamma note",
            createdOffset: 1,
            target: selectionTarget(exact: "gamma", start: 11)
        )
        let controller = CommentsViewController()
        _ = controller.view

        controller.display(comments: [gamma, beta, alpha], source: source)
        XCTAssertEqual(controller.orderedVisibleRootIDs, ["alpha", "beta", "gamma"])
        XCTAssertEqual(controller.reviewProgressDescription, "3 open")
        XCTAssertFalse(buttonTitles(in: controller.view).contains("Reply"))
        XCTAssertFalse(buttonTitles(in: controller.view).contains("Resolve"))

        controller.selectComment(beta.id)
        XCTAssertEqual(controller.reviewProgressDescription, "2 of 3 open")
        XCTAssertEqual(buttonTitles(in: controller.view).filter { $0 == "Reply" }.count, 1)
        XCTAssertEqual(buttonTitles(in: controller.view).filter { $0 == "Resolve" }.count, 1)
    }

    func testNewFilterIsSuppliedByOwnerAndReadClearingIsReported() {
        let root = makeRoot(id: "root")
        let reply = makeReply(id: "reply", parentID: root.id, createdOffset: 1)
        let controller = CommentsViewController()
        _ = controller.view
        controller.display(comments: [root, reply], source: "")

        var cleared = Set<String>()
        controller.onMarkCommentsRead = { cleared.formUnion($0) }
        controller.setUnreadCommentIDs([reply.id])
        XCTAssertEqual(controller.availableFilters, [.new, .open, .resolved, .all])

        controller.setPresentationFilter(.new)
        XCTAssertEqual(controller.orderedVisibleRootIDs, [root.id])
        XCTAssertEqual(controller.reviewProgressDescription, "1 new")

        controller.selectComment(reply.id, markingRead: true)
        XCTAssertEqual(cleared, [reply.id])
        XCTAssertEqual(controller.availableFilters, [.open, .resolved, .all])
        XCTAssertEqual(controller.presentationFilter, .open)
        XCTAssertEqual(controller.selectedRootCommentID, root.id)
    }

    func testQuoteAppearsOnceAndResolvedConversationExpandsAccessibly() throws {
        let root = makeRoot(
            id: "root",
            body: "Root body",
            status: .resolved,
            target: selectionTarget(exact: "quoted passage", start: 0)
        )
        let reply = makeReply(
            id: "reply",
            parentID: root.id,
            body: "Reply body",
            createdOffset: 1
        )
        let controller = CommentsViewController()
        _ = controller.view
        controller.display(
            comments: [root, reply],
            source: "quoted passage",
            selectedCommentID: root.id
        )

        XCTAssertEqual(controller.presentationFilter, .resolved)
        XCTAssertEqual(descendantText(in: controller.view).filter { $0 == "quoted passage" }.count, 1)
        XCTAssertFalse(descendantText(in: controller.view).contains("Reply body"))
        let disclosure = try XCTUnwrap(buttons(in: controller.view).first { $0.title == "Show reply" })
        XCTAssertEqual(disclosure.accessibilityLabel(), "Show reply")

        disclosure.performClick(nil)
        XCTAssertTrue(descendantText(in: controller.view).contains("Reply body"))
        XCTAssertTrue(buttonTitles(in: controller.view).contains("Show fewer"))
    }

    func testNextAndPreviousReviewNavigationUseVisibleRootOrder() {
        let roots = (0..<3).map { makeRoot(id: "root-\($0)", createdOffset: $0) }
        let controller = CommentsViewController()
        _ = controller.view
        controller.display(comments: roots, source: "")

        var selections: [String] = []
        controller.onSelectComment = { selections.append($0) }
        controller.selectNextComment()
        controller.selectNextComment()
        controller.selectPreviousComment()

        XCTAssertEqual(selections, ["root-0", "root-1", "root-0"])
        XCTAssertEqual(controller.selectedRootCommentID, "root-0")
    }

    func testExplicitThreadActivationMarksOnlyThatThreadRead() throws {
        let first = makeRoot(id: "first", createdOffset: 0)
        let second = makeRoot(id: "second", createdOffset: 1)
        let controller = CommentsViewController()
        _ = controller.view
        controller.display(comments: [first, second], source: "")
        controller.setUnreadCommentIDs([first.id, second.id])
        controller.setPresentationFilter(.new)

        var cleared = Set<String>()
        var selected: String?
        controller.onMarkCommentsRead = { cleared.formUnion($0) }
        controller.onSelectComment = { selected = $0 }
        XCTAssertTrue(cleared.isEmpty, "Opening or filtering must not mark every thread read")

        let firstThread = try XCTUnwrap(
            descendants(in: controller.view, ofType: CommentThreadView.self)
                .first { $0.identifier?.rawValue == first.id }
        )
        XCTAssertTrue(firstThread.accessibilityPerformPress())

        XCTAssertEqual(cleared, [first.id])
        XCTAssertEqual(selected, first.id)
        XCTAssertEqual(controller.presentationFilter, .new)
        XCTAssertEqual(controller.orderedVisibleRootIDs, [second.id])
        XCTAssertEqual(controller.reviewProgressDescription, "1 new")
    }

    func testOwnerLifecycleActionsAreActiveOnlyAndReuseMarkdownComposer() throws {
        let localAuthor = "Local Writer"
        let root = makeRoot(id: "owned-root", author: localAuthor, body: "Original root")
        let reply = makeReply(
            id: "owned-reply",
            parentID: root.id,
            author: localAuthor,
            body: "Original reply",
            createdOffset: 1
        )
        let other = makeRoot(id: "other-root", author: "Collaborator", createdOffset: 2)
        let controller = CommentsViewController()
        _ = controller.view
        controller.setLocalActorID("urn:actor:\(localAuthor)")
        controller.display(
            comments: [root, reply, other],
            source: "",
            selectedCommentID: root.id,
            commentRevision: 17
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 620)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(buttonTitles(in: controller.view).filter { $0 == "Edit" }.count, 2)
        XCTAssertTrue(buttonTitles(in: controller.view).contains("Delete Thread"))
        XCTAssertTrue(buttonTitles(in: controller.view).contains("Delete Reply"))
        for title in ["Reply", "Resolve", "Edit", "Delete Thread", "Delete Reply"] {
            let matches = buttons(in: controller.view).filter { $0.title == title }
            XCTAssertFalse(matches.isEmpty, "Expected \(title) in the active owner thread")
            XCTAssertTrue(matches.allSatisfy { $0.frame.width >= 24 }, "\(title) must not collapse vertically")
        }

        var edited: (id: String, body: String, revision: Int)?
        controller.onEditComment = { edited = ($0, $1, $2) }
        let rootEdit = try XCTUnwrap(buttons(in: controller.view).first { $0.title == "Edit" })
        rootEdit.performClick(nil)
        controller.display(
            comments: [root, reply, other],
            source: "",
            selectedCommentID: root.id,
            commentRevision: 18
        )
        let composer = try XCTUnwrap(
            descendants(in: controller.view, ofType: NSTextView.self)
                .first { $0.accessibilityLabel() == "Comment text" }
        )
        XCTAssertEqual(composer.string, "Original root")
        composer.string = "Edited **Markdown**"
        composer.didChangeText()
        try XCTUnwrap(buttons(in: controller.view).first { $0.title == "Save" }).performClick(nil)
        XCTAssertEqual(edited?.id, root.id)
        XCTAssertEqual(edited?.body, "Edited **Markdown**")
        XCTAssertEqual(edited?.revision, 17, "An open edit composer must retain its original revision")

        var deletions: [(id: String, subtree: Bool)] = []
        controller.onDeleteComment = { deletions.append(($0, $1)) }
        try XCTUnwrap(buttons(in: controller.view).first { $0.title == "Delete Reply" }).performClick(nil)
        try XCTUnwrap(buttons(in: controller.view).first { $0.title == "Delete Thread" }).performClick(nil)
        XCTAssertEqual(deletions.map(\.id), [reply.id, root.id])
        XCTAssertEqual(deletions.map(\.subtree), [false, true])

        controller.selectComment(other.id)
        XCTAssertFalse(buttonTitles(in: controller.view).contains("Edit"))
        XCTAssertFalse(buttonTitles(in: controller.view).contains("Delete Thread"))
        XCTAssertFalse(buttonTitles(in: controller.view).contains("Delete Reply"))
    }

    private func makeRoot(
        id: String,
        author: String = "Reviewer",
        body: String = "Root body",
        createdOffset: Int = 0,
        status: MarginCommentStatus = .open,
        target: CommentTarget = .resource("urn:document:test")
    ) -> MarginComment {
        makeComment(
            id: id,
            motivation: "commenting",
            author: author,
            body: body,
            createdOffset: createdOffset,
            target: target,
            status: status
        )
    }

    private func makeReply(
        id: String,
        parentID: String,
        author: String = "Responder",
        body: String = "Reply body",
        createdOffset: Int
    ) -> MarginComment {
        makeComment(
            id: id,
            motivation: "replying",
            author: author,
            body: body,
            createdOffset: createdOffset,
            target: .resource(parentID),
            status: nil
        )
    }

    private func makeComment(
        id: String,
        motivation: String,
        author: String,
        body: String,
        createdOffset: Int,
        target: CommentTarget,
        status: MarginCommentStatus?
    ) -> MarginComment {
        let timestamp = String(format: "2026-08-16T03:%02d:00.000Z", createdOffset)
        let actor = MarginActor(id: "urn:actor:\(author)", type: .person, name: author)
        return MarginComment(
            id: id,
            motivation: motivation,
            creator: actor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: body),
            target: target,
            status: status,
            statusModified: timestamp,
            statusModifiedBy: actor
        )
    }

    private func selectionTarget(exact: String, start: Int) -> CommentTarget {
        .selection(CommentSelectionTarget(
            source: MarginSourceReference(id: "urn:document:test"),
            selector: [
                .position(TextPositionSelector(start: start, end: start + exact.unicodeScalars.count)),
                .quote(TextQuoteSelector(exact: exact)),
            ]
        ))
    }

    private func buttons(in view: NSView) -> [NSButton] {
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(buttons)
    }

    private func buttonTitles(in view: NSView) -> [String] {
        buttons(in: view).map(\.title)
    }

    private func descendantText(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(descendantText)
    }

    private func descendants<T: NSView>(in view: NSView, ofType type: T.Type) -> [T] {
        let own = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(in: $0, ofType: type) }
    }
}
