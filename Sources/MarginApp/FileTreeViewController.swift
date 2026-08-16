import AppKit

final class FileTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let directoryLabel = NSTextField(labelWithString: "Files")
    private let directoryIcon = NSImageView()
    private let headerRule = MarginHairlineView()
    private var rootNode: FileNode?
    private var watcher: FileSystemWatcher?
    private var representedDirectoryURL: URL?
    private var scanGeneration = UUID()
    private var suppressSelectionCallback = false
    private var selectedFileURL: URL?

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        view = background

        directoryLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false
        directoryLabel.setAccessibilityLabel("Open directory")

        directoryIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        directoryIcon.contentTintColor = .tertiaryLabelColor
        directoryIcon.imageScaling = .scaleProportionallyDown
        directoryIcon.translatesAutoresizingMaskIntoConstraints = false
        directoryIcon.setAccessibilityElement(false)
        headerRule.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.style = .sourceList
        outlineView.rowHeight = 26
        outlineView.indentationPerLevel = 15
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)
        outlineView.backgroundColor = .clear
        outlineView.autosaveExpandedItems = false
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickedItem(_:))
        outlineView.setAccessibilityLabel("Directory files")
        outlineView.setAccessibilityHelp("Navigate files and folders in the open directory")

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(directoryIcon)
        background.addSubview(directoryLabel)
        background.addSubview(headerRule)
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            directoryIcon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 13),
            directoryIcon.centerYAnchor.constraint(equalTo: directoryLabel.centerYAnchor),
            directoryIcon.widthAnchor.constraint(equalToConstant: 14),
            directoryIcon.heightAnchor.constraint(equalToConstant: 14),

            directoryLabel.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 13),
            directoryLabel.leadingAnchor.constraint(equalTo: directoryIcon.trailingAnchor, constant: 7),
            directoryLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),

            headerRule.topAnchor.constraint(equalTo: directoryLabel.bottomAnchor, constant: 11),
            headerRule.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    func openDirectory(
        _ url: URL,
        selectInitialMarkdown: Bool = true,
        selecting explicitSelectionURL: URL? = nil
    ) {
        _ = view
        let directoryURL = url.standardizedFileURL
        representedDirectoryURL = directoryURL
        rootNode = FileNode(url: directoryURL)
        selectedFileURL = explicitSelectionURL?.standardizedFileURL
        directoryLabel.stringValue = directoryURL.lastPathComponent.isEmpty
            ? directoryURL.path
            : directoryURL.lastPathComponent
        directoryLabel.toolTip = directoryURL.path
        outlineView.reloadData()

        watcher?.stop()
        watcher = FileSystemWatcher(url: directoryURL) { [weak self] _ in
            self?.reloadDirectory()
        }
        watcher?.start()

        loadRoot { [weak self] in
            guard let self else { return }
            if let explicitSelectionURL {
                self.revealAndSelect(explicitSelectionURL, openFile: false)
            } else if selectInitialMarkdown {
                self.findAndSelectInitialMarkdown(in: directoryURL)
            }
        }
    }

    func reloadDirectory() {
        guard let rootNode else { return }
        let selectedURL = selectedFileURL
        rootNode.discardChildren()
        loadRoot { [weak self] in
            guard let self, let selectedURL else { return }
            self.revealAndSelect(selectedURL, openFile: false)
        }
    }

    func revealAndSelect(_ url: URL, openFile: Bool) {
        guard let rootNode, let representedDirectoryURL else { return }
        let rootComponents = representedDirectoryURL.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard targetComponents.starts(with: rootComponents), targetComponents.count > rootComponents.count else {
            return
        }

        let relativeComponents = Array(targetComponents.dropFirst(rootComponents.count))
        reveal(
            components: relativeComponents,
            componentIndex: 0,
            in: rootNode,
            openFile: openFile
        )
    }

    var hasVisibleFiles: Bool {
        (0..<outlineView.numberOfRows).contains { row in
            guard let node = outlineView.item(atRow: row) as? FileNode else { return false }
            return !node.isDirectory
        }
    }

    func focusNavigator() {
        _ = view
        view.window?.makeFirstResponder(outlineView)
    }

    /// Moves through the files currently revealed in the navigator. Collapsed
    /// folders remain collapsed, so keyboard traversal preserves the user's
    /// chosen working set instead of unexpectedly crawling the directory.
    @discardableResult
    func openAdjacentFile(direction: Int) -> Bool {
        _ = view
        let rowCount = outlineView.numberOfRows
        guard rowCount > 0 else { return false }
        let step = direction < 0 ? -1 : 1
        var row = outlineView.selectedRow >= 0
            ? outlineView.selectedRow
            : (step > 0 ? -1 : rowCount)

        for _ in 0..<rowCount {
            row = (row + step + rowCount) % rowCount
            guard let node = outlineView.item(atRow: row) as? FileNode, !node.isDirectory else {
                continue
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    func numberOfChildren(in outlineView: NSOutlineView) -> Int {
        rootNode?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode {
            return node.children?.count ?? 0
        }
        return rootNode?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = (item as? FileNode)?.children ?? rootNode?.children ?? []
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isExpandableDirectory ?? false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        // The outline view is already in the middle of expanding this item.
        // Asking it to expand again from the load completion recursively emits
        // another will-expand notification (and eventually overflows AppKit's
        // accessibility stack). Only populate the children here.
        guard node.children == nil else { return }
        loadChildren(of: node, expandWhenLoaded: false)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView

        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = makeCell(identifier: identifier)
        }

        cell.textField?.stringValue = node.name
        cell.textField?.toolTip = node.url.path
        cell.imageView?.image = icon(for: node)
        cell.imageView?.contentTintColor = node.isDirectory
            ? .secondaryLabelColor
            : (node.isMarkdown ? NSColor.controlAccentColor.withAlphaComponent(0.82) : .tertiaryLabelColor)
        cell.setAccessibilityLabel(node.name)
        cell.setAccessibilityHelp(node.isDirectory ? "Folder" : "File")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        selectedFileURL = node.isDirectory ? selectedFileURL : node.url
        if !node.isDirectory {
            onOpenFile?(node.url)
        }
    }

    @objc private func doubleClickedItem(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isExpandableDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                loadChildren(of: node, expandWhenLoaded: true)
            }
        } else {
            selectedFileURL = node.url
            onOpenFile?(node.url)
        }
    }

    private func loadRoot(completion: @escaping () -> Void) {
        guard let rootNode else { return }
        rootNode.loadChildren { [weak self] _ in
            guard let self else { return }
            self.outlineView.reloadData()
            completion()
        }
    }

    private func loadChildren(of node: FileNode, expandWhenLoaded: Bool = true) {
        node.loadChildren { [weak self, weak node] _ in
            guard let self, let node else { return }
            self.outlineView.reloadItem(node, reloadChildren: true)
            if expandWhenLoaded {
                self.outlineView.expandItem(node)
            }
        }
    }

    private func findAndSelectInitialMarkdown(in directoryURL: URL) {
        scanGeneration = UUID()
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let markdownURL = FileNode.firstMarkdownFile(beneath: directoryURL)
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation, let markdownURL else { return }
                self.revealAndSelect(markdownURL, openFile: true)
            }
        }
    }

    private func reveal(
        components: [String],
        componentIndex: Int,
        in parent: FileNode,
        openFile: Bool
    ) {
        guard componentIndex < components.count else { return }
        parent.loadChildren { [weak self, weak parent] result in
            guard let self, let parent, case let .success(children) = result else { return }
            self.outlineView.reloadItem(parent === self.rootNode ? nil : parent, reloadChildren: true)
            guard let child = children.first(where: { $0.name == components[componentIndex] }) else {
                return
            }

            if child.isDirectory, componentIndex + 1 < components.count {
                self.outlineView.expandItem(child)
                self.reveal(
                    components: components,
                    componentIndex: componentIndex + 1,
                    in: child,
                    openFile: openFile
                )
                return
            }

            let row = self.outlineView.row(forItem: child)
            guard row >= 0 else { return }
            self.suppressSelectionCallback = true
            self.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.suppressSelectionCallback = false
            self.outlineView.scrollRowToVisible(row)
            self.selectedFileURL = child.url
            if openFile, !child.isDirectory {
                self.onOpenFile?(child.url)
            }
        }
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityElement(false)

        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 12.5, weight: .regular)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.imageView = imageView
        cell.textField = textField
        cell.addSubview(imageView)
        cell.addSubview(textField)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 15),
            imageView.heightAnchor.constraint(equalToConstant: 15),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func icon(for node: FileNode) -> NSImage? {
        let symbolName: String
        if node.isSymbolicLink {
            symbolName = "arrow.turn.up.right"
        } else if node.isDirectory {
            symbolName = "folder"
        } else if node.isMarkdown {
            symbolName = "doc.richtext"
        } else {
            symbolName = "doc"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
}
