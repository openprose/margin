import Foundation
import XCTest
@testable import MarginCore

final class CollaborationStageRefreshTests: XCTestCase {
    func testUnrelatedDriftCreatesNewImmutableStageAndPreservesPayload() throws {
        let fixture = try StageRefreshFixture(files: [
            "draft.md": "Draft body\n",
            "context.md": "Context one\n",
        ])
        defer { fixture.remove() }
        let base = try fixture.cursor(paths: ["draft.md", "context.md"])
        let contribution = try fixture.comment(path: "draft.md", id: "urn:comment:refresh")
        let original = try fixture.changeSet(
            base: base,
            identity: "unrelated",
            operations: [.contribution(
                id: "urn:operation:refresh",
                CollaborationContributionOperation(contribution: contribution)
            )],
            extensions: ["vendor:opaque": .object(["unicode": .string("é文✨")])]
        )
        _ = try fixture.store.stage(original)
        try Data("Context two\n".utf8).write(to: fixture.file("context.md"))

        let receipt = try fixture.service.refresh(stageID: original.stageID, root: fixture.root)
        XCTAssertTrue(receipt.priorStageWasStale)
        XCTAssertEqual(receipt.priorStageID, original.stageID)
        XCTAssertNotEqual(receipt.refreshedStageID, original.stageID)
        XCTAssertEqual(receipt.disposition, .created)
        XCTAssertEqual(receipt.evaluatedMutationCount, 1)

        let refreshed = try fixture.store.load(stageID: receipt.refreshedStageID, root: fixture.root)
        XCTAssertEqual(refreshed.operations, original.operations)
        XCTAssertEqual(refreshed.actor, original.actor)
        XCTAssertEqual(refreshed.requestID, original.requestID)
        XCTAssertEqual(refreshed.created, original.created)
        XCTAssertEqual(refreshed.extensions["vendor:opaque"], original.extensions["vendor:opaque"])
        XCTAssertNotEqual(
            refreshed.baseCursor["context.md"]?.contentSha256,
            original.baseCursor["context.md"]?.contentSha256
        )
        guard case .object(let provenance)? = refreshed.extensions["margin:stageRefresh"] else {
            return XCTFail("Missing durable refresh provenance")
        }
        XCTAssertEqual(provenance["priorStageID"], .string(original.stageID))
        XCTAssertEqual(provenance["priorChangeSetID"], .string(original.id))
        XCTAssertEqual(try fixture.store.load(stageID: original.stageID, root: fixture.root), original)
    }

    func testChangedSemanticTargetAndInvalidSuggestionExpectedTextFailBeforeStorage() throws {
        let fixture = try StageRefreshFixture(files: ["draft.md": "Alpha beta gamma\n"])
        defer { fixture.remove() }
        let base = try fixture.cursor(paths: ["draft.md"])
        let comment = try fixture.comment(path: "draft.md", id: "urn:comment:target-drift")
        let original = try fixture.changeSet(
            base: base,
            identity: "target-drift",
            operations: [.contribution(
                id: "urn:operation:target-drift",
                CollaborationContributionOperation(contribution: comment)
            )]
        )
        _ = try fixture.store.stage(original)
        try Data("Changed Alpha beta gamma\n".utf8).write(to: fixture.file("draft.md"))

        let rejectedID = "urn:stage:target-drift:refreshed"
        XCTAssertThrowsError(try fixture.service.refresh(
            stageID: original.stageID,
            root: fixture.root,
            newStageID: rejectedID
        )) { error in
            guard case CollaborationError.preconditionFailed(let path, let reason) = error else {
                return XCTFail("Expected semantic precondition failure, got \(error)")
            }
            XCTAssertEqual(path, "draft.md")
            XCTAssertTrue(reason.contains("logical Markdown changed"))
        }
        XCTAssertThrowsError(try fixture.store.load(stageID: rejectedID, root: fixture.root))

        // A malformed staged suggestion cannot use refresh to bypass its exact
        // expected-text guard, even when the logical source itself is unchanged.
        try Data("Alpha beta gamma\n".utf8).write(to: fixture.file("draft.md"))
        let restored = try fixture.cursor(paths: ["draft.md"])
        let suggestion = try CollaborationContributionFactory.suggestion(
            actor: fixture.actor,
            path: "draft.md",
            range: UnicodeScalarRange(start: 6, end: 10),
            message: "Replace the word.",
            expectedText: "WRONG",
            replacementText: "delta",
            baseCursor: restored,
            created: fixture.timestamp,
            id: "urn:suggestion:invalid-expected"
        )
        let invalid = try fixture.changeSet(
            base: restored,
            identity: "invalid-expected",
            operations: [.contribution(
                id: "urn:operation:invalid-expected",
                CollaborationContributionOperation(contribution: suggestion)
            )]
        )
        _ = try fixture.store.stage(invalid)
        XCTAssertThrowsError(try fixture.service.refresh(
            stageID: invalid.stageID,
            root: fixture.root,
            newStageID: "urn:stage:invalid-expected:refreshed"
        )) { error in
            guard case CollaborationError.preconditionFailed(let path, let reason) = error else {
                return XCTFail("Expected suggestion precondition failure, got \(error)")
            }
            XCTAssertEqual(path, "draft.md")
            XCTAssertTrue(reason.contains("expected text"))
        }
    }

    func testChangedDirectTargetFailsClosedWithoutBlessingNewBytes() throws {
        let fixture = try StageRefreshFixture(files: [
            "direct.md": "Original\n",
            "context.md": "Context\n",
        ])
        defer { fixture.remove() }
        let base = try fixture.cursor(paths: ["direct.md", "context.md"])
        let cursor = try XCTUnwrap(base["direct.md"])
        let mutation = try CollaborationFileMutation(
            id: "urn:mutation:direct-refresh",
            path: "direct.md",
            precondition: .exact(cursor),
            result: .write(data: Data("Intended\n".utf8), permissions: nil)
        )
        let original = try fixture.changeSet(
            base: base,
            identity: "direct-refresh",
            operations: [.file(id: "urn:operation:direct-refresh", mutation)]
        )
        _ = try fixture.store.stage(original)
        try Data("External edit\n".utf8).write(to: fixture.file("direct.md"))

        let rejectedID = "urn:stage:direct-refresh:refreshed"
        XCTAssertThrowsError(try fixture.service.refresh(
            stageID: original.stageID,
            root: fixture.root,
            newStageID: rejectedID
        )) { error in
            guard case CollaborationError.preconditionFailed(let path, let reason) = error else {
                return XCTFail("Expected direct-file precondition failure, got \(error)")
            }
            XCTAssertEqual(path, "direct.md")
            XCTAssertTrue(reason.contains("direct-file target changed"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.file("direct.md")), "External edit\n")
        XCTAssertThrowsError(try fixture.store.load(stageID: rejectedID, root: fixture.root))
    }

    func testMultifileSemanticPlanRefreshesAsOneEvaluatedSnapshot() throws {
        let fixture = try StageRefreshFixture(files: [
            "a.md": "Alpha\n", "b.md": "Beta\n", "input.md": "Input one\n",
        ])
        defer { fixture.remove() }
        let base = try fixture.cursor(paths: ["a.md", "b.md", "input.md"])
        let operations: [CollaborationOperation] = [
            .contribution(
                id: "urn:operation:multi:a",
                CollaborationContributionOperation(
                    contribution: try fixture.comment(path: "a.md", id: "urn:comment:multi:a")
                )
            ),
            .contribution(
                id: "urn:operation:multi:b",
                CollaborationContributionOperation(
                    contribution: try fixture.comment(path: "b.md", id: "urn:comment:multi:b")
                )
            ),
        ]
        let original = try fixture.changeSet(base: base, identity: "multi", operations: operations)
        _ = try fixture.store.stage(original)
        try Data("Input two\n".utf8).write(to: fixture.file("input.md"))

        let receipt = try fixture.service.refresh(stageID: original.stageID, root: fixture.root)
        XCTAssertEqual(receipt.evaluatedMutationCount, 2)
        let refreshed = try fixture.store.load(stageID: receipt.refreshedStageID, root: fixture.root)
        XCTAssertEqual(refreshed.operations, operations)
        XCTAssertEqual(Set(refreshed.operations.map(\.path)), Set(["a.md", "b.md"]))
    }

    func testDeterministicReplayAndConcurrentRefreshShareOneImmutableStage() throws {
        let fixture = try StageRefreshFixture(files: [
            "draft.md": "Draft\n", "input.md": "Input one\n",
        ])
        defer { fixture.remove() }
        let base = try fixture.cursor(paths: ["draft.md", "input.md"])
        let original = try fixture.changeSet(
            base: base,
            identity: "concurrent",
            operations: [.contribution(
                id: "urn:operation:concurrent",
                CollaborationContributionOperation(
                    contribution: try fixture.comment(path: "draft.md", id: "urn:comment:concurrent")
                )
            )]
        )
        _ = try fixture.store.stage(original)
        try Data("Input two\n".utf8).write(to: fixture.file("input.md"))

        let results = StageRefreshResultBox()
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                results.append(Result {
                    try fixture.service.refresh(stageID: original.stageID, root: fixture.root)
                })
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let receipts = try results.values.map { try $0.get() }
        XCTAssertEqual(Set(receipts.map(\.refreshedStageID)).count, 1)
        XCTAssertEqual(receipts.filter { $0.disposition == .created }.count, 1)
        XCTAssertEqual(receipts.filter { $0.disposition == .alreadyPresent }.count, 7)

        let replay = try fixture.service.refresh(stageID: original.stageID, root: fixture.root)
        XCTAssertEqual(replay.refreshedStageID, receipts[0].refreshedStageID)
        XCTAssertEqual(replay.disposition, .alreadyPresent)

        let explicitID = "urn:stage:concurrent:explicit-refresh"
        let explicitFirst = try fixture.service.refresh(
            stageID: original.stageID,
            root: fixture.root,
            newStageID: explicitID
        )
        XCTAssertEqual(explicitFirst.disposition, .created)
        XCTAssertEqual(try fixture.service.refresh(
            stageID: original.stageID,
            root: fixture.root,
            newStageID: explicitID
        ).disposition, .alreadyPresent)

        // A caller-selected id stays immutable if another unrelated file drifts
        // again; it cannot be rebound to a second refreshed cursor.
        try Data("Input three\n".utf8).write(to: fixture.file("input.md"))
        XCTAssertThrowsError(try fixture.service.refresh(
            stageID: original.stageID,
            root: fixture.root,
            newStageID: explicitID
        )) { error in
            guard case CollaborationError.preconditionFailed(_, let reason) = error else {
                return XCTFail("Expected immutable refreshed-stage collision, got \(error)")
            }
            XCTAssertTrue(reason.contains("immutable stage id"))
        }
    }

    func testStageListingEnforcesAggregateByteBudgetAndNewestOrdering() throws {
        let fixture = try StageRefreshFixture(files: ["draft.md": "Draft\n"])
        defer { fixture.remove() }
        let base = try fixture.cursor(paths: ["draft.md"])
        func largeChangeSet(identity: String, byte: UInt8) throws -> CollaborationChangeSet {
            let cursor = try XCTUnwrap(base["draft.md"])
            let mutation = try CollaborationFileMutation(
                id: "urn:mutation:\(identity)",
                path: "draft.md",
                precondition: .exact(cursor),
                result: .write(data: Data(repeating: byte, count: 700_000), permissions: nil)
            )
            return try fixture.changeSet(
                base: base,
                identity: identity,
                operations: [.file(id: "urn:operation:\(identity)", mutation)]
            )
        }
        let older = try largeChangeSet(identity: "large-old", byte: 65)
        let newer = try largeChangeSet(identity: "large-new", byte: 66)
        let oldReceipt = try fixture.store.stage(older)
        let newReceipt = try fixture.store.stage(newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: oldReceipt.location
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newReceipt.location
        )

        let oneStageBudget = try CollaborationCanonicalJSON.encode(newer).count + 32
        let listing = try fixture.store.list(
            root: fixture.root,
            limit: 10,
            maximumAggregateBytes: oneStageBudget
        )
        XCTAssertEqual(listing.stages.map(\.stageID), [newer.stageID])
        XCTAssertEqual(listing.omittedCount, 1)
        XCTAssertTrue(listing.isTruncated)
        XCTAssertLessThanOrEqual(listing.selectedCanonicalBytes, oneStageBudget)
        XCTAssertGreaterThan(listing.omittedCanonicalBytes, 0)
    }
}

private final class StageRefreshFixture: @unchecked Sendable {
    let directory: URL
    let state: URL
    let root: CollaborationRoot
    let actor: CollaborationActor
    let timestamp = "2026-08-16T12:00:00Z"
    let store: CollaborationStageStore
    let service: CollaborationStageRefreshService

    init(files: [String: String]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-stage-refresh-\(UUID().uuidString)", isDirectory: true)
        state = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-stage-refresh-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        root = try CollaborationRootResolver().directory(at: directory)
        actor = try CollaborationActor(
            id: "urn:agent:stage-refresh",
            type: .software,
            name: "Stage Refresh Agent"
        )
        store = CollaborationStageStore(stateDirectory: state)
        let reader = CollaborationTransactionEngine(stateDirectory: state)
        service = CollaborationStageRefreshService(
            stageStore: store,
            evaluator: CollaborationChangeSetEvaluator(reader: reader)
        )
    }

    func file(_ path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    func cursor(paths: [String]) throws -> CollaborationCursor {
        try CollaborationCursorService().capture(
            root: root,
            paths: paths,
            limits: CollaborationDiscoveryLimits(
                maxFiles: max(1, paths.count),
                maxBytes: 128 * 1_024 * 1_024,
                maxDepth: 32
            )
        )
    }

    func comment(path: String, id: String) throws -> CollaborationContribution {
        try CollaborationContribution(
            id: id,
            actorID: actor.id,
            created: timestamp,
            body: "Review this passage.",
            target: CollaborationTarget(path: path),
            details: .comment(CollaborationCommentDetails())
        )
    }

    func changeSet(
        base: CollaborationCursor,
        identity: String,
        operations: [CollaborationOperation],
        extensions: [String: JSONValue] = [:]
    ) throws -> CollaborationChangeSet {
        try CollaborationChangeSet(
            id: "urn:changeset:\(identity)",
            root: root,
            baseCursor: base,
            actor: actor,
            requestID: "urn:request:\(identity)",
            stageID: "urn:stage:\(identity)",
            created: timestamp,
            operations: operations,
            extensions: extensions
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: state)
    }
}

private final class StageRefreshResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<CollaborationStageRefreshReceipt, Error>] = []

    var values: [Result<CollaborationStageRefreshReceipt, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Result<CollaborationStageRefreshReceipt, Error>) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
