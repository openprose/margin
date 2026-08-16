import AppKit

final class FileTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let directoryLabel = NSTextField(labelWithString: "Files")
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

        directoryLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false
        directoryLabel.setAccessibilityLabel("Open directory")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.style = .sourceList
        outlineView.rowHeight = 23
        outlineView.indentationPerLevel = 14
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)
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

        background.addSubview(directoryLabel)
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            directoryLabel.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 11),
            directoryLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 13),
            directoryLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: directoryLabel.bottomAnchor, constant: 7),
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
        loadChildren(of: node)
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
        textField.font = .systemFont(ofSize: 12.5)
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
