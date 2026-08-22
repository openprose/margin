import Foundation
import XCTest
@testable import MarginCore

final class ComparisonDiffTests: XCTestCase {
    func testSnapshotIdentityIsLogicalBodyOnlyAndStripsLeadingBOM() throws {
        let body = Data([0xef, 0xbb, 0xbf]) + Data("# Note\n".utf8)
        let envelope = EmbeddedCommentEnvelope(
            documentID: "urn:test:document",
            modified: "2026-08-21T12:00:00Z"
        )
        let document = try EmbeddedCommentCodec().encode(bodyData: body, envelope: envelope)

        let snapshot = try ComparisonSnapshot(
            markdownDocumentData: document,
            label: "Note"
        )

        XCTAssertEqual(snapshot.content, "# Note\n")
        XCTAssertEqual(snapshot.bodyData, Data("# Note\n".utf8))
        XCTAssertEqual(snapshot.utf8ByteCount, 7)
        XCTAssertEqual(
            snapshot.sha256,
            CollaborationCanonicalJSON.sha256(of: Data("# Note\n".utf8))
        )
        XCTAssertFalse(snapshot.content.contains(EmbeddedCommentCodec.openingMarker))
    }

    func testSnapshotRejectsLiteralEnvelopeNULAndTamperedDigest() throws {
        let documentID = "urn:test:document"
        let actor = MarginActor(id: "urn:test:actor", type: .software, name: "Test Agent")
        let comment = MarginComment(
            id: "urn:test:comment",
            motivation: "commenting",
            creator: actor,
            created: "2026-08-21T12:00:00Z",
            modified: "2026-08-21T12:00:00Z",
            body: MarginCommentBody(value: "A real embedded comment."),
            target: .resource(documentID),
            status: .open,
            statusModified: "2026-08-21T12:00:00Z",
            statusModifiedBy: actor
        )
        let envelope = EmbeddedCommentEnvelope(
            documentID: documentID,
            modified: "2026-08-21T12:00:00Z",
            items: [comment],
            revision: 1
        )
        let document = try EmbeddedCommentCodec().encode(
            bodyData: Data("body\n".utf8),
            envelope: envelope
        )
        XCTAssertThrowsError(
            try ComparisonSnapshot(
                markdownBody: String(decoding: document, as: UTF8.self),
                label: "Literal"
            )
        ) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "EMBEDDED_COMMENT_ENVELOPE")
        }
        XCTAssertThrowsError(
            try ComparisonSnapshot(markdownBody: "a\0b", label: "NUL")
        ) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "INVALID_SNAPSHOT")
        }

        let snapshot = try ComparisonSnapshot(markdownBody: "safe\n", label: "Safe")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        object["sha256"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ComparisonSnapshot.self, from: tampered))
    }

    func testGoldenMarkdownLineAndWordDiffIsDeterministic() throws {
        let left = try ComparisonSnapshot(
            markdownBody: "# Plan\r\n\r\nThe **old** plan.\r\n- alpha\r\n",
            label: "Before"
        )
        let right = try ComparisonSnapshot(
            markdownBody: "# Plan\n\nThe **new** plan.\n- alpha\n- beta\n",
            label: "After"
        )
        let pair = try ComparisonSnapshotPair(generation: 4, left: left, right: right)

        let first = try ComparisonEngine().compare(pair)
        let second = try ComparisonEngine().compare(pair)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pairID, pair.id)
        XCTAssertEqual(first.snapshotGeneration, 4)
        XCTAssertEqual(
            first.blocks.map(\.kind),
            [.unchanged, .replacement, .unchanged, .insertion]
        )
        XCTAssertEqual(first.changedBlocks.count, 2)
        XCTAssertTrue(first.changedBlocks.allSatisfy {
            $0.id?.hasPrefix("urn:margin:comparison-block:") == true
        })
        let wordKinds = first.blocks[1].wordDiffs[0].segments.map(\.kind)
        XCTAssertEqual(wordKinds, [.unchanged, .deletion, .insertion, .unchanged])
        XCTAssertFalse(first.isCoarse)
    }

    func testLineEndingSpellingIsNormalizedButFinalBoundaryIsLiteral() throws {
        let crlf = try ComparisonSnapshot(markdownBody: "one\r\ntwo\r\n", label: "CRLF")
        let lf = try ComparisonSnapshot(markdownBody: "one\ntwo\n", label: "LF")
        let normalized = try ComparisonEngine().compare(
            ComparisonSnapshotPair(left: crlf, right: lf)
        )
        XCTAssertTrue(normalized.changedBlocks.isEmpty)

        let missingFinal = try ComparisonSnapshot(markdownBody: "one\ntwo", label: "No newline")
        let literal = try ComparisonEngine().compare(
            ComparisonSnapshotPair(left: lf, right: missingFinal)
        )
        XCTAssertEqual(literal.changedBlocks.map(\.kind), [.replacement])
    }

    func testUnicodeRangesNameScalarAndUTF8CoordinatesExactly() throws {
        let left = try ComparisonSnapshot(markdownBody: "é😀 old\n", label: "Left")
        let right = try ComparisonSnapshot(markdownBody: "é😀 new\n", label: "Right")
        let result = try ComparisonEngine().compare(
            ComparisonSnapshotPair(left: left, right: right)
        )
        let block = try XCTUnwrap(result.changedBlocks.first)

        XCTAssertEqual(block.left.unicodeScalarStart, 0)
        XCTAssertEqual(block.left.unicodeScalarLength, 7)
        XCTAssertEqual(block.left.utf8ByteStart, 0)
        XCTAssertEqual(block.left.utf8ByteLength, 11)
        let deletion = try XCTUnwrap(
            block.wordDiffs[0].segments.first { $0.kind == .deletion }
        )
        XCTAssertEqual(deletion.leftUnicodeScalars, UnicodeScalarRange(start: 3, end: 6))
        XCTAssertEqual(deletion.leftUTF8Bytes?.start, 7)
        XCTAssertEqual(deletion.leftUTF8Bytes?.length, 3)
    }

    func testDeterministicBudgetProducesOneCoarseInterior() throws {
        let left = try ComparisonSnapshot(markdownBody: "a\nb\nc\n", label: "Left")
        let right = try ComparisonSnapshot(markdownBody: "x\ny\nz\n", label: "Right")
        let limits = ComparisonLimits(maxLineMatrixCells: 1)
        let result = try ComparisonEngine(limits: limits).compare(
            ComparisonSnapshotPair(left: left, right: right)
        )

        XCTAssertTrue(result.isCoarse)
        XCTAssertEqual(result.coarseReasons, [.lineWorkBudget])
        XCTAssertEqual(result.changedBlocks.count, 1)
        XCTAssertEqual(result.changedBlocks[0].kind, .replacement)
        XCTAssertTrue(result.changedBlocks[0].wordDiffs.isEmpty)
    }

    func testLargeRepeatedLineFallbackIsDeterministicAndLineOnly() throws {
        let leftBody = (0..<5_000).map { $0.isMultiple(of: 2) ? "alpha" : "beta" }
            .joined(separator: "\n")
        let rightBody = (0..<5_000).map { $0.isMultiple(of: 2) ? "beta" : "alpha" }
            .joined(separator: "\n")
        let pair = try ComparisonSnapshotPair(
            left: ComparisonSnapshot(markdownBody: leftBody, label: "Left"),
            right: ComparisonSnapshot(markdownBody: rightBody, label: "Right")
        )
        let engine = ComparisonEngine()

        let first = try engine.compare(pair)
        let second = try engine.compare(pair)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.coarseReasons, [.lineWorkBudget])
        XCTAssertEqual(first.changedBlocks.count, 1)
        XCTAssertTrue(first.changedBlocks[0].wordDiffs.isEmpty)
    }

    func testChangedBlockLimitDoesNotCountUnchangedContext() throws {
        let limits = ComparisonLimits(maxBlocks: 1)
        let oneChange = try ComparisonEngine(limits: limits).compare(
            ComparisonSnapshotPair(
                left: ComparisonSnapshot(
                    markdownBody: "before\nold\nafter\n",
                    label: "Left"
                ),
                right: ComparisonSnapshot(
                    markdownBody: "before\nnew\nafter\n",
                    label: "Right"
                )
            )
        )
        XCTAssertEqual(oneChange.blocks.map(\.kind), [.unchanged, .replacement, .unchanged])
        XCTAssertEqual(oneChange.changedBlocks.count, 1)

        XCTAssertThrowsError(try ComparisonEngine(limits: limits).compare(
            ComparisonSnapshotPair(
                left: ComparisonSnapshot(
                    markdownBody: "old one\nmiddle\nold two\n",
                    label: "Left"
                ),
                right: ComparisonSnapshot(
                    markdownBody: "new one\nmiddle\nnew two\n",
                    label: "Right"
                )
            )
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }
    }

    func testCancellationNeverReturnsPartialOutput() throws {
        let snapshot = try ComparisonSnapshot(
            markdownBody: (0..<2_000).map { "line \($0)" }.joined(separator: "\n"),
            label: "Many"
        )
        let pair = try ComparisonSnapshotPair(left: snapshot, right: snapshot)
        let token = ComparisonCancellationToken()
        token.cancel()

        XCTAssertThrowsError(try ComparisonEngine().compare(pair, cancellation: token)) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "COMPARISON_CANCELLED")
        }
    }

    func testPhysicalLineAndExtensionComplexityCapsAreHard() throws {
        let accepted = String(repeating: "a", count: ComparisonHardLimits.lineUTF8Bytes)
        XCTAssertNoThrow(try ComparisonSnapshot(markdownBody: accepted, label: "Maximum line"))
        XCTAssertThrowsError(
            try ComparisonSnapshot(markdownBody: accepted + "a", label: "Oversized line")
        ) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }

        let tooMany = Dictionary(uniqueKeysWithValues: (0...ComparisonHardLimits.extensionKeys).map {
            ("key-\($0)", JSONValue.bool(true))
        })
        XCTAssertThrowsError(
            try ComparisonSnapshot(
                markdownBody: "body",
                label: "Extensions",
                extensions: tooMany
            )
        ) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }

        var nested: JSONValue = .string("leaf")
        for _ in 0...ComparisonHardLimits.extensionNestingDepth {
            nested = .array([nested])
        }
        XCTAssertThrowsError(
            try ComparisonSnapshot(
                markdownBody: "body",
                label: "Nested",
                extensions: ["nested": nested]
            )
        )
    }

    func testWordDiffUsesExactThirtyTwoKiBPhysicalLineBoundary() throws {
        let limit = ComparisonHardLimits.wordDiffLineUTF8Bytes
        let exactPrefix = String(repeating: "a", count: limit - 2)
        let exactLeft = try ComparisonSnapshot(
            markdownBody: exactPrefix + "x\n",
            label: "Exact left"
        )
        let exactRight = try ComparisonSnapshot(
            markdownBody: exactPrefix + "y\n",
            label: "Exact right"
        )
        let exact = try ComparisonEngine().compare(
            ComparisonSnapshotPair(left: exactLeft, right: exactRight)
        )
        XCTAssertEqual(exact.changedBlocks.first?.wordDiffs.count, 1)
        XCTAssertFalse(exact.isCoarse)

        let overPrefix = String(repeating: "a", count: limit - 1)
        let overLeft = try ComparisonSnapshot(
            markdownBody: overPrefix + "x\n",
            label: "Over left"
        )
        let overRight = try ComparisonSnapshot(
            markdownBody: overPrefix + "y\n",
            label: "Over right"
        )
        let over = try ComparisonEngine().compare(
            ComparisonSnapshotPair(left: overLeft, right: overRight)
        )
        XCTAssertEqual(over.changedBlocks.first?.wordDiffs, [])
        XCTAssertFalse(over.isCoarse)
    }

    func testSnapshotLabelHasExactFiveHundredTwelveByteBoundary() throws {
        let exact = String(repeating: "l", count: ComparisonHardLimits.labelUTF8Bytes)
        XCTAssertNoThrow(try ComparisonSnapshot(markdownBody: "body", label: exact))
        XCTAssertThrowsError(
            try ComparisonSnapshot(markdownBody: "body", label: exact + "x")
        ) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "INVALID_SNAPSHOT")
        }
    }

    func testRegularReaderRejectsMissingSymlinkAndMidReadMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.md")
        XCTAssertThrowsError(try ComparisonSnapshot.readMarkdownFile(at: missing)) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "INPUT_NOT_FOUND")
        }

        let real = directory.appendingPathComponent("real.md")
        let link = directory.appendingPathComponent("link.md")
        try Data("real\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try ComparisonSnapshot.readMarkdownFile(at: link)) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "SYMBOLIC_LINK")
        }

        let changing = directory.appendingPathComponent("changing.md")
        try Data(repeating: 0x61, count: 256 * 1_024).write(to: changing)
        var changed = false
        XCTAssertThrowsError(
            try ComparisonRegularFile.read(
                at: changing,
                maximumBytes: 1_024 * 1_024,
                afterReadChunk: { _ in
                    guard !changed else { return }
                    changed = true
                    let handle = try! FileHandle(forWritingTo: changing)
                    try! handle.seekToEnd()
                    try! handle.write(contentsOf: Data("x".utf8))
                    try! handle.close()
                }
            )
        ) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "INPUT_CHANGED")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-comparison-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
