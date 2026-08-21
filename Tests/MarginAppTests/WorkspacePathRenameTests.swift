import AppKit
import XCTest
@testable import MarginApp

final class WorkspacePathRenameTests: XCTestCase {
    func testVetoPreflightsEveryAffectedDocumentAndMovesNothing() throws {
        let fixture = try makeDirectoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let first = RenameParticipant(documentURL: fixture.first, prepareResult: true)
        let second = RenameParticipant(documentURL: fixture.second, prepareResult: false)
        let unrelated = RenameParticipant(
            documentURL: fixture.parent.appendingPathComponent("outside.md"),
            prepareResult: false
        )

        XCTAssertThrowsError(
            try WorkspacePathRenameCoordinator().rename(
                sourceURL: fixture.directory,
                proposedName: "Renamed",
                participants: [first, second, unrelated]
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspacePathRenameCoordinatorError,
                .documentVeto([fixture.second.path])
            )
        }

        XCTAssertEqual(first.prepareCount, 1)
        XCTAssertEqual(second.prepareCount, 1)
        XCTAssertEqual(unrelated.prepareCount, 0)
        XCTAssertEqual(first.applyCount + second.applyCount + unrelated.applyCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.parent.appendingPathComponent("Renamed").path
            )
        )
    }

    func testMoveFailureOrCollisionNeverAppliesPathRemaps() throws {
        let parent = try temporaryDirectory(named: "margin-rename-collision")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("draft.md")
        let destination = parent.appendingPathComponent("existing.md")
        try "Draft".write(to: source, atomically: true, encoding: .utf8)
        try "Existing".write(to: destination, atomically: true, encoding: .utf8)
        let participant = RenameParticipant(documentURL: source, prepareResult: true)

        XCTAssertThrowsError(
            try WorkspacePathRenameCoordinator().rename(
                sourceURL: source,
                proposedName: destination.lastPathComponent,
                participants: [participant]
            )
        )
        XCTAssertEqual(participant.prepareCount, 1)
        XCTAssertEqual(participant.applyCount, 0)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Draft")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Existing")
    }

    func testDirectoryRenameRemapsEveryOpenWorkspaceEditorTabAndSessionPath() throws {
        let fixture = try makeDirectoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let suite = "margin-path-rename-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recentStore = RecentWorkspaceStore(defaults: defaults, key: "recent")

        var editors: [RenameTrackingEditor] = []
        WorkspacePaneFactory.makeEditor = {
            let editor = RenameTrackingEditor()
            editors.append(editor)
            return editor
        }
        WorkspacePaneFactory.makeComments = { CommentsViewController() }
        defer {
            WorkspacePaneFactory.makeEditor = { EditorViewController() }
            WorkspacePaneFactory.makeComments = { CommentsViewController() }
        }

        let directoryState = WorkspaceTabSession(
            workspacePath: fixture.directory.path,
            documentPath: fixture.first.path,
            readerMode: false,
            navigatorVisible: true,
            commentsVisible: false,
            editor: .beginning
        )
        let directoryController = WorkspaceWindowController(
            workspaceURL: fixture.directory,
            restorationState: directoryState,
            recentWorkspaceStore: recentStore
        )
        let standaloneController = WorkspaceWindowController(
            workspaceURL: fixture.second,
            recentWorkspaceStore: recentStore
        )
        defer {
            directoryController.close()
            standaloneController.close()
        }
        XCTAssertEqual(editors.count, 2)
        XCTAssertEqual(directoryController.navigatorActiveDocumentURLForTesting, fixture.first)

        let destination = try WorkspacePathRenameCoordinator().rename(
            sourceURL: fixture.directory,
            proposedName: "Renamed Project",
            participants: [directoryController, standaloneController]
        )
        let movedFirst = destination.appendingPathComponent(fixture.first.lastPathComponent)
        let movedSecond = destination.appendingPathComponent(fixture.second.lastPathComponent)

        XCTAssertEqual(directoryController.workspaceURL, destination)
        XCTAssertEqual(directoryController.documentURL, movedFirst)
        XCTAssertEqual(directoryController.navigatorActiveDocumentURLForTesting, movedFirst)
        XCTAssertEqual(directoryController.sessionState?.workspacePath, destination.path)
        XCTAssertEqual(directoryController.sessionState?.documentPath, movedFirst.path)
        XCTAssertEqual(directoryController.window?.representedURL, movedFirst)

        XCTAssertEqual(standaloneController.workspaceURL, movedSecond)
        XCTAssertEqual(standaloneController.documentURL, movedSecond)
        XCTAssertEqual(standaloneController.sessionState?.workspacePath, movedSecond.path)
        XCTAssertEqual(standaloneController.sessionState?.documentPath, movedSecond.path)
        XCTAssertEqual(standaloneController.window?.representedURL, movedSecond)

        XCTAssertEqual(editors.map(\.prepareCount), [1, 1])
        XCTAssertEqual(editors.map(\.relocationCount), [1, 1])
        XCTAssertEqual(editors.map(\.representedURL), [movedFirst, movedSecond])
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedFirst.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedSecond.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    private func makeDirectoryFixture() throws -> (
        parent: URL,
        directory: URL,
        first: URL,
        second: URL
    ) {
        let parent = try temporaryDirectory(named: "margin-path-rename")
        let directory = parent.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try "# First\n".write(to: first, atomically: true, encoding: .utf8)
        try "# Second\n".write(to: second, atomically: true, encoding: .utf8)
        return (parent, directory, first, second)
    }

    private func temporaryDirectory(named prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private final class RenameParticipant: WorkspacePathRenameParticipating {
    var documentURLForPathRename: URL?
    let prepareResult: Bool
    private(set) var prepareCount = 0
    private(set) var applyCount = 0

    init(documentURL: URL?, prepareResult: Bool) {
        documentURLForPathRename = documentURL
        self.prepareResult = prepareResult
    }

    func prepareForPathRename(from sourceURL: URL) -> Bool {
        prepareCount += 1
        return prepareResult
    }

    func applyPathRename(from sourceURL: URL, to destinationURL: URL) {
        applyCount += 1
        if let documentURLForPathRename,
           let relocatedURL = WorkspacePathRelocation.relocatedURL(
               documentURLForPathRename,
               from: sourceURL,
               to: destinationURL
           ) {
            self.documentURLForPathRename = relocatedURL
        }
    }
}

private final class RenameTrackingEditor: NSViewController, WorkspaceDocumentPresenting,
    WorkspaceDocumentSaving, WorkspaceDocumentPathRelocating
{
    private(set) var representedURL: URL?
    private(set) var prepareCount = 0
    private(set) var relocationCount = 0

    override func loadView() {
        view = NSView()
    }

    func presentDocument(at url: URL) {
        _ = view
        representedURL = url.standardizedFileURL
    }

    func clearDocument() {
        representedURL = nil
    }

    func saveDocument(_ sender: Any?) {}

    func prepareForPathRename() -> Bool {
        prepareCount += 1
        return true
    }

    func applyDocumentPathRename(from sourceURL: URL, to destinationURL: URL) {
        relocationCount += 1
        guard let representedURL,
              let relocatedURL = WorkspacePathRelocation.relocatedURL(
                  representedURL,
                  from: sourceURL,
                  to: destinationURL
              )
        else { return }
        self.representedURL = relocatedURL
    }
}
