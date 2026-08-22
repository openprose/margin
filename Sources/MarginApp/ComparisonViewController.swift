import AppKit
import MarginCore

final class ComparisonViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case identical
        case failed(String)
    }

    var onCommentRequest: ((ComparisonSelectionRequest) -> Void)?
    var onPresentationChanged: ((ComparisonPresentation) -> Void)?
    var onDisplayOptionsChanged: ((ComparisonPresentationLayout, Bool) -> Void)?
    var onApplyRequest: ((ComparisonApplyDirection, [String]?) -> Void)?
    var onRefreshRequest: (() -> AppComparisonRequest?)? {
        didSet {
            if isViewLoaded { updateControlAvailability() }
        }
    }

    private var request: AppComparisonRequest
    private let loader: any ComparisonLoading
    private let tableView = ComparisonPassagesTableView()
    private let scrollView = NSScrollView()
    private let leftTitleLabel = NSTextField(labelWithString: "Left")
    private let rightTitleLabel = NSTextField(labelWithString: "Right")
    private let detailLabel = NSTextField(labelWithString: "")
    private let layoutNoteLabel = NSTextField(labelWithString: "")
    private let stateStack = NSStackView()
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let swapButton = NSButton()
    private let refreshButton = NSButton()
    private let whitespaceButton = NSButton(checkboxWithTitle: "Whitespace", target: nil, action: nil)
    private let applyControl = NSPopUpButton(frame: .zero, pullsDown: true)
    private let layoutControl = NSSegmentedControl(
        labels: ["Inline", "Side by Side"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private(set) var state: State = .idle
    private var presentation: ComparisonPresentation?
    private var rows: [ComparisonPresentedRow] = []
    private var loadGeneration = UUID()
    private var cancellation: ComparisonCancellationToken?
    private var hasBegun = false
    private var preferredLayout: ComparisonPresentationLayout = .inline
    private var effectiveLayout: ComparisonPresentationLayout = .inline
    private var showWhitespace = false
    private var isSwapped = false
    private var lastRowHeightWidth: CGFloat = 0
    private var rowHeightRefreshWorkItem: DispatchWorkItem?

    init(
        request: AppComparisonRequest,
        loader: any ComparisonLoading = CoreComparisonLoader()
    ) {
        self.request = request
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = MarginSurfaceView(fillColor: MarginTheme.documentBackground)
        configureHeader()
        configureTable()
        configureStateView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateAdaptiveLayout(for: view.bounds.width)
    }

    private func updateAdaptiveLayout(for width: CGFloat) {
        let next = ComparisonPresentationLayout.effective(
            preferred: preferredLayout,
            width: width
        )
        if next != effectiveLayout {
            effectiveLayout = next
            tableView.reloadData()
        }
        layoutNoteLabel.stringValue = preferredLayout == .sideBySide && next == .inline
            ? "Inline at this width"
            : ""
        whitespaceButton.isHidden = width < 720
        layoutControl.isHidden = width < 560
        refreshButton.isHidden = width < 470
        scheduleVisibleRowHeightRefresh(for: width)
    }

    private func scheduleVisibleRowHeightRefresh(for width: CGFloat) {
        guard abs(width - lastRowHeightWidth) >= 1 else { return }
        lastRowHeightWidth = width
        rowHeightRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.rows.isEmpty else { return }
            let visible = self.tableView.rows(in: self.tableView.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            let end = visible.location + visible.length
            self.tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: visible.location..<end)
            )
        }
        rowHeightRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    func beginLoadingIfNeeded() {
        guard !hasBegun else { return }
        hasBegun = true
        load()
    }

    func cancelLoading() {
        loadGeneration = UUID()
        if let cancellation {
            cancellation.cancel()
            ComparisonPerformanceSignal.record(.cancelled)
        }
        cancellation = nil
    }

    var canNavigateChanges: Bool {
        state == .loaded && rows.contains(where: \.isFirstRowForChange)
    }

    var canRefresh: Bool {
        (request.supportsRefresh || onRefreshRequest != nil)
            && presentation != nil
            && state != .loading
    }
    var canApplyChanges: Bool { state == .loaded && presentation != nil && canNavigateChanges }
    var canApplySelectedChange: Bool {
        guard state == .loaded else { return false }
        let row = tableView.selectedRow
        return rows.indices.contains(row) && rows[row].isChanged && rows[row].blockID != nil
    }
    var isSideBySidePreferred: Bool { preferredLayout == .sideBySide }
    var isWhitespaceShown: Bool { showWhitespace }
    var canSwapSides: Bool { presentation != nil && state != .loading }
    var canChangeDisplayOptions: Bool { presentation != nil && state != .loading }
    var canRefreshAfterSuccessfulApply: Bool {
        guard presentation != nil else { return false }
        switch request {
        case .files:
            return true
        case .sources:
            return onRefreshRequest != nil
        case .snapshots, .openRequest, .review:
            return false
        }
    }

    @objc func previousChange(_ sender: Any?) {
        navigateChange(forward: false)
    }

    @objc func nextChange(_ sender: Any?) {
        navigateChange(forward: true)
    }

    func focusComparison() {
        view.window?.makeFirstResponder(tableView)
    }

    @objc func refreshComparison(_ sender: Any?) {
        if let onRefreshRequest {
            guard let refreshed = onRefreshRequest() else { return }
            request = refreshed
        } else {
            guard request.supportsRefresh else { return }
        }
        detailLabel.stringValue = "Refreshing snapshots…"
        detailLabel.textColor = .secondaryLabelColor
        load()
    }

    func refreshAfterSuccessfulApplyIfSafe() {
        guard canRefreshAfterSuccessfulApply else { return }
        refreshComparison(nil)
    }

    @objc func swapSides(_ sender: Any?) {
        guard presentation != nil, state != .loading else { return }
        isSwapped.toggle()
        updateSnapshotHeader()
        tableView.reloadData()
        let message = isSwapped ? "Comparison sides swapped" : "Original comparison order restored"
        NSAccessibility.post(
            element: swapButton,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    @objc func toggleSideBySide(_ sender: Any?) {
        guard canChangeDisplayOptions else { return }
        layoutControl.selectedSegment = preferredLayout == .sideBySide ? 0 : 1
        layoutChanged(layoutControl)
    }

    @objc func toggleWhitespace(_ sender: Any?) {
        guard canChangeDisplayOptions else { return }
        whitespaceButton.state = showWhitespace ? .off : .on
        whitespaceChanged(whitespaceButton)
    }

    func requestApply(
        visualDirection: ComparisonApplyDirection,
        selectedOnly: Bool
    ) {
        guard state == .loaded, presentation != nil else {
            showOperationStatus("Wait for the comparison to finish before applying changes.", isError: true)
            return
        }
        let actualDirection: ComparisonApplyDirection
        if isSwapped {
            actualDirection = visualDirection == .leftToRight ? .rightToLeft : .leftToRight
        } else {
            actualDirection = visualDirection
        }
        var blockIDs: [String]?
        if selectedOnly {
            let row = tableView.selectedRow
            guard rows.indices.contains(row),
                  rows[row].isChanged,
                  let blockID = rows[row].blockID else {
                showOperationStatus(
                    "Select a changed passage before applying one change.",
                    isError: true
                )
                return
            }
            blockIDs = [blockID]
        }
        onApplyRequest?(actualDirection, blockIDs)
    }

    func showCommentingUnavailable(for request: ComparisonSelectionRequest) {
        let sideName = request.side == .left ? "left" : "right"
        detailLabel.stringValue = "Selection mapped on the \(sideName). Save a review to begin a thread."
        NSAccessibility.post(
            element: detailLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: detailLabel.stringValue,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    func showOperationStatus(_ message: String, isError: Bool = false) {
        detailLabel.stringValue = message
        detailLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        NSAccessibility.post(
            element: detailLabel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: isError
                    ? NSAccessibilityPriorityLevel.high.rawValue
                    : NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    func restoreSnapshotStatus() {
        updateSnapshotHeader()
    }

    private func load() {
        cancelLoading()
        state = .loading
        updateStatePresentation()
        let generation = UUID()
        loadGeneration = generation
        let cancellation = ComparisonCancellationToken()
        self.cancellation = cancellation
        let request = self.request
        let loader = self.loader

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try loader.load(request, cancellation: cancellation)
            }
            DispatchQueue.main.async {
                guard let self,
                      self.loadGeneration == generation,
                      !cancellation.isCancelled else { return }
                self.cancellation = nil
                switch result {
                case .success(let presentation):
                    self.apply(presentation)
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                    self.updateStatePresentation()
                }
            }
        }
    }

    private func apply(_ presentation: ComparisonPresentation) {
        self.presentation = presentation
        rows = presentation.rows
        if let review = presentation.review {
            preferredLayout = review.display.layout == .sideBySide ? .sideBySide : .inline
            layoutControl.selectedSegment = preferredLayout.rawValue
            showWhitespace = review.display.showWhitespace
            whitespaceButton.state = showWhitespace ? .on : .off
        }
        updateSnapshotHeader()
        state = presentation.isIdentical ? .identical : .loaded
        tableView.reloadData()
        updateStatePresentation()
        ComparisonPerformanceSignal.record(.completeReady)
        onPresentationChanged?(presentation)
    }

    private func configureHeader() {
        let eyebrow = NSTextField(labelWithAttributedString: MarginTheme.microLabel("Compare"))
        eyebrow.setAccessibilityLabel("Comparison")

        [leftTitleLabel, rightTitleLabel].forEach { label in
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
        }
        let arrow = NSTextField(labelWithString: "→")
        arrow.font = .systemFont(ofSize: 13, weight: .regular)
        arrow.textColor = .tertiaryLabelColor
        arrow.setAccessibilityElement(false)

        let titles = NSStackView(views: [leftTitleLabel, arrow, rightTitleLabel])
        titles.orientation = .horizontal
        titles.alignment = .centerY
        titles.spacing = 8
        leftTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setAccessibilityLabel("Comparison status")

        let titleColumn = NSStackView(views: [eyebrow, titles, detailLabel])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 3
        titleColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)

        layoutControl.selectedSegment = 0
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged(_:))
        layoutControl.segmentStyle = .texturedRounded
        layoutControl.setAccessibilityLabel("Comparison layout")
        layoutControl.setAccessibilityHelp("Choose an inline proof or aligned side-by-side passages")

        swapButton.image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "Swap comparison sides"
        )
        swapButton.bezelStyle = .inline
        swapButton.target = self
        swapButton.action = #selector(swapSides(_:))
        swapButton.toolTip = "Swap left and right presentation"
        swapButton.setAccessibilityLabel("Swap comparison sides")

        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh comparison"
        )
        refreshButton.bezelStyle = .inline
        refreshButton.target = self
        refreshButton.action = #selector(refreshComparison(_:))
        refreshButton.toolTip = "Refresh comparison from its explicit sources"
        refreshButton.setAccessibilityLabel("Refresh comparison")
        refreshButton.isEnabled = request.supportsRefresh

        whitespaceButton.target = self
        whitespaceButton.action = #selector(whitespaceChanged(_:))
        whitespaceButton.controlSize = .small
        whitespaceButton.setAccessibilityLabel("Show comparison whitespace")
        whitespaceButton.setAccessibilityHelp("Show spaces and tabs without changing the Markdown")

        applyControl.addItem(withTitle: "Apply")
        applyControl.addItem(withTitle: "Selected Change, Left to Right")
        applyControl.lastItem?.tag = 1
        applyControl.addItem(withTitle: "Selected Change, Right to Left")
        applyControl.lastItem?.tag = 2
        applyControl.menu?.addItem(.separator())
        applyControl.addItem(withTitle: "All Changes, Left to Right")
        applyControl.lastItem?.tag = 3
        applyControl.addItem(withTitle: "All Changes, Right to Left")
        applyControl.lastItem?.tag = 4
        applyControl.target = self
        applyControl.action = #selector(applyChoiceChanged(_:))
        applyControl.controlSize = .small
        applyControl.setAccessibilityLabel("Apply comparison changes")
        applyControl.setAccessibilityHelp(
            "Choose a direction. Margin verifies the destination before changing it."
        )
        applyControl.isEnabled = false

        let controls = NSStackView(views: [
            swapButton,
            refreshButton,
            whitespaceButton,
            layoutControl,
            applyControl,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        layoutNoteLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        layoutNoteLabel.textColor = .tertiaryLabelColor
        layoutNoteLabel.alignment = .right
        layoutNoteLabel.setAccessibilityLabel("Layout note")
        let layoutColumn = NSStackView(views: [controls, layoutNoteLabel])
        layoutColumn.orientation = .vertical
        layoutColumn.alignment = .trailing
        layoutColumn.spacing = 4

        let header = NSStackView(views: [titleColumn, layoutColumn])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 20
        header.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
        header.translatesAutoresizingMaskIntoConstraints = false

        let rule = MarginHairlineView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(rule)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        header.setAccessibilityElement(false)
        rule.identifier = NSUserInterfaceItemIdentifier("ComparisonHeaderRule")
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ComparisonBlock"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = MarginTheme.documentBackground
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickedRow(_:))
        tableView.onReturn = { [weak self] in self?.activateSelectedRow() }
        tableView.setAccessibilityLabel("Comparison passages")
        tableView.setAccessibilityHelp(
            "Use Option Command Up and Down Arrow to move between changes. Press Return on a collapsed passage to reveal it."
        )

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MarginTheme.documentBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        guard let rule = view.subviews.first(where: { $0.identifier?.rawValue == "ComparisonHeaderRule" }) else {
            return
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureStateView() {
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.startAnimation(nil)
        progressIndicator.setAccessibilityLabel("Comparing")

        stateLabel.font = .systemFont(ofSize: 14, weight: .regular)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .center
        stateLabel.maximumNumberOfLines = 4
        stateLabel.preferredMaxLayoutWidth = 460

        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.bezelStyle = .rounded

        stateStack.orientation = .vertical
        stateStack.alignment = .centerX
        stateStack.spacing = 10
        stateStack.addArrangedSubview(progressIndicator)
        stateStack.addArrangedSubview(stateLabel)
        stateStack.addArrangedSubview(retryButton)
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateStack)
        NSLayoutConstraint.activate([
            stateStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -18),
            stateStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stateStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
        ])
        updateStatePresentation()
    }

    private func updateStatePresentation() {
        switch state {
        case .idle:
            scrollView.isHidden = true
            stateStack.isHidden = false
            progressIndicator.isHidden = true
            retryButton.isHidden = true
            stateLabel.stringValue = "Ready to compare"
        case .loading:
            scrollView.isHidden = true
            stateStack.isHidden = false
            progressIndicator.isHidden = false
            retryButton.isHidden = true
            stateLabel.stringValue = "Comparing literal Markdown…"
        case .loaded:
            scrollView.isHidden = false
            stateStack.isHidden = true
        case .identical:
            scrollView.isHidden = true
            stateStack.isHidden = false
            progressIndicator.isHidden = true
            retryButton.isHidden = true
            stateLabel.stringValue = "These snapshots are identical."
        case .failed(let message):
            scrollView.isHidden = true
            stateStack.isHidden = false
            progressIndicator.isHidden = true
            retryButton.isHidden = false
            stateLabel.stringValue = "Margin could not compare these snapshots.\n\(message)"
        }
        updateControlAvailability()
    }

    private func updateControlAvailability() {
        let hasPresentation = presentation != nil
        let isLoading = state == .loading
        refreshButton.isEnabled = hasPresentation
            && !isLoading
            && (request.supportsRefresh || onRefreshRequest != nil)
        swapButton.isEnabled = hasPresentation && !isLoading
        layoutControl.isEnabled = hasPresentation && !isLoading
        whitespaceButton.isEnabled = hasPresentation && !isLoading
        applyControl.isEnabled = state == .loaded && canNavigateChanges
    }

    @objc private func layoutChanged(_ sender: NSSegmentedControl) {
        preferredLayout = sender.selectedSegment == 1 ? .sideBySide : .inline
        let next = ComparisonPresentationLayout.effective(
            preferred: preferredLayout,
            width: view.bounds.width
        )
        if effectiveLayout != next {
            effectiveLayout = next
        }
        tableView.reloadData()
        view.needsLayout = true
        onDisplayOptionsChanged?(preferredLayout, showWhitespace)
    }

    @objc private func whitespaceChanged(_ sender: NSButton) {
        showWhitespace = sender.state == .on
        tableView.reloadData()
        onDisplayOptionsChanged?(preferredLayout, showWhitespace)
    }

    @objc private func applyChoiceChanged(_ sender: NSPopUpButton) {
        let tag = sender.selectedItem?.tag ?? 0
        defer { sender.selectItem(at: 0) }
        guard tag > 0 else { return }
        let visualDirection: ComparisonApplyDirection = tag == 1 || tag == 3
            ? .leftToRight
            : .rightToLeft
        requestApply(
            visualDirection: visualDirection,
            selectedOnly: tag == 1 || tag == 2
        )
    }

    @objc private func retry(_ sender: Any?) {
        load()
    }

    @objc private func doubleClickedRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard rows.indices.contains(row),
              case .collapsed = rows[row].kind else { return }
        expandCollapsedRow(at: row)
    }

    private func activateSelectedRow() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row), case .collapsed = rows[row].kind else {
            NSSound.beep()
            return
        }
        expandCollapsedRow(at: row)
    }

    private func expandCollapsedRow(at index: Int) {
        guard rows.indices.contains(index),
              let hidden = presentation?.collapsedRows[rows[index].id] else { return }
        rows.replaceSubrange(index...index, with: hidden)
        tableView.reloadData()
        if rows.indices.contains(index) { tableView.scrollRowToVisible(index) }
    }

    private func navigateChange(forward: Bool) {
        let changed = rows.indices.filter { rows[$0].isFirstRowForChange }
        guard !changed.isEmpty else { return }
        let selected = tableView.selectedRow
        let destination: Int
        if forward {
            destination = changed.first(where: { $0 > selected }) ?? changed[0]
        } else {
            destination = changed.last(where: { $0 < selected }) ?? changed[changed.count - 1]
        }
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        tableView.scrollRowToVisible(destination)
        view.window?.makeFirstResponder(tableView)
        let ordinal = (changed.firstIndex(of: destination) ?? 0) + 1
        NSAccessibility.post(
            element: tableView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Change \(ordinal) of \(changed.count)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let presentation else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ComparisonBlockRow")
        let view: ComparisonBlockRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ComparisonBlockRowView {
            view = reused
        } else {
            view = ComparisonBlockRowView(identifier: identifier)
        }
        view.configure(
            row: rows[row],
            layout: effectiveLayout,
            pair: presentation.pair,
            swapped: isSwapped,
            showWhitespace: showWhitespace,
            onComment: { [weak self] request in self?.onCommentRequest?(request) },
            onExpand: { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                let current = tableView.row(for: view)
                if current >= 0 { self.expandCollapsedRow(at: current) }
            }
        )
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 36 }
        return ComparisonBlockRowView.height(
            for: rows[row],
            layout: effectiveLayout,
            availableWidth: max(320, tableView.bounds.width)
        )
    }

    var stateForTesting: State { state }
    var rowCountForTesting: Int { rows.count }
    var effectiveLayoutForTesting: ComparisonPresentationLayout { effectiveLayout }
    var firstCollapsedRowIndexForTesting: Int? {
        rows.firstIndex {
            if case .collapsed = $0.kind { return true }
            return false
        }
    }
    var headerVisibilityForTesting: (refresh: Bool, whitespace: Bool, layout: Bool) {
        (!refreshButton.isHidden, !whitespaceButton.isHidden, !layoutControl.isHidden)
    }
    var snapshotStatusForTesting: String { detailLabel.stringValue }
    func updateAdaptiveLayoutForTesting(width: CGFloat) {
        updateAdaptiveLayout(for: width)
    }

    private func updateSnapshotHeader() {
        guard let presentation else { return }
        detailLabel.textColor = .secondaryLabelColor
        let left = isSwapped ? presentation.pair.right : presentation.pair.left
        let right = isSwapped ? presentation.pair.left : presentation.pair.right
        leftTitleLabel.stringValue = left.label
        rightTitleLabel.stringValue = right.label
        leftTitleLabel.toolTip = left.pathHint
        rightTitleLabel.toolTip = right.pathHint
        let leftDigest = String(left.sha256.prefix(8))
        let rightDigest = String(right.sha256.prefix(8))
        if presentation.result.isCoarse {
            detailLabel.stringValue = "\(leftDigest)  →  \(rightDigest)  ·  simplified for size"
        } else {
            let count = presentation.result.changedBlocks.count
            let noun = count == 1 ? "change" : "changes"
            detailLabel.stringValue = "\(leftDigest)  →  \(rightDigest)  ·  \(count) \(noun)"
        }
    }
}

private final class ComparisonPassagesTableView: NSTableView {
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

enum ComparisonSelectionMapping {
    static func request(
        row: ComparisonPresentedRow,
        pair: ComparisonSnapshotPair,
        swapped: Bool,
        visualSide: ComparisonSide,
        selection: UnicodeScalarRange
    ) -> ComparisonSelectionRequest? {
        let model: ComparisonPresentedSide?
        let actualSide: ComparisonSide
        switch (swapped, visualSide) {
        case (false, .left):
            model = row.left
            actualSide = .left
        case (false, .right):
            model = row.right
            actualSide = .right
        case (true, .left):
            model = row.right
            actualSide = .right
        case (true, .right):
            model = row.left
            actualSide = .left
        }
        guard let model else { return nil }
        let quote = scalarSubstring(
            model.text,
            start: selection.start,
            end: selection.end
        )
        guard !quote.isEmpty else { return nil }
        return ComparisonSelectionRequest(
            side: actualSide,
            pairID: pair.id,
            snapshotSHA256: actualSide == .left ? pair.left.sha256 : pair.right.sha256,
            blockID: row.blockID,
            unicodeScalarRange: UnicodeScalarRange(
                start: model.unicodeScalarStart + selection.start,
                end: model.unicodeScalarStart + selection.end
            ),
            quote: quote
        )
    }

    private static func scalarSubstring(_ source: String, start: Int, end: Int) -> String {
        let scalars = source.unicodeScalars
        guard start >= 0, end > start, end <= scalars.count else { return "" }
        let lower = scalars.index(scalars.startIndex, offsetBy: start)
        let upper = scalars.index(scalars.startIndex, offsetBy: end)
        return String(scalars[lower..<upper])
    }
}

private final class ComparisonBlockRowView: NSTableCellView {
    private let inlineStack = NSStackView()
    private let sideStack = NSStackView()
    private let inlineLeft = ComparisonTextCellView()
    private let inlineRight = ComparisonTextCellView()
    private let sideLeft = ComparisonTextCellView()
    private let sideRight = ComparisonTextCellView()
    private let collapsedButton = NSButton(title: "", target: nil, action: nil)
    private var onExpand: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true

        inlineStack.orientation = .vertical
        inlineStack.alignment = .width
        inlineStack.spacing = 1
        inlineStack.translatesAutoresizingMaskIntoConstraints = false
        inlineStack.addArrangedSubview(inlineLeft)
        inlineStack.addArrangedSubview(inlineRight)

        sideStack.orientation = .horizontal
        sideStack.alignment = .height
        sideStack.spacing = 1
        sideStack.distribution = .fillEqually
        sideStack.translatesAutoresizingMaskIntoConstraints = false
        sideStack.addArrangedSubview(sideLeft)
        sideStack.addArrangedSubview(sideRight)

        collapsedButton.bezelStyle = .inline
        collapsedButton.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        collapsedButton.contentTintColor = .secondaryLabelColor
        collapsedButton.target = self
        collapsedButton.action = #selector(expand(_:))
        collapsedButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(inlineStack)
        addSubview(sideStack)
        addSubview(collapsedButton)
        NSLayoutConstraint.activate([
            inlineStack.topAnchor.constraint(equalTo: topAnchor),
            inlineStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            inlineStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            inlineStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            sideStack.topAnchor.constraint(equalTo: topAnchor),
            sideStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            sideStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            sideStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            collapsedButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            collapsedButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        row: ComparisonPresentedRow,
        layout: ComparisonPresentationLayout,
        pair: ComparisonSnapshotPair,
        swapped: Bool,
        showWhitespace: Bool,
        onComment: @escaping (ComparisonSelectionRequest) -> Void,
        onExpand: @escaping () -> Void
    ) {
        self.onExpand = onExpand
        switch row.kind {
        case .collapsed(let omitted):
            inlineStack.isHidden = true
            sideStack.isHidden = true
            collapsedButton.isHidden = false
            let noun = omitted == 1 ? "line" : "lines"
            collapsedButton.title = "Show \(omitted) unchanged \(noun)"
            collapsedButton.setAccessibilityLabel(collapsedButton.title)
            setAccessibilityLabel(collapsedButton.title)
        case .content(let kind):
            let displayedKind: ComparisonBlockKind
            if swapped {
                switch kind {
                case .insertion: displayedKind = .deletion
                case .deletion: displayedKind = .insertion
                case .unchanged: displayedKind = .unchanged
                case .replacement: displayedKind = .replacement
                }
            } else {
                displayedKind = kind
            }
            let displayedLeft = swapped ? row.right : row.left
            let displayedRight = swapped ? row.left : row.right
            collapsedButton.isHidden = true
            inlineStack.isHidden = layout != .inline
            sideStack.isHidden = layout != .sideBySide
            configure(
                cell: inlineLeft,
                model: displayedLeft,
                visualSide: .left,
                kind: displayedKind,
                row: row,
                pair: pair,
                swapped: swapped,
                showWhitespace: showWhitespace,
                onComment: onComment
            )
            configure(
                cell: inlineRight,
                model: displayedRight,
                visualSide: .right,
                kind: displayedKind,
                row: row,
                pair: pair,
                swapped: swapped,
                showWhitespace: showWhitespace,
                onComment: onComment
            )
            configure(
                cell: sideLeft,
                model: displayedLeft,
                visualSide: .left,
                kind: displayedKind,
                row: row,
                pair: pair,
                swapped: swapped,
                showWhitespace: showWhitespace,
                onComment: onComment
            )
            configure(
                cell: sideRight,
                model: displayedRight,
                visualSide: .right,
                kind: displayedKind,
                row: row,
                pair: pair,
                swapped: swapped,
                showWhitespace: showWhitespace,
                onComment: onComment
            )
            inlineLeft.isHidden = displayedLeft == nil
            inlineRight.isHidden = displayedRight == nil
                || (displayedKind == .unchanged && displayedLeft != nil)
            sideLeft.isHidden = false
            sideRight.isHidden = false
            let description = Self.accessibilityDescription(
                kind: displayedKind,
                left: displayedLeft,
                right: displayedRight
            )
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel(description)
        }
    }

    private func configure(
        cell: ComparisonTextCellView,
        model: ComparisonPresentedSide?,
        visualSide: ComparisonSide,
        kind: ComparisonBlockKind,
        row: ComparisonPresentedRow,
        pair: ComparisonSnapshotPair,
        swapped: Bool,
        showWhitespace: Bool,
        onComment: @escaping (ComparisonSelectionRequest) -> Void
    ) {
        cell.configure(
            model: model,
            side: visualSide,
            kind: kind,
            showWhitespace: showWhitespace
        ) { selection, _ in
            guard let request = ComparisonSelectionMapping.request(
                row: row,
                pair: pair,
                swapped: swapped,
                visualSide: visualSide,
                selection: selection
            ) else { return }
            onComment(request)
        }
    }

    @objc private func expand(_ sender: Any?) { onExpand?() }

    static func height(
        for row: ComparisonPresentedRow,
        layout: ComparisonPresentationLayout,
        availableWidth: CGFloat
    ) -> CGFloat {
        guard case .content(let kind) = row.kind else { return 38 }
        let cellWidth = layout == .sideBySide ? (availableWidth - 1) / 2 : availableWidth
        let left = textHeight(row.left?.text, width: cellWidth)
        let right = textHeight(row.right?.text, width: cellWidth)
        if layout == .sideBySide { return max(left, right) }
        if kind == .replacement, row.left != nil, row.right != nil { return left + right + 1 }
        return max(left, right)
    }

    private static func textHeight(_ text: String?, width: CGFloat) -> CGFloat {
        guard let text else { return 34 }
        let font = MarginTheme.sourceBodyFont(size: 13.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        let bounds = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: NSSize(width: max(80, width - 88), height: 1_200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        return min(1_200, max(34, ceil(bounds.height) + 15))
    }

    private static func accessibilityDescription(
        kind: ComparisonBlockKind,
        left: ComparisonPresentedSide?,
        right: ComparisonPresentedSide?
    ) -> String {
        let name: String
        switch kind {
        case .unchanged: name = "Unchanged"
        case .insertion: name = "Inserted"
        case .deletion: name = "Deleted"
        case .replacement: name = "Replaced"
        }
        let leftDescription = left.map { "left line \($0.lineNumber)" }
        let rightDescription = right.map { "right line \($0.lineNumber)" }
        return ([name] + [leftDescription, rightDescription].compactMap { $0 })
            .joined(separator: ", ")
    }
}

private final class ComparisonTextCellView: NSView {
    private let backgroundView = ComparisonChangeBackgroundView()
    private let markerLabel = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")
    private let textView = ComparisonSelectionTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        markerLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        markerLabel.alignment = .center
        markerLabel.translatesAutoresizingMaskIntoConstraints = false
        lineLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        lineLabel.textColor = .tertiaryLabelColor
        lineLabel.alignment = .right
        lineLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backgroundView)
        addSubview(markerLabel)
        addSubview(lineLabel)
        addSubview(textView)
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            markerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            markerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            markerLabel.widthAnchor.constraint(equalToConstant: 16),
            lineLabel.leadingAnchor.constraint(equalTo: markerLabel.trailingAnchor, constant: 2),
            lineLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            lineLabel.widthAnchor.constraint(equalToConstant: 36),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            textView.leadingAnchor.constraint(equalTo: lineLabel.trailingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        model: ComparisonPresentedSide?,
        side: ComparisonSide,
        kind: ComparisonBlockKind,
        showWhitespace: Bool,
        onComment: @escaping (UnicodeScalarRange, String) -> Void
    ) {
        backgroundView.kind = model == nil ? nil : kind
        let marker: String
        switch (kind, side, model != nil) {
        case (.insertion, .right, true), (.replacement, .right, true): marker = "+"
        case (.deletion, .left, true), (.replacement, .left, true): marker = "−"
        default: marker = ""
        }
        markerLabel.stringValue = marker
        markerLabel.textColor = marker == "+" ? .systemGreen : (marker == "−" ? .systemRed : .tertiaryLabelColor)
        lineLabel.stringValue = model.map { String($0.lineNumber) } ?? ""

        guard let model else {
            textView.string = ""
            textView.onComment = nil
            textView.setAccessibilityLabel(side == .left ? "No left passage" : "No right passage")
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        let renderedText = showWhitespace
            ? Self.whitespaceVisible(model.text)
            : model.text
        let attributed = NSMutableAttributedString(
            string: renderedText.isEmpty ? " " : renderedText,
            attributes: [
                .font: MarginTheme.sourceBodyFont(size: 13.5),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        for scalarRange in model.wordEmphasis {
            if let range = Self.utf16Range(for: scalarRange, in: model.text),
               NSMaxRange(range) <= attributed.length {
                attributed.addAttribute(
                    .backgroundColor,
                    value: NSColor.controlAccentColor.withAlphaComponent(0.18),
                    range: range
                )
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.sourceScalarLength = model.unicodeScalarLength
        textView.onComment = onComment
        let sideName = side == .left ? "Left" : "Right"
        let stateName: String
        switch kind {
        case .unchanged: stateName = "unchanged"
        case .insertion: stateName = "inserted"
        case .deletion: stateName = "deleted"
        case .replacement: stateName = side == .left ? "replaced original" : "replacement"
        }
        textView.setAccessibilityLabel("\(sideName), \(stateName), line \(model.lineNumber)")
        textView.setAccessibilityHelp(
            model.isDisplayTruncated
                ? "This unusually long line is shortened for display. Select visible text to comment."
                : "Select text and press Option Command M to request a comparison comment."
        )
    }

    private static func utf16Range(
        for scalarRange: UnicodeScalarRange,
        in string: String
    ) -> NSRange? {
        let scalars = string.unicodeScalars
        guard scalarRange.start >= 0,
              scalarRange.end >= scalarRange.start,
              scalarRange.end <= scalars.count else { return nil }
        let startScalar = scalars.index(scalars.startIndex, offsetBy: scalarRange.start)
        let endScalar = scalars.index(scalars.startIndex, offsetBy: scalarRange.end)
        guard let start = startScalar.samePosition(in: string),
              let end = endScalar.samePosition(in: string) else { return nil }
        return NSRange(start..<end, in: string)
    }

    private static func whitespaceVisible(_ value: String) -> String {
        String(value.map { character in
            switch character {
            case " ": return "·"
            case "\t": return "→"
            default: return character
            }
        })
    }
}

private final class ComparisonSelectionTextView: NSTextView {
    var sourceScalarLength = 0
    var onComment: ((UnicodeScalarRange, String) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        let item = NSMenuItem(
            title: "Comment on Selection",
            action: #selector(beginComment(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = selectedRange().length > 0 && onComment != nil
        menu.addItem(item)
        return menu
    }

    @objc func beginComment(_ sender: Any?) {
        guard let onComment else { return }
        let full = string as NSString
        let visibleScalars = String(string.unicodeScalars.prefix(sourceScalarLength))
        let originalLength = (visibleScalars as NSString).length
        let selection = NSIntersectionRange(
            selectedRange(),
            NSRange(location: 0, length: originalLength)
        )
        guard selection.length > 0, NSMaxRange(selection) <= full.length else { return }
        let prefix = full.substring(to: selection.location)
        let quote = full.substring(with: selection)
        let start = prefix.unicodeScalars.count
        onComment(
            UnicodeScalarRange(start: start, end: start + quote.unicodeScalars.count),
            quote
        )
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(beginComment(_:)) {
            return selectedRange().length > 0 && onComment != nil
        }
        return true
    }
}

private final class ComparisonChangeBackgroundView: NSView {
    var kind: ComparisonBlockKind? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let contrastMultiplier: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? 1.8
            : 1
        let color: NSColor
        switch kind {
        case .insertion:
            color = NSColor.systemGreen.withAlphaComponent(0.065 * contrastMultiplier)
        case .deletion:
            color = NSColor.systemRed.withAlphaComponent(0.055 * contrastMultiplier)
        case .replacement:
            color = NSColor.controlAccentColor.withAlphaComponent(0.055 * contrastMultiplier)
        case .unchanged, nil:
            color = .clear
        }
        color.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
