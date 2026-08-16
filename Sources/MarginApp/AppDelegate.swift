import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var workspaceWindows: [WorkspaceWindowController] = []
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false
    private let sessionStore = WorkspaceSessionStore()
    private let sessionPersistenceQueue = DispatchQueue(
        label: "ink.margin.session-persistence",
        qos: .utility
    )
    private var isRestoringSession = false
    private var isSessionPersistScheduled = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        WorkspacePaneFactory.makeEditor = { EditorViewController() }
        WorkspacePaneFactory.makeComments = { CommentsViewController() }
        AppMenu.install(for: NSApplication.shared, delegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true

        let startupURLs = pendingURLs.isEmpty ? commandLineURLs() : pendingURLs
        pendingURLs.removeAll()

        if startupURLs.isEmpty, restoreLastSession() {
            // The first restored tab is visible immediately. Remaining tabs
            // attach on the next run-loop turn so session continuity never
            // delays the first usable window.
        } else if startupURLs.isEmpty {
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

    func applicationDidResignActive(_ notification: Notification) {
        persistSession()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistSession(synchronously: true)
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

    @objc func showCommandPalette(_ sender: Any?) {
        activeWorkspaceWindow?.showCommandPalette(sender)
    }

    @objc func navigateToHeading(_ sender: Any?) {
        activeWorkspaceWindow?.navigateToHeading(sender)
    }

    @objc func navigateToComment(_ sender: Any?) {
        activeWorkspaceWindow?.navigateToComment(sender)
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

    @objc func previousOpenComment(_ sender: Any?) {
        activeWorkspaceWindow?.previousOpenComment(sender)
    }

    @objc func nextOpenComment(_ sender: Any?) {
        activeWorkspaceWindow?.nextOpenComment(sender)
    }

    @objc func resolveCurrentComment(_ sender: Any?) {
        activeWorkspaceWindow?.resolveCurrentComment(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller = activeWorkspaceWindow else { return false }
        return validateMenuItem(menuItem, for: controller)
    }

    func validateMenuItem(
        _ menuItem: NSMenuItem,
        for controller: WorkspaceWindowController
    ) -> Bool {
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
        case #selector(showCommandPalette(_:)):
            return true
        case #selector(navigateToHeading(_:)):
            return controller.canNavigateHeadings
        case #selector(navigateToComment(_:)):
            return controller.canNavigateAnyComments
        case #selector(previousFile(_:)), #selector(nextFile(_:)):
            return controller.canNavigateFiles
        case #selector(focusNavigator(_:)):
            return controller.canShowNavigator
        case #selector(focusComments(_:)):
            return controller.canShowComments
        case #selector(focusEditor(_:)):
            return true
        case #selector(previousOpenComment(_:)), #selector(nextOpenComment(_:)),
             #selector(resolveCurrentComment(_:)):
            return controller.canNavigateComments
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
        tabbedTo parentWindow: NSWindow? = nil,
        restorationState: WorkspaceTabSession? = nil
    ) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            workspaceURL: url,
            restorationState: restorationState
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.workspaceWindows.removeAll { $0 === controller }
            self.persistSession()
        }
        controller.onSessionStateChange = { [weak self] in self?.schedulePersistSession() }
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
        schedulePersistSession()
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

    private func restoreLastSession() -> Bool {
        guard let session = sessionStore.load() else { return false }
        let requestedSelectedState = session.tabs.indices.contains(session.selectedIndex)
            ? session.tabs[session.selectedIndex]
            : session.tabs.first
        let tabs = session.tabs.filter { state in
            FileManager.default.fileExists(atPath: state.workspacePath)
        }
        guard let first = tabs.first else { return false }

        isRestoringSession = true
        let firstController = makeWorkspaceWindow(
            for: URL(fileURLWithPath: first.workspacePath),
            restorationState: first
        )

        DispatchQueue.main.async { [weak self, weak firstController] in
            guard let self, let firstController else { return }
            var controllers = [firstController]
            var tabAnchor = firstController.window
            for state in tabs.dropFirst() {
                let controller = self.makeWorkspaceWindow(
                    for: URL(fileURLWithPath: state.workspacePath),
                    tabbedTo: tabAnchor,
                    restorationState: state
                )
                controllers.append(controller)
                tabAnchor = controller.window
            }
            let selected = requestedSelectedState.flatMap { tabs.firstIndex(of: $0) }
                ?? min(max(session.selectedIndex, 0), controllers.count - 1)
            self.focus(controllers[selected])
            self.isRestoringSession = false
            self.persistSession()
        }
        return true
    }

    private func persistSession(synchronously: Bool = false) {
        guard didFinishLaunching, !isRestoringSession else { return }
        let tabs = workspaceWindows.compactMap(\.sessionState)
        let selectedController = activeWorkspaceWindow
        let selectedIndex = selectedController.flatMap { selected in
            workspaceWindows.firstIndex { $0 === selected }
        } ?? 0
        let session = tabs.isEmpty
            ? nil
            : WorkspaceSession(tabs: tabs, selectedIndex: selectedIndex)
        let save = { [sessionStore] in sessionStore.save(session) }
        if synchronously {
            sessionPersistenceQueue.sync(execute: save)
        } else {
            sessionPersistenceQueue.async(execute: save)
        }
    }

    private func schedulePersistSession() {
        guard didFinishLaunching, !isRestoringSession, !isSessionPersistScheduled else { return }
        isSessionPersistScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSessionPersistScheduled = false
            self.persistSession()
        }
    }
}
