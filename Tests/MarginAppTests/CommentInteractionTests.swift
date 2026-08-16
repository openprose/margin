import AppKit
import XCTest
@testable import MarginApp

final class CommentInteractionTests: XCTestCase {
    func testContextMenuOffersCommentOnlyForNonemptySelectionAndPreservesIt() {
        let textView = CommentInteractionTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        textView.string = "A selected passage"
        textView.setSelectedRange(NSRange(location: 2, length: 8))

        var received: NSRange?
        textView.onCommentOnSelection = { received = $0 }
        let menu = textView.menuByAddingCommentAction(to: NSMenu())
        XCTAssertEqual(
            menu?.items.first(where: { $0.identifier == CommentInteractionTextView.commentMenuIdentifier })?.title,
            "Comment on Selection"
        )

        // A contextual action must retain the range that opened its menu even
        // if AppKit subsequently moves the insertion point.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.performCommentOnSelection())
        XCTAssertEqual(received, NSRange(location: 2, length: 8))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 8))

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(textView.menuByAddingCommentAction(to: nil))
    }

    func testHighlightActivationUsesTheNativeTextViewClickSeam() {
        let textView = CommentInteractionTextView(frame: .zero)
        var location: Int?
        textView.onCommentHighlightClick = {
            location = $0
            return true
        }

        XCTAssertTrue(textView.activateCommentHighlight(at: 12))
        XCTAssertEqual(location, 12)
    }

    func testSelectionBubbleIsLazyAccessibleAndStaysInTheOuterMargin() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        let textView = NSTextView(frame: host.bounds)
        textView.textContainerInset = NSSize(width: 48, height: 32)
        textView.string = "A quiet selection near the text measure."
        host.addSubview(textView)

        var invoked = false
        let affordance = SelectionCommentAffordance(hostView: host) { invoked = true }
        XCTAssertNil(affordance.buttonForTesting)

        textView.setSelectedRange(NSRange(location: 2, length: 15))
        affordance.showImmediatelyForTesting(in: textView)
        guard let button = affordance.buttonForTesting else {
            return XCTFail("Expected the selection action to be created on demand")
        }
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.accessibilityLabel(), "Comment on selection")
        XCTAssertLessThanOrEqual(button.frame.maxX, host.bounds.maxX)
        XCTAssertGreaterThan(button.frame.minX, host.bounds.midX)

        button.performClick(nil)
        XCTAssertTrue(invoked)
        XCTAssertFalse(affordance.isVisible)

        let caretOnly = SelectionCommentAffordance(hostView: host) {}
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        caretOnly.selectionDidChange(in: textView)
        XCTAssertNil(caretOnly.buttonForTesting)
    }

    func testReaderMarkerLayoutCountsOverlapsAndExposesAccessibleThreads() {
        let candidates = [
            ReaderCommentMarkerCandidate(
                id: "first",
                summary: "Open comment by Ada: First",
                minY: 20,
                maxY: 40,
                isActive: true,
                isResolved: false
            ),
            ReaderCommentMarkerCandidate(
                id: "second",
                summary: "Open comment by Lin: Second",
                minY: 38,
                maxY: 55,
                isActive: false,
                isResolved: false
            ),
            ReaderCommentMarkerCandidate(
                id: "third",
                summary: "Resolved comment by Jo: Third",
                minY: 90,
                maxY: 104,
                isActive: false,
                isResolved: true
            ),
        ]
        let groups = ReaderCommentMarkerLayout.groups(from: candidates, x: 700)
        XCTAssertEqual(groups.map(\.ids), [["first", "second"], ["third"]])
        XCTAssertEqual(groups[0].activeID, "first")
        XCTAssertTrue(groups[1].isResolvedOnly)

        let gutter = ReaderCommentGutterView(frame: NSRect(x: 0, y: 0, width: 760, height: 180))
        var selected: String?
        gutter.onSelectComment = { selected = $0 }
        gutter.update(groups: groups)
        XCTAssertEqual(gutter.markerButtons.count, 2)
        XCTAssertEqual(
            gutter.markerButtons[0].accessibilityLabel(),
            "2 overlapping comment threads"
        )
        gutter.markerButtons[0].performClick(nil)
        XCTAssertEqual(selected, "second", "The active overlap advances to its neighboring thread")
    }

    func testReaderHighlightClickUsesSourceMappingWithoutChangingMeasure() {
        let reader = ReaderViewController()
        reader.maximumTextWidth = 620
        _ = reader.view
        let markdown = "# Title\n\nA **mapped passage** for review.\n"
        _ = reader.render(markdown: markdown, baseURL: nil)
        let sourceRange = (markdown as NSString).range(of: "mapped passage")
        reader.setCommentHighlights([
            .init(id: "thread", sourceRange: sourceRange, summary: "Open comment")
        ])

        var selected: String?
        reader.onSelectComment = { selected = $0 }
        guard let renderedRange = reader.readerRange(forSourceRange: sourceRange) else {
            return XCTFail("Expected a source-to-reader mapping")
        }
        XCTAssertTrue(reader.activateCommentHighlight(atReaderLocation: renderedRange.location))
        XCTAssertEqual(selected, "thread")
        XCTAssertEqual(reader.maximumTextWidth, 620)
    }
}
