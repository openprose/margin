import Foundation
import XCTest
@testable import MarginCore

final class ComparisonApplyServiceTests: XCTestCase {
    func testAppliesEveryChangedBlockInOnePlan() throws {
        let left = try ComparisonSnapshot(markdownBody: "# Plan\n\nold one\nold two\n", label: "Before")
        let right = try ComparisonSnapshot(markdownBody: "# Plan\n\nnew one\nold two\nadded\n", label: "After")
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)
        let service = ComparisonApplyService()
        let plan = try service.plan(pair: pair, result: result, direction: .leftToRight)

        let applied = try service.applying(plan, to: right.bodyData)

        XCTAssertEqual(String(decoding: applied, as: UTF8.self), left.content)
        XCTAssertEqual(plan.patches.count, result.changedBlocks.count)
    }

    func testUnknownBlockBuildsNoPartialPlan() throws {
        let left = try ComparisonSnapshot(markdownBody: "left\n", label: "Left")
        let right = try ComparisonSnapshot(markdownBody: "right\n", label: "Right")
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)

        XCTAssertThrowsError(
            try ComparisonApplyService().plan(
                pair: pair,
                result: result,
                direction: .rightToLeft,
                blockIDs: ["urn:margin:comparison-block:missing"]
            )
        ) { error in
            XCTAssertEqual(
                (error as? ComparisonApplyError)?.code,
                "COMPARISON_BLOCK_NOT_FOUND"
            )
        }
    }

    func testFileApplyPreservesConcurrentAnnotationAndRefreshesAnchor() throws {
        let fixture = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("review.md")
        try Data("alpha target omega\n".utf8).write(to: file)
        let left = try ComparisonSnapshot.readMarkdownFile(at: file, label: "Current")
        let right = try ComparisonSnapshot(
            markdownBody: "prefix alpha target omega\n",
            label: "Proposal"
        )
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)
        let plan = try ComparisonApplyService().plan(
            pair: pair,
            result: result,
            direction: .rightToLeft
        )

        let actor = MarginActor(id: "urn:test:reviewer", type: .person, name: "Reviewer")
        let comment = try CommentService().add(
            at: file,
            message: "Keep this phrase.",
            creator: actor,
            anchor: .quote(exact: "target")
        )
        let receipt = try ComparisonApplyService().apply(plan, to: file)
        let decoded = try EmbeddedCommentCodec().decode(Data(contentsOf: file))
        let commentID = comment.annotation.id
        let stored = try XCTUnwrap(decoded.envelope?.items.first { $0.id == commentID })
        let selection = try XCTUnwrap(stored.selectionTarget)

        XCTAssertEqual(decoded.body, right.content)
        XCTAssertEqual(selection.positionSelector?.start, 13)
        XCTAssertEqual(receipt.annotationRevision, 2)
        XCTAssertEqual(receipt.refreshedAnchorIDs, [commentID])
    }

    func testAnchorReconciliationBudgetExhaustionLeavesFileByteForByteUnchanged() throws {
        let fixture = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("bounded.md")
        try Data("alpha target omega\n".utf8).write(to: file)
        let left = try ComparisonSnapshot.readMarkdownFile(at: file, label: "Current")
        let right = try ComparisonSnapshot(
            markdownBody: "prefix alpha target omega\n",
            label: "Proposal"
        )
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)
        let plan = try ComparisonApplyService().plan(
            pair: pair,
            result: result,
            direction: .rightToLeft
        )
        _ = try CommentService().add(
            at: file,
            message: "Keep this phrase.",
            creator: MarginActor(id: "urn:test:agent", type: .software, name: "Agent"),
            anchor: .quote(exact: "target")
        )
        let before = try Data(contentsOf: file)

        XCTAssertThrowsError(try ComparisonApplyService().apply(
            plan,
            to: file,
            maximumAnchorScalarComparisons: 1
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testStaleLogicalBodyLeavesFileUnchanged() throws {
        let fixture = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("stale.md")
        try Data("before\n".utf8).write(to: file)
        let left = try ComparisonSnapshot.readMarkdownFile(at: file, label: "Before")
        let right = try ComparisonSnapshot(markdownBody: "after\n", label: "After")
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)
        let plan = try ComparisonApplyService().plan(
            pair: pair,
            result: result,
            direction: .rightToLeft
        )
        try Data("someone else\n".utf8).write(to: file)
        let before = try Data(contentsOf: file)

        XCTAssertThrowsError(try ComparisonApplyService().apply(plan, to: file)) { error in
            XCTAssertEqual(
                (error as? ComparisonApplyError)?.code,
                "COMPARISON_DESTINATION_STALE"
            )
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testSymlinkDestinationIsRefused() throws {
        let fixture = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("real.md")
        let link = fixture.appendingPathComponent("link.md")
        try Data("left\n".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let left = try ComparisonSnapshot(markdownBody: "left\n", label: "Left")
        let right = try ComparisonSnapshot(markdownBody: "right\n", label: "Right")
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)
        let plan = try ComparisonApplyService().plan(
            pair: pair,
            result: result,
            direction: .rightToLeft
        )

        XCTAssertThrowsError(try ComparisonApplyService().apply(plan, to: link)) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "SYMBOLIC_LINK")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "left\n")
    }

    func testFileApplyUsesLogicalBOMIdentityAndRestoresBOM() throws {
        let fixture = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("bom.md")
        let bom = Data([0xef, 0xbb, 0xbf])
        var original = bom
        original.append(Data("left\n".utf8))
        try original.write(to: file)

        let left = try ComparisonSnapshot.readMarkdownFile(at: file, label: "Left")
        let right = try ComparisonSnapshot(markdownBody: "right\n", label: "Right")
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)
        let plan = try ComparisonApplyService().plan(
            pair: pair,
            result: result,
            direction: .rightToLeft
        )

        let receipt = try ComparisonApplyService().apply(plan, to: file)
        let written = try Data(contentsOf: file)
        XCTAssertTrue(written.starts(with: bom))
        XCTAssertEqual(Data(written.dropFirst(bom.count)), Data("right\n".utf8))
        XCTAssertEqual(receipt.previousBodySHA256, left.sha256)
        XCTAssertEqual(receipt.contentSHA256, right.sha256)
    }

    func testReconciliationRefreshesSelectionRegardlessOfMotivation() throws {
        let documentID = "urn:test:future-annotation"
        let oldBody = "target\n"
        let newBody = "prefix target\n"
        let target = try AnchorResolver().target(
            for: .quote(exact: "target"),
            documentID: documentID,
            in: oldBody
        )
        let actor = MarginActor(id: "urn:test:agent", type: .software, name: "Agent")
        let suggestion = MarginComment(
            id: "urn:test:suggestion",
            motivation: "suggesting",
            creator: actor,
            created: "2026-08-21T12:00:00Z",
            modified: "2026-08-21T12:00:00Z",
            body: MarginCommentBody(value: "Use this wording."),
            target: target
        )
        let envelope = EmbeddedCommentEnvelope(
            documentID: documentID,
            modified: "2026-08-21T12:00:00Z",
            items: [suggestion],
            revision: 1
        )
        let service = ComparisonApplyService(timestamp: { "2026-08-21T12:01:00Z" })

        let reconciled = try service.reconciledEnvelopeAfterBodyChange(
            envelope,
            newPhysicalBody: newBody
        )
        let refreshed = try XCTUnwrap(reconciled.envelope.items.first?.selectionTarget)
        XCTAssertEqual(refreshed.positionSelector?.start, 7)
        XCTAssertEqual(reconciled.refreshedAnchorIDs, [suggestion.id])
        XCTAssertEqual(reconciled.envelope.revision, 2)

        let resourceOnly = MarginComment(
            id: "urn:test:document-note",
            motivation: "commenting",
            creator: actor,
            created: "2026-08-21T12:00:00Z",
            modified: "2026-08-21T12:00:00Z",
            body: MarginCommentBody(value: "Document note"),
            target: .resource(documentID),
            status: .open
        )
        let resourceEnvelope = EmbeddedCommentEnvelope(
            documentID: documentID,
            modified: "2026-08-21T12:00:00Z",
            items: [resourceOnly],
            revision: 1
        )
        let resourceResult = try service.reconciledEnvelopeAfterBodyChange(
            resourceEnvelope,
            newPhysicalBody: newBody
        )
        XCTAssertEqual(resourceResult.envelope.items, [resourceOnly])
        XCTAssertEqual(resourceResult.envelope.revision, resourceEnvelope.revision + 1)
        XCTAssertEqual(resourceResult.envelope.modified, "2026-08-21T12:01:00Z")
        XCTAssertTrue(resourceResult.refreshedAnchorIDs.isEmpty)

        var exhausted = envelope
        exhausted.revision = Int.max
        XCTAssertThrowsError(try service.reconciledEnvelopeAfterBodyChange(
            exhausted,
            newPhysicalBody: newBody
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "INVALID_COMPARISON_REVIEW")
        }
    }

    func testSelectivePreparedRefreshPreservesExcludedAndResourceAnnotationsAtomically() throws {
        let oldBody = "alpha target omega\n"
        let newBody = "prefix alpha target omega\n"
        let documentID = "urn:test:selective-refresh"
        let target = try AnchorResolver().target(
            for: .quote(exact: "target"),
            documentID: documentID,
            in: oldBody
        )
        let actor = MarginActor(id: "urn:test:agent", type: .software, name: "Agent")
        let timestamp = "2026-08-21T12:00:00Z"
        let suggestion = MarginComment(
            id: "urn:test:selective-suggestion",
            motivation: "suggesting",
            creator: actor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: "Suggestion"),
            target: target
        )
        let excludedSelection = MarginComment(
            id: "urn:test:excluded-comment",
            motivation: "commenting",
            creator: actor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: "Comment"),
            target: target,
            status: .open
        )
        let resource = MarginComment(
            id: "urn:test:resource-comment",
            motivation: "commenting",
            creator: actor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: "Document note"),
            target: .resource(documentID),
            status: .open
        )
        let original = [suggestion, excludedSelection, resource]
        let service = ComparisonApplyService()

        let refreshed = try service.refreshSelectionAnnotations(
            original,
            withIDs: [suggestion.id],
            in: newBody
        )
        XCTAssertEqual(refreshed.refreshedAnchorIDs, [suggestion.id])
        XCTAssertNotEqual(refreshed.annotations[0], suggestion)
        XCTAssertEqual(refreshed.annotations[1], excludedSelection)
        XCTAssertEqual(refreshed.annotations[2], resource)

        XCTAssertThrowsError(try service.refreshSelectionAnnotations(
            original,
            withIDs: [suggestion.id],
            in: newBody,
            maximumScalarComparisons: 1
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }
        XCTAssertEqual(original, [suggestion, excludedSelection, resource])
    }

    func testAnnotationRefreshWorkLimitCannotBeRaisedAndNegativeLimitFailsClosed() throws {
        XCTAssertEqual(
            ComparisonReviewRefreshWork(limit: Int.max, cancellation: nil).limit,
            ComparisonHardLimits.anchorRefreshScalarComparisons
        )
        XCTAssertEqual(
            ComparisonReviewRefreshWork(limit: -1, cancellation: nil).limit,
            0
        )

        let oldBody = "alpha target omega\n"
        let target = try AnchorResolver().target(
            for: .quote(exact: "target"),
            documentID: "urn:test:bounded-public-refresh",
            in: oldBody
        )
        let annotation = MarginComment(
            id: "urn:test:bounded-public-refresh",
            motivation: "suggesting",
            creator: MarginActor(id: "urn:test:agent", type: .software, name: "Agent"),
            created: "2026-08-21T12:00:00Z",
            modified: "2026-08-21T12:00:00Z",
            body: MarginCommentBody(value: "Bounded"),
            target: target
        )
        XCTAssertThrowsError(try ComparisonApplyService().refreshSelectionAnnotations(
            [annotation],
            in: "prefix " + oldBody,
            maximumScalarComparisons: -1
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }
    }

    func testInvalidMultiHunkResultLeavesFileByteForByteUnchanged() throws {
        let fixture = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("atomic.md")
        let destination = "# Plan\n\nnew one\nold two\nadded\n"
        try Data(destination.utf8).write(to: file)
        let left = try ComparisonSnapshot(
            markdownBody: "# Plan\n\nold one\nold two\n",
            label: "Before"
        )
        let right = try ComparisonSnapshot(markdownBody: destination, label: "After")
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)
        let service = ComparisonApplyService()
        let valid = try service.plan(pair: pair, result: result, direction: .leftToRight)
        XCTAssertGreaterThan(valid.patches.count, 1)
        var patches = valid.patches
        let last = try XCTUnwrap(patches.last)
        patches[patches.count - 1] = ComparisonApplyPatch(
            blockID: last.blockID,
            destination: last.destination,
            replacement: String(
                repeating: "x",
                count: ComparisonHardLimits.lineUTF8Bytes + 1
            )
        )
        let invalid = ComparisonApplyPlan(
            pairID: valid.pairID,
            snapshotGeneration: valid.snapshotGeneration,
            direction: valid.direction,
            expectedDestinationSHA256: valid.expectedDestinationSHA256,
            patches: patches
        )
        let before = try Data(contentsOf: file)

        XCTAssertThrowsError(try service.apply(invalid, to: file))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testSymlinkSwapAfterTransactionReadCannotRedirectWrite() throws {
        let fixture = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("destination.md")
        let victim = fixture.appendingPathComponent("victim.md")
        try Data("left\n".utf8).write(to: file)
        try Data("private\n".utf8).write(to: victim)
        let left = try ComparisonSnapshot(markdownBody: "left\n", label: "Left")
        let right = try ComparisonSnapshot(markdownBody: "right\n", label: "Right")
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let result = try ComparisonEngine().compare(pair)
        let ordinary = ComparisonApplyService()
        let plan = try ordinary.plan(pair: pair, result: result, direction: .rightToLeft)
        let strictStore = AtomicDocumentStore(beforeReplaceForTesting: {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim)
        })
        let service = ComparisonApplyService(store: strictStore)

        XCTAssertThrowsError(try service.apply(plan, to: file)) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "SYMBOLIC_LINK")
        }
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "private\n")
    }

    func testStrictTransactionsShareOneLockAcrossParentDirectoryAliases() throws {
        let fixture = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let realParent = fixture.appendingPathComponent("real", isDirectory: true)
        let aliasParent = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliasParent,
            withDestinationURL: realParent
        )
        let realFile = realParent.appendingPathComponent("document.md")
        let aliasFile = aliasParent.appendingPathComponent("document.md")
        try Data("body\n".utf8).write(to: realFile)

        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = expectation(description: "first strict transaction finished")
        DispatchQueue.global().async {
            defer { firstFinished.fulfill() }
            _ = try? AtomicDocumentStore().transaction(
                at: realFile,
                maximumBytes: 1_024,
                rejectSymbolicLinks: true
            ) { data in
                firstEntered.signal()
                releaseFirst.wait()
                return AtomicDocumentMutation(data: data, result: ())
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        defer {
            releaseFirst.signal()
            wait(for: [firstFinished], timeout: 2)
        }

        XCTAssertThrowsError(try AtomicDocumentStore(lockTimeout: 0).transaction(
            at: aliasFile,
            maximumBytes: 1_024,
            rejectSymbolicLinks: true
        ) { data in
            AtomicDocumentMutation(data: data, result: ())
        }) { error in
            XCTAssertEqual((error as? CommentProtocolError)?.code, "LOCK_TIMEOUT")
        }
        XCTAssertEqual(try Data(contentsOf: realFile), Data("body\n".utf8))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-comparison-apply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension MarginComment {
    var selectionTarget: CommentSelectionTarget? {
        guard case .selection(let value) = target else { return nil }
        return value
    }
}
