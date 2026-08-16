import AppKit

struct NavigationPaletteItem {
    let title: String
    let subtitle: String
    let symbolName: String
    let searchText: String
    let action: () -> Void

    init(
        title: String,
        subtitle: String = "",
        symbolName: String,
        searchText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.searchText = searchText ?? "\(title) \(subtitle)"
        self.action = action
    }
}

/// A small native command palette shared by file and heading navigation.
/// It is created only when invoked, so it adds no work to application launch.
final class NavigationPaletteController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate,
    NSWindowDelegate
{
    var onClose: (() -> Void)?

    private let searchField = NavigationSearchField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyMessage: String
    private var allItems: [NavigationPaletteItem]
    private var visibleItems: [NavigationPaletteItem] = []
    private var transientStatus: String?

    init(
        title: String,
        placeholder: String,
        items: [NavigationPaletteItem] = [],
        emptyMessage: String
    ) {
        self.allItems = items
        self.emptyMessage = emptyMessage

        let panel = NavigationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 410),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.animationBehavior = .utilityWindow
        panel.setAccessibilityLabel(title)

        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel, placeholder: placeholder)
        applyFilter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(relativeTo parent: NSWindow) {
        guard let panel = window else { return }
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }

        let frame = parent.frame
        let origin = NSPoint(
            x: floor(frame.midX - panel.frame.width / 2),
            y: floor(frame.maxY - panel.frame.height - 86)
        )
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func update(items: [NavigationPaletteItem], status: String? = nil) {
        allItems = items
        transientStatus = status
        applyFilter()
    }

    func setStatus(_ status: String?) {
        transientStatus = status
        updateStatus()
    }

    func controlTextDidChange(_ obj: Notification) {
        transientStatus = nil
        applyFilter()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "moveDown:":
            moveSelection(by: 1)
        case "moveUp:":
            moveSelection(by: -1)
        case "insertNewline:":
            chooseSelection()
        case "cancelOperation:":
            close()
        default:
            return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleItems.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard visibleItems.indices.contains(row) else { return nil }
        let item = visibleItems[row]
        let identifier = NSUserInterfaceItemIdentifier("NavigationPaletteCell")
        let cell: NavigationPaletteCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NavigationPaletteCell {
            cell = reused
        } else {
            cell = NavigationPaletteCell(identifier: identifier)
        }
        cell.configure(with: item)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
    }

    func windowWillClose(_ notification: Notification) {
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
        }
        onClose?()
    }

    private func configureContent(in panel: NSPanel, placeholder: String) {
        let root = MarginSurfaceView(fillColor: MarginTheme.paletteBackground)
        panel.contentView = root

        searchField.placeholderString = placeholder
        searchField.delegate = self
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel(panel.title)
        searchField.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        searchField.onChoose = { [weak self] in self?.chooseSelection() }
        searchField.onCancel = { [weak self] in self?.close() }

        let separator = MarginHairlineView()
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NavigationPaletteColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 50
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.setAccessibilityLabel("Navigation results")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MarginTheme.paletteBackground
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = MarginTheme.paletteBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityLabel("Navigation status")

        root.addSubview(searchField)
        root.addSubview(separator)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -11),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            visibleItems = allItems
        } else {
            visibleItems = allItems.compactMap { item -> (NavigationPaletteItem, Int)? in
                guard let score = Self.matchScore(item, query: query) else { return nil }
                return (item, score)
            }.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.subtitle.localizedStandardCompare(rhs.0.subtitle) == .orderedAscending
            }.map(\.0)
        }

        tableView.reloadData()
        if !visibleItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        updateStatus()
    }

    private func updateStatus() {
        if let transientStatus {
            statusLabel.stringValue = transientStatus
        } else if visibleItems.isEmpty {
            statusLabel.stringValue = emptyMessage
        } else {
            let noun = visibleItems.count == 1 ? "result" : "results"
            statusLabel.stringValue = "\(visibleItems.count) \(noun)  ·  ↑↓ navigate  ·  ↩ open  ·  Esc close"
        }
    }

    private func moveSelection(by delta: Int) {
        guard !visibleItems.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = min(max(current + delta, 0), visibleItems.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        chooseSelection()
    }

    private func chooseSelection() {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        guard visibleItems.indices.contains(row) else { return }
        let action = visibleItems[row].action
        close()
        DispatchQueue.main.async(execute: action)
    }

    private static func matchScore(_ item: NavigationPaletteItem, query: String) -> Int? {
        let normalizedQuery = normalize(query)
        let terms = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let title = normalize(item.title)
        let searchable = normalize(item.searchText)
        var score = 0

        for term in terms {
            if title == term {
                score += 0
            } else if title.hasPrefix(term) {
                score += 4
            } else if let range = title.range(of: term) {
                score += 12 + title.distance(from: title.startIndex, to: range.lowerBound)
            } else if let range = searchable.range(of: term) {
                score += 36 + min(searchable.distance(from: searchable.startIndex, to: range.lowerBound), 80)
            } else if let distance = subsequenceDistance(term, in: searchable) {
                score += 120 + distance
            } else {
                return nil
            }
        }
        return score + min(item.subtitle.count / 18, 12)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func subsequenceDistance(_ needle: String, in haystack: String) -> Int? {
        var position = haystack.startIndex
        var first: String.Index?
        var last: String.Index?
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            first = first ?? found
            last = found
            position = haystack.index(after: found)
        }
        guard let first, let last else { return 0 }
        return haystack.distance(from: first, to: last)
    }
}

enum WorkspaceFileScanner {
    static func files(beneath rootURL: URL, limit: Int = 20_000) -> [URL] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
        ]
        let excludedDirectories: Set<String> = [
            ".build", ".git", ".hg", ".svn", ".swiftpm", "DerivedData", "node_modules",
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL, files.count < limit {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let hidden = values.isHidden == true || url.lastPathComponent.hasPrefix(".")
            if values.isDirectory == true {
                if hidden || values.isPackage == true || values.isSymbolicLink == true
                    || excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard !hidden, values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(url.standardizedFileURL)
        }

        return files.sorted {
            relativePath(for: $0, beneath: rootURL)
                .localizedStandardCompare(relativePath(for: $1, beneath: rootURL)) == .orderedAscending
        }
    }

    static func relativePath(for url: URL, beneath rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private final class NavigationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class NavigationSearchField: NSSearchField {
    var onMove: ((Int) -> Void)?
    var onChoose: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            onMove?(1)
        case 126:
            onMove?(-1)
        case 36, 76:
            onChoose?()
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

private final class NavigationPaletteCell: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.setAccessibilityElement(false)

        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .monospacedSystemFont(ofSize: 9.75, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(symbolView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 17),
            symbolView.heightAnchor.constraint(equalToConstant: 17),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(with item: NavigationPaletteItem) {
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.isHidden = item.subtitle.isEmpty
        symbolView.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
        symbolView.contentTintColor = item.symbolName == "doc.richtext"
            ? NSColor.controlAccentColor.withAlphaComponent(0.82)
            : .secondaryLabelColor
        setAccessibilityLabel(item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)")
    }
}
