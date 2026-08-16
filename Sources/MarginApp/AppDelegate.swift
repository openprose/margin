import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var workspaceWindows: [WorkspaceWindowController] = []
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        WorkspacePaneFactory.makeEditor = { EditorViewController() }
        WorkspacePaneFactory.makeComments = { CommentsViewController() }
        AppMenu.install(for: NSApplication.shared, delegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true

        let startupURLs = pendingURLs.isEmpty ? commandLineURLs() : pendingURLs
        pendingURLs.removeAll()

        if startupURLs.isEmpty {
            makeWorkspaceWindow(for: nil)
        } else {
            open(startupURLs)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if didFinishLaunching {
            open(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0).standardizedFileURL }
        if didFinishLaunching {
            open(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open in Margin"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls)
        }
    }

    @objc func toggleNavigator(_ sender: Any?) {
        activeWorkspaceWindow?.toggleNavigator(sender)
    }

    @objc func toggleComments(_ sender: Any?) {
        activeWorkspaceWindow?.toggleComments(sender)
    }

    @objc func toggleReaderMode(_ sender: Any?) {
        activeWorkspaceWindow?.toggleReaderMode(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller = activeWorkspaceWindow else { return false }

        switch menuItem.action {
        case #selector(toggleNavigator(_:)):
            menuItem.state = controller.isNavigatorVisible ? .on : .off
            return controller.canShowNavigator
        case #selector(toggleComments(_:)):
            menuItem.state = controller.isCommentsVisible ? .on : .off
            return true
        case #selector(toggleReaderMode(_:)):
            menuItem.state = controller.isReaderModeActive ? .on : .off
            return controller.canToggleReaderMode
        case #selector(WorkspaceDocumentSaving.saveDocument(_:)):
            return controller.canSaveDocument
        default:
            return true
        }
    }

    private var activeWorkspaceWindow: WorkspaceWindowController? {
        if let controller = NSApplication.shared.keyWindow?.windowController as? WorkspaceWindowController {
            return controller
        }
        return workspaceWindows.last(where: { $0.window?.isVisible == true })
    }

    private func open(_ urls: [URL]) {
        var seen = Set<String>()
        for url in urls.map(\.standardizedFileURL) where seen.insert(url.path).inserted {
            if let existing = workspaceWindows.first(where: { $0.workspaceURL == url }) {
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }

            if let empty = workspaceWindows.first(where: \.isEmpty) {
                empty.open(url)
                empty.showWindow(nil)
                empty.window?.makeKeyAndOrderFront(nil)
            } else {
                makeWorkspaceWindow(for: url)
            }
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func makeWorkspaceWindow(for url: URL?) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(workspaceURL: url)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.workspaceWindows.removeAll { $0 === controller }
        }
        workspaceWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func commandLineURLs() -> [URL] {
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )

        return CommandLine.arguments.dropFirst().compactMap { argument in
            guard !argument.hasPrefix("-") else { return nil }
            let expanded = (argument as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, relativeTo: workingDirectory)
                .standardizedFileURL
        }
    }
}
