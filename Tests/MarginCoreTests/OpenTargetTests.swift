import Foundation
import XCTest
@testable import MarginCore

final class OpenTargetTests: XCTestCase {
    func testCreatesMissingFileWhenParentDirectoryExists() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("new draft.md")

        let prepared = try OpenTargetPreparer.prepare(at: file)

        XCTAssertEqual(prepared.url, file.standardizedFileURL)
        XCTAssertTrue(prepared.wasCreated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data())
    }

    func testExistingFileIsNeverTruncated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("existing.md")
        let original = Data("Keep me.\n".utf8)
        try original.write(to: file)

        let prepared = try OpenTargetPreparer.prepare(at: file)

        XCTAssertFalse(prepared.wasCreated)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testExistingDirectoryRemainsAnOpenableTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let prepared = try OpenTargetPreparer.prepare(at: directory)

        XCTAssertFalse(prepared.wasCreated)
        XCTAssertEqual(prepared.url, directory.standardizedFileURL)
    }

    func testMissingParentFailsWithoutCreatingIntermediateDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingParent = directory.appendingPathComponent("missing", isDirectory: true)
        let file = missingParent.appendingPathComponent("draft.md")

        XCTAssertThrowsError(try OpenTargetPreparer.prepare(at: file)) { error in
            XCTAssertEqual(error as? OpenTargetPreparationError, .parentNotFound(missingParent.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path))
    }

    func testConcurrentPreparationDoesNotTruncateTheWinner() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("race.md")
        let queue = DispatchQueue(label: "margin.open-target", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [PreparedOpenTarget] = []
        var errors: [Error] = []

        for _ in 0..<12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let result = try OpenTargetPreparer.prepare(at: file)
                    lock.lock()
                    results.append(result)
                    lock.unlock()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
            }
        }
        group.wait()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(results.filter(\.wasCreated).count, 1)
        XCTAssertEqual(results.count, 12)
        XCTAssertEqual(try Data(contentsOf: file), Data())
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-open-target-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
