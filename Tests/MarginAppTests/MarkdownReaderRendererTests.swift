import XCTest
@testable import MarginApp

final class MarkdownReaderRendererTests: XCTestCase {
    func testBlankTableHeaderRendersAndPreservesColumns() {
        let markdown = """
        # Inventory

        | | |
        |---|---|
        | Alpha | Beta |
        """

        let result = MarkdownReaderRenderer().render(markdown)

        XCTAssertTrue(result.attributedString.string.contains("Alpha\tBeta"))
        XCTAssertLessThan(result.attributedString.length, markdown.utf16.count * 4)
    }

    func testBlankTableHeaderRenderCompletesWithinInteractiveBudget() {
        let row = "| A modest cell | Another modest cell |\n"
        let markdown = "| | |\n|---|---|\n" + String(repeating: row, count: 400)

        measure(metrics: [XCTClockMetric()]) {
            _ = MarkdownReaderRenderer().render(markdown)
        }
    }
}
