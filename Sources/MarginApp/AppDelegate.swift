import AppKit
import MarginCore

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
        makeWorkspaceWindow(for: nil, tabbedTo: activeTabAnchorWindow)
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
        controller.showWindow(nil)
        focus(controller)
        schedulePersistSession()
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
