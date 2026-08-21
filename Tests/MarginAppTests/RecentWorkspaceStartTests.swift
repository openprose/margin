import AppKit
import XCTest
@testable import MarginApp

final class RecentWorkspaceStartTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WorkspacePaneFactory.makeEditor = { EditorViewController() }
        WorkspacePaneFactory.makeComments = { CommentsViewController() }
    }

    func testStorePersistsDatesAndOrdersByMostRecentOpen() {
        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let store = RecentWorkspaceStore(defaults: fixture.defaults, key: "recents")
        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)

        store.record(first, at: earlier)
        store.record(second, at: later)

        XCTAssertEqual(
            store.workspaces(),
            [
                RecentWorkspace(url: second, lastOpened: later),
                RecentWorkspace(url: first, lastOpened: earlier),
            ]
        )
    }

    func testQueuedRecordCapturesOpenTimeAndLoadsAfterThePendingWrite() {
        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let store = RecentWorkspaceStore(defaults: fixture.defaults, key: "recents")
        let directory = URL(fileURLWithPath: "/tmp/captured-open-time", isDirectory: true)
        let openedAt = Date(timeIntervalSince1970: 123)
        let loaded = expectation(description: "Loaded after queued record")

        store.recordAfterLaunch(directory, at: openedAt)
        store.loadAfterPendingWrites { workspaces in
            XCTAssertEqual(workspaces.map(\.url.path), [directory.path])
            XCTAssertEqual(workspaces.map(\.lastOpened), [openedAt])
            loaded.fulfill()
        }

        wait(for: [loaded], timeout: 2)
    }

    func testLegacyPathsMigrateWithoutInventingDatesAndFilesNormalizeToTheirFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-recent-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))

        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.defaults.set([file.path, directory.path], forKey: "recents")
        let store = RecentWorkspaceStore(defaults: fixture.defaults, key: "recents")

        let migrated = store.workspaces()
        XCTAssertEqual(migrated.map(\.url), [file, directory])
        XCTAssertTrue(migrated.allSatisfy { $0.lastOpened == nil })

        let normalized = WorkspaceWindowController.existingRecentDirectories(from: migrated)
        XCTAssertEqual(normalized.map(\.url), [directory.standardizedFileURL])
        XCTAssertNil(normalized.first?.lastOpened)
    }

    func testStandaloneFilesRecordTheirContainingDirectoryWithoutAFileScan() {
        let file = URL(fileURLWithPath: "/tmp/project/notes/plan.md")
        let directory = URL(fileURLWithPath: "/tmp/project/notes", isDirectory: true)

        XCTAssertEqual(
            WorkspaceWindowController.recentDirectoryURL(for: file, isDirectory: false),
            directory.standardizedFileURL
        )
        XCTAssertEqual(
            WorkspaceWindowController.recentDirectoryURL(for: directory, isDirectory: true),
            directory.standardizedFileURL
        )
    }

    func testRecentFoldersLoadOnlyAfterTheEmptyWindowIsFirstDisplayed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-recent-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let store = RecentWorkspaceStore(defaults: fixture.defaults, key: "recents")
        store.record(directory, at: Date(timeIntervalSince1970: 200))

        let controller = WorkspaceWindowController(
            workspaceURL: nil,
            recentWorkspaceStore: store
        )
        defer { controller.close() }

        XCTAssertFalse(descendantText(in: controller.window?.contentView).contains("RECENT FOLDERS"))
        XCTAssertFalse(descendantText(in: controller.window?.contentView).contains(directory.path))

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        waitUntil {
            let text = self.descendantText(in: controller.window?.contentView)
            return text.contains("RECENT FOLDERS")
                && text.contains(directory.lastPathComponent)
                && text.contains(directory.path)
        }
    }

    func testRecentFolderRowsOpenWithReturnAndExposeKeyboardReachableCopyControl() throws {
        let url = URL(fileURLWithPath: "/tmp/keyboard-folder", isDirectory: true)
        let controller = RecentWorkspaceStartViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        var openedURLs: [URL] = []
        controller.onOpen = { openedURLs.append($0) }
        controller.render([RecentWorkspace(url: url, lastOpened: Date())])
        controller.view.layoutSubtreeIfNeeded()

        guard let tableView = descendant(of: NSTableView.self, in: controller.view) else {
            return XCTFail("Expected a native recent-folders table")
        }
        XCTAssertEqual(tableView.selectedRow, 0)
        XCTAssertGreaterThan(tableView.bounds.width, 600)
        XCTAssertGreaterThan(try XCTUnwrap(tableView.tableColumns.first).width, 600)
        let rowView = try XCTUnwrap(tableView.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertGreaterThan(rowView.frame.width, 600)

        let returnEvent = try makeReturnKeyEvent()
        tableView.keyDown(with: returnEvent)
        XCTAssertEqual(openedURLs, [url])

        let copyControl = descendantButtons(in: controller.view).first {
            $0.accessibilityLabel()?.contains("Copy full path") == true
        }
        XCTAssertNotNil(copyControl)
        XCTAssertFalse(copyControl?.refusesFirstResponder ?? true)
    }

    func testARecentFolderDeletedAfterRenderingIsRemovedInsteadOfOpenedAsAFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-recent-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let store = RecentWorkspaceStore(defaults: fixture.defaults, key: "recents")
        store.record(directory, at: Date(timeIntervalSince1970: 200))
        let controller = WorkspaceWindowController(
            workspaceURL: nil,
            recentWorkspaceStore: store
        )
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        waitUntil {
            self.descendant(of: NSTableView.self, in: controller.window?.contentView)?.numberOfRows == 1
        }
        let tableView = try XCTUnwrap(
            descendant(of: NSTableView.self, in: try XCTUnwrap(controller.window?.contentView))
        )
        try FileManager.default.removeItem(at: directory)

        tableView.keyDown(with: try makeReturnKeyEvent())

        XCTAssertTrue(controller.isEmpty)
        XCTAssertNil(controller.workspaceURL)
        XCTAssertEqual(tableView.numberOfRows, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "margin-recent-start-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @escaping () -> Bool
    ) {
        let expectation = expectation(description: "Condition became true")
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if predicate() {
                expectation.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
            }
        }
        poll()
        wait(for: [expectation], timeout: timeout + 0.2)
    }

    private func makeReturnKeyEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
    }

    private func descendantText(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { descendantText(in: $0) }
    }

    private func descendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
    }

    private func descendant<T: NSView>(of type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        return descendant(of: type, in: view)
    }

    private func descendantButtons(in view: NSView) -> [NSButton] {
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantButtons)
    }
}
