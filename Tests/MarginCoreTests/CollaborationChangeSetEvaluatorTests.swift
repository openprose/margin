import Foundation
import XCTest
@testable import MarginCore

final class CollaborationChangeSetEvaluatorTests: XCTestCase {
    func testSuggestionInsertionPreservesCreatorAndAcceptanceEditsSourceWithProvenance() throws {
        let fixture = try EvaluatorFixture(body: "# Draft\n\nA fast editor.\n")
        defer { fixture.remove() }
        let actor = try CollaborationActor(
            id: "urn:agent:writer",
            type: .software,
            name: "Writer Agent"
        )
        let initial = try fixture.cursor()
        let range = try scalarRange(of: "fast", in: "# Draft\n\nA fast editor.\n")
        let suggestion = try CollaborationContributionFactory.suggestion(
            actor: actor,
            path: ".",
            range: range,
            message: "Use a stronger adjective.",
            expectedText: "fast",
            replacementText: "lightning-fast",
            baseCursor: initial,
            created: fixture.timestamp,
            id: "urn:suggestion:speed"
        )
        let add = try fixture.changeSet(
            cursor: initial,
            actor: actor,
            identity: "add-suggestion",
            operations: [.contribution(
                id: "urn:operation:add-suggestion",
                CollaborationContributionOperation(contribution: suggestion)
            )]
        )
        let engine = fixture.engine()
        let evaluator = CollaborationChangeSetEvaluator(reader: engine)
        let stageStore = CollaborationStageStore(stateDirectory: fixture.state)
        XCTAssertEqual(try stageStore.stage(add).disposition, .created)
        let addImages = try evaluator.evaluate(add)
        XCTAssertEqual(addImages.count, 1)
        _ = try engine.submit(add, evaluatedMutations: addImages)

        var decoded = try fixture.decoded()
        XCTAssertEqual(decoded.body, "# Draft\n\nA fast editor.\n")
        XCTAssertEqual(decoded.envelope?.revision, 1)
        XCTAssertEqual(decoded.envelope?.items.first?.creator, actor.marginActor)
        XCTAssertEqual(decoded.envelope?.items.first?.extensions["margin:kind"], .string("suggestion"))

        let replayImages = try evaluator.evaluate(add)
        XCTAssertEqual(try engine.submit(add, evaluatedMutations: replayImages).disposition, .alreadyApplied)
        try stageStore.remove(stageID: add.stageID, root: fixture.root)
        try stageStore.remove(stageID: add.stageID, root: fixture.root)
        XCTAssertTrue(try stageStore.list(root: fixture.root).isEmpty)

        let acceptanceBase = try fixture.cursor()
        let acceptance = try fixture.changeSet(
            cursor: acceptanceBase,
            actor: actor,
            identity: "accept-suggestion",
            operations: [.suggestionDisposition(
                id: "urn:operation:accept-suggestion",
                CollaborationSuggestionDispositionOperation(
                    path: ".",
                    contributionID: suggestion.id,
                    disposition: .accept
                )
            )]
        )
        let acceptedImages = try evaluator.evaluate(acceptance)
        _ = try engine.submit(acceptance, evaluatedMutations: acceptedImages)
        decoded = try fixture.decoded()
        XCTAssertEqual(decoded.body, "# Draft\n\nA lightning-fast editor.\n")
        XCTAssertEqual(decoded.envelope?.revision, 2)
        let annotation = try XCTUnwrap(decoded.envelope?.items.first)
        guard case .object(let metadata)? = annotation.extensions["margin:suggestion"] else {
            return XCTFail("Missing suggestion metadata")
        }
        XCTAssertEqual(metadata["status"], .string("accepted"))
        XCTAssertEqual(metadata["acceptedAt"], .string(fixture.timestamp))
        guard case .object(let acceptedBy)? = metadata["acceptedBy"] else {
            return XCTFail("Missing acceptance actor")
        }
        XCTAssertEqual(acceptedBy["name"], .string("Writer Agent"))
        XCTAssertEqual(try CommentService().list(at: fixture.file).comments.first?.anchor?.state, .anchored)
    }

    func testStaleSuggestionCanBeRejectedWithoutChangingLogicalSource() throws {
        let fixture = try EvaluatorFixture(body: "Alpha beta gamma\n")
        defer { fixture.remove() }
        let author = try CollaborationActor(id: "urn:agent:author", type: .person, name: "Author")
        let initial = try fixture.cursor()
        let suggestion = try CollaborationContributionFactory.suggestion(
            actor: author,
            path: ".",
            range: try scalarRange(of: "beta", in: "Alpha beta gamma\n"),
            message: "Try delta.",
            expectedText: "beta",
            replacementText: "delta",
            baseCursor: initial,
            created: fixture.timestamp,
            id: "urn:suggestion:stale"
        )
        let add = try fixture.changeSet(
            cursor: initial,
            actor: author,
            identity: "stale-add",
            operations: [.contribution(
                id: "urn:operation:stale-add",
                CollaborationContributionOperation(contribution: suggestion)
            )]
        )
        let engine = fixture.engine()
        let evaluator = CollaborationChangeSetEvaluator(reader: engine)
        _ = try engine.submit(add, evaluatedMutations: evaluator.evaluate(add))

        var stale = try fixture.decoded()
        let externallyEditedBody = "Preface. Alpha beta gamma\n"
        let externallyEdited = try EmbeddedCommentCodec().encode(
            bodyData: Data(externallyEditedBody.utf8),
            envelope: stale.envelope
        )
        try externallyEdited.write(to: fixture.file)
        stale = try fixture.decoded()
        let bodyBefore = stale.bodyData

        let reviewer = try CollaborationActor(id: "urn:agent:reviewer", type: .person, name: "Reviewer")
        let rejectBase = try fixture.cursor()
        XCTAssertNotEqual(rejectBase.files[0].contentSha256, initial.files[0].contentSha256)
        let reject = try fixture.changeSet(
            cursor: rejectBase,
            actor: reviewer,
            identity: "stale-reject",
            operations: [.suggestionDisposition(
                id: "urn:operation:stale-reject",
                CollaborationSuggestionDispositionOperation(
                    path: ".",
                    contributionID: suggestion.id,
                    disposition: .reject
                )
            )]
        )
        _ = try engine.submit(reject, evaluatedMutations: evaluator.evaluate(reject))
        let decoded = try fixture.decoded()
        XCTAssertEqual(decoded.bodyData, bodyBefore)
        guard case .object(let metadata)? = decoded.envelope?.items.first?.extensions["margin:suggestion"] else {
            return XCTFail("Missing suggestion metadata")
        }
        XCTAssertEqual(metadata["status"], .string("rejected"))
        guard case .object(let rejectedBy)? = metadata["rejectedBy"] else {
            return XCTFail("Missing rejection provenance")
        }
        XCTAssertEqual(rejectedBy["id"], .string(reviewer.id))
    }

    func testSemanticReplayRejectsSameIDWithChangedContentOrProvenance() throws {
        let fixture = try EvaluatorFixture(body: "Stable body.\n")
        defer { fixture.remove() }
        let actor = try CollaborationActor(id: "urn:agent:replay", type: .software, name: "Replay Agent")
        let cursor = try fixture.cursor()
        let contribution = try CollaborationContribution(
            id: "urn:comment:replay",
            actorID: actor.id,
            created: fixture.timestamp,
            body: "Original observation",
            target: CollaborationTarget(path: "."),
            details: .comment(CollaborationCommentDetails())
        )
        let changeSet = try fixture.changeSet(
            cursor: cursor,
            actor: actor,
            identity: "replay-conflict",
            operations: [.contribution(
                id: "urn:operation:replay-conflict",
                CollaborationContributionOperation(contribution: contribution)
            )]
        )
        let engine = fixture.engine()
        let evaluator = CollaborationChangeSetEvaluator(reader: engine)
        _ = try engine.submit(changeSet, evaluatedMutations: evaluator.evaluate(changeSet))

        var decoded = try fixture.decoded()
        decoded.envelope?.items[0].body.value = "Externally changed observation"
        let conflicted = try EmbeddedCommentCodec().encode(
            bodyData: decoded.bodyData,
            envelope: decoded.envelope
        )
        try conflicted.write(to: fixture.file)
        XCTAssertThrowsError(try evaluator.evaluate(changeSet)) { error in
            guard case CollaborationError.preconditionFailed = error else {
                return XCTFail("Expected old-base failure, got \(error)")
            }
        }
    }

    func testEveryTypedContributionRejectsSameIDWithChangedImmutablePayload() throws {
        let kinds = CollaborationContributionKind.allCases
        for kind in kinds {
            let fixture = try EvaluatorFixture(body: "Alpha beta gamma.\n")
            defer { fixture.remove() }
            let actor = try CollaborationActor(
                id: "urn:agent:collision",
                type: .software,
                name: "Collision Agent"
            )
            let cursor = try fixture.cursor()
            let cursorToken = try cursor.token()
            let details: (CollaborationContributionDetails, CollaborationContributionDetails)
            switch kind {
            case .comment:
                details = (
                    .comment(CollaborationCommentDetails()),
                    .comment(CollaborationCommentDetails())
                )
            case .question:
                details = (
                    .question(CollaborationQuestionDetails()),
                    .question(CollaborationQuestionDetails(answerContributionID: "urn:answer:different"))
                )
            case .issue:
                details = (
                    .issue(CollaborationIssueDetails(state: .open)),
                    .issue(CollaborationIssueDetails(state: .resolved))
                )
            case .decision:
                details = (
                    .decision(CollaborationDecisionDetails(rationale: "First rationale")),
                    .decision(CollaborationDecisionDetails(rationale: "Different rationale"))
                )
            case .task:
                details = (
                    .task(CollaborationTaskDetails(assignee: actor.id, priority: .normal)),
                    .task(CollaborationTaskDetails(assignee: "urn:agent:other", priority: .urgent))
                )
            case .suggestion:
                details = (
                    .suggestion(CollaborationSuggestionDetails(
                        expectedText: "beta",
                        replacementText: "delta",
                        baseContentSha256: cursor.files[0].contentSha256
                    )),
                    .suggestion(CollaborationSuggestionDetails(
                        expectedText: "beta",
                        replacementText: "epsilon",
                        baseContentSha256: cursor.files[0].contentSha256
                    ))
                )
            case .handoff:
                details = (
                    .handoff(CollaborationHandoffDetails(
                        startingCursor: cursorToken,
                        touchedAnnotationIDs: ["urn:annotation:first"]
                    )),
                    .handoff(CollaborationHandoffDetails(
                        startingCursor: cursorToken,
                        touchedAnnotationIDs: ["urn:annotation:different"]
                    ))
                )
            case .approval:
                details = (
                    .approval(CollaborationApprovalDetails(state: .requested)),
                    .approval(CollaborationApprovalDetails(state: .approved))
                )
            }
            let target = try CollaborationTarget(
                path: ".",
                range: try scalarRange(of: "beta", in: "Alpha beta gamma.\n")
            )
            func contribution(
                _ value: CollaborationContributionDetails,
                alternateAudience: Bool = false
            ) throws -> CollaborationContribution {
                try CollaborationContribution(
                    id: "urn:contribution:collision:\(kind.rawValue)",
                    actorID: actor.id,
                    created: fixture.timestamp,
                    body: "Identical visible message",
                    target: target,
                    audience: kind == .task
                        ? [alternateAudience ? "urn:audience:different" : "urn:audience:one"]
                        : [],
                    details: value,
                    extensions: kind == .comment && alternateAudience
                        ? ["example:variant": .string("different")]
                        : [:]
                )
            }
            let firstContribution = try contribution(details.0)
            let secondContribution = try contribution(details.1, alternateAudience: true)
            let first = try fixture.changeSet(
                cursor: cursor,
                actor: actor,
                identity: "typed-collision-\(kind.rawValue)",
                operations: [.contribution(
                    id: "urn:operation:typed-collision:\(kind.rawValue)",
                    CollaborationContributionOperation(contribution: firstContribution)
                )]
            )
            let conflicting = try fixture.changeSet(
                cursor: cursor,
                actor: actor,
                identity: "typed-collision-\(kind.rawValue)",
                operations: [.contribution(
                    id: "urn:operation:typed-collision:\(kind.rawValue)",
                    CollaborationContributionOperation(contribution: secondContribution)
                )]
            )
            let engine = fixture.engine()
            let evaluator = CollaborationChangeSetEvaluator(reader: engine)
            _ = try engine.submit(first, evaluatedMutations: evaluator.evaluate(first))
            let bytesBefore = try Data(contentsOf: fixture.file)
            XCTAssertThrowsError(try evaluator.evaluate(conflicting), "kind=\(kind.rawValue)")
            XCTAssertEqual(try Data(contentsOf: fixture.file), bytesBefore, "kind=\(kind.rawValue)")
        }
    }

    func testTwoSemanticOperationsOnOneFileAdvanceRevisionOnce() throws {
        let fixture = try EvaluatorFixture(body: "One two three.\n")
        defer { fixture.remove() }
        let actor = try CollaborationActor(id: "urn:agent:multi", type: .software, name: "Multi Agent")
        let cursor = try fixture.cursor()
        let first = try CollaborationContribution(
            id: "urn:comment:first",
            actorID: actor.id,
            created: fixture.timestamp,
            body: "First note",
            target: CollaborationTarget(path: ".", range: try scalarRange(of: "One", in: "One two three.\n")),
            details: .comment(CollaborationCommentDetails())
        )
        let second = try CollaborationContribution(
            id: "urn:task:second",
            actorID: actor.id,
            created: fixture.timestamp,
            body: "Follow up",
            target: CollaborationTarget(path: ".", range: try scalarRange(of: "three", in: "One two three.\n")),
            details: .task(CollaborationTaskDetails(assignee: actor.id, priority: .high))
        )
        let changeSet = try fixture.changeSet(
            cursor: cursor,
            actor: actor,
            identity: "two-operations",
            operations: [
                .contribution(id: "urn:operation:first", CollaborationContributionOperation(contribution: first)),
                .contribution(id: "urn:operation:second", CollaborationContributionOperation(contribution: second)),
            ]
        )
        let engine = fixture.engine()
        let images = try CollaborationChangeSetEvaluator(reader: engine).evaluate(changeSet)
        XCTAssertEqual(images.count, 1)
        _ = try engine.submit(changeSet, evaluatedMutations: images)
        let decoded = try fixture.decoded()
        XCTAssertEqual(decoded.envelope?.revision, 1)
        XCTAssertEqual(decoded.envelope?.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(decoded.body, "One two three.\n")
    }

    func testStatusOperationOnReplyResolvesThreadRoot() throws {
        let fixture = try EvaluatorFixture(body: "Review me.\n")
        defer { fixture.remove() }
        let actor = MarginActor(id: "urn:agent:commenter", type: .person, name: "Commenter")
        let rootReceipt = try CommentService().add(
            at: fixture.file,
            message: "Root",
            creator: actor,
            anchor: .quote(exact: "Review"),
            annotationID: "urn:comment:root"
        )
        let reply = try CommentService().reply(
            at: fixture.file,
            parentID: rootReceipt.annotation.id,
            message: "Reply",
            creator: actor,
            annotationID: "urn:comment:reply"
        )
        let cursor = try fixture.cursor()
        let collaborationActor = try CollaborationActor(actor)
        let changeSet = try fixture.changeSet(
            cursor: cursor,
            actor: collaborationActor,
            identity: "resolve-reply",
            operations: [.status(
                id: "urn:operation:resolve-reply",
                CollaborationStatusOperation(path: ".", annotationID: reply.annotation.id, status: .resolved)
            )]
        )
        let engine = fixture.engine()
        _ = try engine.submit(
            changeSet,
            evaluatedMutations: CollaborationChangeSetEvaluator(reader: engine).evaluate(changeSet)
        )
        let snapshot = try CommentService().list(at: fixture.file)
        XCTAssertTrue(snapshot.comments.allSatisfy { $0.threadStatus == .resolved })
        XCTAssertEqual(snapshot.revision, cursor.files[0].annotationRevision + 1)
    }

    func testMixedSemanticMultiFileChangeSetProducesOneImagePerPath() throws {
        let directory = try temporaryDirectory(prefix: "margin-evaluator-multifile")
        let state = try temporaryDirectory(prefix: "margin-evaluator-multifile-state")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: state)
        }
        try Data("First file.\n".utf8).write(to: directory.appendingPathComponent("first.md"))
        try Data("Second file.\n".utf8).write(to: directory.appendingPathComponent("second.md"))
        let root = try CollaborationRootResolver().directory(at: directory)
        let cursor = try CollaborationCursorService().capture(root: root, paths: ["first.md", "second.md"])
        let actor = try CollaborationActor(id: "urn:agent:cross-file", type: .software, name: "Cross-file Agent")
        let question = try CollaborationContribution(
            id: "urn:question:first",
            actorID: actor.id,
            created: "2026-08-16T12:00:00Z",
            body: "Why this opening?",
            target: CollaborationTarget(path: "first.md", range: try scalarRange(of: "First", in: "First file.\n")),
            details: .question(CollaborationQuestionDetails())
        )
        let task = try CollaborationContribution(
            id: "urn:task:second",
            actorID: actor.id,
            created: "2026-08-16T12:00:00Z",
            body: "Revise this sentence.",
            target: CollaborationTarget(path: "second.md", range: try scalarRange(of: "Second", in: "Second file.\n")),
            details: .task(CollaborationTaskDetails(assignee: actor.id))
        )
        let changeSet = try CollaborationChangeSet(
            id: "urn:changeset:cross-file",
            root: root,
            baseCursor: cursor,
            actor: actor,
            requestID: "urn:request:cross-file",
            stageID: "urn:stage:cross-file",
            created: "2026-08-16T12:00:00Z",
            operations: [
                .contribution(id: "urn:operation:question", CollaborationContributionOperation(contribution: question)),
                .contribution(id: "urn:operation:task", CollaborationContributionOperation(contribution: task)),
            ]
        )
        let engine = CollaborationTransactionEngine(stateDirectory: state)
        let images = try CollaborationChangeSetEvaluator(reader: engine).evaluate(changeSet)
        XCTAssertEqual(images.map(\.path), ["first.md", "second.md"])
        _ = try engine.submit(changeSet, evaluatedMutations: images)
        XCTAssertEqual(try CommentService().list(at: directory.appendingPathComponent("first.md")).revision, 1)
        XCTAssertEqual(try CommentService().list(at: directory.appendingPathComponent("second.md")).revision, 1)
    }

    private func scalarRange(of needle: String, in body: String) throws -> UnicodeScalarRange {
        guard let range = body.range(of: needle),
              let scalarStart = range.lowerBound.samePosition(in: body.unicodeScalars),
              let scalarEnd = range.upperBound.samePosition(in: body.unicodeScalars) else {
            throw CollaborationError.invalidContribution("Test range is not scalar-aligned.")
        }
        return UnicodeScalarRange(
            start: body.unicodeScalars.distance(from: body.unicodeScalars.startIndex, to: scalarStart),
            end: body.unicodeScalars.distance(from: body.unicodeScalars.startIndex, to: scalarEnd)
        )
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class EvaluatorFixture {
    let directory: URL
    let state: URL
    let file: URL
    let root: CollaborationRoot
    let timestamp = "2026-08-16T12:00:00Z"

    init(body: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-evaluator-\(UUID().uuidString)", isDirectory: true)
        state = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-evaluator-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("document.md")
        try Data(body.utf8).write(to: file)
        root = try CollaborationRootResolver().document(at: file)
    }

    func cursor() throws -> CollaborationCursor {
        try CollaborationCursorService().capture(root: root)
    }

    func engine() -> CollaborationTransactionEngine {
        CollaborationTransactionEngine(stateDirectory: state)
    }

    func decoded() throws -> EmbeddedCommentDocument {
        try EmbeddedCommentCodec().decode(Data(contentsOf: file))
    }

    func changeSet(
        cursor: CollaborationCursor,
        actor: CollaborationActor,
        identity: String,
        operations: [CollaborationOperation]
    ) throws -> CollaborationChangeSet {
        try CollaborationChangeSet(
            id: "urn:changeset:\(identity)",
            root: root,
            baseCursor: cursor,
            actor: actor,
            requestID: "urn:request:\(identity)",
            stageID: "urn:stage:\(identity)",
            created: timestamp,
            operations: operations
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: state)
    }
}
