import Foundation
import MarginCore
import XCTest
@testable import MarginCLI

final class SuggestionWaitTests: XCTestCase {
    private let actor = MarginActor(
        id: "urn:agent:suggestion-wait-tests",
        type: .software,
        name: "Suggestion wait tests"
    )

    func testImmediateWaitReturnsOnlyNamedSuggestionState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = "00000000-0000-4000-8000-000000000001"
        let second = "00000000-0000-4000-8000-000000000002"
        try addSuggestion(first, to: fixture.file)
        try addSuggestion(second, to: fixture.file, status: "accepted")

        let result = try SuggestionWaitSession(file: fixture.file).wait(
            expectedIDs: [second, first],
            timeoutSeconds: 1
        )

        XCTAssertTrue(result.complete)
        XCTAssertTrue(result.receiptConclusiveForNamedIDs)
        XCTAssertFalse(result.immediateRecheckRequired)
        XCTAssertEqual(result.expectedCount, 2)
        XCTAssertEqual(result.matchedCount, 2)
        XCTAssertEqual(result.omittedMatchedCount, 0)
        XCTAssertEqual(result.missingIDs, [])
        XCTAssertEqual(result.matched.map(\.id), [
            "urn:uuid:\(first)",
            "urn:uuid:\(second)",
        ])
        XCTAssertEqual(result.matched.map(\.status), ["proposed", "accepted"])
        XCTAssertEqual(result.revision, 2)
        XCTAssertTrue(result.contentSha256.hasPrefix("sha256:"))
        XCTAssertLessThan(result.elapsedMilliseconds, 1_000)
    }

    func testWaitObservesAtomicReplacementAfterRegistration() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = "00000000-0000-4000-8000-000000000011"
        let second = "00000000-0000-4000-8000-000000000012"
        try addSuggestion(first, to: fixture.file)

        let writerFinished = expectation(description: "writer finished")
        var writerError: Error?
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(120)) {
            do {
                try self.addSuggestion(second, to: fixture.file)
            } catch {
                writerError = error
            }
            writerFinished.fulfill()
        }

        let result = try SuggestionWaitSession(file: fixture.file).wait(
            expectedIDs: [first, second],
            timeoutSeconds: 3
        )
        wait(for: [writerFinished], timeout: 3)

        XCTAssertNil(writerError)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.matchedCount, 2)
        XCTAssertGreaterThanOrEqual(result.elapsedMilliseconds, 50)
        XCTAssertLessThan(result.elapsedMilliseconds, 3_000)
    }

    func testImmediateTimeoutReportsOnlyMissingSuggestionIDs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let ordinary = "00000000-0000-4000-8000-000000000021"
        let missing = "00000000-0000-4000-8000-000000000022"
        _ = try CommentService().add(
            at: fixture.file,
            message: "An ordinary comment must not satisfy suggestion wait.",
            creator: actor,
            anchor: .document,
            annotationID: ordinary
        )

        let result = try SuggestionWaitSession(file: fixture.file).wait(
            expectedIDs: [ordinary, missing],
            timeoutSeconds: 0
        )

        XCTAssertFalse(result.complete)
        XCTAssertFalse(result.receiptConclusiveForNamedIDs)
        XCTAssertTrue(result.immediateRecheckRequired)
        XCTAssertEqual(result.matchedCount, 0)
        XCTAssertEqual(result.missingIDs, [
            "urn:uuid:\(ordinary)",
            "urn:uuid:\(missing)",
        ])
        XCTAssertLessThan(result.elapsedMilliseconds, 1_000)
    }

    func testSuccessfulStatusProjectionHasAnExplicitBound() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let ids = (1...(SuggestionWaitSession.maximumReportedMatches + 1)).map {
            String(format: "00000000-0000-4000-8000-%012d", $0)
        }
        for id in ids {
            try addSuggestion(id, to: fixture.file)
        }

        let result = try SuggestionWaitSession(file: fixture.file).wait(
            expectedIDs: ids,
            timeoutSeconds: 1
        )

        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.matchedCount, ids.count)
        XCTAssertEqual(result.matched.count, SuggestionWaitSession.maximumReportedMatches)
        XCTAssertEqual(result.omittedMatchedCount, 1)
    }

    func testWaitInputIsBoundedAndCanonicalDuplicatesAreRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let id = "00000000-0000-4000-8000-000000000031"
        let session = SuggestionWaitSession(file: fixture.file)

        XCTAssertThrowsError(try session.wait(expectedIDs: [], timeoutSeconds: 0))
        XCTAssertThrowsError(try session.wait(
            expectedIDs: [id, "urn:uuid:\(id)"],
            timeoutSeconds: 0
        ))
        XCTAssertThrowsError(try session.wait(
            expectedIDs: Array(repeating: id, count: SuggestionWaitSession.maximumExpectedIDs + 1),
            timeoutSeconds: 0
        ))
        XCTAssertThrowsError(try session.wait(
            expectedIDs: [id],
            timeoutSeconds: SuggestionWaitSession.maximumTimeoutSeconds + 1
        ))
        XCTAssertThrowsError(try session.wait(
            expectedIDs: [String(repeating: "a", count: SuggestionWaitSession.maximumExpectedIDBytes + 1)],
            timeoutSeconds: 0
        ))
    }

    func testCLIWaitReturnsBoundedTemporaryFailureDetails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let id = "00000000-0000-4000-8000-000000000041"
        var cursor = ArgumentCursor([
            "wait", fixture.file.path, id, "--timeout", "0",
        ])

        XCTAssertThrowsError(try CollaborationCLI.run(command: "suggest", cursor: &cursor)) {
            guard let error = $0 as? CLIError else {
                return XCTFail("Expected CLIError, received \($0).")
            }
            XCTAssertEqual(error.code, "SUGGESTION_WAIT_TIMEOUT")
            XCTAssertEqual(error.exit, .temporaryFailure)
            XCTAssertEqual(error.details?["expectedCount"], "1")
            XCTAssertEqual(error.details?["matchedCount"], "0")
            XCTAssertEqual(error.details?["missingCount"], "1")
            XCTAssertEqual(error.details?["omittedMissingIDCount"], "0")
            XCTAssertEqual(error.details?["missingIDs"], "urn:uuid:\(id)")
            XCTAssertTrue(error.details?["contentSha256"]?.hasPrefix("sha256:") == true)
        }
    }

    private func makeFixture() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-suggestion-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("review.md")
        try Data("# Review\n\nLiteral source remains unchanged.\n".utf8).write(to: file)
        return (directory, file)
    }

    private func addSuggestion(
        _ id: String,
        to file: URL,
        status: String = "proposed"
    ) throws {
        _ = try CommentService().add(
            at: file,
            message: "Suggestion \(id.suffix(4))",
            creator: actor,
            anchor: .document,
            annotationID: id
        )
        let codec = EmbeddedCommentCodec()
        let decoded = try codec.decode(Data(contentsOf: file, options: .mappedIfSafe))
        guard var envelope = decoded.envelope,
              let index = envelope.items.firstIndex(where: {
                  $0.id == MarginID.annotation(id)
              }) else {
            XCTFail("Suggestion fixture annotation was not created.")
            return
        }
        envelope.items[index].extensions["margin:kind"] = .string("suggestion")
        envelope.items[index].extensions["margin:suggestion"] = .object([
            "status": .string(status),
            "expectedText": .string("Literal source"),
            "replacementText": .string("Revised source"),
            "baseContentSha256": .string(EmbeddedCommentCodec.contentHash(decoded.bodyData)),
        ])
        let output = try codec.encode(bodyData: decoded.bodyData, envelope: envelope)
        try output.write(to: file, options: .atomic)
    }
}
