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

    @objc func newWindow(_ sender: Any?) {
        makeWorkspaceWindow(for: nil)
    }

    @objc func newWindowForTab(_ sender: Any?) {
        makeWorkspaceWindow(for: nil, tabbedTo: activeWorkspaceWindow?.window)
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        guard let window = activeWorkspaceWindow?.window else { return }
        let windows = window.tabGroup?.windows ?? [window]
        guard !windows.isEmpty else { return }
        let requestedIndex = sender.tag == 9 ? windows.count - 1 : sender.tag - 1
        guard windows.indices.contains(requestedIndex) else { return }
        let selected = windows[requestedIndex]
        window.tabGroup?.selectedWindow = selected
        selected.makeKeyAndOrderFront(sender)
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

    @objc func quickOpen(_ sender: Any?) {
        activeWorkspaceWindow?.quickOpen(sender)
    }

    @objc func navigateToHeading(_ sender: Any?) {
        activeWorkspaceWindow?.navigateToHeading(sender)
    }

    @objc func previousFile(_ sender: Any?) {
        activeWorkspaceWindow?.previousFile(sender)
    }

    @objc func nextFile(_ sender: Any?) {
        activeWorkspaceWindow?.nextFile(sender)
    }

    @objc func focusNavigator(_ sender: Any?) {
        activeWorkspaceWindow?.focusNavigator(sender)
    }

    @objc func focusEditor(_ sender: Any?) {
        activeWorkspaceWindow?.focusEditor(sender)
    }

    @objc func focusComments(_ sender: Any?) {
        activeWorkspaceWindow?.focusComments(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller = activeWorkspaceWindow else { return false }

        switch menuItem.action {
        case #selector(toggleNavigator(_:)):
            menuItem.state = controller.isNavigatorVisible ? .on : .off
            return controller.canShowNavigator
        case #selector(toggleComments(_:)):
            menuItem.state = controller.isCommentsVisible ? .on : .off
            return controller.canShowComments
        case #selector(toggleReaderMode(_:)):
            menuItem.state = controller.isReaderModeActive ? .on : .off
            return controller.canToggleReaderMode
        case #selector(WorkspaceDocumentSaving.saveDocument(_:)):
            return controller.canSaveDocument
        case #selector(quickOpen(_:)):
            return controller.canQuickOpen
        case #selector(navigateToHeading(_:)):
            return controller.canNavigateHeadings
        case #selector(previousFile(_:)), #selector(nextFile(_:)):
            return controller.canNavigateFiles
        case #selector(focusNavigator(_:)):
            return controller.canShowNavigator
        case #selector(focusComments(_:)):
            return controller.canShowComments
        case #selector(focusEditor(_:)):
            return true
        case #selector(selectTab(_:)):
            guard let window = controller.window else { return false }
            let windows = window.tabGroup?.windows ?? [window]
            let index = menuItem.tag == 9 ? windows.count - 1 : menuItem.tag - 1
            guard windows.indices.contains(index) else {
                menuItem.state = .off
                return false
            }
            menuItem.state = windows[index] === window ? .on : .off
            return true
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
        var tabAnchor = activeWorkspaceWindow?.window
        for url in urls.map(\.standardizedFileURL) where seen.insert(url.path).inserted {
            if let existing = workspaceWindows.first(where: {
                $0.workspaceURL == url || $0.documentURL == url
            }) {
                focus(existing)
                tabAnchor = existing.window
                continue
            }

            if let empty = activeWorkspaceWindow, empty.isEmpty {
                empty.open(url)
                focus(empty)
                tabAnchor = empty.window
            } else {
                let created = makeWorkspaceWindow(for: url, tabbedTo: tabAnchor)
                tabAnchor = created.window
            }
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func makeWorkspaceWindow(
        for url: URL?,
        tabbedTo parentWindow: NSWindow? = nil
    ) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(workspaceURL: url)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.workspaceWindows.removeAll { $0 === controller }
        }
        workspaceWindows.append(controller)
        if let parentWindow, let window = controller.window, parentWindow !== window {
            let parentController = parentWindow.windowController as? WorkspaceWindowController
            parentController?.prepareForTabAttachment()
            controller.prepareForTabAttachment()
            parentWindow.addTabbedWindow(window, ordered: .above)
            parentController?.refreshTabPresentation()
            controller.refreshTabPresentation()
        }
        controller.showWindow(nil)
        focus(controller)
        return controller
    }

    private func focus(_ controller: WorkspaceWindowController) {
        guard let window = controller.window else { return }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
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
