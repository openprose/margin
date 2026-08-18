import Foundation
import XCTest
@testable import MarginCore

final class CrossPlatformSupportTests: XCTestCase {
    func testSHA256MatchesPublishedVectors() {
        XCTAssertEqual(
            MarginSHA256.hexDigest(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            MarginSHA256.hexDigest(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            MarginSHA256.hexDigest(of: Data("Margin 🧭 collaboration".utf8)),
            "8dd0b42f629d9d569b4c70ccbdc7af52fe43761da90c67762d7b775eae6205a0"
        )
    }
}
