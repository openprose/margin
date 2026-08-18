import XCTest
@testable import MarginCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class CommentServiceTests: XCTestCase {
    private let human = MarginActor(id: "urn:person:alice", type: .person, name: "Alice")
    private let agent = MarginActor(id: "urn:agent:codex", type: .software, name: "Codex")

    func testNestedThreadResolveReopenAndList() throws {
        let fixture = makeFixture("A minimalist fast editor.")
        defer { fixture.remove() }
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "Can we quantify fast?",
            creator: human,
            anchor: .quote(exact: "fast"),
            annotationID: "00000000-0000-4000-8000-000000000201"
        )
        let reply = try service.reply(
            at: fixture.file,
            parentID: root.annotation.id,
            message: "I'll add a startup benchmark.",
            creator: agent,
            annotationID: "00000000-0000-4000-8000-000000000202"
        )
        _ = try service.reply(
            at: fixture.file,
            parentID: reply.annotation.id,
            message: "Perfect.",
            creator: human,
            annotationID: "00000000-0000-4000-8000-000000000203"
        )

        let snapshot = try service.list(at: fixture.file)
        XCTAssertEqual(snapshot.revision, 3)
        XCTAssertEqual(snapshot.comments.map(\.depth), [0, 1, 2])
        XCTAssertTrue(snapshot.comments.allSatisfy { $0.rootID == root.annotation.id })
        XCTAssertTrue(snapshot.comments.allSatisfy { $0.threadStatus == .open })

        let resolved = try service.resolve(at: fixture.file, id: reply.annotation.id, actor: agent)
        XCTAssertTrue(resolved.changed)
        XCTAssertEqual(resolved.rootID, root.annotation.id)
        XCTAssertEqual(resolved.annotation.status, .resolved)
        let idempotentResolve = try service.resolve(at: fixture.file, id: root.annotation.id, actor: agent)
        XCTAssertFalse(idempotentResolve.changed)
        XCTAssertEqual(idempotentResolve.revision, 4)

        XCTAssertThrowsError(try service.reply(
            at: fixture.file,
            parentID: reply.annotation.id,
            message: "One more thing",
            creator: agent
        )) { error in
            guard case CommentProtocolError.resolvedThread = error else {
                return XCTFail("Expected resolvedThread, got \(error)")
            }
        }
        let reopenedReply = try service.reply(
            at: fixture.file,
            parentID: reply.annotation.id,
            message: "One more thing",
            creator: agent,
            annotationID: "00000000-0000-4000-8000-000000000204",
            reopen: true
        )
        XCTAssertEqual(reopenedReply.revision, 5)
        XCTAssertEqual(try service.get(root.annotation.id, at: fixture.file).threadStatus, .open)
    }

    func testIdempotencyAndPreconditionsPreventLostUpdates() throws {
        let fixture = makeFixture("alpha beta gamma")
        defer { fixture.remove() }
        let service = CommentService()
        let initial = try service.validate(at: fixture.file)
        let first = try service.add(
            at: fixture.file,
            message: "beta note",
            creator: agent,
            anchor: .quote(exact: "beta"),
            annotationID: "00000000-0000-4000-8000-000000000210",
            preconditions: CommentMutationPreconditions(
                revision: 0,
                contentSha256: initial.contentSha256
            )
        )
        let replay = try service.add(
            at: fixture.file,
            message: "beta note",
            creator: agent,
            anchor: .quote(exact: "beta"),
            annotationID: "00000000-0000-4000-8000-000000000210",
            preconditions: CommentMutationPreconditions(revision: 0)
        )
        XCTAssertFalse(replay.changed)
        XCTAssertEqual(replay.revision, first.revision)
        XCTAssertEqual(try service.list(at: fixture.file).comments.count, 1)

        XCTAssertThrowsError(try service.add(
            at: fixture.file,
            message: "different",
            creator: agent,
            anchor: .quote(exact: "beta"),
            annotationID: "00000000-0000-4000-8000-000000000210"
        )) { error in
            guard case CommentProtocolError.idConflict = error else {
                return XCTFail("Expected idConflict, got \(error)")
            }
        }
        XCTAssertThrowsError(try service.reply(
            at: fixture.file,
            parentID: first.annotation.id,
            message: "stale",
            creator: human,
            preconditions: CommentMutationPreconditions(revision: 0)
        )) { error in
            guard case CommentProtocolError.revisionConflict = error else {
                return XCTFail("Expected revisionConflict, got \(error)")
            }
        }
    }

    func testReanchorMovesSelectionAndPreservesSourcePermissions() throws {
        let fixture = makeFixture("one target three")
        defer { fixture.remove() }
        XCTAssertEqual(chmod(fixture.file.path, 0o640), 0)
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "target note",
            creator: human,
            anchor: .quote(exact: "target"),
            annotationID: "00000000-0000-4000-8000-000000000220"
        )
        _ = try service.reanchor(
            at: fixture.file,
            id: root.annotation.id,
            anchor: .quote(exact: "three")
        )
        let listed = try service.get(root.annotation.id, at: fixture.file)
        XCTAssertEqual(listed.anchor?.state, .anchored)
        guard case .selection(let target) = listed.annotation.target else {
            return XCTFail("Expected selection target")
        }
        XCTAssertEqual(target.quoteSelector?.exact, "three")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testConcurrentRepliesAreSerialized() throws {
        let fixture = makeFixture("shared passage")
        defer { fixture.remove() }
        let service = CommentService(store: AtomicDocumentStore(lockTimeout: 10, retryLimit: 3))
        let root = try service.add(
            at: fixture.file,
            message: "root",
            creator: human,
            anchor: .quote(exact: "passage"),
            annotationID: "00000000-0000-4000-8000-000000000230"
        )
        let queue = DispatchQueue(label: "MarginConcurrentComments", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [Error] = []
        for offset in 0..<12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try service.reply(
                        at: fixture.file,
                        parentID: root.annotation.id,
                        message: "reply \(offset)",
                        creator: self.agent,
                        annotationID: String(format: "00000000-0000-4000-8000-%012d", 300 + offset)
                    )
                } catch {
                    lock.lock()
                    failures.append(error)
                    lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(failures.isEmpty, "Failures: \(failures)")
        let snapshot = try service.list(at: fixture.file)
        XCTAssertEqual(snapshot.comments.count, 13)
        XCTAssertEqual(snapshot.revision, 13)
    }

    private func makeFixture(_ contents: String) -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginServiceTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document.md")
        try! Data(contents.utf8).write(to: file)
        return Fixture(directory: directory, file: file)
    }
}

private struct Fixture {
    let directory: URL
    let file: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
