import Foundation
import XCTest
import MarginCore
@testable import MarginCLI

final class CommentWatchTests: XCTestCase {
    private let actor = MarginActor(
        id: "urn:agent:watch-tests",
        type: .software,
        name: "Watch Tests"
    )

    func testWatchReportsAtomicCommentReplacementWithoutPolling() throws {
        let fixture = try makeFixture("# Héading\n\nUnicode 👩🏽‍💻 target.\n")
        defer { fixture.remove() }
        let session = CommentWatchSession(file: fixture.file)
        let ready = expectation(description: "initial ready")
        let changed = expectation(description: "atomic comment change")
        let stopped = expectation(description: "clean stop")
        let events = EventRecorder()

        try session.start(sinceRevision: 0) { event in
            events.append(event)
            switch event.event {
            case "ready": ready.fulfill()
            case "change": changed.fulfill()
            case "stopped": stopped.fulfill()
            default: break
            }
        }
        wait(for: [ready], timeout: 1)

        _ = try CommentService().add(
            at: fixture.file,
            message: "Review the emoji — ✅",
            creator: actor,
            anchor: .quote(exact: "👩🏽‍💻 target"),
            annotationID: "00000000-0000-4000-8000-000000000701"
        )
        wait(for: [changed], timeout: 5)
        session.stop()
        wait(for: [stopped], timeout: 2)

        let change = try XCTUnwrap(events.snapshot().first { $0.event == "change" })
        XCTAssertEqual(change.previous?.revision, 0)
        XCTAssertEqual(change.current?.revision, 1)
        XCTAssertEqual(change.current?.annotationCount, 1)
        XCTAssertEqual(change.changes?.fileReplaced, true)
        XCTAssertEqual(change.changes?.protocolVersionChanged, true)
        XCTAssertEqual(change.changes?.revisionChanged, true)
        XCTAssertEqual(change.changes?.commentsChanged, true)
        XCTAssertEqual(change.changes?.contentChanged, false)
        XCTAssertEqual(events.snapshot().map(\.sequence), [0, 1, 2])
    }

    func testWatchEmitsMachineErrorThenReconnectsAfterFileReturns() throws {
        let fixture = try makeFixture("Reconnect body.\n")
        defer { fixture.remove() }
        let originalBody = try Data(contentsOf: fixture.file)
        let session = CommentWatchSession(file: fixture.file)
        let initial = expectation(description: "initial snapshot")
        let unavailable = expectation(description: "recoverable error")
        let reconnected = expectation(description: "reconnected")
        let stopped = expectation(description: "stopped")
        let events = EventRecorder()

        try session.start(sinceRevision: nil) { event in
            events.append(event)
            switch event.event {
            case "snapshot": initial.fulfill()
            case "error": unavailable.fulfill()
            case "reconnected": reconnected.fulfill()
            case "stopped": stopped.fulfill()
            default: break
            }
        }
        wait(for: [initial], timeout: 1)

        try FileManager.default.removeItem(at: fixture.file)
        wait(for: [unavailable], timeout: 5)
        try originalBody.write(to: fixture.file, options: .atomic)
        wait(for: [reconnected], timeout: 5)
        session.stop()
        wait(for: [stopped], timeout: 2)

        let error = try XCTUnwrap(events.snapshot().first { $0.event == "error" })
        XCTAssertEqual(error.error?.code, "IO_ERROR")
        XCTAssertEqual(error.error?.recoverable, true)
        XCTAssertNil(error.changes)
        let reconnect = try XCTUnwrap(events.snapshot().first { $0.event == "reconnected" })
        XCTAssertEqual(reconnect.changes?.fileReplaced, true)
        XCTAssertEqual(reconnect.current?.contentSha256, reconnect.previous?.contentSha256)
    }

    func testWatchStateJSONIsBoundedForHugeDocumentAndComments() throws {
        let fixture = try makeFixture(String(repeating: "界", count: 1_000_000))
        defer { fixture.remove() }
        _ = try CommentService().add(
            at: fixture.file,
            message: String(repeating: "comment", count: 100_000),
            creator: actor,
            anchor: .document,
            annotationID: "00000000-0000-4000-8000-000000000702"
        )
        let session = CommentWatchSession(file: fixture.file)
        let initial = expectation(description: "bounded initial event")
        var encodedSize = 0

        try session.start(sinceRevision: nil) { event in
            if event.sequence == 0 {
                let encoder = JSONEncoder()
                encodedSize = (try? encoder.encode(event).count) ?? .max
                initial.fulfill()
            }
        }
        wait(for: [initial], timeout: 2)
        session.stop()
        XCTAssertLessThan(encodedSize, 4_096)
    }

    private func makeFixture(_ body: String) throws -> WatchFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginWatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document.md")
        try Data(body.utf8).write(to: file)
        return WatchFixture(directory: directory, file: file)
    }
}

private final class EventRecorder {
    private let lock = NSLock()
    private var events: [CommentWatchEvent] = []

    func append(_ event: CommentWatchEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [CommentWatchEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private struct WatchFixture {
    let directory: URL
    let file: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
