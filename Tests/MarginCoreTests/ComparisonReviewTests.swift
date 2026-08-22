import Foundation
import XCTest
@testable import MarginCore

final class ComparisonReviewTests: XCTestCase {
    private let timestamp = "2026-08-21T12:00:00Z"
    private let later = "2026-08-21T12:01:00Z"
    private let actor = MarginActor(
        id: "urn:margin:test:reviewer",
        type: .software,
        name: "Review Agent"
    )

    func testPortableReviewRoundTripsThreadsAndUnknownExtensionsCanonically() throws {
        var review = try makeReview()
        review.extensions["vendor:review"] = .object([
            "future": .array([.number(1), .bool(true), .null])
        ])
        review.unknownFields["vendor:top-level"] = .string("preserved")
        review.threads[0].comments[0].extensions["vendor:comment"] = .string("kept")

        let encoded = try ComparisonReviewCodec.encode(review)
        let decoded = try ComparisonReviewCodec.decode(encoded)
        let reencoded = try ComparisonReviewCodec.encode(decoded)

        XCTAssertEqual(decoded, review)
        XCTAssertEqual(reencoded, encoded)
        XCTAssertEqual(decoded.unknownFields["vendor:top-level"], .string("preserved"))
        XCTAssertEqual(
            decoded.threads[0].comments[0].extensions["vendor:comment"],
            .string("kept")
        )
        XCTAssertEqual(decoded.threads[0].target.side, .left)
        XCTAssertEqual(
            decoded.threads[0].target.left?.snapshotSHA256,
            decoded.snapshots.left.sha256
        )
    }

    func testReviewAndLaunchCodecsRejectDuplicateObjectKeys() throws {
        let review = try makeReview()
        let encoded = try ComparisonReviewCodec.encode(review)
        var text = String(decoding: encoded, as: UTF8.self)
        text.insert(contentsOf: #""revision":0,"#, at: text.index(after: text.startIndex))
        XCTAssertThrowsError(try ComparisonReviewCodec.decode(Data(text.utf8))) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "INVALID_COMPARISON_REVIEW")
            XCTAssertTrue(error.localizedDescription.contains("duplicate key"))
        }

        let request = try makeRequest()
        let requestData = try ComparisonOpenRequestCodec.encode(request)
        var requestText = String(decoding: requestData, as: UTF8.self)
        requestText.insert(
            contentsOf: #""requestID":"duplicate","#,
            at: requestText.index(after: requestText.startIndex)
        )
        XCTAssertThrowsError(try ComparisonOpenRequestCodec.decode(Data(requestText.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate key"))
        }
    }

    func testMalformedReviewCorpusAndSampledByteFuzzFailClosed() throws {
        let encoded = try ComparisonReviewCodec.encode(makeReview())
        let malformed: [Data] = [
            Data(),
            Data("{".utf8),
            Data("[]".utf8),
            Data("null".utf8),
            Data([0xff]),
            Data(encoded.dropLast()),
            Data(encoded.prefix(max(1, encoded.count / 2))),
            encoded + Data(" trailing".utf8),
            Data(#"{"schema":"urn:margin:comparison-review:v1","version":1}"#.utf8),
        ]
        for (index, artifact) in malformed.enumerated() {
            XCTAssertThrowsError(
                try ComparisonReviewCodec.decode(artifact),
                "Malformed corpus item \(index) decoded unexpectedly."
            )
        }

        let stride = max(1, encoded.count / 64)
        for index in Swift.stride(from: 0, to: encoded.count, by: stride) {
            var corrupted = encoded
            corrupted[index] = 0xff
            XCTAssertThrowsError(
                try ComparisonReviewCodec.decode(corrupted),
                "Invalid UTF-8 mutation at byte \(index) decoded unexpectedly."
            )
        }
    }

    func testOpenRequestIsStrictPathlessBoundedAndAgeCheckable() throws {
        let request = try makeRequest()
        let encoded = try ComparisonOpenRequestCodec.encode(request)
        let decoded = try ComparisonOpenRequestCodec.decode(encoded)
        XCTAssertEqual(decoded, request)
        let created = try XCTUnwrap(ISO8601DateFormatter().date(from: decoded.created))
        XCTAssertNoThrow(try decoded.validateAge(
            relativeTo: created.addingTimeInterval(30),
            maximumAge: 60
        ))
        XCTAssertThrowsError(try decoded.validateAge(
            relativeTo: Date(timeIntervalSince1970: 4_000_000_000),
            maximumAge: 60
        ))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["vendor:future"] = true
        XCTAssertThrowsError(
            try ComparisonOpenRequestCodec.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )

        let hinted = try ComparisonSnapshot(
            markdownBody: "body",
            label: "Body",
            pathHint: "folder/note.md"
        )
        XCTAssertThrowsError(try ComparisonOpenRequest(
            requestID: "urn:request:paths",
            created: timestamp,
            left: hinted,
            right: hinted
        ))
        XCTAssertThrowsError(
            try ComparisonSnapshot(markdownBody: "body", label: "Body", pathHint: "../secret.md")
        )
    }

    func testIdentifiersAndActorNamesHaveExactFiveHundredTwelveByteBoundary() throws {
        let exact = String(repeating: "i", count: ComparisonHardLimits.identifierUTF8Bytes)
        let exactName = String(repeating: "n", count: ComparisonHardLimits.actorNameUTF8Bytes)
        let boundedActor = MarginActor(id: exact, type: .software, name: exactName)
        XCTAssertNoThrow(try ComparisonReviewComment(
            id: exact,
            creator: boundedActor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: "Bounded")
        ))

        let oversizedActorID = MarginActor(id: exact + "x", type: .software, name: "Agent")
        XCTAssertThrowsError(try ComparisonReviewComment(
            id: "urn:comment:bounded",
            creator: oversizedActorID,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: "Too large")
        ))
        let oversizedActorName = MarginActor(id: "urn:actor:bounded", type: .software, name: exactName + "x")
        XCTAssertThrowsError(try ComparisonReviewComment(
            id: "urn:comment:bounded",
            creator: oversizedActorName,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: "Too large")
        ))
        XCTAssertThrowsError(try ComparisonReviewComment(
            id: exact + "x",
            creator: actor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: "Too large")
        ))
    }

    func testThreadMutationIsIdempotentAndGraphValidationFailsClosed() throws {
        var review = try makeReview()
        let reply = try ComparisonReviewComment(
            id: "urn:comment:reply",
            parentID: "urn:thread:one",
            creator: actor,
            created: later,
            modified: later,
            body: MarginCommentBody(value: "Reply", purpose: "commenting")
        )

        XCTAssertTrue(try review.addComment(reply, to: "urn:thread:one"))
        XCTAssertFalse(try review.addComment(reply, to: "urn:thread:one"))
        var conflicting = reply
        conflicting.body = MarginCommentBody(value: "Different", purpose: "commenting")
        XCTAssertThrowsError(try review.addComment(conflicting, to: "urn:thread:one")) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "ID_CONFLICT")
        }

        let root = review.threads[0].comments[0]
        let disconnected = try ComparisonReviewComment(
            id: "urn:comment:disconnected",
            parentID: "urn:comment:missing",
            creator: actor,
            created: later,
            modified: later,
            body: MarginCommentBody(value: "Disconnected")
        )
        XCTAssertThrowsError(try ComparisonReviewThread(
            id: root.id,
            target: review.threads[0].target,
            statusModified: later,
            statusModifiedBy: actor,
            comments: [root, disconnected]
        ))

        var deep = [root]
        var parent = root.id
        for index in 1...(ComparisonHardLimits.replyDepth + 1) {
            let id = "urn:comment:depth-\(index)"
            deep.append(try ComparisonReviewComment(
                id: id,
                parentID: parent,
                creator: actor,
                created: later,
                modified: later,
                body: MarginCommentBody(value: "Depth \(index)")
            ))
            parent = id
        }
        XCTAssertThrowsError(try ComparisonReviewThread(
            id: root.id,
            target: review.threads[0].target,
            statusModified: later,
            statusModifiedBy: actor,
            comments: deep
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }
    }

    func testRefreshAdvancesSnapshotGenerationNotReviewRevisionAndNeverReusesBlockID() throws {
        var review = try makeReview(changedBlockID: "urn:margin:comparison-block:old")
        let originalRevision = review.revision
        let newLeft = try ComparisonSnapshot(
            markdownBody: "prefix alpha beta\n",
            label: "Left"
        )
        let replacement = try ComparisonSnapshotPair(
            generation: review.snapshots.generation + 1,
            left: newLeft,
            right: review.snapshots.right
        )

        try review.refreshSnapshots(replacement, modified: later)

        XCTAssertEqual(review.revision, originalRevision)
        XCTAssertEqual(review.snapshots.generation, 1)
        XCTAssertNil(review.threads[0].target.changedBlockID)
        XCTAssertEqual(review.threads[0].target.left?.snapshotSHA256, newLeft.sha256)
        XCTAssertEqual(review.threads[0].target.left?.selector.quoteSelector?.exact, "alpha")
        XCTAssertEqual(review.threads[0].target.left?.state, .moved)
    }

    func testResolvedAndMovedAnchorsRequireExactStoredPositionWithoutGlobalSearch() throws {
        let original = try makeReview()
        for state in [ComparisonReviewAnchorState.resolved, .moved] {
            var tampered = original
            var anchor = try XCTUnwrap(tampered.threads[0].target.left)
            anchor.state = state
            anchor.selector.selector = anchor.selector.selector.map { selector in
                if case .position = selector {
                    return .position(TextPositionSelector(start: 6, end: 11))
                }
                return selector
            }
            tampered.threads[0].target.left = anchor
            XCTAssertThrowsError(try tampered.validate()) { error in
                XCTAssertEqual(
                    (error as? ComparisonError)?.code,
                    "INVALID_COMPARISON_REVIEW"
                )
                XCTAssertTrue(error.localizedDescription.contains("stored quote and position"))
            }
        }

        var declaredEvidence = original
        var ambiguous = try XCTUnwrap(declaredEvidence.threads[0].target.left)
        ambiguous.state = .ambiguous
        ambiguous.selector.selector = ambiguous.selector.selector.map { selector in
            if case .position = selector {
                return .position(TextPositionSelector(start: 6, end: 11))
            }
            return selector
        }
        declaredEvidence.threads[0].target.left = ambiguous
        XCTAssertNoThrow(try declaredEvidence.validate())
    }

    func testManyAnchorValidationMaterializesEachSnapshotProjectionOnce() throws {
        let prefixCount = 256_000
        let leftBody = String(repeating: "x", count: prefixCount) + "anchor\n"
        let left = try ComparisonSnapshot(markdownBody: leftBody, label: "Left")
        let right = try ComparisonSnapshot(markdownBody: "right\n", label: "Right")
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let anchor = try ComparisonReviewAnchor(
            snapshot: left,
            input: .range(
                start: prefixCount,
                end: prefixCount + 6,
                expectedExact: "anchor"
            )
        )
        let target = try ComparisonReviewTarget(side: .left, left: anchor)
        let threadCount = 128
        let threads = try (0..<threadCount).map { index -> ComparisonReviewThread in
            let id = "urn:thread:bounded:\(index)"
            let root = try ComparisonReviewComment(
                id: id,
                creator: actor,
                created: timestamp,
                modified: timestamp,
                body: MarginCommentBody(value: "Bounded review \(index).")
            )
            return try ComparisonReviewThread(
                id: id,
                target: target,
                statusModified: timestamp,
                statusModifiedBy: actor,
                comments: [root]
            )
        }
        let review = try ComparisonReview(
            id: "urn:review:many-bounded-anchors",
            created: timestamp,
            modified: timestamp,
            snapshots: pair,
            threads: threads
        )

        let metrics = try review.validationMetrics()
        XCTAssertEqual(metrics.snapshotProjectionsBuilt, 1)
        XCTAssertEqual(
            metrics.snapshotScalarsMaterialized,
            AnchorResolver.normalizedProjection(left.content).unicodeScalars.count
        )
        XCTAssertEqual(metrics.anchorsChecked, threadCount)
        XCTAssertEqual(metrics.exactScalarsCompared, threadCount * 6)
    }

    func testRefreshSearchHasDeterministicBudgetAndCancellationWithoutMutation() throws {
        let review = try makeReview(changedBlockID: "urn:margin:comparison-block:old")
        let replacement = try ComparisonSnapshotPair(
            generation: review.snapshots.generation + 1,
            left: ComparisonSnapshot(
                markdownBody: "a long prefix before alpha beta\n",
                label: "Left"
            ),
            right: review.snapshots.right
        )

        var budgeted = review
        XCTAssertThrowsError(try budgeted.refreshSnapshots(
            replacement,
            modified: later,
            maximumScalarComparisons: 1
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }
        XCTAssertEqual(budgeted, review)

        let cancellation = ComparisonCancellationToken()
        cancellation.cancel()
        var cancelled = review
        XCTAssertThrowsError(try cancelled.refreshSnapshots(
            replacement,
            modified: later,
            cancellation: cancellation
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "COMPARISON_CANCELLED")
        }
        XCTAssertEqual(cancelled, review)
    }

    func testFailedRefreshLeavesReviewCompletelyUnchanged() throws {
        var review = try makeReview(changedBlockID: "urn:margin:comparison-block:old")
        let original = review
        let replacement = try ComparisonSnapshotPair(
            generation: review.snapshots.generation + 1,
            left: ComparisonSnapshot(markdownBody: "new alpha beta\n", label: "Left"),
            right: review.snapshots.right
        )

        XCTAssertThrowsError(try review.refreshSnapshots(
            replacement,
            modified: "not-a-timestamp"
        ))
        XCTAssertEqual(review, original)
    }

    func testIdenticalContentRefreshStillChangesPairAndClearsBlockIdentity() throws {
        var review = try makeReview(changedBlockID: "urn:margin:comparison-block:old")
        let oldPairID = review.snapshots.id
        let replacement = try ComparisonSnapshotPair(
            generation: review.snapshots.generation + 1,
            left: review.snapshots.left,
            right: review.snapshots.right
        )

        try review.refreshSnapshots(replacement, modified: later)

        XCTAssertNotEqual(review.snapshots.id, oldPairID)
        XCTAssertNil(review.threads[0].target.changedBlockID)
    }

    func testGenerationAndRevisionOverflowFailWithoutMutationOrWrite() throws {
        let left = try ComparisonSnapshot(markdownBody: "left\n", label: "Left")
        let right = try ComparisonSnapshot(markdownBody: "right\n", label: "Right")
        let exhaustedPair = try ComparisonSnapshotPair(
            generation: Int.max,
            left: left,
            right: right
        )
        var exhaustedReview = try ComparisonReview(
            id: "urn:review:exhausted-generation",
            created: timestamp,
            modified: timestamp,
            snapshots: exhaustedPair
        )
        let original = exhaustedReview
        XCTAssertThrowsError(try exhaustedReview.refreshSnapshots(
            exhaustedPair,
            modified: later
        ))
        XCTAssertEqual(exhaustedReview, original)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("exhausted.margin-review.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ComparisonReviewCodec.encode(makeReview()))
                as? [String: Any]
        )
        object["revision"] = Int.max
        let encoded = try JSONSerialization.data(withJSONObject: object)
        try encoded.write(to: url)
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try ComparisonReviewStore().update(
            at: url,
            expectedRevision: Int.max,
            modified: later,
            { $0.display.showWhitespace = true }
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "INVALID_COMPARISON_REVIEW")
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAtomicStoreCASIdempotenceSnapshotImmutabilityAndExplicitRefresh() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.margin-review.json")
        let store = ComparisonReviewStore()
        let review = try makeReview()

        let created = try store.create(review, at: url)
        XCTAssertTrue(created.changed)
        XCTAssertFalse(try store.create(review, at: url).changed)
        XCTAssertEqual(try store.load(at: url), review)

        let changed = try store.update(
            at: url,
            expectedRevision: 0,
            modified: later
        ) { value in
            value.display.showWhitespace = true
        }
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.revision, 1)
        XCTAssertTrue(changed.review.display.showWhitespace)

        let idempotent = try store.update(
            at: url,
            expectedRevision: 1,
            modified: "2026-08-21T12:02:00Z"
        ) { value in
            value.display.showWhitespace = true
        }
        XCTAssertFalse(idempotent.changed)
        XCTAssertEqual(idempotent.revision, 1)
        XCTAssertThrowsError(try store.update(
            at: url,
            expectedRevision: 0,
            modified: later,
            { $0.display.contextLines = 7 }
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "REVISION_CONFLICT")
        }

        let replacement = try ComparisonSnapshotPair(
            generation: 1,
            left: ComparisonSnapshot(markdownBody: "prefix alpha beta\n", label: "Left"),
            right: review.snapshots.right
        )
        XCTAssertThrowsError(try store.update(
            at: url,
            expectedRevision: 1,
            modified: later,
            { try $0.refreshSnapshots(replacement, modified: later) }
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "IMMUTABLE_SNAPSHOTS")
        }
        let refreshed = try store.refresh(
            at: url,
            expectedRevision: 1,
            snapshots: replacement,
            modified: "2026-08-21T12:03:00Z"
        )
        XCTAssertEqual(refreshed.revision, 2)
        XCTAssertEqual(refreshed.review.snapshots.generation, 1)
    }

    func testConcurrentReviewWritersHaveExactlyOneCASWinner() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("concurrent.margin-review.json")
        let store = ComparisonReviewStore()
        _ = try store.create(makeReview(), at: url)

        let queue = DispatchQueue(label: "comparison-review-cas", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var successes = 0
        var conflicts = 0
        for contextLines in [5, 9] {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try store.update(
                        at: url,
                        expectedRevision: 0,
                        modified: self.later
                    ) { $0.display.contextLines = contextLines }
                    lock.lock(); successes += 1; lock.unlock()
                } catch ComparisonError.revisionConflict {
                    lock.lock(); conflicts += 1; lock.unlock()
                } catch {
                    XCTFail("Unexpected concurrent mutation error: \(error)")
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(conflicts, 1)
        XCTAssertEqual(try store.load(at: url).revision, 1)
    }

    func testReviewStoreRejectsSymlinkAndOversizedArtifact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real.margin-review.json")
        let link = directory.appendingPathComponent("link.margin-review.json")
        let store = ComparisonReviewStore()
        _ = try store.create(makeReview(), at: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try store.load(at: link)) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "SYMBOLIC_LINK")
        }

        let tiny = ComparisonLimits(maxArtifactBytes: 16)
        XCTAssertThrowsError(try ComparisonReviewCodec.decode(
            Data(repeating: 0x20, count: 17),
            limits: tiny
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "RESOURCE_LIMIT")
        }
    }

    func testReviewSymlinkSwapAfterTransactionReadCannotRedirectWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("destination.margin-review.json")
        let victimURL = directory.appendingPathComponent("victim.json")
        let review = try makeReview()
        let victim = Data("private material\n".utf8)
        try victim.write(to: victimURL)

        let strictDocumentStore = AtomicDocumentStore(beforeReplaceForTesting: {
            try? FileManager.default.removeItem(at: reviewURL)
            try? FileManager.default.createSymbolicLink(
                at: reviewURL,
                withDestinationURL: victimURL
            )
        })
        let store = ComparisonReviewStore(documentStore: strictDocumentStore)
        _ = try store.create(review, at: reviewURL)

        XCTAssertThrowsError(try store.update(
            at: reviewURL,
            expectedRevision: 0,
            modified: later,
            { $0.display.showWhitespace = true }
        )) { error in
            XCTAssertEqual((error as? ComparisonError)?.code, "SYMBOLIC_LINK")
        }
        XCTAssertEqual(try Data(contentsOf: victimURL), victim)
    }

    private func makeReview(changedBlockID: String? = nil) throws -> ComparisonReview {
        let left = try ComparisonSnapshot(
            markdownBody: "alpha beta\n",
            label: "Left",
            pathHint: "left.md",
            includeApplyPrecondition: true
        )
        let right = try ComparisonSnapshot(
            markdownBody: "alpha gamma\n",
            label: "Right",
            pathHint: "right.md",
            includeApplyPrecondition: true
        )
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        let anchor = try ComparisonReviewAnchor(
            snapshot: left,
            input: .quote(exact: "alpha")
        )
        let target = try ComparisonReviewTarget(
            side: .left,
            left: anchor,
            changedBlockID: changedBlockID
        )
        let root = try ComparisonReviewComment(
            id: "urn:thread:one",
            creator: actor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: "Review this phrase.", purpose: "commenting")
        )
        let thread = try ComparisonReviewThread(
            id: root.id,
            target: target,
            statusModified: timestamp,
            statusModifiedBy: actor,
            comments: [root]
        )
        return try ComparisonReview(
            id: "urn:comparison-review:one",
            created: timestamp,
            modified: timestamp,
            snapshots: pair,
            threads: [thread]
        )
    }

    private func makeRequest() throws -> ComparisonOpenRequest {
        let left = try ComparisonSnapshot(
            markdownBody: "left\n",
            label: "Left",
            pathHint: "left.md"
        )
        let right = try ComparisonSnapshot(
            markdownBody: "right\n",
            label: "Right",
            pathHint: "right.md"
        )
        return try ComparisonOpenRequest(
            requestID: "urn:comparison-request:one",
            created: timestamp,
            left: left,
            right: right
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-comparison-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
