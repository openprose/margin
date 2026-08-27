import AppKit
import XCTest
@testable import MarginApp

final class MarkdownReaderRendererTests: XCTestCase {
    func testBlankTableHeaderRendersAndPreservesNativeColumns() throws {
        let markdown = """
        # Inventory

        | | |
        |---|---|
        | Alpha | Beta |
        """

        let result = MarkdownReaderRenderer().render(markdown)
        let alpha = try tableBlock(containing: "Alpha", in: result.attributedString)
        let beta = try tableBlock(containing: "Beta", in: result.attributedString)

        XCTAssertEqual(alpha.startingRow, 1)
        XCTAssertEqual(alpha.startingColumn, 0)
        XCTAssertEqual(beta.startingRow, 1)
        XCTAssertEqual(beta.startingColumn, 1)
        XCTAssertTrue(alpha.table === beta.table)
        XCTAssertEqual(alpha.table.numberOfColumns, 2)
        XCTAssertFalse(result.attributedString.string.contains("\t"))
        XCTAssertLessThan(result.attributedString.length, markdown.utf16.count * 4)
    }

    func testTableUsesRowsRulesProportionalColumnsAndMarkdownAlignment() throws {
        let markdown = """
        | Layer | Owns | Must not own |
        |:---|:---:|---:|
        | Language | Contract structure, reference semantics, and observable failure rules | Harness command names and storage vendor |
        | Program | Domain goals and chosen topology | Host-specific workarounds |
        """

        let result = MarkdownReaderRenderer().render(markdown)
        let layer = try tableBlock(containing: "Layer", in: result.attributedString)
        let owns = try tableBlock(containing: "Owns", in: result.attributedString)
        let mustNotOwn = try tableBlock(containing: "Must not own", in: result.attributedString)
        let language = try tableBlock(containing: "Language", in: result.attributedString)
        let contract = try tableBlock(containing: "Contract structure", in: result.attributedString)
        let harness = try tableBlock(containing: "Harness command", in: result.attributedString)
        let program = try tableBlock(containing: "Program", in: result.attributedString)

        XCTAssertTrue(layer.table === owns.table)
        XCTAssertTrue(owns.table === mustNotOwn.table)
        XCTAssertTrue(layer.table === language.table)
        XCTAssertEqual(layer.table.numberOfColumns, 3)
        XCTAssertEqual(layer.table.value(for: .width), 100, accuracy: 0.001)
        XCTAssertEqual(layer.table.valueType(for: .width), .percentageValueType)

        XCTAssertEqual(layer.startingRow, 0)
        XCTAssertEqual(layer.startingColumn, 0)
        XCTAssertEqual(owns.startingColumn, 1)
        XCTAssertEqual(mustNotOwn.startingColumn, 2)
        XCTAssertEqual(language.startingRow, 1)
        XCTAssertEqual(contract.startingRow, 1)
        XCTAssertEqual(contract.startingColumn, 1)
        XCTAssertEqual(harness.startingColumn, 2)
        XCTAssertEqual(program.startingRow, 2)

        XCTAssertNotNil(layer.backgroundColor)
        XCTAssertNil(language.backgroundColor)
        XCTAssertGreaterThan(layer.width(for: .border, edge: .maxY), 0)
        XCTAssertGreaterThan(language.width(for: .border, edge: .maxY), 0)

        XCTAssertEqual(
            try paragraphStyle(containing: "Layer", in: result.attributedString).alignment,
            .left
        )
        XCTAssertEqual(
            try paragraphStyle(containing: "Owns", in: result.attributedString).alignment,
            .center
        )
        XCTAssertEqual(
            try paragraphStyle(containing: "Must not own", in: result.attributedString).alignment,
            .right
        )

        let widths = [layer, owns, mustNotOwn].map { $0.value(for: .width) }
        XCTAssertEqual(widths.reduce(0, +), 100, accuracy: 0.001)
        XCTAssertLessThan(widths[0], widths[1])

        XCTAssertFalse(result.attributedString.string.contains("|"))
        XCTAssertFalse(result.attributedString.string.contains("---"))
    }

    func testLongTableCellsWrapInsideTheirRowsWithoutCollapsingTheGrid() throws {
        let markdown = """
        | Layer | Owns | Boundary |
        |---|---|---|
        | Language | Contract structure; parameter and return semantics; call, spawn, settle, bind, return, fail; reference and state semantics; observable failure rules | Harness commands |
        | Program | Domain goals | Host lifecycle |
        """
        let rendered = MarkdownReaderRenderer().render(markdown).attributedString
        let storage = NSTextStorage(attributedString: rendered)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 690, height: CGFloat.greatestFiniteMagnitude)
        )
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let language = try tableBlock(containing: "Language", in: rendered)
        let contract = try tableBlock(containing: "Contract structure", in: rendered)
        let harness = try tableBlock(containing: "Harness commands", in: rendered)
        let program = try tableBlock(containing: "Program", in: rendered)

        let languageRect = try blockBounds(
            language,
            at: "Language",
            in: storage,
            layoutManager: layoutManager
        )
        let contractRect = try blockBounds(
            contract,
            at: "Contract structure",
            in: storage,
            layoutManager: layoutManager
        )
        let harnessRect = try blockBounds(
            harness,
            at: "Harness commands",
            in: storage,
            layoutManager: layoutManager
        )
        let programRect = try blockBounds(
            program,
            at: "Program",
            in: storage,
            layoutManager: layoutManager
        )

        XCTAssertLessThan(languageRect.minX, contractRect.minX)
        XCTAssertLessThan(contractRect.minX, harnessRect.minX)
        XCTAssertEqual(languageRect.minY, contractRect.minY, accuracy: 1)
        XCTAssertEqual(contractRect.minY, harnessRect.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(programRect.minY, contractRect.maxY - 1)
        XCTAssertGreaterThan(layoutManager.usedRect(for: textContainer).height, 120)
    }

    func testTableTextKeepsExactCommentSelectionMappings() throws {
        let markdown = """
        | Layer | Owns |
        |---|---|
        | Program | Domain goals and **chosen topology** |
        """
        let result = MarkdownReaderRenderer().render(markdown)
        let source = markdown as NSString
        let sourceRange = source.range(of: "chosen topology")
        let renderedRange = try XCTUnwrap(result.renderedRange(for: sourceRange))

        XCTAssertEqual(
            (result.attributedString.string as NSString).substring(with: renderedRange),
            "chosen topology"
        )
        XCTAssertEqual(result.sourceRange(for: renderedRange), sourceRange)
    }

    func testBlankTableHeaderRenderCompletesWithinInteractiveBudget() {
        let row = "| A modest cell | Another modest cell |\n"
        let markdown = "| | |\n|---|---|\n" + String(repeating: row, count: 400)

        let started = ProcessInfo.processInfo.systemUptime
        _ = MarkdownReaderRenderer().render(markdown)
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - started,
            0.35,
            "Reader tables should remain comfortably inside an interactive budget"
        )
    }

    private func tableBlock(
        containing text: String,
        in attributedString: NSAttributedString
    ) throws -> NSTextTableBlock {
        let paragraph = try paragraphStyle(containing: text, in: attributedString)
        return try XCTUnwrap(paragraph.textBlocks.first as? NSTextTableBlock)
    }

    private func paragraphStyle(
        containing text: String,
        in attributedString: NSAttributedString
    ) throws -> NSParagraphStyle {
        let range = (attributedString.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing rendered text: \(text)")
        return try XCTUnwrap(
            attributedString.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
    }

    private func blockBounds(
        _ block: NSTextTableBlock,
        at text: String,
        in storage: NSTextStorage,
        layoutManager: NSLayoutManager
    ) throws -> NSRect {
        let characterRange = (storage.string as NSString).range(of: text)
        XCTAssertNotEqual(characterRange.location, NSNotFound, "Missing laid-out text: \(text)")
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        return layoutManager.boundsRect(
            for: block,
            at: glyphRange.location,
            effectiveRange: nil
        )
    }
}
