import AppKit
import ColorSync
import MarginCore

enum MarginRuntimeEnvironment {
    static var isPerformanceBenchmark: Bool {
        ProcessInfo.processInfo.environment["MARGIN_BENCHMARK_READY_FILE"] != nil
    }
}

enum WorkspaceRestorationIdentifier {
    private static let prefix = "ink.margin.workspace."

    static func make(_ value: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(prefix + value)
    }
}

enum WorkspaceScreenIdentity {
    static func identifier(for screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let identifier = CFUUIDCreateString(nil, displayUUID)
        else {
            return "display-\(displayID)"
        }
        return identifier as String
    }
}

enum WorkspaceLaunchAction: Equatable {
    case focusRestoredWindow(Int)
    case createEmptyWindow
}

enum WorkspaceLaunchPolicy {
    static func action(
        previouslySelectedIndex: Int,
        restoredWindowsOnActiveSpace: [Bool]
    ) -> WorkspaceLaunchAction {
        if restoredWindowsOnActiveSpace.indices.contains(previouslySelectedIndex),
           restoredWindowsOnActiveSpace[previouslySelectedIndex] {
            return .focusRestoredWindow(previouslySelectedIndex)
        }
        if let localIndex = restoredWindowsOnActiveSpace.firstIndex(of: true) {
            return .focusRestoredWindow(localIndex)
        }
        return .createEmptyWindow
    }
}

private struct WorkspaceBackgroundReveal {
    let windows: [NSWindow]
    let selectedWindow: NSWindow
    let assignment: WorkspaceSpaceAssignment?
}

protocol WorkspacePathRenameParticipating: AnyObject {
    var documentURLForPathRename: URL? { get }
    func prepareForPathRename(from sourceURL: URL) -> Bool
    func applyPathRename(from sourceURL: URL, to destinationURL: URL)
}

enum WorkspacePathRenameCoordinatorError: LocalizedError, Equatable {
    case documentVeto([String])

    var errorDescription: String? {
        switch self {
        case .documentVeto(let paths):
            let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: ", ")
            return "Rename cancelled because Margin could not safely save \(names). Nothing was moved."
        }
    }
}

enum WorkspacePathRelocation {
    static func destinationURL(for sourceURL: URL, proposedName: String) throws -> URL {
        let nameIsEmpty = proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !nameIsEmpty,
              proposedName != ".",
              proposedName != "..",
              !proposedName.contains("/")
        else {
            throw NavigatorRenameError.invalidName
        }
        var sourceIsDirectory = ObjCBool(false)
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory)
        return sourceURL.deletingLastPathComponent()
            .appendingPathComponent(
                proposedName,
                isDirectory: sourceURL.hasDirectoryPath || sourceIsDirectory.boolValue
            )
            .standardizedFileURL
    }

    static func relocatedURL(_ candidateURL: URL, from sourceURL: URL, to destinationURL: URL) -> URL? {
        let sourceComponents = sourceURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        guard candidateComponents.starts(with: sourceComponents) else { return nil }
        return candidateComponents.dropFirst(sourceComponents.count).reduce(destinationURL) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }

    static func contains(_ candidateURL: URL, within directoryURL: URL) -> Bool {
        candidateURL.standardizedFileURL.pathComponents.starts(
            with: directoryURL.standardizedFileURL.pathComponents
        )
    }
}

struct WorkspacePathRenameCoordinator {
    var fileManager: FileManager = .default

    func rename(
        sourceURL: URL,
        proposedName: String,
        participants: [WorkspacePathRenameParticipating]
    ) throws -> URL {
        let sourceURL = sourceURL.standardizedFileURL
        let destinationURL = try WorkspacePathRelocation.destinationURL(
            for: sourceURL,
            proposedName: proposedName
        )
        guard destinationURL != sourceURL else { return sourceURL }

        let affected = participants.filter { participant in
            guard let documentURL = participant.documentURLForPathRename else { return false }
            return WorkspacePathRelocation.relocatedURL(
                documentURL,
                from: sourceURL,
                to: destinationURL
            ) != nil
        }
        let vetoedPaths = affected.compactMap { participant -> String? in
            participant.prepareForPathRename(from: sourceURL)
                ? nil
                : participant.documentURLForPathRename?.path
        }
        guard vetoedPaths.isEmpty else {
            throw WorkspacePathRenameCoordinatorError.documentVeto(vetoedPaths)
        }

        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        participants.forEach {
            $0.applyPathRename(from: sourceURL, to: destinationURL)
        }
        return destinationURL
    }
}

/// Builds the open-tab comparison command from lightweight tab metadata. Full
/// editor strings are resolved only after the user chooses a candidate.
enum OpenTabComparisonPickerModel {
    static func isAvailable(
        active: WorkspaceWindowController?,
        windows: [WorkspaceWindowController]
    ) -> Bool {
        guard let active, active.comparisonSourceMetadata != nil else { return false }
        return windows.contains {
            $0 !== active && $0.comparisonSourceMetadata != nil
        }
    }

    static func items(
        active: WorkspaceWindowController,
        windows: [WorkspaceWindowController],
        onChoose: @escaping (WorkspaceWindowController, WorkspaceWindowController) -> Void
    ) -> [NavigationPaletteItem] {
        guard active.comparisonSourceMetadata != nil else { return [] }
        return windows.compactMap { candidate -> NavigationPaletteItem? in
            guard candidate !== active,
                  let metadata = candidate.comparisonSourceMetadata else { return nil }
            return NavigationPaletteItem(
                title: metadata.label,
                subtitle: metadata.sourceURL?.deletingLastPathComponent().path ?? "Open snapshot",
                detail: metadata.sourceURL?.path ?? "",
                symbolName: "doc.on.doc",
                searchText: "\(metadata.label) \(metadata.sourceURL?.path ?? "")"
            ) { [weak active, weak candidate] in
                guard let active, let candidate else { return }
                onChoose(active, candidate)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var workspaceWindows: [WorkspaceWindowController] = []
    private var comparisonWindows: [ComparisonWindowController] = []
    private var comparisonPickerController: NavigationPaletteController?
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false
    private let sessionStore: WorkspaceSessionStore
    private let scratchpadStore: ScratchpadStore
    private let recentWorkspaceStore: RecentWorkspaceStore
    private let shouldPersistSession: Bool
    private let sessionPersistenceQueue = DispatchQueue(
        label: "ink.margin.session-persistence",
        qos: .utility
    )
    private var isRestoringSession = false
    private var isSessionPersistScheduled = false
    private var terminationSession: WorkspaceSession?
    private var isDisplayLayoutScheduled = false
    private lazy var spaceRestorationBackend = WorkspaceSpaceRestorationBackendFactory.make()

    override init() {
        let defaults = Self.runtimeDefaults()
        let shouldPersistSession = !MarginRuntimeEnvironment.isPerformanceBenchmark
        sessionStore = WorkspaceSessionStore(defaults: defaults)
        scratchpadStore = ScratchpadStore(defaults: defaults)
        recentWorkspaceStore = RecentWorkspaceStore(
            defaults: defaults,
            persistenceEnabled: shouldPersistSession
        )
        self.shouldPersistSession = shouldPersistSession
        super.init()
    }

    init(
        sessionStore: WorkspaceSessionStore,
        scratchpadStore: ScratchpadStore,
        recentWorkspaceStore: RecentWorkspaceStore = RecentWorkspaceStore(),
        shouldPersistSession: Bool = true
    ) {
        self.sessionStore = sessionStore
        self.scratchpadStore = scratchpadStore
        self.recentWorkspaceStore = recentWorkspaceStore
        self.shouldPersistSession = shouldPersistSession
        super.init()
    }

    private static func runtimeDefaults() -> UserDefaults {
        guard let suiteName = ProcessInfo.processInfo.environment[
            "MARGIN_PREFERENCES_SUITE"
        ],
              !suiteName.isEmpty,
              let defaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return defaults
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        WorkspacePaneFactory.makeEditor = { EditorViewController() }
        WorkspacePaneFactory.makeComments = { CommentsViewController() }
        AppMenu.install(for: NSApplication.shared, delegate: self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowScreenDidChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true

        let startupURLs = pendingURLs.isEmpty ? commandLineURLs() : pendingURLs
        pendingURLs.removeAll()
        var defersActivationUntilRestorationCompletes = false

        if startupURLs.isEmpty, restoreLastSession() {
            // Rebuild the complete native tab graph before revealing it so
            // each independent window can return to its saved Space cleanly.
            defersActivationUntilRestorationCompletes = true
        } else if startupURLs.isEmpty {
            makeWorkspaceWindow(for: nil)
        } else {
            open(startupURLs)
        }

        if !defersActivationUntilRestorationCompletes {
            activatePreparedApplication()
        }
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        false
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

    func applicationShouldHandleReopen(
        _ _: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        // Reopen is the only running-app event that may surface a window.
        // In particular, never pre-create or key a window from an active-Space
        // notification: doing so can steal focus from the app the user is
        // switching to, and makes ordinary Space navigation observable work.
        if let localWindow = activeSpaceDocumentWindow {
            localWindow.makeKeyAndOrderFront(nil)
            localWindow.makeMain()
        } else {
            let controller = makeWorkspaceWindow(for: nil, ordersFront: false)
            focus(controller)
            controller.window?.makeMain()
        }
        // The reopen event already carries activation intent. Explicitly
        // activating here can make AppKit choose a previously key window on a
        // different Space even after the local window has been made key.
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        persistSession()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        schedulePersistSession()
    }

    @objc private func windowScreenDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.windowController is WorkspaceWindowController else { return }
        schedulePersistSession()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard didFinishLaunching, !MarginRuntimeEnvironment.isPerformanceBenchmark else { return }
        let displays = workspaceDisplayGeometries()
        workspaceWindows.forEach {
            $0.windowPlacementMemory.displayConfigurationChanged(to: displays)
        }
        if workspaceWindows.contains(where: { $0.windowPlacementMemory.needsDisplayAdjustment }) {
            scheduleDisplayLayoutAdjustment()
        }
    }

    private func scheduleDisplayLayoutAdjustment() {
        guard !isDisplayLayoutScheduled else { return }
        isDisplayLayoutScheduled = true
        // Coalesce a display reconfiguration on the main queue. No polling,
        // active-Space observer, activation, or private Space moves are needed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isDisplayLayoutScheduled = false }
            guard !self.isRestoringSession, self.terminationSession == nil else { return }
            var visited = Set<ObjectIdentifier>()
            for controller in self.workspaceWindows {
                guard let window = controller.window else { continue }
                let selected = window.tabGroup?.selectedWindow ?? window
                guard visited.insert(ObjectIdentifier(selected)).inserted,
                      !selected.styleMask.contains(.fullScreen),
                      !selected.isMiniaturized,
                      !selected.inLiveResize,
                      let selectedController = selected.windowController as? WorkspaceWindowController,
                      let frame = selectedController.windowPlacementMemory.takeFrameForDisplayChange() else { continue }
                selectedController.applyRestoredWindowFrame(frame)
            }
            self.schedulePersistSession()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspaceWindows.allSatisfy({ $0.prepareForApplicationTermination() }) else {
            terminationSession = nil
            return .terminateCancel
        }
        guard shouldPersistSession else { return .terminateNow }
        terminationSession = captureWorkspaceSession()
        persistSession(synchronously: true)
        workspaceWindows.forEach {
            $0.invalidateRestorableState()
            $0.window?.invalidateRestorableState()
        }
        sender.invalidateRestorableState()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard shouldPersistSession else { return }
        if let terminationSession {
            sessionPersistenceQueue.sync { [sessionStore] in
                sessionStore.save(terminationSession)
            }
        } else {
            persistSession(synchronously: true)
        }
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
        makeScratchpadWindow(tabbedTo: nil)
    }

    @objc func newWindowForTab(_ sender: Any?) {
        makeScratchpadWindow(tabbedTo: activeTabAnchorWindow)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        activeWorkspaceWindow?.saveDocumentAs(sender)
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        guard let window = activeTabAnchorWindow else { return }
        let windows = window.tabGroup?.windows ?? [window]
        guard !windows.isEmpty else { return }
        let requestedIndex = sender.tag == 9 ? windows.count - 1 : sender.tag - 1
        guard windows.indices.contains(requestedIndex) else { return }
        let selected = windows[requestedIndex]
        window.tabGroup?.selectedWindow = selected
        selected.makeKeyAndOrderFront(sender)
    }

    @objc func compareFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Compare Markdown Files"
        panel.message = "Choose exactly two files. The first is the reference; the second is the proposed state."
        panel.prompt = "Compare"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            guard panel.urls.count == 2 else {
                let alert = NSAlert()
                alert.messageText = "Choose two files to compare"
                alert.informativeText = "Margin needs one reference file and one proposed file."
                alert.alertStyle = .informational
                alert.runModal()
                return
            }
            self.makeComparisonWindow(
                request: .files(left: panel.urls[0], right: panel.urls[1]),
                tabbedTo: self.activeTabAnchorWindow
            )
        }
    }

    @objc func compareActiveTab(_ sender: Any?) {
        guard let active = activeWorkspaceWindow,
              active.comparisonSourceMetadata != nil,
              let window = active.window else { return }
        comparisonPickerController?.close()

        let items = OpenTabComparisonPickerModel.items(
            active: active,
            windows: workspaceWindows
        ) { [weak self] active, candidate in
            guard let self,
                  let refreshedLeft = active.comparisonSource,
                  let refreshedRight = candidate.comparisonSource else { return }
                self.makeComparisonWindow(
                    request: .sources(left: refreshedLeft, right: refreshedRight),
                    tabbedTo: active.window,
                    refreshRequestProvider: { [weak active, weak candidate] in
                        guard let left = active?.comparisonSource,
                              let right = candidate?.comparisonSource else { return nil }
                        return .sources(left: left, right: right)
                    }
                )
        }
        guard !items.isEmpty else { return }

        let palette = NavigationPaletteController(
            title: "Compare With Open Tab",
            placeholder: "Search open tabs",
            items: items,
            emptyMessage: "No other open Markdown tabs"
        )
        comparisonPickerController = palette
        palette.onClose = { [weak self, weak palette] in
            guard let self, self.comparisonPickerController === palette else { return }
            self.comparisonPickerController = nil
        }
        palette.show(relativeTo: window)
    }

    @objc func previousComparisonChange(_ sender: Any?) {
        activeComparisonWindow?.previousChange(sender)
    }

    @objc func nextComparisonChange(_ sender: Any?) {
        activeComparisonWindow?.nextChange(sender)
    }

    @objc func refreshComparison(_ sender: Any?) {
        activeComparisonWindow?.refreshComparison(sender)
    }

    @objc func swapComparisonSides(_ sender: Any?) {
        activeComparisonWindow?.swapSides(sender)
    }

    @objc func toggleComparisonSideBySide(_ sender: Any?) {
        activeComparisonWindow?.toggleSideBySide(sender)
    }

    @objc func toggleComparisonWhitespace(_ sender: Any?) {
        activeComparisonWindow?.toggleWhitespace(sender)
    }

    @objc func applySelectedComparisonLeftToRight(_ sender: Any?) {
        activeComparisonWindow?.apply(visualDirection: .leftToRight, selectedOnly: true)
    }

    @objc func applySelectedComparisonRightToLeft(_ sender: Any?) {
        activeComparisonWindow?.apply(visualDirection: .rightToLeft, selectedOnly: true)
    }

    @objc func applyAllComparisonLeftToRight(_ sender: Any?) {
        activeComparisonWindow?.apply(visualDirection: .leftToRight, selectedOnly: false)
    }

    @objc func applyAllComparisonRightToLeft(_ sender: Any?) {
        activeComparisonWindow?.apply(visualDirection: .rightToLeft, selectedOnly: false)
    }

    @objc func toggleNavigator(_ sender: Any?) {
        activeWorkspaceWindow?.toggleNavigator(sender)
    }

    @objc func toggleComments(_ sender: Any?) {
        if let comparison = activeComparisonWindow {
            comparison.toggleComments(sender)
        } else {
            activeWorkspaceWindow?.toggleComments(sender)
        }
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
        if let comparison = activeComparisonWindow {
            comparison.focusComparison(sender)
        } else {
            activeWorkspaceWindow?.focusEditor(sender)
        }
    }

    @objc func focusComments(_ sender: Any?) {
        if let comparison = activeComparisonWindow {
            comparison.focusComments(sender)
        } else {
            activeWorkspaceWindow?.focusComments(sender)
        }
    }

    @objc func previousOpenComment(_ sender: Any?) {
        if let comparison = activeComparisonWindow {
            comparison.previousOpenComment(sender)
        } else {
            activeWorkspaceWindow?.previousOpenComment(sender)
        }
    }

    @objc func nextOpenComment(_ sender: Any?) {
        if let comparison = activeComparisonWindow {
            comparison.nextOpenComment(sender)
        } else {
            activeWorkspaceWindow?.nextOpenComment(sender)
        }
    }

    @objc func resolveCurrentComment(_ sender: Any?) {
        if let comparison = activeComparisonWindow {
            comparison.resolveCurrentComment(sender)
        } else {
            activeWorkspaceWindow?.resolveCurrentComment(sender)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openDocument(_:)), #selector(newWindow(_:)),
             #selector(newWindowForTab(_:)), #selector(compareFiles(_:)):
            return true
        case #selector(saveDocumentAs(_:)):
            return activeWorkspaceWindow?.canSaveDocumentAs == true
        case #selector(compareActiveTab(_:)):
            return OpenTabComparisonPickerModel.isAvailable(
                active: activeWorkspaceWindow,
                windows: workspaceWindows
            )
        case #selector(previousComparisonChange(_:)), #selector(nextComparisonChange(_:)):
            return activeComparisonWindow?.canNavigateChanges == true
        case #selector(refreshComparison(_:)):
            return activeComparisonWindow?.canRefresh == true
        case #selector(swapComparisonSides(_:)):
            return activeComparisonWindow?.canSwapSides == true
        case #selector(toggleComparisonSideBySide(_:)):
            guard let comparison = activeComparisonWindow else { return false }
            menuItem.state = comparison.isSideBySidePreferred ? .on : .off
            return comparison.canChangeDisplayOptions
        case #selector(toggleComparisonWhitespace(_:)):
            guard let comparison = activeComparisonWindow else { return false }
            menuItem.state = comparison.isWhitespaceShown ? .on : .off
            return comparison.canChangeDisplayOptions
        case #selector(applySelectedComparisonLeftToRight(_:)),
             #selector(applySelectedComparisonRightToLeft(_:)):
            return activeComparisonWindow?.canApplySelectedChange == true
        case #selector(applyAllComparisonLeftToRight(_:)),
             #selector(applyAllComparisonRightToLeft(_:)):
            return activeComparisonWindow?.canApplyChanges == true
        case #selector(toggleComments(_:)) where activeComparisonWindow != nil:
            guard let comparison = activeComparisonWindow else { return false }
            menuItem.state = comparison.isCommentsVisible ? .on : .off
            return comparison.canShowComments
        case #selector(focusComments(_:)) where activeComparisonWindow != nil:
            return activeComparisonWindow?.canShowComments == true
        case #selector(focusEditor(_:)) where activeComparisonWindow != nil:
            return activeComparisonWindow?.canShowComments == true
        case #selector(previousOpenComment(_:)) where activeComparisonWindow != nil,
             #selector(nextOpenComment(_:)) where activeComparisonWindow != nil:
            return activeComparisonWindow?.canNavigateComments == true
        case #selector(resolveCurrentComment(_:)) where activeComparisonWindow != nil:
            return activeComparisonWindow?.canResolveCurrentComment == true
        case #selector(selectTab(_:)):
            guard let window = activeTabAnchorWindow else { return false }
            let windows = window.tabGroup?.windows ?? [window]
            let index = menuItem.tag == 9 ? windows.count - 1 : menuItem.tag - 1
            guard windows.indices.contains(index) else {
                menuItem.state = .off
                return false
            }
            menuItem.state = windows[index] === window ? .on : .off
            return true
        default:
            break
        }
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
        default:
            return true
        }
    }

    private var activeWorkspaceWindow: WorkspaceWindowController? {
        if let keyWindow = NSApplication.shared.keyWindow {
            let documentWindow = keyWindow.parent ?? keyWindow
            return documentWindow.windowController as? WorkspaceWindowController
        }
        return workspaceWindows.last(where: { $0.window?.isVisible == true })
    }

    private var activeComparisonWindow: ComparisonWindowController? {
        guard let keyWindow = NSApplication.shared.keyWindow else { return nil }
        let documentWindow = keyWindow.parent ?? keyWindow
        return documentWindow.windowController as? ComparisonWindowController
    }

    private var activeTabAnchorWindow: NSWindow? {
        if let keyWindow = NSApplication.shared.keyWindow {
            let documentWindow = keyWindow.parent ?? keyWindow
            if documentWindow.windowController is WorkspaceWindowController
                || documentWindow.windowController is ComparisonWindowController {
                return documentWindow
            }
            return nil
        }
        return workspaceWindows.last(where: { $0.window?.isVisible == true })?.window
    }

    private var activeSpaceDocumentWindow: NSWindow? {
        NSApplication.shared.windows.first { window in
            guard windowIsOnActiveSpace(window),
                  (window.windowController is WorkspaceWindowController
                    || window.windowController is ComparisonWindowController) else { return false }
            return window.tabGroup?.selectedWindow == nil
                || window.tabGroup?.selectedWindow === window
        }
    }

    private func windowIsOnActiveSpace(_ window: NSWindow) -> Bool {
        if window.windowNumber > 0,
           let result = spaceRestorationBackend.windowsAreOnActiveSpace([
            CGWindowID(window.windowNumber)
           ]) {
            return result
        }
        return window.isOnActiveSpace
    }

    private func open(_ urls: [URL]) {
        var seen = Set<String>()
        var tabAnchor = activeTabAnchorWindow
        for url in urls.map(\.standardizedFileURL) where seen.insert(url.path).inserted {
            switch ComparisonURLClassifier.classify(url) {
            case .openRequest:
                let created = makeComparisonWindow(
                    request: .openRequest(url),
                    tabbedTo: tabAnchor
                )
                tabAnchor = created.window
                continue
            case .review:
                let created = makeComparisonWindow(
                    request: .review(url),
                    tabbedTo: tabAnchor
                )
                tabAnchor = created.window
                continue
            case .document:
                break
            }
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

        activatePreparedApplication()
    }

    private func makeScratchpadWindow(tabbedTo parentWindow: NSWindow?) {
        do {
            let scratchpad = try scratchpadStore.create()
            makeWorkspaceWindow(
                for: nil,
                tabbedTo: parentWindow,
                scratchpad: scratchpad
            )
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could Not Create Scratchpad"
            alert.runModal()
        }
    }

    @discardableResult
    private func makeWorkspaceWindow(
        for url: URL?,
        tabbedTo parentWindow: NSWindow? = nil,
        restorationState: WorkspaceTabSession? = nil,
        scratchpad: ScratchpadDescriptor? = nil,
        restorationIdentifier: String? = nil,
        ordersFront: Bool = true
    ) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            workspaceURL: url,
            scratchpad: scratchpad,
            restorationState: restorationState,
            recentWorkspaceStore: recentWorkspaceStore,
            scratchpadStore: scratchpadStore,
            restorationIdentifier: restorationIdentifier
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.workspaceWindows.removeAll { $0 === controller }
            if self.terminationSession == nil {
                self.schedulePersistSession()
            }
        }
        controller.onSessionStateChange = { [weak self, weak controller] in
            controller?.invalidateRestorableState()
            controller?.window?.invalidateRestorableState()
            self?.schedulePersistSession()
            if controller?.windowPlacementMemory.needsDisplayAdjustment == true {
                self?.scheduleDisplayLayoutAdjustment()
            }
        }
        controller.onUserWindowGeometryChange = { [weak controller] in
            guard let window = controller?.window else { return }
            for tab in window.tabGroup?.windows ?? [window] {
                (tab.windowController as? WorkspaceWindowController)?
                    .windowPlacementMemory.userWillChangeFrame()
            }
        }
        controller.onRequestPathRename = { [weak self] sourceURL, proposedName in
            guard let self else {
                return .failure(NavigatorRenameError.coordinationUnavailable)
            }
            do {
                let destinationURL = try WorkspacePathRenameCoordinator().rename(
                    sourceURL: sourceURL,
                    proposedName: proposedName,
                    participants: self.workspaceWindows
                )
                self.schedulePersistSession()
                return .success(destinationURL)
            } catch {
                return .failure(error)
            }
        }
        workspaceWindows.append(controller)
        if let parentWindow, let window = controller.window, parentWindow !== window {
            switch parentWindow.windowController {
            case let parent as WorkspaceWindowController:
                parent.prepareForTabAttachment()
            case let parent as ComparisonWindowController:
                parent.prepareForTabAttachment()
            default:
                break
            }
            controller.prepareForTabAttachment()
            if let parent = parentWindow.windowController as? WorkspaceWindowController {
                controller.windowPlacementMemory = parent.windowPlacementMemory
            }
            parentWindow.addTabbedWindow(window, ordered: .above)
            switch parentWindow.windowController {
            case let parent as WorkspaceWindowController:
                parent.refreshTabPresentation()
            case let parent as ComparisonWindowController:
                parent.refreshTabPresentation()
            default:
                break
            }
            controller.refreshTabPresentation()
        }
        if ordersFront {
            controller.showWindow(nil)
            focus(controller)
            schedulePersistSession()
        }
        return controller
    }

    @discardableResult
    private func makeComparisonWindow(
        request: AppComparisonRequest,
        tabbedTo parentWindow: NSWindow? = nil,
        refreshRequestProvider: (() -> AppComparisonRequest?)? = nil
    ) -> ComparisonWindowController {
        let controller = ComparisonWindowController(
            request: request,
            refreshRequestProvider: refreshRequestProvider
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.comparisonWindows.removeAll { $0 === controller }
        }
        controller.onApplyRequest = { [weak self, weak controller] direction, blockIDs, presentation in
            guard let self, let controller else { return }
            self.beginComparisonApply(
                direction: direction,
                blockIDs: blockIDs,
                presentation: presentation,
                controller: controller
            )
        }
        comparisonWindows.append(controller)
        if let parentWindow, let window = controller.window, parentWindow !== window {
            switch parentWindow.windowController {
            case let parent as WorkspaceWindowController:
                parent.prepareForTabAttachment()
                parent.refreshTabPresentation()
            case let parent as ComparisonWindowController:
                parent.prepareForTabAttachment()
                parent.refreshTabPresentation()
            default:
                break
            }
            controller.prepareForTabAttachment()
            parentWindow.addTabbedWindow(window, ordered: .above)
            controller.refreshTabPresentation()
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func beginComparisonApply(
        direction: ComparisonApplyDirection,
        blockIDs: [String]?,
        presentation: ComparisonPresentation,
        controller: ComparisonWindowController
    ) {
        controller.comparisonViewController.showOperationStatus("Preparing verified change set…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak controller] in
            let result = Result {
                try ComparisonApplyService().plan(
                    pair: presentation.pair,
                    result: presentation.result,
                    direction: direction,
                    blockIDs: blockIDs
                )
            }
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                switch result {
                case .success(let plan):
                    let knownDestination = direction.destinationIsLeft
                        ? presentation.leftSourceURL
                        : presentation.rightSourceURL
                    if let knownDestination {
                        self.confirmComparisonApply(
                            plan,
                            to: knownDestination,
                            controller: controller
                        )
                    } else {
                        self.chooseComparisonDestination(plan: plan, controller: controller)
                    }
                case .failure(let error):
                    controller.comparisonViewController.showOperationStatus(
                        error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }

    private func chooseComparisonDestination(
        plan: ComparisonApplyPlan,
        controller: ComparisonWindowController
    ) {
        let panel = NSOpenPanel()
        panel.title = "Choose Destination Markdown File"
        panel.message = "Margin will apply only if this file still matches the compared snapshot."
        panel.prompt = "Choose Destination"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak controller] response in
            guard let controller else { return }
            guard response == .OK,
                  let self,
                  let url = panel.url else {
                controller.comparisonViewController.restoreSnapshotStatus()
                return
            }
            self.confirmComparisonApply(plan, to: url, controller: controller)
        }
        if let window = controller.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func confirmComparisonApply(
        _ plan: ComparisonApplyPlan,
        to destinationURL: URL,
        controller: ComparisonWindowController
    ) {
        let count = plan.patches.count
        let noun = count == 1 ? "change" : "changes"
        let openDestination = workspaceWindows.first {
            $0.documentURL?.standardizedFileURL == destinationURL.standardizedFileURL
        }
        let alert = NSAlert()
        alert.messageText = "Apply \(count) \(noun) to \(destinationURL.lastPathComponent)?"
        let destinationPath = destinationURL.standardizedFileURL.path
        let safetyMessage = openDestination == nil
            ? "Margin will verify the exact compared content and write every change together, or write nothing."
            : "Margin will verify the open editor content and make this one undoable editing action."
        alert.informativeText = "\(destinationPath)\n\n\(safetyMessage)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apply \(count) \(noun.capitalized)")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = {
            [weak self, weak controller] response in
            guard let controller else { return }
            guard response == .alertFirstButtonReturn,
                  let self else {
                controller.comparisonViewController.restoreSnapshotStatus()
                return
            }
            // Re-resolve at commit time. A matching document may have opened
            // while the confirmation sheet was visible; writing behind that
            // editor would bypass its undo stack and dirty-state protections.
            let openDestination = self.workspaceWindows.first {
                $0.documentURL?.standardizedFileURL == destinationURL.standardizedFileURL
            }
            if let openDestination {
                do {
                    guard try openDestination.applyComparisonPlan(plan, to: destinationURL) else {
                        throw ComparisonError.io("The destination tab is no longer available.")
                    }
                    controller.comparisonViewController.showOperationStatus(
                        "Applied \(count) \(noun) to the open tab. Undo is available."
                    )
                    controller.refreshAfterSuccessfulApplyIfSafe()
                } catch {
                    controller.comparisonViewController.showOperationStatus(
                        error.localizedDescription,
                        isError: true
                    )
                }
                return
            }
            self.applyComparisonToClosedFile(
                plan,
                destinationURL: destinationURL,
                controller: controller
            )
        }
        if let window = controller.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func applyComparisonToClosedFile(
        _ plan: ComparisonApplyPlan,
        destinationURL: URL,
        controller: ComparisonWindowController
    ) {
        controller.comparisonViewController.showOperationStatus("Applying verified changes…")
        DispatchQueue.global(qos: .userInitiated).async { [weak controller] in
            let result = Result {
                try ComparisonApplyService().apply(plan, to: destinationURL)
            }
            DispatchQueue.main.async {
                guard let controller else { return }
                switch result {
                case .success(let receipt):
                    let count = receipt.appliedBlockIDs.count
                    let noun = count == 1 ? "change" : "changes"
                    controller.comparisonViewController.showOperationStatus(
                        "Applied \(count) \(noun) to \(destinationURL.lastPathComponent)."
                    )
                    controller.refreshAfterSuccessfulApplyIfSafe()
                case .failure(let error):
                    controller.comparisonViewController.showOperationStatus(
                        error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }

    private func focus(_ controller: WorkspaceWindowController) {
        guard let window = controller.window else { return }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func activatePreparedApplication() {
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
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
        let indexedWindows = session.windows.enumerated().compactMap {
            originalIndex, window -> (Int, WorkspaceWindowSession)? in
            let tabs = window.tabs.filter(isRestorable)
            guard !tabs.isEmpty else { return nil }
            let requestedTab = window.tabs.indices.contains(window.selectedIndex)
                ? window.tabs[window.selectedIndex]
                : nil
            let selectedIndex = requestedTab.flatMap { tabs.firstIndex(of: $0) }
                ?? min(max(window.selectedIndex, 0), tabs.count - 1)
            return (originalIndex, WorkspaceWindowSession(
                tabs: tabs,
                selectedIndex: selectedIndex,
                frame: window.frame,
                space: window.space,
                preferredFrame: window.preferredFrame
            ))
        }
        let windows = indexedWindows.map(\.1)
        guard let firstWindow = windows.first, let firstTab = firstWindow.tabs.first else {
            return false
        }
        let restoredSelectedWindowIndex = indexedWindows.firstIndex {
            $0.0 == session.selectedWindowIndex
        } ?? min(max(session.selectedWindowIndex, 0), windows.count - 1)

        isRestoringSession = true
        let firstController = makeWorkspaceWindow(
            for: nil,
            restorationState: firstTab,
            ordersFront: false
        )
        let firstFrame = firstWindow.preferredFrame ?? firstWindow.frame
        firstController.windowPlacementMemory = WorkspaceWindowPlacementMemory(preferredFrame: firstFrame)
        firstFrame.map(firstController.applyRestoredWindowFrame)

        DispatchQueue.main.async { [weak self, weak firstController] in
            guard let self, let firstController else { return }
            var restoredWindows: [[WorkspaceWindowController]] = []

            for (windowIndex, windowState) in windows.enumerated() {
                var controllers: [WorkspaceWindowController] = []
                var tabAnchor: NSWindow?

                for (tabIndex, state) in windowState.tabs.enumerated() {
                    let controller: WorkspaceWindowController
                    if windowIndex == 0, tabIndex == 0 {
                        controller = firstController
                    } else {
                        controller = self.makeWorkspaceWindow(
                            for: nil,
                            tabbedTo: tabAnchor,
                            restorationState: state,
                            ordersFront: false
                        )
                    }
                    controllers.append(controller)
                    tabAnchor = controller.window
                }

                let preferredFrame = windowState.preferredFrame ?? windowState.frame
                for controller in controllers {
                    controller.windowPlacementMemory = WorkspaceWindowPlacementMemory(preferredFrame: preferredFrame)
                }
                if let frame = preferredFrame {
                    controllers.first?.applyRestoredWindowFrame(frame)
                }
                let selectedIndex = min(
                    max(windowState.selectedIndex, 0),
                    controllers.count - 1
                )
                if let selectedWindow = controllers[selectedIndex].window {
                    selectedWindow.tabGroup?.selectedWindow = selectedWindow
                }
                restoredWindows.append(controllers)
            }

            let selectedWindowIndex = min(
                max(restoredSelectedWindowIndex, 0),
                restoredWindows.count - 1
            )
            let groups = Array(zip(windows, restoredWindows))
            self.restoreSpaceAssignments(for: groups) { [weak self] in
                self?.finishSessionRestoration(
                    groups: groups,
                    selectedWindowIndex: selectedWindowIndex
                )
            }
        }
        return true
    }

    private func restoreSpaceAssignments(
        for groups: [(WorkspaceWindowSession, [WorkspaceWindowController])],
        completion: @escaping () -> Void
    ) {
        guard spaceRestorationBackend.isAvailable else {
            completion()
            return
        }
        let requests = groups.compactMap {
            state, controllers -> ([CGWindowID], WorkspaceSpaceAssignment)? in
            guard let assignment = state.space else { return nil }
            let windowIDs = controllers.compactMap(\.window).compactMap { window in
                window.windowNumber > 0 ? CGWindowID(window.windowNumber) : nil
            }
            return windowIDs.isEmpty ? nil : (windowIDs, assignment)
        }
        guard !requests.isEmpty else {
            completion()
            return
        }

        var remaining = requests.count
        for (windowIDs, assignment) in requests {
            spaceRestorationBackend.restore(
                windowIDs: windowIDs,
                assignment: assignment
            ) { _ in
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    private func revealBackgroundWindows(
        _ reveals: [WorkspaceBackgroundReveal],
        at index: Int = 0,
        completion: @escaping () -> Void
    ) {
        guard reveals.indices.contains(index) else {
            completion()
            return
        }
        let reveal = reveals[index]
        let insertedMoveToActiveSpace = !reveal.selectedWindow.collectionBehavior.contains(
            .moveToActiveSpace
        )
        reveal.selectedWindow.collectionBehavior.insert(.moveToActiveSpace)
        reveal.selectedWindow.orderFrontRegardless()
        if insertedMoveToActiveSpace {
            reveal.selectedWindow.collectionBehavior.remove(.moveToActiveSpace)
        }

        let finishReveal = { [weak self] in
            reveal.windows.forEach { $0.alphaValue = 1 }
            DispatchQueue.main.async {
                self?.revealBackgroundWindows(
                    reveals,
                    at: index + 1,
                    completion: completion
                )
            }
        }
        guard let assignment = reveal.assignment else {
            finishReveal()
            return
        }
        let windowIDs = reveal.windows.compactMap { window in
            window.windowNumber > 0 ? CGWindowID(window.windowNumber) : nil
        }
        guard !windowIDs.isEmpty else {
            finishReveal()
            return
        }
        spaceRestorationBackend.restore(
            windowIDs: windowIDs,
            assignment: assignment
        ) { _ in
            finishReveal()
        }
    }

    private func finishSessionRestoration(
        groups: [(WorkspaceWindowSession, [WorkspaceWindowController])],
        selectedWindowIndex: Int
    ) {
        var restoredWindowsOnActiveSpace: [Bool] = []
        var selectedControllers: [WorkspaceWindowController?] = []
        for (state, controllers) in groups {
            guard !controllers.isEmpty else {
                restoredWindowsOnActiveSpace.append(false)
                selectedControllers.append(nil)
                continue
            }
            let selectedIndex = min(max(state.selectedIndex, 0), controllers.count - 1)
            let selectedController = controllers[selectedIndex]
            let selectedWindow = selectedController.window
            // Capture locality before ordering any restored window. Ordering a
            // remote window while launch activation is in flight can switch
            // Spaces, which would make subsequent isOnActiveSpace results refer
            // to the wrong (newly activated) Space.
            restoredWindowsOnActiveSpace.append(
                selectedWindow.map(windowIsOnActiveSpace) == true
            )
            selectedControllers.append(selectedController)
        }

        let launchAction = WorkspaceLaunchPolicy.action(
            previouslySelectedIndex: selectedWindowIndex,
            restoredWindowsOnActiveSpace: restoredWindowsOnActiveSpace
        )
        let launchController: WorkspaceWindowController
        let launchRestoredIndex: Int?
        switch launchAction {
        case .focusRestoredWindow(let index):
            launchController = selectedControllers.indices.contains(index)
                ? selectedControllers[index] ?? makeWorkspaceWindow(for: nil, ordersFront: false)
                : makeWorkspaceWindow(for: nil, ordersFront: false)
            launchRestoredIndex = selectedControllers.indices.contains(index)
                && selectedControllers[index] != nil ? index : nil
        case .createEmptyWindow:
            launchController = makeWorkspaceWindow(for: nil, ordersFront: false)
            launchRestoredIndex = nil
        }

        var backgroundReveals: [WorkspaceBackgroundReveal] = []
        for (index, (state, controllers)) in groups.enumerated() {
            let windows = controllers.compactMap(\.window)
            if index == launchRestoredIndex {
                windows.forEach { $0.alphaValue = 1 }
            } else if let selectedWindow = selectedControllers[index]?.window {
                windows.forEach { $0.alphaValue = 0 }
                backgroundReveals.append(WorkspaceBackgroundReveal(
                    windows: windows,
                    selectedWindow: selectedWindow,
                    assignment: state.space
                ))
            }
        }

        // Complete activation with the current-Space target as the only newly
        // ordered window. Once AppKit has committed that activation, reveal
        // every other restored window without making it key or changing Space.
        focus(launchController)
        activatePreparedApplication()
        revealBackgroundWindows(backgroundReveals) { [weak self] in
            guard let self else { return }
            self.isRestoringSession = false
            self.persistSession()
            if self.workspaceWindows.contains(where: { $0.windowPlacementMemory.needsDisplayAdjustment }) {
                self.scheduleDisplayLayoutAdjustment()
            }
        }
    }

    private func persistSession(synchronously: Bool = false) {
        guard shouldPersistSession, didFinishLaunching, !isRestoringSession else { return }
        let session = captureWorkspaceSession()
        let save = { [sessionStore] in sessionStore.save(session) }
        if synchronously {
            sessionPersistenceQueue.sync(execute: save)
        } else {
            sessionPersistenceQueue.async(execute: save)
        }
    }

    private func isRestorable(_ state: WorkspaceTabSession) -> Bool {
        if let id = state.scratchpadID {
            return scratchpadStore.exists(ScratchpadDescriptor(
                id: id,
                title: state.scratchpadTitle ?? "Untitled"
            ))
        }
        return FileManager.default.fileExists(atPath: state.workspacePath)
    }

    private func captureWorkspaceSession() -> WorkspaceSession? {
        var visitedWindows = Set<ObjectIdentifier>()
        var windowSessions: [WorkspaceWindowSession] = []
        var controllerWindowIndices: [ObjectIdentifier: Int] = [:]
        let displays = workspaceDisplayGeometries()

        for controller in workspaceWindows {
            guard let window = controller.window,
                  !visitedWindows.contains(ObjectIdentifier(window)) else { continue }

            let tabWindows = window.tabGroup?.windows ?? [window]
            let controllers = tabWindows.compactMap {
                $0.windowController as? WorkspaceWindowController
            }
            controllers.compactMap(\.window).forEach {
                visitedWindows.insert(ObjectIdentifier($0))
            }
            let tabs = controllers.compactMap(\.sessionState)
            guard !tabs.isEmpty else { continue }

            let selectedWindow = window.tabGroup?.selectedWindow ?? window
            let selectedController = selectedWindow.windowController as? WorkspaceWindowController
                ?? controller
            let currentFrame = WorkspaceWindowFrame(
                selectedWindow.frame,
                displayIdentifier: WorkspaceScreenIdentity.identifier(for: selectedWindow.screen),
                displayFrame: selectedWindow.screen?.visibleFrame
            )
            var placement = selectedController.windowPlacementMemory
            if !selectedWindow.styleMask.contains(.fullScreen) {
                placement.capture(currentFrame, displays: displays)
            }
            controllers.forEach { $0.windowPlacementMemory = placement }
            let selectedIndex = controllers.firstIndex {
                $0.window === selectedWindow
            } ?? 0
            let windowIndex = windowSessions.count
            controllers.forEach { controller in
                controllerWindowIndices[ObjectIdentifier(controller)] = windowIndex
            }
            let windowIDs = controllers.compactMap(\.window).compactMap { window in
                window.windowNumber > 0 ? CGWindowID(window.windowNumber) : nil
            }
            windowSessions.append(WorkspaceWindowSession(
                tabs: tabs,
                selectedIndex: selectedIndex,
                frame: currentFrame,
                space: spaceRestorationBackend.captureAssignment(
                    forWindowIDs: windowIDs
                ),
                preferredFrame: placement.preferredFrame
            ))
        }

        guard !windowSessions.isEmpty else { return nil }
        let selectedWindowIndex = activeWorkspaceWindow.flatMap {
            controllerWindowIndices[ObjectIdentifier($0)]
        } ?? 0
        return WorkspaceSession(
            windows: windowSessions,
            selectedWindowIndex: selectedWindowIndex
        )
    }

    var workspaceSessionForTesting: WorkspaceSession? {
        captureWorkspaceSession()
    }

    private func workspaceDisplayGeometries() -> [WorkspaceDisplayGeometry] {
        NSScreen.screens.map {
            WorkspaceDisplayGeometry(
                identifier: WorkspaceScreenIdentity.identifier(for: $0),
                visibleFrame: $0.visibleFrame,
                screenFrame: $0.frame
            )
        }
    }

    var isTerminatingApplication: Bool {
        terminationSession != nil
    }

    private func schedulePersistSession() {
        guard didFinishLaunching, !isRestoringSession, !isSessionPersistScheduled else { return }
        NSApplication.shared.invalidateRestorableState()
        isSessionPersistScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSessionPersistScheduled = false
            self.persistSession()
        }
    }
}
