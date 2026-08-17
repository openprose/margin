import Foundation
import XCTest
@testable import MarginCore

final class ReconciliationServiceTests: XCTestCase {
    func testReconcileRefreshesMovedAnchorWithoutChangingEditedMarkdown() throws {
        let fixture = try makeFixture(body: "# Design\n\nA precise boundary.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let commentService = CommentService()
        _ = try commentService.add(
            at: fixture.previous,
            message: "Keep this exact.",
            creator: actor,
            anchor: .quote(exact: "precise boundary")
        )
        try makeStaleCopy(
            previous: fixture.previous,
            current: fixture.current,
            newBody: "# Design\n\nAfter review, a precise boundary remains.\n"
        )

        let service = fixedService()
        let analysis = try service.analyze(at: fixture.current, from: fixture.previous)
        XCTAssertTrue(analysis.canApplyStrictly)
        XCTAssertEqual(analysis.movedCount, 1)

        let receipt = try service.apply(
            at: fixture.current,
            from: fixture.previous,
            policy: .requireAllAnchored
        )
        XCTAssertTrue(receipt.changed)
        XCTAssertEqual(receipt.refreshedAnchorIDs.count, 1)
        let decoded = try EmbeddedCommentCodec().decode(Data(contentsOf: fixture.current))
        XCTAssertEqual(decoded.body, "# Design\n\nAfter review, a precise boundary remains.\n")
        XCTAssertEqual(decoded.envelope?.modified, "2026-08-16T12:00:00Z")
        XCTAssertEqual(decoded.envelope?.revision, 2)
        XCTAssertEqual(try commentService.list(at: fixture.current).comments[0].anchor?.state, .anchored)
    }

    func testStrictReconcileRefusesOrphanButExplicitPolicyPreservesIt() throws {
        let fixture = try makeFixture(body: "# Design\n\nA precise boundary.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try CommentService().add(
            at: fixture.previous,
            message: "Keep this exact.",
            creator: actor,
            anchor: .quote(exact: "precise boundary")
        )
        try makeStaleCopy(
            previous: fixture.previous,
            current: fixture.current,
            newBody: "# Design\n\nThe passage was deleted.\n"
        )
        let before = try Data(contentsOf: fixture.current)
        let service = fixedService()

        XCTAssertThrowsError(try service.apply(
            at: fixture.current,
            from: fixture.previous,
            policy: .requireAllAnchored
        )) { error in
            guard case ReconciliationError.unresolvedAnchors = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.current), before)

        let receipt = try service.apply(
            at: fixture.current,
            from: fixture.previous,
            policy: .preserveUnresolved
        )
        XCTAssertEqual(receipt.unresolvedAnchorIDs.count, 1)
        XCTAssertEqual(try CommentService().list(at: fixture.current).comments[0].anchor?.state, .orphaned)
    }

    func testReconcileFailsClosedWhenEnvelopeSeparatorChanged() throws {
        let fixture = try makeFixture(body: "Body\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try CommentService().add(
            at: fixture.previous,
            message: "Document note",
            creator: actor,
            anchor: .document
        )
        var stale = try Data(contentsOf: fixture.previous)
        let closing = try XCTUnwrap(stale.range(of: Data("\n-->\n".utf8), options: .backwards))
        stale.replaceSubrange(closing, with: Data("\n-- >\n".utf8))
        try stale.write(to: fixture.current)

        XCTAssertThrowsError(try fixedService().analyze(at: fixture.current, from: fixture.previous)) {
            XCTAssertEqual(($0 as? ReconciliationError)?.code, "RECONCILE_ENVELOPE_CHANGED")
        }
    }

    private var actor: MarginActor {
        MarginActor(id: "urn:agent:reconcile", type: .software, name: "Reconcile Agent")
    }

    private func fixedService() -> ReconciliationService {
        ReconciliationService(timestamp: { "2026-08-16T12:00:00Z" })
    }

    private func makeFixture(body: String) throws -> (directory: URL, previous: URL, current: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = directory.appendingPathComponent("previous.md")
        let current = directory.appendingPathComponent("current.md")
        try Data(body.utf8).write(to: previous)
        return (directory, previous, current)
    }

    private func makeStaleCopy(previous: URL, current: URL, newBody: String) throws {
        let source = try Data(contentsOf: previous)
        let decoded = try EmbeddedCommentCodec().decode(source)
        let suffix = source.dropFirst(decoded.bodyData.count)
        var stale = Data(newBody.utf8)
        stale.append(contentsOf: suffix)
        try stale.write(to: current)
    }
}
