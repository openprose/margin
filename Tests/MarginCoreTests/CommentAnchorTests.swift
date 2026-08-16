import XCTest
@testable import MarginCore

final class CommentAnchorTests: XCTestCase {
    private let resolver = AnchorResolver()
    private let documentID = "urn:uuid:00000000-0000-4000-8000-000000000100"

    func testUnicodeScalarOffsetsRoundTripWithoutSplittingGraphemes() throws {
        let source = "A 👩🏽‍💻 writes"
        let scalars = Array(source.unicodeScalars)
        let exact = Array("👩🏽‍💻".unicodeScalars)
        let start = try XCTUnwrap(firstOccurrence(exact, in: scalars))
        let target = try resolver.target(
            for: .range(start: start, end: start + exact.count, expectedExact: "👩🏽‍💻"),
            documentID: documentID,
            in: source
        )
        guard case .selection(let selection) = target else { return XCTFail("Expected selection") }
        let resolution = try resolver.resolve(selection, in: source)
        XCTAssertEqual(resolution.state, .anchored)
        XCTAssertEqual(resolution.range, UnicodeScalarRange(start: start, end: start + exact.count))

        XCTAssertThrowsError(try resolver.target(
            for: .range(start: start + 1, end: start + exact.count),
            documentID: documentID,
            in: source
        ))
    }

    func testQuoteContextReanchorsUniqueRepeatedText() throws {
        let original = "red fox then blue fox"
        let target = try resolver.target(
            for: .quote(exact: "fox", prefix: "blue "),
            documentID: documentID,
            in: original
        )
        guard case .selection(let selection) = target else { return XCTFail("Expected selection") }
        let edited = "intro red fox then blue fox"
        let resolution = try resolver.resolve(selection, in: edited)
        XCTAssertEqual(resolution.state, .moved)
        let range = try XCTUnwrap(resolution.range)
        let scalars = Array(AnchorResolver.normalizedProjection(edited).unicodeScalars)
        XCTAssertEqual(String(String.UnicodeScalarView(scalars[range.start..<range.end])), "fox")
        XCTAssertGreaterThan(range.start, 20)
    }

    func testRepeatedQuoteWithoutEnoughContextIsAmbiguous() throws {
        let target = CommentSelectionTarget(
            source: MarginSourceReference(id: documentID),
            selector: [
                .position(TextPositionSelector(start: 99, end: 102)),
                .quote(TextQuoteSelector(exact: "fox"))
            ]
        )
        let resolution = try resolver.resolve(target, in: "fox and fox")
        XCTAssertEqual(resolution.state, .ambiguous)
        XCTAssertEqual(resolution.candidates.map(\.range.start), [0, 8])
    }

    func testMissingQuoteBecomesOrphanedAndCRLFIsNormalized() throws {
        let target = try resolver.target(
            for: .quote(exact: "two\nthree"),
            documentID: documentID,
            in: "one\r\ntwo\r\nthree"
        )
        guard case .selection(let selection) = target else { return XCTFail("Expected selection") }
        XCTAssertEqual(try resolver.resolve(selection, in: "one\ntwo\nthree").state, .anchored)
        XCTAssertEqual(try resolver.resolve(selection, in: "one\nremoved").state, .orphaned)
    }

    private func firstOccurrence(_ needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        return (0...(haystack.count - needle.count)).first {
            Array(haystack[$0..<($0 + needle.count)]) == needle
        }
    }
}
