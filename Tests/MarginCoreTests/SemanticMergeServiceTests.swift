import Foundation
import XCTest
@testable import MarginCore

final class SemanticMergeServiceTests: XCTestCase {
    func testMergeCombinesIndependentAnnotationGraphAdditions() throws {
        let fixture = try fixture(body: "# Plan\n\nAlpha and beta.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let comments = CommentService()
        let root = try comments.add(
            at: fixture.base,
            message: "Base review",
            creator: actor("base"),
            anchor: .quote(exact: "Alpha")
        ).rootID
        try copy(fixture.base, to: fixture.ours)
        try copy(fixture.base, to: fixture.theirs)
        _ = try comments.reply(
            at: fixture.ours,
            parentID: root,
            message: "Independent reply",
            creator: actor("ours")
        )
        _ = try comments.add(
            at: fixture.theirs,
            message: "Independent root",
            creator: actor("theirs"),
            anchor: .quote(exact: "beta")
        )

        let result = try merger.merge(
            base: Data(contentsOf: fixture.base),
            ours: Data(contentsOf: fixture.ours),
            theirs: Data(contentsOf: fixture.theirs)
        )

        XCTAssertTrue(result.clean)
        XCTAssertEqual(result.annotationCount, 3)
        let output = try XCTUnwrap(result.data)
        let decoded = try EmbeddedCommentCodec().decode(output)
        XCTAssertEqual(decoded.body, "# Plan\n\nAlpha and beta.\n")
        XCTAssertEqual(decoded.envelope?.items.count, 3)
    }

    func testMergeNormalizesIndependentFirstEnvelopeIdentitiesFromCleanBase() throws {
        let fixture = try fixture(body: "Alpha and beta.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let comments = CommentService()
        _ = try comments.add(
            at: fixture.ours,
            message: "Review alpha",
            creator: actor("ours"),
            anchor: .quote(exact: "Alpha")
        )
        _ = try comments.add(
            at: fixture.theirs,
            message: "Review beta",
            creator: actor("theirs"),
            anchor: .quote(exact: "beta")
        )
        let ourID = try XCTUnwrap(
            EmbeddedCommentCodec().decode(Data(contentsOf: fixture.ours)).envelope?.document.id
        )
        let theirID = try XCTUnwrap(
            EmbeddedCommentCodec().decode(Data(contentsOf: fixture.theirs)).envelope?.document.id
        )
        XCTAssertNotEqual(ourID, theirID)

        let result = try merger.merge(
            base: Data(contentsOf: fixture.base),
            ours: Data(contentsOf: fixture.ours),
            theirs: Data(contentsOf: fixture.theirs)
        )
        XCTAssertTrue(result.clean)
        let decoded = try EmbeddedCommentCodec().decode(try XCTUnwrap(result.data))
        let documentID = try XCTUnwrap(decoded.envelope?.document.id)
        XCTAssertEqual(decoded.envelope?.items.count, 2)
        for annotation in decoded.envelope?.items ?? [] {
            guard case .selection(let target) = annotation.target else {
                return XCTFail("Expected a selection target")
            }
            XCTAssertEqual(target.source.id, documentID)
        }
    }

    func testExplicitRootDeletionCascadesAnIndependentlyAddedReply() throws {
        let fixture = try fixture(body: "# Design\n\nShared source.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let comments = CommentService()
        let rootID = try comments.add(
            at: fixture.base,
            message: "Root",
            creator: actor("base"),
            anchor: .document
        ).rootID
        try copy(fixture.base, to: fixture.ours)
        try copy(fixture.base, to: fixture.theirs)
        _ = try comments.delete(at: fixture.ours, id: rootID, subtree: true)
        _ = try comments.reply(
            at: fixture.theirs,
            parentID: rootID,
            message: "Independent reply",
            creator: actor("theirs")
        )

        let result = try merger.merge(
            base: Data(contentsOf: fixture.base),
            ours: Data(contentsOf: fixture.ours),
            theirs: Data(contentsOf: fixture.theirs)
        )

        XCTAssertTrue(result.clean)
        XCTAssertEqual(result.annotationCount, 0)
        XCTAssertEqual(result.data, Data("# Design\n\nShared source.\n".utf8))
    }

    func testMergeDetectsCompetingAnnotationEditsAndAcceptsExplicitResolution() throws {
        let fixture = try fixture(body: "Stable source.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let comments = CommentService()
        let root = try comments.add(
            at: fixture.base,
            message: "Original",
            creator: actor("base"),
            anchor: .document
        ).rootID
        try copy(fixture.base, to: fixture.ours)
        try copy(fixture.base, to: fixture.theirs)
        _ = try comments.edit(at: fixture.ours, id: root, message: "Ours", editor: actor("ours"))
        _ = try comments.edit(at: fixture.theirs, id: root, message: "Theirs", editor: actor("theirs"))

        let unresolved = try merger.merge(
            base: Data(contentsOf: fixture.base),
            ours: Data(contentsOf: fixture.ours),
            theirs: Data(contentsOf: fixture.theirs)
        )
        XCTAssertNil(unresolved.data)
        XCTAssertEqual(unresolved.conflicts.map(\.kind), [.annotation])
        XCTAssertEqual(unresolved.conflicts.first?.key, root)

        let resolved = try merger.merge(
            base: Data(contentsOf: fixture.base),
            ours: Data(contentsOf: fixture.ours),
            theirs: Data(contentsOf: fixture.theirs),
            annotationResolutions: [root: .ours]
        )
        XCTAssertTrue(resolved.clean)
        let document = try EmbeddedCommentCodec().decode(try XCTUnwrap(resolved.data))
        XCTAssertEqual(document.envelope?.items.first?.body.value, "Ours")
    }

    func testMergeRequiresExplicitBodyWhenBothSidesChangedSource() throws {
        let fixture = try fixture(body: "Base\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("Ours\n".utf8).write(to: fixture.ours)
        try Data("Theirs\n".utf8).write(to: fixture.theirs)

        let conflict = try merger.merge(
            base: Data(contentsOf: fixture.base),
            ours: Data(contentsOf: fixture.ours),
            theirs: Data(contentsOf: fixture.theirs)
        )
        XCTAssertEqual(conflict.conflicts.map(\.kind), [.source])
        XCTAssertNil(conflict.data)

        let resolved = try merger.merge(
            base: Data(contentsOf: fixture.base),
            ours: Data(contentsOf: fixture.ours),
            theirs: Data(contentsOf: fixture.theirs),
            mergedBody: Data("Combined\n".utf8)
        )
        XCTAssertEqual(resolved.data, Data("Combined\n".utf8))
    }

    func testMergeReportsOrphanedAnchorWithoutCorruptingGraph() throws {
        let fixture = try fixture(body: "Anchor this phrase.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try CommentService().add(
            at: fixture.base,
            message: "Review",
            creator: actor("base"),
            anchor: .quote(exact: "this phrase")
        )
        try copy(fixture.base, to: fixture.ours)
        try copy(fixture.base, to: fixture.theirs)

        let result = try merger.merge(
            base: Data(contentsOf: fixture.base),
            ours: Data(contentsOf: fixture.ours),
            theirs: Data(contentsOf: fixture.theirs),
            mergedBody: Data("The anchor disappeared.\n".utf8)
        )
        XCTAssertTrue(result.clean)
        XCTAssertEqual(result.anchorsNeedingAttention.map(\.state), [.orphaned])
        let output = try XCTUnwrap(result.data)
        XCTAssertEqual(try EmbeddedCommentCodec().decode(output).body, "The anchor disappeared.\n")
        XCTAssertEqual(try CommentService().snapshot(from: EmbeddedCommentCodec().decode(output)).comments[0].anchor?.state, .orphaned)
    }

    private var merger: SemanticMergeService {
        SemanticMergeService(timestamp: { "2026-08-16T12:00:00Z" })
    }

    private func actor(_ name: String) -> MarginActor {
        MarginActor(id: "urn:agent:\(name)", type: .software, name: name.capitalized)
    }

    private func fixture(body: String) throws -> (directory: URL, base: URL, ours: URL, theirs: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent("base.md")
        let ours = directory.appendingPathComponent("ours.md")
        let theirs = directory.appendingPathComponent("theirs.md")
        try Data(body.utf8).write(to: base)
        try copy(base, to: ours)
        try copy(base, to: theirs)
        return (directory, base, ours, theirs)
    }

    private func copy(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
