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

    func testStageSubmissionConfirmationUsesCountAwareNouns() {
        XCTAssertEqual(
            WorkspaceWindowController.stageSubmissionConfirmationText(changeCount: 1, fileCount: 1),
            "1 change across 1 file will be applied together. If any file changed since staging, nothing will be submitted."
        )
        XCTAssertEqual(
            WorkspaceWindowController.stageSubmissionConfirmationText(changeCount: 2, fileCount: 3),
            "2 changes across 3 files will be applied together. If any file changed since staging, nothing will be submitted."
        )
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
        XCTAssertNil(controller.sessionState)

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

        let saveScratchpadAs = menuItem(named: "Save Scratchpad As…")
        XCTAssertEqual(saveScratchpadAs?.keyEquivalent, "s")
        XCTAssertEqual(saveScratchpadAs?.keyEquivalentModifierMask, [.command, .shift])

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

    func testProgrammaticWorkspaceAndPaletteClosureAvoidStaleAnimations() {
        let workspace = WorkspaceWindowController(workspaceURL: nil)
        let workspaceWindow = workspace.window
        let palette = NavigationPaletteController(
            title: "Test Palette",
            placeholder: "Search",
            emptyMessage: "No results"
        )

        XCTAssertEqual(
            palette.window?.animationBehavior,
            NSWindow.AnimationBehavior.none
        )
        workspace.close()
        XCTAssertEqual(
            workspaceWindow?.animationBehavior,
            NSWindow.AnimationBehavior.none
        )
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
            windows: [
                WorkspaceWindowSession(
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
                            ),
                            restorationIdentifier: "window-restoration-test"
                        )
                    ],
                    selectedIndex: 0,
                    frame: WorkspaceWindowFrame(
                        CGRect(x: 40, y: 80, width: 1180, height: 780),
                        displayIdentifier: "display-test",
                        displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
                    ),
                    space: WorkspaceSpaceAssignment(
                        spaceUUID: "space-test",
                        managedSpaceID: 42,
                        displayIdentifier: "display-test",
                        desktopOrdinal: 1,
                        spaceType: 0
                    )
                )
            ],
            selectedWindowIndex: 0
        )

        store.save(value)
        XCTAssertEqual(store.load(), value)
        store.save(nil)
        XCTAssertNil(store.load())
    }

    func testVersionTwoSessionWithoutPlacementMetadataStillLoads() throws {
        let suite = "margin-session-compatibility-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Expected isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data("""
        {
          "version": 2,
          "windows": [{
            "selectedIndex": 0,
            "frame": {"x": 40, "y": 80, "width": 1180, "height": 780},
            "tabs": [{
              "workspacePath": "/tmp/legacy-v2.md",
              "documentPath": "/tmp/legacy-v2.md",
              "readerMode": false,
              "navigatorVisible": false,
              "commentsVisible": false,
              "editor": {
                "selectionLocation": 0,
                "selectionLength": 0,
                "scrollFraction": 0
              }
            }]
          }],
          "selectedWindowIndex": 0
        }
        """.utf8)
        defaults.set(data, forKey: "session")

        let session = try XCTUnwrap(
            WorkspaceSessionStore(defaults: defaults, key: "session").load()
        )
        XCTAssertNil(session.windows[0].tabs[0].restorationIdentifier)
        XCTAssertNil(session.windows[0].frame?.displayIdentifier)
        XCTAssertNil(session.windows[0].space)
    }

    func testSpaceResolverPrefersStableUUIDOverTransientSpaceID() throws {
        let assignment = WorkspaceSpaceAssignment(
            spaceUUID: "target-space",
            managedSpaceID: 12,
            displayIdentifier: "display-a",
            desktopOrdinal: 0,
            spaceType: 0
        )
        let resolved = try XCTUnwrap(WorkspaceSpaceResolver.resolve(
            assignment,
            in: [
                spaceDescriptor(id: 12, uuid: "recycled-space", ordinal: 0),
                spaceDescriptor(id: 99, uuid: "target-space", ordinal: 3),
            ]
        ))

        XCTAssertEqual(resolved.managedSpaceID, 99)
    }

    func testSpaceResolverFallsBackToDesktopOrdinalThenActiveDesktop() throws {
        let ordinalAssignment = WorkspaceSpaceAssignment(
            spaceUUID: "deleted-space",
            managedSpaceID: 12,
            displayIdentifier: "display-a",
            desktopOrdinal: 1,
            spaceType: 0
        )
        let catalog = [
            spaceDescriptor(id: 20, uuid: "first", ordinal: 0),
            spaceDescriptor(id: 21, uuid: "second", ordinal: 1),
            spaceDescriptor(id: 22, uuid: "active", ordinal: 2, isActive: true),
        ]
        XCTAssertEqual(
            WorkspaceSpaceResolver.resolve(ordinalAssignment, in: catalog)?.managedSpaceID,
            21
        )

        var activeAssignment = ordinalAssignment
        activeAssignment.desktopOrdinal = 8
        XCTAssertEqual(
            WorkspaceSpaceResolver.resolve(activeAssignment, in: catalog)?.managedSpaceID,
            22
        )
    }

    func testSpaceResolverNeverTargetsFullscreenOrAnotherDisplay() {
        let assignment = WorkspaceSpaceAssignment(
            spaceUUID: "missing",
            managedSpaceID: 12,
            displayIdentifier: "display-a",
            desktopOrdinal: 1,
            spaceType: 0
        )
        let catalog = [
            spaceDescriptor(
                id: 20,
                uuid: "fullscreen",
                display: "display-a",
                ordinal: nil,
                type: 4,
                isActive: true
            ),
            spaceDescriptor(
                id: 21,
                uuid: "other-display",
                display: "display-b",
                ordinal: 1,
                isActive: true
            ),
        ]

        XCTAssertNil(WorkspaceSpaceResolver.resolve(assignment, in: catalog))
    }

    func testLaunchPolicyKeepsThePreviouslySelectedWindowWhenItIsLocal() {
        XCTAssertEqual(
            WorkspaceLaunchPolicy.action(
                previouslySelectedIndex: 1,
                restoredWindowsOnActiveSpace: [true, true, false]
            ),
            .focusRestoredWindow(1)
        )
    }

    func testLaunchPolicyUsesAnotherLocalWindowInsteadOfSwitchingSpaces() {
        XCTAssertEqual(
            WorkspaceLaunchPolicy.action(
                previouslySelectedIndex: 2,
                restoredWindowsOnActiveSpace: [false, true, false]
            ),
            .focusRestoredWindow(1)
        )
    }

    func testLaunchPolicyCreatesAnEmptyWindowWhenOnlySavedWindowIsRemote() {
        XCTAssertEqual(
            WorkspaceLaunchPolicy.action(
                previouslySelectedIndex: 0,
                restoredWindowsOnActiveSpace: [false]
            ),
            .createEmptyWindow
        )
    }

    func testLaunchPolicyCreatesAnEmptyWindowWhenEverySavedWindowIsRemote() {
        XCTAssertEqual(
            WorkspaceLaunchPolicy.action(
                previouslySelectedIndex: 1,
                restoredWindowsOnActiveSpace: [false, false, false]
            ),
            .createEmptyWindow
        )
    }

    func testWindowPlacementFollowsTheSameDisplayWhenItsLayoutChanges() throws {
        let state = WorkspaceWindowFrame(
            CGRect(x: 1560, y: 80, width: 900, height: 650),
            displayIdentifier: "external",
            displayFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        let restored = try XCTUnwrap(WorkspaceWindowPlacementResolver.resolve(
            state,
            displays: [
                WorkspaceDisplayGeometry(
                    identifier: "built-in",
                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
                ),
                WorkspaceDisplayGeometry(
                    identifier: "external",
                    visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
                ),
            ]
        ))

        XCTAssertEqual(restored.origin.x, -1800, accuracy: 0.5)
        XCTAssertEqual(restored.origin.y, 80, accuracy: 0.5)
        XCTAssertEqual(restored.size, state.rect.size)
    }

    func testWindowPlacementFallsBackOnscreenWhenDisplayIsDisconnected() throws {
        let state = WorkspaceWindowFrame(
            CGRect(x: 1600, y: 100, width: 900, height: 650),
            displayIdentifier: "disconnected",
            displayFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        let restored = try XCTUnwrap(WorkspaceWindowPlacementResolver.resolve(
            state,
            displays: [WorkspaceDisplayGeometry(
                identifier: "built-in",
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            )]
        ))

        XCTAssertEqual(restored.origin.x, 160, accuracy: 0.5)
        XCTAssertEqual(restored.origin.y, 100, accuracy: 0.5)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1440, height: 900).contains(restored))
    }

    func testScratchpadIsPrivateEditableAndCanBecomeANamedMarkdownFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-scratch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "margin-scratch-defaults-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Expected isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let scratchStore = ScratchpadStore(
            rootURL: directory.appendingPathComponent("private", isDirectory: true),
            defaults: defaults,
            counterKey: "counter"
        )
        let descriptor = try scratchStore.create()
        let controller = WorkspaceWindowController(
            workspaceURL: nil,
            scratchpad: descriptor,
            scratchpadStore: scratchStore
        )
        defer { controller.close() }
        controller.showWindow(nil)

        XCTAssertTrue(controller.isScratchpad)
        XCTAssertEqual(controller.window?.title, "Untitled 1")
        XCTAssertNil(controller.window?.representedURL)
        XCTAssertEqual(controller.sessionState?.scratchpadID, descriptor.id)
        XCTAssertEqual(
            controller.sessionState?.restorationIdentifier,
            controller.restorationIdentifier
        )
        XCTAssertEqual(
            controller.window?.identifier,
            WorkspaceRestorationIdentifier.make(controller.restorationIdentifier)
        )
        XCTAssertFalse(controller.window?.isRestorable == true)
        XCTAssertNil(controller.window?.restorationClass)

        let textView = try XCTUnwrap(descendantTextView(in: controller.window?.contentView))
        waitUntil { textView.isEditable }
        textView.insertText("# Durable scratch\n", replacementRange: NSRange(location: 0, length: 0))
        let scratchURL = scratchStore.url(for: descriptor.id)
        XCTAssertTrue(controller.prepareForApplicationTermination())
        XCTAssertEqual(
            try String(contentsOf: scratchURL, encoding: .utf8),
            "# Durable scratch\n"
        )

        let destination = directory.appendingPathComponent("named.md")
        XCTAssertTrue(controller.saveScratchpad(to: destination))
        XCTAssertFalse(controller.isScratchpad)
        XCTAssertFalse(scratchStore.exists(descriptor))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "# Durable scratch\n")
        XCTAssertEqual(controller.window?.representedURL, destination.standardizedFileURL)
    }

    func testLegacyFlatSessionMigratesToOneWindow() throws {
        let suite = "margin-legacy-session-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Expected isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let tab = WorkspaceTabSession(
            workspacePath: "/tmp/legacy.md",
            documentPath: "/tmp/legacy.md",
            readerMode: false,
            navigatorVisible: false,
            commentsVisible: false,
            editor: .beginning
        )
        let tabJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab))
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "tabs": [tabJSON],
            "selectedIndex": 0,
        ])
        defaults.set(data, forKey: "session")

        let migrated = try XCTUnwrap(
            WorkspaceSessionStore(defaults: defaults, key: "session").load()
        )
        XCTAssertEqual(migrated.windows.count, 1)
        XCTAssertEqual(migrated.windows[0].tabs, [tab])
        XCTAssertEqual(migrated.windows[0].selectedIndex, 0)
    }

    func testSessionCapturePreservesIndependentWindowsAndTheirTabGroups() throws {
        let originalWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-window-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            NSApplication.shared.windows
                .filter { !originalWindows.contains(ObjectIdentifier($0)) }
                .forEach { $0.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let suite = "margin-window-session-defaults-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Expected isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let scratchStore = ScratchpadStore(
            rootURL: directory.appendingPathComponent("scratch", isDirectory: true),
            defaults: defaults,
            counterKey: "counter"
        )
        let delegate = AppDelegate(
            sessionStore: WorkspaceSessionStore(defaults: defaults, key: "session"),
            scratchpadStore: scratchStore
        )

        delegate.newWindow(nil)
        delegate.newWindowForTab(nil)
        var captured = try XCTUnwrap(delegate.workspaceSessionForTesting)
        XCTAssertEqual(captured.windows.count, 1)
        XCTAssertEqual(captured.windows[0].tabs.count, 2)

        delegate.newWindow(nil)
        captured = try XCTUnwrap(delegate.workspaceSessionForTesting)
        XCTAssertEqual(captured.windows.count, 2)
        XCTAssertEqual(captured.windows.map { $0.tabs.count }.sorted(), [1, 2])
        XCTAssertEqual(captured.windows.flatMap(\.tabs).compactMap(\.scratchpadID).count, 3)
        let restorationIdentifiers = captured.windows
            .flatMap(\.tabs)
            .compactMap(\.restorationIdentifier)
        XCTAssertEqual(restorationIdentifiers.count, 3)
        XCTAssertEqual(Set(restorationIdentifiers).count, 3)
        XCTAssertNotNil(captured.windows[0].frame?.displayIdentifier)
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

    func testCollaborationOverviewIsLazyAndLoadsDurableActorActivityOnDemand() throws {
        let fixture = try makeDocument("# Collaboration\n\nA shared boundary.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try CommentService().add(
            at: fixture.file,
            message: "Check the shared boundary.",
            creator: MarginActor(
                id: "urn:agent:context-test",
                type: .software,
                name: "Context Agent"
            ),
            anchor: .quote(exact: "shared boundary")
        )
        let sourceBefore = try Data(contentsOf: fixture.file)
        let controller = WorkspaceWindowController(workspaceURL: fixture.file)
        defer { controller.close() }
        controller.showWindow(nil)

        controller.showCommandPalette(nil)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent(".margin").path
        ))

        controller.showCollaborationOverview(nil)
        waitUntil(timeout: 4) {
            controller.window?.childWindows?.contains(where: {
                self.descendantText(in: $0.contentView).contains("Context Agent")
            }) == true
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), sourceBefore)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent(".margin").path
        ))
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

    private func spaceDescriptor(
        id: UInt64,
        uuid: String,
        display: String = "display-a",
        ordinal: Int?,
        type: Int = 0,
        isActive: Bool = false
    ) -> WorkspaceSpaceDescriptor {
        WorkspaceSpaceDescriptor(
            managedSpaceID: id,
            spaceUUID: uuid,
            displayIdentifier: display,
            desktopOrdinal: ordinal,
            spaceType: type,
            isActive: isActive
        )
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

    private func descendantTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { descendantTextView(in: $0) }.first
    }
}
