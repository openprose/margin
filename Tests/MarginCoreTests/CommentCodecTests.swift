import XCTest
@testable import MarginCore

final class CommentCodecTests: XCTestCase {
    private let actor = MarginActor(id: "urn:agent:test", type: .software, name: "Test Agent")

    func testRoundTripPreservesMarkdownAndHidesArbitraryCommentTextSafely() throws {
        let body = Data("# Heading\n\nA fast editor.\n".utf8)
        let documentID = "urn:uuid:00000000-0000-4000-8000-000000000001"
        let target = try AnchorResolver().target(
            for: .quote(exact: "fast"),
            documentID: documentID,
            in: String(decoding: body, as: UTF8.self)
        )
        let annotation = MarginComment(
            id: "urn:uuid:00000000-0000-4000-8000-000000000002",
            motivation: "commenting",
            creator: actor,
            created: "2026-08-16T03:00:00.000Z",
            modified: "2026-08-16T03:00:00.000Z",
            body: MarginCommentBody(value: "A --> delimiter -- and **Markdown**."),
            target: target,
            status: .open,
            statusModified: "2026-08-16T03:00:00.000Z",
            statusModifiedBy: actor
        )
        var envelope = EmbeddedCommentEnvelope(
            documentID: documentID,
            modified: "2026-08-16T03:00:00.000Z",
            items: [annotation],
            revision: 1
        )
        envelope.extensions["vendor:future"] = .object(["dash--key": .string("x--y")])

        let codec = EmbeddedCommentCodec()
        let encoded = try codec.encode(bodyData: body, envelope: envelope)
        let decoded = try codec.decode(encoded)

        XCTAssertEqual(decoded.bodyData, body)
        XCTAssertEqual(decoded.body, String(decoding: body, as: UTF8.self))
        XCTAssertEqual(decoded.envelope?.items.first?.body.value, "A --> delimiter -- and **Markdown**.")
        XCTAssertEqual(decoded.envelope?.extensions["vendor:future"], envelope.extensions["vendor:future"])

        let opening = Data(EmbeddedCommentCodec.openingMarker.utf8)
        let start = try XCTUnwrap(encoded.range(of: opening)?.upperBound)
        let payload = encoded[start..<(encoded.count - Data("\n-->\n".utf8).count)]
        XCTAssertNil(payload.range(of: Data("--".utf8)))
        XCTAssertNotNil(payload.range(of: Data("\\u002d".utf8)))
    }

    func testNoEnvelopeIsOrdinaryUTF8Markdown() throws {
        let data = Data("Plain **Markdown**".utf8)
        let decoded = try EmbeddedCommentCodec().decode(data)
        XCTAssertEqual(decoded.bodyData, data)
        XCTAssertNil(decoded.envelope)
    }

    func testContentTamperingFailsClosed() throws {
        let url = temporaryFile(contents: "Alpha beta gamma")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let service = CommentService()
        _ = try service.add(
            at: url,
            message: "Review beta",
            creator: actor,
            anchor: .quote(exact: "beta"),
            annotationID: "00000000-0000-4000-8000-000000000010"
        )
        var bytes = try Data(contentsOf: url)
        bytes[0] = Character("O").asciiValue!
        try bytes.write(to: url)

        XCTAssertThrowsError(try EmbeddedCommentCodec().decode(bytes)) { error in
            guard case CommentProtocolError.contentHashMismatch = error else {
                return XCTFail("Expected contentHashMismatch, got \(error)")
            }
        }
    }

    func testMultipleAndNonterminalBlocksAreRejected() throws {
        let marker = EmbeddedCommentCodec.openingMarker
        XCTAssertThrowsError(try EmbeddedCommentCodec().decode(Data("\(marker){}\n-->\n\(marker){}\n-->\n".utf8))) { error in
            guard case CommentProtocolError.multipleCommentBlocks = error else {
                return XCTFail("Expected multipleCommentBlocks, got \(error)")
            }
        }
        XCTAssertThrowsError(try EmbeddedCommentCodec().decode(Data("\(marker){}\n-->\ntrailing".utf8))) { error in
            guard case CommentProtocolError.nonterminalCommentBlock = error else {
                return XCTFail("Expected nonterminalCommentBlock, got \(error)")
            }
        }
    }

    private func temporaryFile(contents: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginCodecTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("document.md")
        try! Data(contents.utf8).write(to: url)
        return url
    }
}
