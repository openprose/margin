import XCTest
@testable import MarginCore

final class MarkdownOutlineTests: XCTestCase {
    func testOutlineIgnoresFencedHeadingsAndBuildsSections() {
        let markdown = """
        # Plan
        Intro

        ## Details
        Body

        ```md
        # Not a heading
        ```

        ## Details
        More

        End
        ===
        Tail
        """
        let outline = MarkdownOutline(markdown: markdown)
        XCTAssertEqual(outline.headings.map(\.title), ["Plan", "Details", "Details", "End"])
        XCTAssertEqual(outline.headings.map(\.id), ["plan", "details", "details-2", "end"])
        XCTAssertEqual(outline.headings[1].sectionEndLine, 10)
        XCTAssertEqual(outline.heading(matching: "details-2")?.line, 11)
    }

    func testInspectionAndHeadingSlice() throws {
        let markdown = "# One\nA\n## Two\nB\n# Three\nC"
        let outline = MarkdownOutline(markdown: markdown)
        let heading = try XCTUnwrap(outline.heading(matching: "Two"))
        let slice = try DocumentSlice(body: markdown, heading: heading)
        XCTAssertEqual(slice.text, "## Two\nB")
        XCTAssertEqual(DocumentInspection(path: "x.md", body: markdown).lines, 6)
    }
}
