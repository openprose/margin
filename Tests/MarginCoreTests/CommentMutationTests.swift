import XCTest
@testable import MarginCore

final class CommentMutationTests: XCTestCase {
    private let human = MarginActor(id: "urn:person:alice", type: .person, name: "Alice")
    private let agent = MarginActor(id: "urn:agent:reviewer", type: .software, name: "Reviewer")

    func testEditPreservesIdentityThreadAndUnicodeWhileReturningUndo() throws {
        let fixture = makeFixture("One café 👩🏽‍💻 passage.\n")
        defer { fixture.remove() }
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "Original",
            creator: human,
            anchor: .quote(exact: "café 👩🏽‍💻"),
            annotationID: "00000000-0000-4000-8000-000000000501"
        )
        let reply = try service.reply(
            at: fixture.file,
            parentID: root.annotation.id,
            message: "First reply",
            creator: agent,
            annotationID: "00000000-0000-4000-8000-000000000502"
        )

        let edited = try service.edit(
            at: fixture.file,
            id: reply.annotation.id,
            message: "Révisé — ✅",
            editor: human,
            preconditions: CommentMutationPreconditions(revision: reply.revision)
        )

        XCTAssertTrue(edited.changed)
        XCTAssertEqual(edited.rootID, root.annotation.id)
        XCTAssertEqual(edited.annotation.id, reply.annotation.id)
        XCTAssertEqual(edited.annotation.creator, reply.annotation.creator)
        XCTAssertEqual(edited.annotation.created, reply.annotation.created)
        XCTAssertEqual(edited.annotation.target, reply.annotation.target)
        XCTAssertEqual(edited.annotation.body.value, "Révisé — ✅")
        XCTAssertEqual(edited.previousAnnotation?.body.value, "First reply")
        XCTAssertEqual(edited.undo.message, "First reply")
        XCTAssertEqual(edited.undo.ifRevision, edited.revision)
        XCTAssertEqual(
            edited.annotation.extensions["margin:lastModifiedBy"],
            .object(["id": .string(human.id), "type": .string(human.type.rawValue), "name": .string(human.name)])
        )

        let noChange = try service.edit(
            at: fixture.file,
            id: reply.annotation.id,
            message: "Révisé — ✅",
            editor: agent,
            preconditions: CommentMutationPreconditions(revision: edited.revision)
        )
        XCTAssertFalse(noChange.changed)
        XCTAssertEqual(noChange.revision, edited.revision)

        XCTAssertThrowsError(try service.edit(
            at: fixture.file,
            id: reply.annotation.id,
            message: "Stale",
            editor: agent,
            preconditions: CommentMutationPreconditions(revision: reply.revision)
        )) { error in
            guard case CommentProtocolError.revisionConflict = error else {
                return XCTFail("Expected revisionConflict, got \(error)")
            }
        }
        XCTAssertEqual(try decodedBody(at: fixture.file), fixture.body)
    }

    func testDeleteRequiresExplicitSubtreeAndNeverOrphansReplies() throws {
        let fixture = makeFixture("Root target.\n")
        defer { fixture.remove() }
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "Root",
            creator: human,
            anchor: .quote(exact: "target"),
            annotationID: "00000000-0000-4000-8000-000000000510"
        )
        let reply = try service.reply(
            at: fixture.file,
            parentID: root.annotation.id,
            message: "Reply",
            creator: agent,
            annotationID: "00000000-0000-4000-8000-000000000511"
        )
        let nested = try service.reply(
            at: fixture.file,
            parentID: reply.annotation.id,
            message: "Nested",
            creator: human,
            annotationID: "00000000-0000-4000-8000-000000000512"
        )
        let codec = EmbeddedCommentCodec()
        let decodedBeforeDeletion = try codec.decode(Data(contentsOf: fixture.file))
        var extendedEnvelope = try XCTUnwrap(decodedBeforeDeletion.envelope)
        extendedEnvelope.extensions["example:reviewMode"] = .string("precise")
        try codec.encode(bodyData: decodedBeforeDeletion.bodyData, envelope: extendedEnvelope)
            .write(to: fixture.file)

        XCTAssertThrowsError(try service.delete(at: fixture.file, id: reply.annotation.id)) { error in
            guard case CommentProtocolError.commentHasReplies(let id, let count) = error else {
                return XCTFail("Expected commentHasReplies, got \(error)")
            }
            XCTAssertEqual(id, reply.annotation.id)
            XCTAssertEqual(count, 1)
            XCTAssertEqual((error as? CommentProtocolError)?.code, "COMMENT_HAS_REPLIES")
        }

        let removedLeaf = try service.delete(
            at: fixture.file,
            id: nested.annotation.id,
            preconditions: CommentMutationPreconditions(revision: nested.revision)
        )
        XCTAssertEqual(removedLeaf.deletedIDs, [nested.annotation.id])
        XCTAssertEqual(removedLeaf.undo.records.first?.annotation.body.value, "Nested")
        XCTAssertEqual(try service.list(at: fixture.file).comments.count, 2)

        let removedTree = try service.delete(
            at: fixture.file,
            id: root.annotation.id,
            subtree: true,
            preconditions: CommentMutationPreconditions(revision: removedLeaf.revision)
        )
        XCTAssertEqual(removedTree.deletedCount, 2)
        XCTAssertEqual(Set(removedTree.deletedIDs), Set([root.annotation.id, reply.annotation.id]))
        XCTAssertEqual(removedTree.undo.records.map(\.index), [0, 1])
        XCTAssertFalse(removedTree.undo.expectedDocumentSha256.isEmpty)
        XCTAssertEqual(removedTree.undo.envelopeTemplate?.extensions["example:reviewMode"], .string("precise"))
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.body)
        XCTAssertEqual(try service.list(at: fixture.file).comments.count, 0)

        let restored = try service.restoreDeletion(at: fixture.file, undo: removedTree.undo)
        XCTAssertEqual(restored.revision, removedTree.revision + 1)
        XCTAssertEqual(restored.restoredIDs, [root.annotation.id, reply.annotation.id])
        XCTAssertEqual(restored.annotations, removedTree.undo.records.map(\.annotation))
        let restoredSnapshot = try service.list(at: fixture.file)
        XCTAssertEqual(restoredSnapshot.comments.map { $0.annotation.id }, [root.annotation.id, reply.annotation.id])
        XCTAssertEqual(try decodedBody(at: fixture.file), fixture.body)
        XCTAssertEqual(
            try codec.decode(Data(contentsOf: fixture.file)).envelope?.extensions["example:reviewMode"],
            .string("precise")
        )

        XCTAssertThrowsError(try service.restoreDeletion(at: fixture.file, undo: removedTree.undo)) { error in
            guard case CommentProtocolError.undoConflict = error else {
                return XCTFail("Expected undoConflict after the restore consumed its token, got \(error)")
            }
        }
    }

    func testRestoreDeletionFailsClosedAfterInterveningWrite() throws {
        let fixture = makeFixture("Intervening target.\n")
        defer { fixture.remove() }
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "Root",
            creator: human,
            anchor: .document,
            annotationID: "00000000-0000-4000-8000-000000000540"
        )
        let reply = try service.reply(
            at: fixture.file,
            parentID: root.annotation.id,
            message: "Reply",
            creator: agent,
            annotationID: "00000000-0000-4000-8000-000000000541"
        )
        let deleted = try service.delete(
            at: fixture.file,
            id: reply.annotation.id,
            preconditions: CommentMutationPreconditions(revision: reply.revision)
        )
        let edited = try service.edit(
            at: fixture.file,
            id: root.annotation.id,
            message: "An intervening edit",
            editor: agent,
            preconditions: CommentMutationPreconditions(revision: deleted.revision)
        )

        XCTAssertThrowsError(try service.restoreDeletion(at: fixture.file, undo: deleted.undo)) { error in
            guard case CommentProtocolError.undoConflict = error else {
                return XCTFail("Expected undoConflict, got \(error)")
            }
            XCTAssertEqual((error as? CommentProtocolError)?.code, "UNDO_CONFLICT")
            XCTAssertEqual((error as? CommentProtocolError)?.suggestedExitCode, 75)
        }
        let snapshot = try service.list(at: fixture.file)
        XCTAssertEqual(snapshot.revision, edited.revision)
        XCTAssertEqual(snapshot.comments.map { $0.annotation.id }, [root.annotation.id])
        XCTAssertEqual(try decodedBody(at: fixture.file), fixture.body)
    }

    func testRestoreDeletionValidatesParentsAndLeavesFileUntouchedOnFailure() throws {
        let fixture = makeFixture("Validate undo.\n")
        defer { fixture.remove() }
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "Root",
            creator: human,
            anchor: .document,
            annotationID: "00000000-0000-4000-8000-000000000550"
        )
        let reply = try service.reply(
            at: fixture.file,
            parentID: root.annotation.id,
            message: "Reply",
            creator: agent,
            annotationID: "00000000-0000-4000-8000-000000000551"
        )
        let deleted = try service.delete(at: fixture.file, id: reply.annotation.id)
        let before = try Data(contentsOf: fixture.file)
        var invalidUndo = deleted.undo
        invalidUndo.records[0].annotation.target = .resource(reply.annotation.id)

        XCTAssertThrowsError(try service.restoreDeletion(at: fixture.file, undo: invalidUndo)) { error in
            guard case CommentProtocolError.invalidEnvelope = error else {
                return XCTFail("Expected invalidEnvelope for a self-parent cycle, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), before)
        XCTAssertEqual(try service.list(at: fixture.file).revision, deleted.revision)
    }

    func testConcurrentCASAllowsOnlyOneEdit() throws {
        let fixture = makeFixture("Concurrent target.\n")
        defer { fixture.remove() }
        let service = CommentService(store: AtomicDocumentStore(lockTimeout: 10, retryLimit: 3))
        let root = try service.add(
            at: fixture.file,
            message: "Initial",
            creator: human,
            anchor: .quote(exact: "target"),
            annotationID: "00000000-0000-4000-8000-000000000520"
        )
        let queue = DispatchQueue(label: "margin.edit.cas", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var successes = 0
        var conflicts = 0
        var otherErrors: [Error] = []

        for offset in 0..<12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try service.edit(
                        at: fixture.file,
                        id: root.annotation.id,
                        message: "Edit \(offset)",
                        editor: self.agent,
                        preconditions: CommentMutationPreconditions(revision: root.revision)
                    )
                    lock.lock(); successes += 1; lock.unlock()
                } catch CommentProtocolError.revisionConflict {
                    lock.lock(); conflicts += 1; lock.unlock()
                } catch {
                    lock.lock(); otherErrors.append(error); lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(conflicts, 11)
        XCTAssertTrue(otherErrors.isEmpty)
        XCTAssertEqual(try service.list(at: fixture.file).revision, 2)
        XCTAssertEqual(try decodedBody(at: fixture.file), fixture.body)
    }

    func testConcurrentDeleteWithSameRevisionCannotLoseAnUnrelatedComment() throws {
        let fixture = makeFixture("Concurrent delete target.\n")
        defer { fixture.remove() }
        let service = CommentService(store: AtomicDocumentStore(lockTimeout: 10, retryLimit: 3))
        let first = try service.add(
            at: fixture.file,
            message: "First",
            creator: human,
            anchor: .document,
            annotationID: "00000000-0000-4000-8000-000000000530"
        )
        let second = try service.add(
            at: fixture.file,
            message: "Second",
            creator: agent,
            anchor: .document,
            annotationID: "00000000-0000-4000-8000-000000000531"
        )
        XCTAssertEqual(second.revision, 2)

        let queue = DispatchQueue(label: "margin.delete.cas", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var deletedIDs: [String] = []
        var conflicts = 0
        var otherErrors: [Error] = []
        for id in [first.annotation.id, second.annotation.id] {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let receipt = try service.delete(
                        at: fixture.file,
                        id: id,
                        preconditions: CommentMutationPreconditions(revision: second.revision)
                    )
                    lock.lock(); deletedIDs.append(receipt.deletedID); lock.unlock()
                } catch CommentProtocolError.revisionConflict {
                    lock.lock(); conflicts += 1; lock.unlock()
                } catch {
                    lock.lock(); otherErrors.append(error); lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(deletedIDs.count, 1)
        XCTAssertEqual(conflicts, 1)
        XCTAssertTrue(otherErrors.isEmpty)
        let remaining = try service.list(at: fixture.file)
        XCTAssertEqual(remaining.revision, 3)
        XCTAssertEqual(remaining.comments.count, 1)
        XCTAssertFalse(deletedIDs.contains(remaining.comments[0].annotation.id))
        XCTAssertEqual(try decodedBody(at: fixture.file), fixture.body)
    }

    private func makeFixture(_ text: String) -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginMutationTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document.md")
        let body = Data(text.utf8)
        try! body.write(to: file)
        return Fixture(directory: directory, file: file, body: body)
    }

    private func decodedBody(at file: URL) throws -> Data {
        try EmbeddedCommentCodec().decode(Data(contentsOf: file)).bodyData
    }
}

private struct Fixture {
    let directory: URL
    let file: URL
    let body: Data

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
