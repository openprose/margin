import XCTest
@testable import MarginCore

final class TextCoordinatesTests: XCTestCase {
    func testGraphemeAwareRange() throws {
        let text = "First\nA 👩🏽‍💻 writes\nLast"
        let span = TextSpan(
            start: TextPoint(line: 2, column: 3),
            end: TextPoint(line: 2, column: 4)
        )
        let range = try TextCoordinates.range(for: span, in: text)
        XCTAssertEqual(String(text[range]), "👩🏽‍💻")
        XCTAssertEqual(try TextCoordinates.span(for: range, in: text), span)
    }

    func testEndExclusiveColumnAtLineEnd() throws {
        let text = "abc\ndef"
        let range = try TextCoordinates.range(
            for: TextSpan(start: TextPoint(line: 1, column: 1), end: TextPoint(line: 1, column: 4)),
            in: text
        )
        XCTAssertEqual(String(text[range]), "abc")
    }

    func testInvalidCoordinatesFailClearly() {
        XCTAssertThrowsError(try TextCoordinates.index(for: TextPoint(line: 9, column: 1), in: "one"))
        XCTAssertThrowsError(try TextSpan(parsing: "not-a-range"))
    }
}
