import AppKit

protocol WorkspaceDocumentPresenting: AnyObject {
    func presentDocument(at url: URL)
    func clearDocument()
}

extension WorkspaceDocumentPresenting {
    func clearDocument() {}
}

protocol WorkspaceCommentsPresenting: AnyObject {
    func presentComments(for documentURL: URL?)
}

protocol WorkspaceReaderModeToggling: AnyObject {
    var isReaderModeActive: Bool { get }
    func toggleReaderMode()
}

@objc protocol WorkspaceDocumentSaving: AnyObject {
    func saveDocument(_ sender: Any?)
}

/// Integration seam for the full editor and comment implementations. Their
/// view controllers can conform to the protocols above and replace these
/// factories without changing the window or file-tree shell.
enum WorkspacePaneFactory {
    static var makeEditor: () -> NSViewController = { EditorPlaceholderViewController() }
    static var makeComments: () -> NSViewController = { CommentsPlaceholderViewController() }
}

final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private enum CommentsVisibilityChoice {
        case automatic
        case explicit
    }

    enum WorkspaceKind {
        case empty
        case file(URL)
        case directory(URL)
    }

    var onClose: (() -> Void)?

    private(set) var workspaceURL: URL?
    private(set) var workspaceKind: WorkspaceKind = .empty
    private(set) var documentURL: URL?

    private let splitViewController = NSSplitViewController()
    private let fileTreeViewController = FileTreeViewController()
    private let editorViewController: NSViewController
    private let commentsViewController: NSViewController
    private let navigatorItem: NSSplitViewItem
    private let editorItem: NSSplitViewItem
    private let commentsItem: NSSplitViewItem
    private var navigationPaletteController: NavigationPaletteController?
    private var fileScanGeneration = UUID()
    private var indexedFileURLs: [URL] = []
    private var commentsVisibilityChoice: CommentsVisibilityChoice = .automatic
    private var pendingInitialWindowFrame: NSRect?
    private var isExplicitlyTabbed = false

    var isEmpty: Bool {
        if case .empty = workspaceKind { return true }
        return false
    }

    var canShowNavigator: Bool {
        if case .directory = workspaceKind { return true }
        return false
    }

    var isNavigatorVisible: Bool {
        !navigatorItem.isCollapsed
    }

    var isCommentsVisible: Bool {
        !commentsItem.isCollapsed
    }

    var canShowComments: Bool { documentURL != nil }

    var canToggleReaderMode: Bool {
        documentURL != nil && editorViewController is WorkspaceReaderModeToggling
    }

    var isReaderModeActive: Bool {
        (editorViewController as? WorkspaceReaderModeToggling)?.isReaderModeActive ?? false
    }

    var canSaveDocument: Bool {
        documentURL != nil && editorViewController is WorkspaceDocumentSaving
    }

    var canQuickOpen: Bool { quickOpenDirectoryURL != nil }

    var canNavigateFiles: Bool {
        canShowNavigator && fileTreeViewController.hasVisibleFiles
    }

    var canNavigateHeadings: Bool { documentURL != nil }

    private var quickOpenDirectoryURL: URL? {
        switch workspaceKind {
        case .directory(let url): return url
        case .file(let url): return url.deletingLastPathComponent()
        case .empty: return nil
        }
    }

    init(workspaceURL: URL?) {
        editorViewController = WorkspacePaneFactory.makeEditor()
        commentsViewController = WorkspacePaneFactory.makeComments()

        navigatorItem = NSSplitViewItem(sidebarWithViewController: fileTreeViewController)
        editorItem = NSSplitViewItem(viewController: editorViewController)
        commentsItem = NSSplitViewItem(inspectorWithViewController: commentsViewController)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        if let editor = editorViewController as? EditorViewController,
           let comments = commentsViewController as? CommentsViewController {
            editor.connectComments(comments)
        }
        configureWindow(window)
        configureSplitView()
        configureInitialWindowFrame(window)
        configureCallbacks()

        if let workspaceURL {
            open(workspaceURL)
        } else {
            showEmptyState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible == true
        super.showWindow(sender)
        guard !wasVisible, let window, let frame = pendingInitialWindowFrame else { return }
        pendingInitialWindowFrame = nil

        // AppKit asks a newly installed split view for its fitting size while
        // ordering the window. Reapply the restored/default frame after that
        // first layout pass; explicit child tabs instead inherit their group.
        if !isExplicitlyTabbed {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    func prepareForTabAttachment() {
        isExplicitlyTabbed = true
        pendingInitialWindowFrame = nil
    }

    func refreshTabPresentation() {
        guard isExplicitlyTabbed, let window else { return }
        window.tab.toolTip = (window.representedURL?.path).flatMap { $0.isEmpty ? nil : $0 } ?? "Margin"
    }

    func open(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectory
        )

        workspaceURL = standardizedURL
        if exists && isDirectory.boolValue {
            openDirectory(standardizedURL)
        } else {
            openStandaloneFile(standardizedURL)
        }
    }

    @objc func toggleNavigator(_ sender: Any?) {
        guard canShowNavigator else { return }
        navigatorItem.animator().isCollapsed.toggle()
        window?.toolbar?.validateVisibleItems()
    }

    @objc func toggleComments(_ sender: Any?) {
        guard canShowComments else { return }
        setCommentsVisible(!isCommentsVisible, explicit: true, animated: true)
    }

    @objc func toggleReaderMode(_ sender: Any?) {
        (editorViewController as? WorkspaceReaderModeToggling)?.toggleReaderMode()
        window?.toolbar?.validateVisibleItems()
    }

    @objc func addComment(_ sender: Any?) {
        guard documentURL != nil else { return }
        setCommentsVisible(true, explicit: true, animated: true)
        _ = NSApp.sendAction(NSSelectorFromString("beginComment:"), to: editorViewController, from: sender)
    }

    @objc func quickOpen(_ sender: Any?) {
        guard let directoryURL = quickOpenDirectoryURL, let window else { return }
        navigationPaletteController?.close()

        let palette = NavigationPaletteController(
            title: "Quick Open",
            placeholder: "Search files by name or path",
            items: makeFilePaletteItems(indexedFileURLs, beneath: directoryURL),
            emptyMessage: "No matching files"
        )
        navigationPaletteController = palette
        palette.onClose = { [weak self, weak palette] in
            guard let self, self.navigationPaletteController === palette else { return }
            self.navigationPaletteController = nil
        }
        palette.setStatus(indexedFileURLs.isEmpty ? "Indexing files…" : "Refreshing file index…")
        palette.show(relativeTo: window)

        fileScanGeneration = UUID()
        let generation = fileScanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak palette] in
            let urls = WorkspaceFileScanner.files(beneath: directoryURL)
            DispatchQueue.main.async {
                guard let self, let palette,
                      self.fileScanGeneration == generation,
                      self.navigationPaletteController === palette else { return }
                self.indexedFileURLs = urls
                palette.update(items: self.makeFilePaletteItems(urls, beneath: directoryURL))
            }
        }
    }

    @objc func navigateToHeading(_ sender: Any?) {
        guard let editor = editorViewController as? EditorViewController, let window else { return }
        navigationPaletteController?.close()
        let destinations = editor.headingDestinations()
        let items = destinations.map { destination in
            NavigationPaletteItem(
                title: destination.title,
                subtitle: "H\(destination.level)  ·  Line \(destination.line)",
                symbolName: "number",
                searchText: "\(destination.title) \(destination.id)"
            ) { [weak editor] in
                editor?.revealHeading(destination)
            }
        }
        let palette = NavigationPaletteController(
            title: "Go to Heading",
            placeholder: "Search headings",
            items: items,
            emptyMessage: "This document has no headings"
        )
        navigationPaletteController = palette
        palette.onClose = { [weak self, weak palette] in
            guard let self, self.navigationPaletteController === palette else { return }
            self.navigationPaletteController = nil
        }
        palette.show(relativeTo: window)
    }

    @objc func previousFile(_ sender: Any?) {
        _ = fileTreeViewController.openAdjacentFile(direction: -1)
    }

    @objc func nextFile(_ sender: Any?) {
        _ = fileTreeViewController.openAdjacentFile(direction: 1)
    }

    @objc func focusNavigator(_ sender: Any?) {
        guard canShowNavigator else { return }
        navigatorItem.isCollapsed = false
        fileTreeViewController.focusNavigator()
        window?.toolbar?.validateVisibleItems()
    }

    @objc func focusEditor(_ sender: Any?) {
        (editorViewController as? EditorViewController)?.focusEditor()
    }

    @objc func focusComments(_ sender: Any?) {
        guard canShowComments else { return }
        setCommentsVisible(true, explicit: true, animated: false)
        (commentsViewController as? CommentsViewController)?.focusComments()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let editor = editorViewController as? EditorViewController else { return true }
        return editor.prepareToClose()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.contentViewController = splitViewController
        window.title = "Margin"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.backgroundColor = MarginTheme.documentBackground
        window.isRestorable = false
        // Let AppKit own live resize and full-screen sizing. Explicit frame
        // maxima are ignored by Auto Layout and can interact poorly with
        // split-view fitting sizes; a content minimum is the native contract.
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.tabbingIdentifier = "ink.margin.workspace"
        window.animationBehavior = .documentWindow
        window.preservesContentDuringLiveResize = true
        window.setAccessibilityLabel("Margin workspace")

        let toolbar = NSToolbar(identifier: "MarginUnifiedToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
    }

    private func configureInitialWindowFrame(_ window: NSWindow) {
        let frameName = "MarginWorkspaceWindow.v3"
        let restored = window.setFrameUsingName(frameName)
        let restoredFrame = window.frame
        let restoredIsUsable = restored
            && restoredFrame.width >= 720
            && restoredFrame.height >= 480
            && NSScreen.screens.contains(where: {
                NSIntersectionRect(restoredFrame, $0.visibleFrame).width >= 160
                    && NSIntersectionRect(restoredFrame, $0.visibleFrame).height >= 120
            })

        if !restoredIsUsable {
            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            let width = min(1180, max(720, (visibleFrame?.width ?? 1276) - 96))
            let height = min(780, max(480, (visibleFrame?.height ?? 876) - 96))
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
        }
        pendingInitialWindowFrame = window.frame

        // Version the frame key when the window layout changes materially so
        // an old, cramped frame does not become the new product default.
        window.setFrameAutosaveName(frameName)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.marginNavigator, .flexibleSpace, .marginReader, .marginAddComment, .marginComments]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.marginNavigator, .flexibleSpace, .marginReader, .marginAddComment, .marginComments]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .marginNavigator:
            item.label = "Navigator"
            item.paletteLabel = "Toggle Navigator"
            item.toolTip = "Show or hide the directory navigator"
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Navigator")
            item.target = self
            item.action = #selector(toggleNavigator(_:))
        case .marginReader:
            item.label = "Reader"
            item.paletteLabel = "Reader Mode"
            item.toolTip = "Switch between literal Markdown and reader mode"
            item.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: "Reader mode")
            item.target = self
            item.action = #selector(toggleReaderMode(_:))
        case .marginAddComment:
            item.label = "Comment"
            item.paletteLabel = "Add Comment"
            item.toolTip = "Add a comment to the selected passage"
            item.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Add comment")
            item.target = self
            item.action = #selector(addComment(_:))
        case .marginComments:
            item.label = "Comments"
            item.paletteLabel = "Toggle Comments"
            item.toolTip = "Show or hide document comments"
            item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Comments")
            item.target = self
            item.action = #selector(toggleComments(_:))
        default:
            return nil
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .marginNavigator:
            return canShowNavigator
        case .marginReader:
            let active = isReaderModeActive
            item.label = active ? "Editor" : "Reader"
            item.toolTip = active
                ? "Return to literal Markdown source"
                : "Switch to reader mode"
            item.image = NSImage(
                systemSymbolName: active ? "text.book.closed.fill" : "text.book.closed",
                accessibilityDescription: active ? "Reader mode is on" : "Reader mode"
            )
            item.isBordered = active
            return canToggleReaderMode
        case .marginAddComment:
            return documentURL != nil
        case .marginComments:
            return canShowComments
        default:
            return true
        }
    }

    private func configureSplitView() {
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "MarginWorkspaceSplitView"

        navigatorItem.minimumThickness = 190
        navigatorItem.maximumThickness = 350
        navigatorItem.preferredThicknessFraction = 0.19
        navigatorItem.allowsFullHeightLayout = true
        navigatorItem.canCollapse = true
        navigatorItem.holdingPriority = .defaultHigh
        navigatorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        navigatorItem.isCollapsed = true

        editorItem.minimumThickness = 420
        editorItem.maximumThickness = 100_000
        // The document is the elastic pane. Sidebars keep their working width
        // while the editor absorbs normal window growth and shrinkage.
        editorItem.holdingPriority = .defaultLow

        commentsItem.minimumThickness = 260
        commentsItem.maximumThickness = 420
        commentsItem.preferredThicknessFraction = 0.25
        commentsItem.allowsFullHeightLayout = true
        commentsItem.canCollapse = true
        commentsItem.holdingPriority = .defaultHigh
        commentsItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        commentsItem.isCollapsed = true

        splitViewController.addSplitViewItem(navigatorItem)
        splitViewController.addSplitViewItem(editorItem)
        splitViewController.addSplitViewItem(commentsItem)
    }

    private func configureCallbacks() {
        fileTreeViewController.onOpenFile = { [weak self] url in
            self?.openFileFromDirectory(url)
        }
        if let editor = editorViewController as? EditorViewController {
            editor.onCommentAvailabilityChanged = { [weak self] hasComments in
                guard let self, self.commentsVisibilityChoice == .automatic else { return }
                self.setCommentsVisible(hasComments, explicit: false, animated: self.window?.isVisible == true)
            }
        }
    }

    private func showEmptyState() {
        workspaceKind = .empty
        workspaceURL = nil
        documentURL = nil
        commentsVisibilityChoice = .automatic
        navigatorItem.isCollapsed = true
        commentsItem.isCollapsed = true
        (editorViewController as? WorkspaceDocumentPresenting)?.clearDocument()
        (commentsViewController as? WorkspaceCommentsPresenting)?.presentComments(for: nil)
        updateWindowTitle(documentURL: nil, workspaceURL: nil)
        window?.toolbar?.validateVisibleItems()
    }

    private func openStandaloneFile(_ fileURL: URL) {
        workspaceKind = .file(fileURL)
        documentURL = fileURL
        navigatorItem.isCollapsed = true
        presentDocument(fileURL)
    }

    private func openDirectory(_ directoryURL: URL) {
        workspaceKind = .directory(directoryURL)
        documentURL = nil
        commentsVisibilityChoice = .automatic
        indexedFileURLs.removeAll()
        fileScanGeneration = UUID()
        navigatorItem.isCollapsed = false
        commentsItem.isCollapsed = true
        (editorViewController as? WorkspaceDocumentPresenting)?.clearDocument()
        (commentsViewController as? WorkspaceCommentsPresenting)?.presentComments(for: nil)
        updateWindowTitle(documentURL: nil, workspaceURL: directoryURL)
        window?.toolbar?.validateVisibleItems()
        fileTreeViewController.openDirectory(directoryURL, selectInitialMarkdown: true)
    }

    private func openFileFromDirectory(_ fileURL: URL) {
        guard case .directory = workspaceKind else { return }
        if let editor = editorViewController as? EditorViewController,
           !editor.prepareToClose() {
            if let documentURL {
                fileTreeViewController.revealAndSelect(documentURL, openFile: false)
            }
            return
        }
        documentURL = fileURL
        presentDocument(fileURL)
    }

    private func makeFilePaletteItems(_ urls: [URL], beneath directoryURL: URL) -> [NavigationPaletteItem] {
        urls.map { url in
            let relativePath = WorkspaceFileScanner.relativePath(for: url, beneath: directoryURL)
            let parentPath = (relativePath as NSString).deletingLastPathComponent
            let subtitle = parentPath.isEmpty ? directoryURL.lastPathComponent : parentPath
            let symbol = FileNode.markdownExtensions.contains(url.pathExtension.lowercased())
                ? "doc.richtext"
                : "doc"
            return NavigationPaletteItem(
                title: url.lastPathComponent,
                subtitle: subtitle,
                symbolName: symbol,
                searchText: relativePath
            ) { [weak self] in
                guard let self else { return }
                if case .directory = self.workspaceKind {
                    self.fileTreeViewController.revealAndSelect(url, openFile: false)
                    self.openFileFromDirectory(url)
                } else {
                    guard let editor = self.editorViewController as? EditorViewController,
                          editor.prepareToClose() else { return }
                    self.open(url)
                }
            }
        }
    }

    private func presentDocument(_ fileURL: URL) {
        commentsVisibilityChoice = .automatic
        commentsItem.isCollapsed = true
        (editorViewController as? WorkspaceDocumentPresenting)?.presentDocument(at: fileURL)
        (commentsViewController as? WorkspaceCommentsPresenting)?.presentComments(for: fileURL)
        updateWindowTitle(documentURL: fileURL, workspaceURL: workspaceURL)
        window?.toolbar?.validateVisibleItems()
    }

    private func setCommentsVisible(_ visible: Bool, explicit: Bool, animated: Bool) {
        if explicit { commentsVisibilityChoice = .explicit }
        guard isCommentsVisible != visible else {
            window?.toolbar?.validateVisibleItems()
            return
        }
        if animated {
            commentsItem.animator().isCollapsed = !visible
        } else {
            commentsItem.isCollapsed = !visible
        }
        window?.toolbar?.validateVisibleItems()
    }

    private func updateWindowTitle(documentURL: URL?, workspaceURL: URL?) {
        guard let window else { return }
        let representedURL = documentURL ?? workspaceURL
        window.representedURL = representedURL
        refreshTabPresentation()

        if let documentURL {
            window.title = documentURL.lastPathComponent
            let parent = documentURL.deletingLastPathComponent().path
            window.subtitle = parent
        } else if let workspaceURL {
            window.title = workspaceURL.lastPathComponent.isEmpty ? workspaceURL.path : workspaceURL.lastPathComponent
            window.subtitle = workspaceURL.deletingLastPathComponent().path
        } else {
            window.title = "Margin"
            window.subtitle = ""
        }
    }
}

private final class EditorPlaceholderViewController: NSViewController, WorkspaceDocumentPresenting, WorkspaceDocumentSaving {
    private let textView: NSTextView
    private let scrollView = NSScrollView()
    private var highlighter: MarkdownHighlighter?
    private var representedURL: URL?
    private var loadGeneration = UUID()

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textView = NSTextView(frame: .zero, textContainer: textContainer)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        view = container

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Markdown editor")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        highlighter = MarkdownHighlighter(textView: textView)
        clearDocument()
    }

    func presentDocument(at url: URL) {
        _ = view
        representedURL = url
        loadGeneration = UUID()
        let generation = loadGeneration

        guard FileManager.default.fileExists(atPath: url.path) else {
            textView.isEditable = true
            textView.string = ""
            highlighter?.invalidate()
            textView.window?.makeFirstResponder(textView)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try String(contentsOf: url, encoding: .utf8) }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                switch result {
                case let .success(source):
                    self.textView.isEditable = true
                    self.textView.string = source
                    self.highlighter?.invalidate()
                    self.textView.setSelectedRange(NSRange(location: 0, length: 0))
                case let .failure(error):
                    self.textView.isEditable = false
                    self.textView.string = "Margin could not read this file.\n\n\(error.localizedDescription)"
                }
            }
        }
    }

    func clearDocument() {
        _ = view
        representedURL = nil
        loadGeneration = UUID()
        textView.isEditable = false
        textView.string = "Open a Markdown file or folder to begin."
        textView.setAccessibilityHelp("Use File, Open to choose a Markdown document or directory")
        highlighter?.invalidate()
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let representedURL else { return }
        do {
            try textView.string.write(to: representedURL, atomically: true, encoding: .utf8)
        } catch {
            NSApplication.shared.presentError(error)
        }
    }
}

private final class CommentsPlaceholderViewController: NSViewController, WorkspaceCommentsPresenting {
    private let titleLabel = NSTextField(labelWithString: "Comments")
    private let messageLabel = NSTextField(wrappingLabelWithString: "Select a passage to start a conversation.")

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        view = background

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 12.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(titleLabel)
        background.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 13),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
        background.setAccessibilityLabel("Comments sidebar")
    }

    func presentComments(for documentURL: URL?) {
        _ = view
        messageLabel.stringValue = documentURL == nil
            ? "Open a document to see its conversations."
            : "Select a passage to start a conversation."
    }
}

private extension NSToolbarItem.Identifier {
    static let marginNavigator = NSToolbarItem.Identifier("MarginNavigator")
    static let marginReader = NSToolbarItem.Identifier("MarginReader")
    static let marginAddComment = NSToolbarItem.Identifier("MarginAddComment")
    static let marginComments = NSToolbarItem.Identifier("MarginComments")
}
