import XCTest
@testable import MarginCore

final class ReviewSnapshotTests: XCTestCase {
    private let actor = MarginActor(id: "urn:agent:review", type: .software, name: "Review Agent")

    func testReviewGroupsThreadsIncludesUnicodeExcerptAndIsDeterministic() throws {
        let fixture = makeFixture("# Résumé\n\nBefore 👩🏽‍💻 café after.\n\n# End\n")
        defer { fixture.remove() }
        let comments = CommentService()
        let root = try comments.add(
            at: fixture.file,
            message: "Check the Unicode selection",
            creator: actor,
            anchor: .quote(exact: "👩🏽‍💻 café"),
            annotationID: "00000000-0000-4000-8000-000000000601"
        )
        _ = try comments.reply(
            at: fixture.file,
            parentID: root.annotation.id,
            message: "Nested context",
            creator: actor,
            annotationID: "00000000-0000-4000-8000-000000000602"
        )
        _ = try comments.add(
            at: fixture.file,
            message: "Document note",
            creator: actor,
            anchor: .document,
            annotationID: "00000000-0000-4000-8000-000000000603"
        )
        _ = try comments.resolve(at: fixture.file, id: "00000000-0000-4000-8000-000000000603", actor: actor)

        let service = ReviewService(limits: ReviewLimits(
            maxHeadings: 8,
            maxThreads: 8,
            maxCommentsPerThread: 8,
            maxBodyUnicodeScalars: 128,
            maxExcerptUnicodeScalars: 64,
            contextUnicodeScalars: 8,
            maxHeadingTitleUnicodeScalars: 64
        ))
        let first = try service.review(at: fixture.file)
        let second = try service.review(at: fixture.file)

        XCTAssertEqual(first.change, .snapshot)
        XCTAssertEqual(first.document.id, root.documentID)
        XCTAssertEqual(first.threads.statusOpenTotal, 1)
        XCTAssertEqual(first.threads.statusResolvedTotal, 1)
        XCTAssertEqual(first.threads.open.items.count, 1)
        XCTAssertEqual(first.threads.resolved.items.count, 1)
        let excerpt = try XCTUnwrap(first.threads.open.items.first?.anchor.excerpt)
        XCTAssertTrue(excerpt.text.contains("👩🏽‍💻 café"))
        XCTAssertEqual(first.threads.open.items.first?.comments.items.map(\.depth), [0, 1])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
    }

    func testSinceRevisionReturnsCompactNotModifiedAndResetStates() throws {
        let fixture = makeFixture("No comments yet.\n")
        defer { fixture.remove() }
        let service = ReviewService()

        let unchanged = try service.review(at: fixture.file, sinceRevision: 0)
        XCTAssertEqual(unchanged.change, .notModified)
        XCTAssertTrue(unchanged.truncation.detailsOmittedBecauseNotModified)
        XCTAssertTrue(unchanged.outline.items.isEmpty)

        let reset = try service.review(at: fixture.file, sinceRevision: 9)
        XCTAssertEqual(reset.change, .reset)
        XCTAssertFalse(reset.truncation.detailsOmittedBecauseNotModified)
    }

    func testReviewOutputIsBoundedForHugeDocumentsAndBodies() throws {
        let headings = (0..<2_000).map { "# Heading \($0) \(String(repeating: "x", count: 600))\n" }.joined()
        let fixture = makeFixture(headings)
        defer { fixture.remove() }
        let comments = CommentService()
        _ = try comments.add(
            at: fixture.file,
            message: String(repeating: "界", count: 200_000),
            creator: actor,
            anchor: .quote(exact: "Heading 0"),
            annotationID: "00000000-0000-4000-8000-000000000610"
        )

        let review = try ReviewService().review(at: fixture.file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(review)

        XCTAssertTrue(review.truncation.isTruncated)
        XCTAssertEqual(review.outline.included, ReviewLimits.default.maxHeadings)
        XCTAssertEqual(review.outline.total, 2_000)
        XCTAssertGreaterThan(review.truncation.headingsOmitted, 0)
        XCTAssertEqual(review.truncation.bodiesTruncated, 1)
        XCTAssertLessThan(encoded.count, 200_000, "Default review JSON must remain bounded independently of source size")
    }

    func testReviewCapsAdversarialMetadataOnUTF8Boundaries() throws {
        // Large enough to exceed every projection ceiling while keeping the
        // ordinary test loop fast. Multi-megabyte payload behavior is covered
        // separately by `testReviewOutputIsBoundedForHugeDocumentsAndBodies`.
        let huge = String(repeating: "界🙂", count: 2_000)
        let source = "# \(huge)\n\nBody.\n"
        let fixture = makeFixture(source)
        defer { fixture.remove() }

        let documentID = "urn:margin:document:\(huge)"
        let rootID = "urn:margin:comment:root:\(huge)"
        let replyID = "urn:margin:comment:reply:\(huge)"
        let oversizedActor = MarginActor(
            id: "urn:margin:actor:\(huge)",
            type: .software,
            name: huge
        )
        let root = MarginComment(
            id: rootID,
            motivation: "commenting",
            creator: oversizedActor,
            created: huge,
            modified: huge,
            body: MarginCommentBody(value: huge, purpose: "commenting"),
            target: .resource(documentID),
            status: .open,
            statusModified: huge,
            statusModifiedBy: oversizedActor
        )
        let reply = MarginComment(
            id: replyID,
            motivation: "replying",
            creator: oversizedActor,
            created: huge,
            modified: huge,
            body: MarginCommentBody(value: huge),
            target: .resource(rootID)
        )
        let envelope = EmbeddedCommentEnvelope(
            documentID: documentID,
            modified: huge,
            items: [root, reply],
            revision: 1
        )
        let encodedDocument = try EmbeddedCommentCodec().encode(
            bodyData: Data(source.utf8),
            envelope: envelope
        )
        try encodedDocument.write(to: fixture.file)

        let requestedLimits = ReviewLimits(
            maxHeadings: .max,
            maxThreads: .max,
            maxCommentsPerThread: .max,
            maxBodyUnicodeScalars: .max,
            maxExcerptUnicodeScalars: .max,
            contextUnicodeScalars: .max,
            maxHeadingTitleUnicodeScalars: .max
        )
        XCTAssertEqual(requestedLimits.maxHeadings, ReviewProjectionBounds.maximumHeadings)
        XCTAssertEqual(requestedLimits.maxThreads, ReviewProjectionBounds.maximumThreads)
        XCTAssertEqual(
            requestedLimits.maxCommentsPerThread,
            ReviewProjectionBounds.maximumCommentsPerThread
        )

        let review = try ReviewService(limits: requestedLimits).review(at: fixture.file)
        let thread = try XCTUnwrap(review.threads.open.items.first)
        let projectedRoot = try XCTUnwrap(thread.comments.items.first { $0.parentID == nil })
        let projectedReply = try XCTUnwrap(thread.comments.items.first { $0.parentID != nil })
        let heading = try XCTUnwrap(review.outline.items.first)

        XCTAssertLessThanOrEqual(
            try XCTUnwrap(review.document.id).utf8.count,
            ReviewProjectionBounds.identifierUTF8Bytes
        )
        XCTAssertLessThanOrEqual(thread.id.utf8.count, ReviewProjectionBounds.identifierUTF8Bytes)
        XCTAssertLessThanOrEqual(projectedRoot.id.utf8.count, ReviewProjectionBounds.identifierUTF8Bytes)
        XCTAssertLessThanOrEqual(projectedReply.id.utf8.count, ReviewProjectionBounds.identifierUTF8Bytes)
        let projectedParentID = try XCTUnwrap(projectedReply.parentID)
        XCTAssertLessThanOrEqual(
            projectedParentID.utf8.count,
            ReviewProjectionBounds.identifierUTF8Bytes
        )
        XCTAssertEqual(thread.id, projectedRoot.id)
        XCTAssertEqual(projectedParentID, projectedRoot.id)
        XCTAssertTrue(projectedRoot.id.contains("#sha256:"))
        XCTAssertTrue(projectedReply.id.contains("#sha256:"))

        for comment in [projectedRoot, projectedReply] {
            XCTAssertLessThanOrEqual(
                comment.creator.id.utf8.count,
                ReviewProjectionBounds.identifierUTF8Bytes
            )
            XCTAssertLessThanOrEqual(
                comment.creator.name.utf8.count,
                ReviewProjectionBounds.actorNameUTF8Bytes
            )
            XCTAssertLessThanOrEqual(
                comment.created.utf8.count,
                ReviewProjectionBounds.timestampUTF8Bytes
            )
            XCTAssertLessThanOrEqual(
                comment.modified.utf8.count,
                ReviewProjectionBounds.timestampUTF8Bytes
            )
            XCTAssertLessThanOrEqual(comment.body.utf8.count, ReviewProjectionBounds.bodyUTF8Bytes)
            XCTAssertTrue(comment.bodyTruncated)
        }
        XCTAssertLessThanOrEqual(heading.id.utf8.count, ReviewProjectionBounds.identifierUTF8Bytes)
        XCTAssertLessThanOrEqual(
            heading.title.utf8.count,
            ReviewProjectionBounds.headingTitleUTF8Bytes
        )
        XCTAssertTrue(heading.titleTruncated)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedReview = try encoder.encode(review)
        XCTAssertLessThan(encodedReview.count, 40_000)
    }

    func testMovedAnchorAppearsInNeedsAttentionWithContext() throws {
        let fixture = makeFixture("prefix unique target suffix\n")
        defer { fixture.remove() }
        let comments = CommentService()
        _ = try comments.add(
            at: fixture.file,
            message: "Track movement",
            creator: actor,
            anchor: .quote(exact: "unique target"),
            annotationID: "00000000-0000-4000-8000-000000000620"
        )
        let codec = EmbeddedCommentCodec()
        let decoded = try codec.decode(Data(contentsOf: fixture.file))
        var envelope = try XCTUnwrap(decoded.envelope)
        envelope.revision += 1
        let movedBody = Data("new material prefix unique target suffix\n".utf8)
        try codec.encode(bodyData: movedBody, envelope: envelope).write(to: fixture.file)

        let review = try ReviewService().review(at: fixture.file)
        XCTAssertEqual(review.threads.needsAttentionTotal, 1)
        XCTAssertEqual(review.threads.needsAttention.items.first?.anchor.state, .moved)
        XCTAssertTrue(review.threads.needsAttention.items.first?.anchor.excerpt?.text.contains("unique target") == true)
    }

    private func makeFixture(_ text: String) -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginReviewTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("review.md")
        try! Data(text.utf8).write(to: file)
        return Fixture(directory: directory, file: file)
    }
}

private struct Fixture {
    let directory: URL
    let file: URL
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
