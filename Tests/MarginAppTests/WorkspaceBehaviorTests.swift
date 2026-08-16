import AppKit
import XCTest
@testable import MarginApp
import MarginCore

final class WorkspaceBehaviorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WorkspacePaneFactory.makeEditor = { EditorViewController() }
        WorkspacePaneFactory.makeComments = { CommentsViewController() }
    }

    func testWorkspaceUsesNativeResizableWindowAndQuietEmptyPanes() {
        let controller = WorkspaceWindowController(workspaceURL: nil)
        defer { controller.close() }

        guard let window = controller.window else {
            return XCTFail("Expected a workspace window")
        }
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 720, height: 480))
        XCTAssertEqual(window.tabbingIdentifier, "ink.margin.workspace")
        XCTAssertFalse(controller.isNavigatorVisible)
        XCTAssertFalse(controller.isCommentsVisible)
        XCTAssertFalse(controller.canShowComments)

        let initialWidth = window.frame.width
        let untitled = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-resize-\(UUID().uuidString).md")
        controller.open(untitled)
        controller.focusComments(nil)
        XCTAssertTrue(controller.isCommentsVisible)
        XCTAssertEqual(window.frame.width, initialWidth, accuracy: 1)
    }

    func testDocumentWithoutCommentsKeepsInspectorClosed() throws {
        let fixture = try makeDocument("# Quiet document\n\nNothing to review yet.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = WorkspaceWindowController(workspaceURL: fixture.file)
        defer { controller.close() }

        waitUntil { controller.canShowComments }
        XCTAssertFalse(controller.isCommentsVisible)
        XCTAssertFalse(controller.canNavigateAnyComments)
        XCTAssertFalse(controller.canNavigateComments)
    }

    func testResolvedOnlyDocumentCanGoToCommentButCannotTraverseOpenReview() throws {
        let fixture = try makeDocument("# Resolved review\n\nA finished passage.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = CommentService()
        let actor = MarginActor(
            id: "urn:agent:resolved-test",
            type: .software,
            name: "Resolved Test"
        )
        let rootID = try service.add(
            at: fixture.file,
            message: "This thread is complete.",
            creator: actor,
            anchor: .quote(exact: "finished passage")
        ).rootID
        _ = try service.resolve(at: fixture.file, id: rootID, actor: actor)

        let controller = WorkspaceWindowController(workspaceURL: fixture.file)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        waitUntil { controller.canNavigateAnyComments }

        XCTAssertTrue(controller.canNavigateAnyComments)
        XCTAssertFalse(controller.canNavigateComments)

        let delegate = AppDelegate()
        let goToComment = NSMenuItem(
            title: "Go to Comment…",
            action: #selector(AppDelegate.navigateToComment(_:)),
            keyEquivalent: ""
        )
        let nextOpen = NSMenuItem(
            title: "Next Open Comment",
            action: #selector(AppDelegate.nextOpenComment(_:)),
            keyEquivalent: ""
        )
        let previousOpen = NSMenuItem(
            title: "Previous Open Comment",
            action: #selector(AppDelegate.previousOpenComment(_:)),
            keyEquivalent: ""
        )
        let resolveCurrent = NSMenuItem(
            title: "Resolve Current Comment",
            action: #selector(AppDelegate.resolveCurrentComment(_:)),
            keyEquivalent: ""
        )

        XCTAssertTrue(delegate.validateMenuItem(goToComment, for: controller))
        XCTAssertFalse(delegate.validateMenuItem(nextOpen, for: controller))
        XCTAssertFalse(delegate.validateMenuItem(previousOpen, for: controller))
        XCTAssertFalse(delegate.validateMenuItem(resolveCurrent, for: controller))
    }

    func testDocumentWithCommentsOpensInspectorAutomatically() throws {
        let fixture = try makeDocument("# Reviewed document\n\nA precise passage.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try CommentService().add(
            at: fixture.file,
            message: "Worth refining.",
            creator: MarginActor(id: "urn:agent:test", type: .software, name: "Test Agent"),
            anchor: .quote(exact: "precise")
        )

        let controller = WorkspaceWindowController(workspaceURL: fixture.file)
        defer { controller.close() }

        waitUntil { controller.isCommentsVisible }
        XCTAssertTrue(controller.isCommentsVisible)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            descendantText(in: controller.window?.contentView).contains("Worth refining.")
        )
    }

    func testExternalReplyCreatesUnreadActivityWithoutOpeningInspector() throws {
        let fixture = try makeDocument("# Agent review\n\nA shared passage.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = CommentService()
        let root = try service.add(
            at: fixture.file,
            message: "Initial review.",
            creator: MarginActor(id: "urn:agent:initial", type: .software, name: "Initial Agent"),
            anchor: .quote(exact: "shared passage")
        ).rootID
        var editor: EditorViewController?
        WorkspacePaneFactory.makeEditor = {
            let value = EditorViewController()
            editor = value
            return value
        }
        let controller = WorkspaceWindowController(workspaceURL: fixture.file)
        defer { controller.close() }
        waitUntil { controller.isCommentsVisible && editor?.rootCommentIDsInSourceOrder == [root] }

        controller.toggleComments(nil)
        XCTAssertFalse(controller.isCommentsVisible)
        _ = try service.reply(
            at: fixture.file,
            parentID: root,
            message: "A new agent reply.",
            creator: MarginActor(id: "urn:agent:new", type: .software, name: "New Agent")
        )
        editor?.refreshCommentsFromDisk()

        waitUntil { controller.hasUnreadComments }
        XCTAssertFalse(controller.isCommentsVisible)
        controller.focusComments(nil)
        XCTAssertTrue(controller.hasUnreadComments)
        editor?.revealComment(id: root)
        waitUntil { !controller.hasUnreadComments }
    }

    func testPrimaryNavigationShortcutsReserveCommandDigitsForTabs() {
        let delegate = AppDelegate()
        AppMenu.install(for: NSApplication.shared, delegate: delegate)

        let newTab = menuItem(named: "New Tab")
        XCTAssertEqual(newTab?.keyEquivalent, "t")
        XCTAssertEqual(newTab?.keyEquivalentModifierMask, [.command])

        let focusEditor = menuItem(named: "Focus Editor")
        XCTAssertEqual(focusEditor?.keyEquivalent, "2")
        XCTAssertEqual(focusEditor?.keyEquivalentModifierMask, [.control])

        let lastTab = menuItem(named: "Last Tab")
        XCTAssertEqual(lastTab?.keyEquivalent, "9")
        XCTAssertEqual(lastTab?.keyEquivalentModifierMask, [.command])

        let nextTab = menuItem(named: "Show Next Tab")
        XCTAssertEqual(nextTab?.keyEquivalent, "\t")
        XCTAssertEqual(nextTab?.keyEquivalentModifierMask, [.control])

        let commandPalette = menuItem(named: "Command Palette…")
        XCTAssertEqual(commandPalette?.keyEquivalent, "p")
        XCTAssertEqual(commandPalette?.keyEquivalentModifierMask, [.command, .shift])

        let nextComment = menuItem(named: "Next Open Comment")
        XCTAssertEqual(nextComment?.keyEquivalent, "]")
        XCTAssertEqual(nextComment?.keyEquivalentModifierMask, [.command, .option])

        let previousComment = menuItem(named: "Previous Open Comment")
        XCTAssertEqual(previousComment?.keyEquivalent, "[")
        XCTAssertEqual(previousComment?.keyEquivalentModifierMask, [.command, .option])

        XCTAssertNotNil(menuItem(named: "Go to Comment…"))
    }

    func testFileWatcherNeverBlocksTheInteractionThreadWhileOpening() {
        let openerFinished = expectation(description: "Slow descriptor open finished")
        let watcher = FileSystemWatcher(
            url: FileManager.default.temporaryDirectory,
            descriptorOpener: { _ in
                Thread.sleep(forTimeInterval: 0.2)
                openerFinished.fulfill()
                return -1
            },
            handler: { _ in }
        )

        let start = ContinuousClock.now
        watcher.start()
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(50))
        wait(for: [openerFinished], timeout: 1)
        watcher.stop()
    }

    func testWorkspaceSessionRoundTripsWithoutUnboundedState() throws {
        let suite = "margin-session-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Expected isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceSessionStore(defaults: defaults, key: "session")
        let value = WorkspaceSession(
            tabs: [
                WorkspaceTabSession(
                    workspacePath: "/tmp/workspace",
                    documentPath: "/tmp/workspace/note.md",
                    readerMode: true,
                    navigatorVisible: true,
                    commentsVisible: false,
                    editor: EditorContinuityState(
                        selectionLocation: 42,
                        selectionLength: 7,
                        scrollFraction: 0.5,
                        selectedThreadID: "urn:uuid:test"
                    )
                )
            ],
            selectedIndex: 0
        )

        store.save(value)
        XCTAssertEqual(store.load(), value)
        store.save(nil)
        XCTAssertNil(store.load())
    }

    func testUnreadCommentBadgeIsLazyAndPersistsUntilActivityIsRead() throws {
        let fixture = try makeDocument("# Review\n\nA passage.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = WorkspaceWindowController(workspaceURL: fixture.file)
        defer { controller.close() }

        XCTAssertFalse(controller.hasUnreadComments)
        XCTAssertNil(controller.window?.tab.accessoryView)

        controller.updateUnreadComments(3)
        XCTAssertTrue(controller.hasUnreadComments)
        XCTAssertNotNil(controller.window?.tab.accessoryView)

        controller.focusComments(nil)
        XCTAssertTrue(controller.hasUnreadComments)
        XCTAssertNotNil(controller.window?.tab.accessoryView)

        controller.updateUnreadComments(0)
        XCTAssertFalse(controller.hasUnreadComments)
        XCTAssertNil(controller.window?.tab.accessoryView)
    }

    func testRecentWorkspaceStoreIsOrderedDeduplicatedAndBounded() {
        let suite = "margin-recents-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Expected isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentWorkspaceStore(defaults: defaults, key: "recents")
        let first = URL(fileURLWithPath: "/tmp/first.md")
        let second = URL(fileURLWithPath: "/tmp/second.md")

        store.record(first, limit: 2)
        store.record(second, limit: 2)
        store.record(first, limit: 2)

        XCTAssertEqual(store.urls(limit: 10), [first, second])
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

    private func makeDocument(_ source: String) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("note.md")
        try Data(source.utf8).write(to: file)
        return (directory, file)
    }

    private func menuItem(named title: String) -> NSMenuItem? {
        func find(in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.title == title { return item }
                if let found = find(in: item.submenu) { return found }
            }
            return nil
        }
        return find(in: NSApplication.shared.mainMenu)
    }

    private func descendantText(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { descendantText(in: $0) }
    }
}
