import AppKit
import MarginCore

final class ComparisonCommentsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum ComposerTarget: Equatable {
        case selection(ComparisonSelectionRequest)
        case reply(threadID: String, parentID: String)
    }

    var onSubmit: ((ComposerTarget, String) -> Void)?
    var onSetThreadStatus: ((String, MarginCommentStatus) -> Void)?
    var onClose: (() -> Void)?

    private let tableView = ComparisonCommentsTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No review threads yet.")
    private let composerContainer = MarginSurfaceView(fillColor: MarginTheme.paletteBackground)
    private let composerContextLabel = NSTextField(wrappingLabelWithString: "")
    private let composerTextView = NSTextView()
    private let submitButton = NSButton(title: "Add Comment", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var composerHeightConstraint: NSLayoutConstraint!
    private var rows: [ComparisonCommentRow] = []
    private var composerTarget: ComposerTarget?
    private var review: ComparisonReview?
    private var mutationInProgress = false
    private var lastRowHeightWidth: CGFloat = 0
    private var rowHeightRefreshWorkItem: DispatchWorkItem?

    override func loadView() {
        view = MarginSurfaceView(fillColor: MarginTheme.inspectorBackground)
        configureHeader()
        configureTable()
        configureComposer()
        updateEmptyState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleVisibleRowHeightRefresh(for: tableView.bounds.width)
    }

    func display(review: ComparisonReview?) {
        let selectedThreadID = selectedRow.map { rows[$0].threadID }
        self.review = review
        rows = review.map(ComparisonCommentRow.makeRows) ?? []
        tableView.reloadData()
        if let selectedThreadID,
           let restored = rows.firstIndex(where: { $0.threadID == selectedThreadID }) {
            tableView.selectRowIndexes(IndexSet(integer: restored), byExtendingSelection: false)
        }
        updateEmptyState()
    }

    func beginNewComment(_ selection: ComparisonSelectionRequest) {
        composerTarget = .selection(selection)
        composerContextLabel.stringValue = "Comment on “\(Self.excerpt(selection.quote))”"
        submitButton.title = "Add Comment"
        revealComposer()
    }

    func beginReply(threadID: String, parentID: String, excerpt: String) {
        composerTarget = .reply(threadID: threadID, parentID: parentID)
        composerContextLabel.stringValue = "Reply to “\(Self.excerpt(excerpt))”"
        submitButton.title = "Reply"
        revealComposer()
    }

    func setMutationInProgress(_ inProgress: Bool) {
        mutationInProgress = inProgress
        updateInteractionAvailability()
        statusLabel.stringValue = inProgress ? "Saving review…" : ""
    }

    func finishMutation(review: ComparisonReview, dismissesComposer: Bool = true) {
        setMutationInProgress(false)
        display(review: review)
        if dismissesComposer { dismissComposer() }
    }

    func showMutationError(_ message: String) {
        setMutationInProgress(false)
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        NSAccessibility.post(
            element: statusLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    var canNavigateOpenThreads: Bool {
        composerTarget == nil
            && !mutationInProgress
            && rows.contains { $0.isRoot && $0.status == .open }
    }

    var canResolveSelectedThread: Bool {
        guard composerTarget == nil, !mutationInProgress, let row = selectedRow else { return false }
        return rows[row].status == .open
    }

    var canReplyToSelectedComment: Bool {
        guard composerTarget == nil, !mutationInProgress, let row = selectedRow else { return false }
        return rows[row].status == .open
    }

    func focusComments() {
        view.window?.makeFirstResponder(tableView)
    }

    func navigateOpenThread(forward: Bool) {
        let roots = rows.indices.filter { rows[$0].isRoot && rows[$0].status == .open }
        guard !roots.isEmpty else { return }
        let selected = tableView.selectedRow
        let destination: Int
        if forward {
            destination = roots.first(where: { $0 > selected }) ?? roots[0]
        } else {
            destination = roots.last(where: { $0 < selected }) ?? roots[roots.count - 1]
        }
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        tableView.scrollRowToVisible(destination)
        focusComments()
        let ordinal = (roots.firstIndex(of: destination) ?? 0) + 1
        NSAccessibility.post(
            element: tableView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Open review thread \(ordinal) of \(roots.count)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    func resolveSelectedThread() {
        guard canResolveSelectedThread, let row = selectedRow else { return }
        onSetThreadStatus?(rows[row].threadID, .resolved)
    }

    func replyToSelectedComment() {
        guard canReplyToSelectedComment, let row = selectedRow else {
            NSSound.beep()
            return
        }
        let item = rows[row]
        beginReply(
            threadID: item.threadID,
            parentID: item.commentID,
            excerpt: item.body
        )
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ComparisonCommentCell")
        let cell: ComparisonCommentCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ComparisonCommentCellView {
            cell = reused
        } else {
            cell = ComparisonCommentCellView(identifier: identifier)
        }
        let item = rows[row]
        cell.configure(
            row: item,
            onReply: { [weak self] in
                self?.beginReply(
                    threadID: item.threadID,
                    parentID: item.commentID,
                    excerpt: item.body
                )
            },
            onSetStatus: item.isRoot ? { [weak self] status in
                self?.onSetThreadStatus?(item.threadID, status)
            } : nil
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 72 }
        let item = rows[row]
        let width = max(180, tableView.bounds.width - 48 - CGFloat(min(item.depth, 2) * 14))
        let bodyBounds = (item.body as NSString).boundingRect(
            with: NSSize(width: width, height: 600),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5)]
        )
        let quoteHeight: CGFloat = item.quote == nil ? 0 : 38
        return max(72, ceil(bodyBounds.height) + quoteHeight + 54)
    }

    private func configureHeader() {
        let title = NSTextField(labelWithAttributedString: MarginTheme.microLabel("Review"))
        countLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.setAccessibilityLabel("Review thread count")

        let close = NSButton(
            image: NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Hide review")
                ?? NSImage(),
            target: self,
            action: #selector(closeInspector(_:))
        )
        close.bezelStyle = .inline
        close.toolTip = "Hide comparison review"

        let spacer = NSView()
        let header = NSStackView(views: [title, spacer, countLabel, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false
        let rule = MarginHairlineView()
        rule.identifier = NSUserInterfaceItemIdentifier("ComparisonReviewHeaderRule")
        rule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(rule)
        composerHeightConstraint = composerContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ComparisonComments"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = MarginTheme.inspectorBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelectedComment(_:))
        tableView.onReturn = { [weak self] in self?.replyToSelectedComment() }
        tableView.setAccessibilityLabel("Comparison review threads")
        tableView.setAccessibilityHelp(
            "Use Up and Down Arrow to select a comment, then Return to reply. Use the Review menu to resolve a thread."
        )
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MarginTheme.inspectorBackground
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12.5)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setAccessibilityLabel("No comparison review threads")

        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        guard let rule = view.subviews.first(where: {
            $0.identifier?.rawValue == "ComparisonReviewHeaderRule"
        }) else { return }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func configureComposer() {
        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.isHidden = true
        let rule = MarginHairlineView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        composerContextLabel.font = .systemFont(ofSize: 11, weight: .medium)
        composerContextLabel.textColor = .secondaryLabelColor
        composerContextLabel.maximumNumberOfLines = 2
        composerContextLabel.translatesAutoresizingMaskIntoConstraints = false

        composerTextView.font = .systemFont(ofSize: 12.5)
        composerTextView.isRichText = false
        composerTextView.allowsUndo = true
        composerTextView.drawsBackground = true
        composerTextView.backgroundColor = .textBackgroundColor
        composerTextView.textContainerInset = NSSize(width: 7, height: 6)
        composerTextView.setAccessibilityLabel("Comparison comment")
        composerTextView.setAccessibilityHelp(
            "Write Markdown. Press Command Return to save, or Escape to cancel."
        )
        let composerScroll = NSScrollView()
        composerScroll.documentView = composerTextView
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.borderType = .bezelBorder
        composerScroll.translatesAutoresizingMaskIntoConstraints = false

        submitButton.target = self
        submitButton.action = #selector(submit(_:))
        submitButton.keyEquivalent = "\r"
        submitButton.keyEquivalentModifierMask = [.command]
        submitButton.toolTip = "Save comment (Command Return)"
        cancelButton.target = self
        cancelButton.action = #selector(cancelComposer(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.toolTip = "Cancel comment (Escape)"
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        let buttons = NSStackView(views: [statusLabel, spacer, cancelButton, submitButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        composerContainer.addSubview(rule)
        composerContainer.addSubview(composerContextLabel)
        composerContainer.addSubview(composerScroll)
        composerContainer.addSubview(buttons)
        view.addSubview(composerContainer)
        NSLayoutConstraint.activate([
            composerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composerHeightConstraint,
            rule.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            rule.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            composerContextLabel.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 10),
            composerContextLabel.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: 12),
            composerContextLabel.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -12),
            composerScroll.topAnchor.constraint(equalTo: composerContextLabel.bottomAnchor, constant: 7),
            composerScroll.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: 12),
            composerScroll.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -12),
            composerScroll.heightAnchor.constraint(equalToConstant: 82),
            buttons.topAnchor.constraint(equalTo: composerScroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor, constant: -9),
            scrollView.bottomAnchor.constraint(equalTo: composerContainer.topAnchor),
        ])
    }

    private func updateEmptyState() {
        let threadCount = review?.threads.count ?? 0
        let noun = threadCount == 1 ? "thread" : "threads"
        countLabel.stringValue = "\(threadCount) \(noun)"
        emptyLabel.isHidden = !rows.isEmpty || composerTarget != nil
        tableView.isHidden = rows.isEmpty
    }

    private func revealComposer() {
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        composerTextView.string = ""
        composerHeightConstraint.constant = 184
        composerContainer.isHidden = false
        updateEmptyState()
        updateInteractionAvailability()
        view.window?.makeFirstResponder(composerTextView)
    }

    private func dismissComposer() {
        composerTarget = nil
        composerTextView.string = ""
        composerContainer.isHidden = true
        guard isViewLoaded else { return }
        composerHeightConstraint.constant = 0
        updateEmptyState()
        updateInteractionAvailability()
    }

    @objc private func submit(_ sender: Any?) {
        let body = composerTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let composerTarget, !body.isEmpty else {
            NSSound.beep()
            return
        }
        onSubmit?(composerTarget, body)
    }

    @objc private func cancelComposer(_ sender: Any?) { dismissComposer() }
    @objc private func closeInspector(_ sender: Any?) { onClose?() }
    @objc private func activateSelectedComment(_ sender: Any?) { replyToSelectedComment() }

    private var selectedRow: Int? {
        let row = tableView.selectedRow
        return rows.indices.contains(row) ? row : nil
    }

    private func updateInteractionAvailability() {
        tableView.isEnabled = !mutationInProgress && composerTarget == nil
        submitButton.isEnabled = !mutationInProgress
        cancelButton.isEnabled = !mutationInProgress
        composerTextView.isEditable = !mutationInProgress
    }

    private func scheduleVisibleRowHeightRefresh(for width: CGFloat) {
        guard abs(width - lastRowHeightWidth) >= 1 else { return }
        lastRowHeightWidth = width
        rowHeightRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.rows.isEmpty else { return }
            let visible = self.tableView.rows(in: self.tableView.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            self.tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(
                    integersIn: visible.location..<(visible.location + visible.length)
                )
            )
        }
        rowHeightRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private static func excerpt(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.count > 88 ? String(compact.prefix(85)) + "…" : compact
    }
}

private final class ComparisonCommentsTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.modifierFlags.intersection(disallowedModifiers).isEmpty,
           (event.keyCode == 36 || event.keyCode == 76) {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

private struct ComparisonCommentRow {
    let threadID: String
    let commentID: String
    let parentID: String?
    let depth: Int
    let author: String
    let body: String
    let quote: String?
    let status: MarginCommentStatus
    let isRoot: Bool

    static func makeRows(_ review: ComparisonReview) -> [ComparisonCommentRow] {
        review.threads.flatMap { thread in
            let byParent = Dictionary(grouping: thread.comments, by: \.parentID)
            let quote = thread.target.left?.selector.quoteSelector?.exact
                ?? thread.target.right?.selector.quoteSelector?.exact
            var output: [ComparisonCommentRow] = []
            func append(_ comment: ComparisonReviewComment, depth: Int) {
                output.append(ComparisonCommentRow(
                    threadID: thread.id,
                    commentID: comment.id,
                    parentID: comment.parentID,
                    depth: depth,
                    author: comment.creator.name,
                    body: comment.body.value,
                    quote: comment.parentID == nil ? quote : nil,
                    status: thread.status,
                    isRoot: comment.parentID == nil
                ))
                for child in (byParent[comment.id] ?? []).sorted(by: {
                    if $0.created != $1.created { return $0.created < $1.created }
                    return $0.id < $1.id
                }) {
                    append(child, depth: depth + 1)
                }
            }
            if let root = thread.comments.first(where: { $0.parentID == nil }) {
                append(root, depth: 0)
            }
            return output
        }
    }
}

private final class ComparisonCommentCellView: NSTableCellView {
    private let rail = ComparisonReplyRailView()
    private let quoteLabel = NSTextField(wrappingLabelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let replyButton = NSButton(title: "Reply", target: nil, action: nil)
    private let statusButton = NSButton(title: "Resolve", target: nil, action: nil)
    private var onReply: (() -> Void)?
    private var onSetStatus: ((MarginCommentStatus) -> Void)?
    private var nextStatus: MarginCommentStatus = .resolved
    private var leadingConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        rail.translatesAutoresizingMaskIntoConstraints = false
        quoteLabel.font = MarginTheme.serifFont(ofSize: 12, weight: .regular)
        quoteLabel.textColor = .secondaryLabelColor
        quoteLabel.maximumNumberOfLines = 2
        quoteLabel.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = .systemFont(ofSize: 12.5)
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        replyButton.bezelStyle = .inline
        replyButton.font = .systemFont(ofSize: 10.5)
        replyButton.target = self
        replyButton.action = #selector(reply(_:))
        statusButton.bezelStyle = .inline
        statusButton.font = .systemFont(ofSize: 10.5)
        statusButton.target = self
        statusButton.action = #selector(toggleStatus(_:))
        let spacer = NSView()
        let actions = NSStackView(views: [replyButton, statusButton, spacer])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rail)
        addSubview(quoteLabel)
        addSubview(authorLabel)
        addSubview(bodyLabel)
        addSubview(actions)
        leadingConstraint = rail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            leadingConstraint,
            rail.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            rail.widthAnchor.constraint(equalToConstant: 1),
            quoteLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            quoteLabel.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 9),
            quoteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            authorLabel.topAnchor.constraint(equalTo: quoteLabel.bottomAnchor, constant: 5),
            authorLabel.leadingAnchor.constraint(equalTo: quoteLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: quoteLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 4),
            bodyLabel.leadingAnchor.constraint(equalTo: quoteLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: quoteLabel.trailingAnchor),
            actions.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 5),
            actions.leadingAnchor.constraint(equalTo: quoteLabel.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: quoteLabel.trailingAnchor),
            actions.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        row: ComparisonCommentRow,
        onReply: @escaping () -> Void,
        onSetStatus: ((MarginCommentStatus) -> Void)?
    ) {
        self.onReply = onReply
        self.onSetStatus = onSetStatus
        leadingConstraint.constant = 12 + CGFloat(min(row.depth, 2) * 14)
        quoteLabel.stringValue = row.quote.map { "“\($0)”" } ?? ""
        quoteLabel.isHidden = row.quote == nil
        authorLabel.stringValue = row.author
        bodyLabel.stringValue = row.body
        statusButton.isHidden = !row.isRoot
        replyButton.isEnabled = row.status == .open
        replyButton.toolTip = row.status == .open
            ? "Reply to this review comment"
            : "Reopen the thread before replying"
        nextStatus = row.status == .open ? .resolved : .open
        statusButton.title = nextStatus == .resolved ? "Resolve" : "Reopen"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            "\(row.isRoot ? "Thread" : "Reply") by \(row.author), \(row.status.rawValue): \(row.body)"
        )
    }

    @objc private func reply(_ sender: Any?) { onReply?() }
    @objc private func toggleStatus(_ sender: Any?) { onSetStatus?(nextStatus) }
}

private final class ComparisonReplyRailView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        MarginTheme.rule.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
