import AppKit
import XCTest
@testable import MarginApp

final class FileNavigatorCommandTests: XCTestCase {
    func testContextMenuUsesNativePathRenameAndFinderConventions() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileTreeViewController()
        controller.openDirectory(fixture.directory, selectInitialMarkdown: false)

        let fileMenu = controller.contextMenuForTesting(itemURL: fixture.file)
        XCTAssertEqual(
            fileMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Open", "Rename…", "Copy Path", "Copy Full Path", "Reveal in Finder"]
        )
        XCTAssertEqual(fileMenu.item(withTitle: "Rename…")?.keyEquivalent, "\r")
        XCTAssertEqual(fileMenu.item(withTitle: "Rename…")?.keyEquivalentModifierMask, [])
        XCTAssertEqual(fileMenu.item(withTitle: "Copy Path")?.keyEquivalent, "c")
        XCTAssertEqual(
            fileMenu.item(withTitle: "Copy Path")?.keyEquivalentModifierMask,
            [.command, .option, .shift]
        )
        XCTAssertEqual(
            fileMenu.item(withTitle: "Copy Full Path")?.keyEquivalentModifierMask,
            [.command, .option]
        )
        XCTAssertEqual(
            fileMenu.item(withTitle: "Reveal in Finder")?.keyEquivalentModifierMask,
            [.command, .option]
        )

        let directoryMenu = controller.contextMenuForTesting(itemURL: fixture.nestedDirectory)
        XCTAssertNotNil(directoryMenu.item(withTitle: "Open in Finder"))
    }

    func testCopyPathDistinguishesWorkspaceRelativeAndAbsoluteValues() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileTreeViewController()
        controller.openDirectory(fixture.directory, selectInitialMarkdown: false)
        let pasteboard = NSPasteboard(name: .init("margin.navigator.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(
            controller.copyPathForTesting(
                itemURL: fixture.file,
                fullPath: false,
                to: pasteboard
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "notes/review.md")

        XCTAssertTrue(
            controller.copyPathForTesting(
                itemURL: fixture.file,
                fullPath: true,
                to: pasteboard
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), fixture.file.path)
        XCTAssertEqual(
            FileTreeViewController.relativePath(
                for: fixture.file,
                within: fixture.directory
            ),
            "notes/review.md"
        )
    }

    func testRenameIsAtomicWithinTheParentAndRejectsInvalidNames() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let renamed = try FileTreeViewController.renameItem(
            at: fixture.file,
            toName: "revised.md"
        )
        XCTAssertEqual(renamed.lastPathComponent, "revised.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "# Review\n")

        XCTAssertThrowsError(
            try FileTreeViewController.renameItem(at: renamed, toName: "../escape.md")
        ) { error in
            XCTAssertEqual(error as? NavigatorRenameError, .invalidName)
        }
        XCTAssertThrowsError(
            try FileTreeViewController.renameItem(at: renamed, toName: "   ")
        ) { error in
            XCTAssertEqual(error as? NavigatorRenameError, .invalidName)
        }

        let collision = renamed.deletingLastPathComponent().appendingPathComponent("existing.md")
        try "Existing\n".write(to: collision, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try FileTreeViewController.renameItem(at: renamed, toName: "existing.md")
        )
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "# Review\n")
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "Existing\n")
    }

    func testMainMenuShortcutsAreResponderScopedAndDoNotClaimReturn() {
        AppMenu.install(for: NSApplication.shared, delegate: AppDelegate())

        let rename = menuItem(named: "Rename Navigator Item…")
        XCTAssertEqual(rename?.keyEquivalent, "")
        XCTAssertNil(rename?.target)

        let relative = menuItem(named: "Copy Path")
        XCTAssertEqual(relative?.keyEquivalent, "c")
        XCTAssertEqual(relative?.keyEquivalentModifierMask, [.command, .option, .shift])
        XCTAssertNil(relative?.target)

        let full = menuItem(named: "Copy Full Path")
        XCTAssertEqual(full?.keyEquivalent, "c")
        XCTAssertEqual(full?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertNil(full?.target)

        let finder = menuItem(named: "Reveal in Finder")
        XCTAssertEqual(finder?.keyEquivalent, "r")
        XCTAssertEqual(finder?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertNil(finder?.target)
    }

    func testMainMenuPathActionsReachTheFocusedNavigatorThroughResponderChain() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileTreeViewController()
        controller.openDirectory(fixture.directory, selectInitialMarkdown: false)
        controller.revealAndSelect(fixture.file, openFile: false)

        let outlineView = controller.outlineViewForTesting
        waitUntil { outlineView.selectedRow >= 0 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(outlineView))

        AppMenu.install(for: NSApplication.shared, delegate: AppDelegate())
        let pasteboard = NSPasteboard(name: .init("margin.navigator.responder.\(UUID().uuidString)"))
        controller.commandPasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        let copyRelative = #selector(FileTreeViewController.copyNavigatorPath(_:))
        XCTAssertTrue(outlineView.responds(to: copyRelative))
        XCTAssertTrue(window.firstResponder?.tryToPerform(copyRelative, with: nil) == true)
        XCTAssertEqual(pasteboard.string(forType: .string), "notes/review.md")

        let copyFull = #selector(FileTreeViewController.copyNavigatorFullPath(_:))
        XCTAssertTrue(outlineView.responds(to: copyFull))
        XCTAssertTrue(window.firstResponder?.tryToPerform(copyFull, with: nil) == true)
        XCTAssertEqual(pasteboard.string(forType: .string), fixture.file.path)
    }

    func testNonactiveSelectionNeverChangesTrackedDocument() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileTreeViewController()
        controller.openDirectory(fixture.directory, selectInitialMarkdown: false)
        controller.trackActiveDocument(fixture.file)

        controller.revealAndSelect(fixture.siblingFile, openFile: false)
        waitUntil { controller.outlineViewForTesting.selectedRow >= 0 }

        XCTAssertEqual(controller.activeDocumentURLForTesting, fixture.file)
    }

    func testOpenHandsPackagesAndDirectorySymlinksToTheSystem() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let package = fixture.directory.appendingPathComponent("Reference.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let link = fixture.directory.appendingPathComponent("Linked Notes", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.nestedDirectory)

        let controller = FileTreeViewController()
        var external: [URL] = []
        var documents: [URL] = []
        controller.onOpenExternalItem = { external.append($0) }
        controller.onOpenFile = { documents.append($0) }

        controller.openItemForTesting(package)
        controller.openItemForTesting(link)

        XCTAssertEqual(external, [package.standardizedFileURL, link.standardizedFileURL])
        XCTAssertTrue(documents.isEmpty)
    }

    private func makeFixture() throws -> (
        directory: URL,
        nestedDirectory: URL,
        file: URL,
        siblingFile: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-navigator-\(UUID().uuidString)", isDirectory: true)
        let nestedDirectory = directory.appendingPathComponent("notes", isDirectory: true)
        let file = nestedDirectory.appendingPathComponent("review.md")
        let siblingFile = nestedDirectory.appendingPathComponent("second.md")
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )
        try "# Review\n".write(to: file, atomically: true, encoding: .utf8)
        try "# Second\n".write(to: siblingFile, atomically: true, encoding: .utf8)
        return (directory, nestedDirectory, file, siblingFile)
    }

    private func menuItem(named title: String, in menu: NSMenu? = NSApplication.shared.mainMenu) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title == title { return item }
            if let nested = menuItem(named: title, in: item.submenu) { return nested }
        }
        return nil
    }


    private func waitUntil(timeout: TimeInterval = 1, condition: @escaping () -> Bool) {
        let completed = expectation(description: "Navigator condition became true")
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if condition() {
                completed.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
            }
        }
        poll()
        wait(for: [completed], timeout: timeout + 0.2)
    }
}
