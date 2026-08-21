import AppKit

final class RecentWorkspaceStartViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    var onOpen: ((URL) -> Void)?

    private let tableView = RecentWorkspaceTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Loading recent folders…")
    private var workspaces: [RecentWorkspace] = []
    private var relativeDate = Date()

    override func loadView() {
        let root = MarginSurfaceView(fillColor: MarginTheme.documentBackground)
        view = root

        let titleLabel = NSTextField(
            labelWithString: "Open a Markdown file or folder to begin."
        )
        titleLabel.font = MarginTheme.serifFont(ofSize: 25, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityLabel("Open a Markdown file or folder to begin")

        let sectionLabel = NSTextField(labelWithAttributedString: MarginTheme.microLabel("Recent folders"))
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RecentFolderColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(openSelectedWorkspace(_:))
        tableView.onOpenSelection = { [weak self] in self?.openSelectedWorkspace(nil) }
        tableView.onCopySelection = { [weak self] in self?.copySelectedWorkspace() }
        tableView.setAccessibilityLabel("Recently opened folders")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setAccessibilityLabel("Recent folders status")

        root.addSubview(titleLabel)
        root.addSubview(sectionLabel)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)

        let preferredTop = titleLabel.topAnchor.constraint(
            equalTo: root.safeAreaLayoutGuide.topAnchor,
            constant: 88
        )
        preferredTop.priority = .defaultHigh
        let preferredListHeight = scrollView.heightAnchor.constraint(equalToConstant: 390)
        preferredListHeight.priority = .defaultHigh
        let preferredListWidth = scrollView.widthAnchor.constraint(equalToConstant: 760)
        preferredListWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(
                greaterThanOrEqualTo: root.safeAreaLayoutGuide.topAnchor,
                constant: 38
            ),
            preferredTop,
            titleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 48),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -48),

            sectionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 42),
            sectionLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 10),
            scrollView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            preferredListWidth,
            scrollView.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 40),
            scrollView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            preferredListHeight,
            scrollView.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -42),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let contentWidth = scrollView.contentView.bounds.width
        guard contentWidth > 0 else { return }
        if tableView.frame.width != contentWidth {
            tableView.setFrameSize(NSSize(width: contentWidth, height: tableView.frame.height))
        }
        tableView.sizeLastColumnToFit()
    }

    func render(_ workspaces: [RecentWorkspace], relativeTo now: Date = Date()) {
        _ = view
        self.workspaces = workspaces
        relativeDate = now
        emptyLabel.stringValue = workspaces.isEmpty
            ? "Recently opened folders will appear here."
            : ""
        emptyLabel.isHidden = !workspaces.isEmpty
        tableView.reloadData()
        if workspaces.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            if tableView.window?.isKeyWindow == true {
                tableView.window?.makeFirstResponder(tableView)
            }
        }
    }

    func removeWorkspace(at url: URL) {
        let path = url.standardizedFileURL.path
        let remaining = workspaces.filter { $0.url.standardizedFileURL.path != path }
        guard remaining.count != workspaces.count else { return }
        render(remaining, relativeTo: relativeDate)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        workspaces.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard workspaces.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("RecentWorkspaceRow")
        let rowView: RecentWorkspaceRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? RecentWorkspaceRowView {
            rowView = reused
        } else {
            rowView = RecentWorkspaceRowView(identifier: identifier)
        }

        let workspace = workspaces[row]
        rowView.configure(
            workspace: workspace,
            lastOpenedText: Self.lastOpenedText(
                for: workspace.lastOpened,
                relativeTo: relativeDate
            ),
            onOpen: { [weak self] url in self?.onOpen?(url) }
        )
        return rowView
    }

    @objc private func openSelectedWorkspace(_ sender: Any?) {
        guard workspaces.indices.contains(tableView.selectedRow) else { return }
        onOpen?(workspaces[tableView.selectedRow].url)
    }

    private func copySelectedWorkspace() {
        guard workspaces.indices.contains(tableView.selectedRow) else { return }
        Self.copy(workspaces[tableView.selectedRow].url.path, to: .general)
    }

    @discardableResult
    static func copy(_ path: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(path, forType: .string)
    }

    static func lastOpenedText(for date: Date?, relativeTo now: Date = Date()) -> String {
        guard let date, date != .distantPast else { return "Last opened previously" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return "Last opened \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

private final class RecentWorkspaceTableView: NSTableView {
    var onOpenSelection: (() -> Void)?
    var onCopySelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers
        let modified = event.modifierFlags.intersection([.command, .control, .option])
        if modified.isEmpty,
           (event.keyCode == 36 || event.keyCode == 76 || characters == " ") {
            onOpenSelection?()
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        onCopySelection?()
    }
}

private final class RecentWorkspaceRowView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private var workspaceURL: URL?
    private var onOpen: ((URL) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        pathLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        dateLabel.font = .systemFont(ofSize: 10.5)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        dateLabel.lineBreakMode = .byTruncatingHead

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageOnly
        copyButton.isBordered = false
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyPath(_:))
        copyButton.toolTip = "Copy full path"
        copyButton.refusesFirstResponder = false

        [nameLabel, pathLabel, dateLabel, copyButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -16),

            dateLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -7),

            copyButton.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        workspace: RecentWorkspace,
        lastOpenedText: String,
        onOpen: @escaping (URL) -> Void
    ) {
        workspaceURL = workspace.url
        self.onOpen = onOpen
        let name = workspace.url.lastPathComponent.isEmpty
            ? workspace.url.path
            : workspace.url.lastPathComponent
        nameLabel.stringValue = name
        pathLabel.stringValue = workspace.url.path
        dateLabel.stringValue = lastOpenedText
        toolTip = workspace.url.path
        copyButton.toolTip = "Copy \(workspace.url.path)"
        copyButton.setAccessibilityLabel("Copy full path for \(name)")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(name)")
        setAccessibilityValue(workspace.url.path)
        setAccessibilityHelp(lastOpenedText)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        MarginTheme.rule.setFill()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        NSRect(x: 12, y: 0, width: max(0, bounds.width - 24), height: 1 / scale).fill()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let workspaceURL else { return false }
        onOpen?(workspaceURL)
        return true
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let path = workspaceURL?.path else { return }
        RecentWorkspaceStartViewController.copy(path, to: .general)
    }
}
