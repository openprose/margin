import AppKit
import MarginCore

final class CommentsViewController: NSViewController {
    enum Filter: CaseIterable, Equatable {
        case new
        case open
        case resolved
        case all

        var title: String {
            switch self {
            case .new: return "New"
            case .open: return "Open"
            case .resolved: return "Resolved"
            case .all: return "All"
            }
        }
    }

    var onCreateComment: ((String) -> Void)?
    var onReply: ((String, String) -> Void)?
    var onResolve: ((String) -> Void)?
    var onReopen: ((String) -> Void)?
    var onSelectComment: ((String) -> Void)?
    var onComposerDismiss: (() -> Void)?
    var onMarkCommentsRead: ((Set<String>) -> Void)?
    /// The revision is captured when the edit composer opens, not when it
    /// submits, so a watcher refresh cannot silently bless stale text.
    var onEditComment: ((String, String, Int) -> Void)?
    /// The Boolean is true for a whole-thread subtree and false for one reply.
    var onDeleteComment: ((String, Bool) -> Void)?
    var onAcceptSuggestion: ((String) -> Void)?
    var onRejectSuggestion: ((String) -> Void)?

    private(set) var orderedVisibleRootIDs: [String] = []
    private(set) var reviewProgressDescription = ""
    private(set) var availableFilters: [Filter] = [.open, .resolved, .all]
    private(set) var presentationFilter: Filter = .open

    var selectedRootCommentID: String? {
        guard let selectedCommentID else { return nil }
        return inspectorIndex.rootID(containing: selectedCommentID)
    }

    private let headerLabel = NSTextField(labelWithString: "Review")
    private let countLabel = NSTextField(labelWithString: "")
    private let filterControl = NSSegmentedControl(frame: .zero)
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let composerHost = NSStackView()
    private let threadList = NSStackView()

    private var source = ""
    private var comments: [MarginComment] = []
    private var commentRevision = 0
    private var resolutions: [String: AnchorResolution] = [:]
    private var resolutionsAreCurrent = false
    private var selectedCommentID: String?
    private var unreadCommentIDs = Set<String>()
    private var localActorID: String?
    private var expandedThreadIDs = Set<String>()
    private var inspectorIndexCache: CommentInspectorIndex?
    private var threadViews: [String: CommentThreadView] = [:]
    private var pendingFocusThreadID: String?
    private var pendingFallbackFocusThreadID: String?

    override func loadView() {
        view = MarginSurfaceView(fillColor: MarginTheme.inspectorBackground)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityLabel("Document review")

        let header = MarginSurfaceView(fillColor: MarginTheme.inspectorBackground)
        header.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterControl.trackingMode = .selectOne
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        filterControl.segmentStyle = .automatic
        filterControl.controlSize = .small
        filterControl.setAccessibilityLabel("Comment filter")

        header.addSubview(headerLabel)
        header.addSubview(countLabel)
        header.addSubview(filterControl)

        let separator = MarginHairlineView()
        separator.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MarginTheme.inspectorBackground
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = MarginTheme.inspectorBackground
        scrollView.borderType = .noBorder

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 28, right: 18)
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView

        composerHost.translatesAutoresizingMaskIntoConstraints = false
        composerHost.orientation = .vertical
        composerHost.alignment = .leading
        composerHost.spacing = 0

        threadList.translatesAutoresizingMaskIntoConstraints = false
        threadList.orientation = .vertical
        threadList.alignment = .leading
        threadList.spacing = 0
        threadList.setAccessibilityElement(true)
        threadList.setAccessibilityRole(.list)
        threadList.setAccessibilityLabel("Comment threads")

        contentStack.addArrangedSubview(composerHost)
        contentStack.addArrangedSubview(threadList)

        view.addSubview(header)
        view.addSubview(separator)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 76),

            headerLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            countLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor, constant: 7),

            filterControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            filterControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            filterControl.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 9),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            composerHost.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36),
            threadList.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Comment rendering remains outside the launch path. If the pane is
        // materialized later, build its retained projection only at that point.
        reload()
    }

    func display(
        comments: [MarginComment],
        source: String,
        selectedCommentID: String? = nil,
        commentRevision: Int = 0
    ) {
        let previousStatus = Dictionary(
            self.comments.filter { $0.motivation == "commenting" }.map { ($0.id, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        self.comments = comments
        self.source = source
        self.selectedCommentID = selectedCommentID
        self.commentRevision = commentRevision
        inspectorIndexCache = nil

        let roots = comments.filter { $0.motivation == "commenting" }
        let rootIDs = Set(roots.map(\.id))
        expandedThreadIDs.formIntersection(rootIDs)
        for root in roots where root.status == .resolved && previousStatus[root.id] != .resolved {
            expandedThreadIDs.remove(root.id)
        }

        resolutions.removeAll(keepingCapacity: true)
        resolutionsAreCurrent = false
        ensureSelectedThreadIsPresentable()
        reload()
    }

    /// Source/editor selection synchronization. Callers performing a review
    /// action can opt into clearing supplied unread state without owning the
    /// inspector's thread graph.
    func selectComment(_ id: String?, markingRead: Bool = false) {
        selectedCommentID = id
        if markingRead, let rootID = inspectorIndex.rootID(containing: id) {
            markThreadRead(rootID)
        }
        ensureSelectedThreadIsPresentable()
        reload()
    }

    func setUnreadCommentIDs(_ ids: Set<String>) {
        unreadCommentIDs = ids
        reload()
    }

    func setLocalActorID(_ id: String?) {
        localActorID = id
        reload()
    }

    func markSelectedThreadRead() {
        guard let rootID = selectedRootCommentID else { return }
        pendingFocusThreadID = rootID
        pendingFallbackFocusThreadID = nearestNeighbor(to: rootID)
        markThreadRead(rootID)
        ensureSelectedThreadIsPresentable()
        reload()
    }

    func markCommentIDsRead(_ ids: Set<String>) {
        let removed = unreadCommentIDs.intersection(ids)
        guard !removed.isEmpty else { return }
        unreadCommentIDs.subtract(removed)
        onMarkCommentsRead?(removed)
        ensureSelectedThreadIsPresentable()
        reload()
    }

    func setPresentationFilter(_ filter: Filter) {
        presentationFilter = filter == .new && unreadRootIDs.isEmpty ? .open : filter
        reload()
    }

    func selectNextComment() {
        moveReviewSelection(by: 1)
    }

    func selectPreviousComment() {
        moveReviewSelection(by: -1)
    }

    func beginNewComment(quotedText: String) {
        showComposer(quote: quotedText, parentID: nil)
    }

    func focusComments() {
        _ = view
        if let composer = composerHost.arrangedSubviews.first as? CommentComposerView {
            view.window?.makeFirstResponder(composer.textView)
        } else if let rootID = selectedRootCommentID,
                  let thread = threadViews[rootID] {
            view.window?.makeFirstResponder(thread)
        } else if let first = orderedVisibleRootIDs.first,
                  let thread = threadViews[first] {
            view.window?.makeFirstResponder(thread)
        } else {
            view.window?.makeFirstResponder(filterControl)
        }
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        guard availableFilters.indices.contains(sender.selectedSegment) else { return }
        presentationFilter = availableFilters[sender.selectedSegment]
        reload()
    }

    private var inspectorIndex: CommentInspectorIndex {
        if let inspectorIndexCache { return inspectorIndexCache }
        let index = CommentInspectorIndex(comments: comments)
        inspectorIndexCache = index
        return index
    }

    private var unreadRootIDs: Set<String> {
        Set(unreadCommentIDs.compactMap { inspectorIndex.rootID(containing: $0) })
    }

    private func reload() {
        guard isViewLoaded else { return }
        rebuildResolutionsIfNeeded()
        rebuildFilterSegments()
        threadList.arrangedSubviews.forEach {
            threadList.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        threadViews.removeAll(keepingCapacity: true)

        let visibleThreads = filteredThreads()
        orderedVisibleRootIDs = visibleThreads.map { $0.root.id }
        updateReviewProgress(visibleThreads)

        if visibleThreads.isEmpty {
            let empty = makeEmptyState()
            threadList.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: threadList.widthAnchor).isActive = true
            restorePendingFocus()
            return
        }

        let selectedRootID = selectedRootCommentID
        for thread in visibleThreads {
            let threadView = makeThreadView(thread, isActive: selectedRootID == thread.root.id)
            threadList.addArrangedSubview(threadView)
            threadView.widthAnchor.constraint(equalTo: threadList.widthAnchor).isActive = true
            threadViews[thread.root.id] = threadView
        }

        if let selectedRootID, let selectedView = threadViews[selectedRootID] {
            DispatchQueue.main.async { [weak selectedView] in
                guard let selectedView else { return }
                selectedView.scrollToVisible(selectedView.bounds)
            }
        }
        restorePendingFocus()
    }

    private func rebuildResolutionsIfNeeded() {
        guard !resolutionsAreCurrent else { return }
        let resolver = AnchorResolver()
        resolutions = Dictionary(uniqueKeysWithValues: comments.compactMap { comment in
            guard case .selection(let target) = comment.target else { return nil }
            return (
                comment.id,
                (try? resolver.resolve(target, in: source)) ?? AnchorResolution(state: .orphaned)
            )
        })
        resolutionsAreCurrent = true
    }

    private func rebuildFilterSegments() {
        let hasNew = !unreadRootIDs.isEmpty
        availableFilters = hasNew ? [.new, .open, .resolved, .all] : [.open, .resolved, .all]
        if presentationFilter == .new && !hasNew { presentationFilter = .open }

        filterControl.segmentCount = availableFilters.count
        for (index, filter) in availableFilters.enumerated() {
            filterControl.setLabel(filter.title, forSegment: index)
            filterControl.setToolTip("Show \(filter.title.lowercased()) comment threads", forSegment: index)
        }
        filterControl.selectedSegment = availableFilters.firstIndex(of: presentationFilter) ?? 0
    }

    private func filteredThreads() -> [CommentInspectorIndex.Thread] {
        inspectorIndex.roots.compactMap { inspectorIndex.threadsByRootID[$0.id] }
            .filter { thread in
                switch presentationFilter {
                case .new: return !thread.unreadIDs(in: unreadCommentIDs).isEmpty
                case .open: return thread.root.status != .resolved
                case .resolved: return thread.root.status == .resolved
                case .all: return true
                }
            }
            .sorted { rootOrder($0.root, $1.root) }
    }

    private func updateReviewProgress(_ visibleThreads: [CommentInspectorIndex.Thread]) {
        guard !visibleThreads.isEmpty else {
            reviewProgressDescription = ""
            countLabel.attributedStringValue = NSAttributedString(string: "")
            return
        }

        let suffix: String
        switch presentationFilter {
        case .new: suffix = " new"
        case .open: suffix = " open"
        case .resolved: suffix = " resolved"
        case .all: suffix = ""
        }
        if let selectedRootID = selectedRootCommentID,
           let selectedIndex = visibleThreads.firstIndex(where: { $0.root.id == selectedRootID }) {
            reviewProgressDescription = "\(selectedIndex + 1) of \(visibleThreads.count)\(suffix)"
        } else {
            reviewProgressDescription = "\(visibleThreads.count)\(suffix.isEmpty ? " total" : suffix)"
        }
        countLabel.attributedStringValue = MarginTheme.microLabel(reviewProgressDescription)
        countLabel.setAccessibilityValue(reviewProgressDescription)
    }

    private func ensureSelectedThreadIsPresentable() {
        guard let rootID = selectedRootCommentID,
              let thread = inspectorIndex.threadsByRootID[rootID] else { return }
        let isVisible: Bool
        switch presentationFilter {
        case .new: isVisible = !thread.unreadIDs(in: unreadCommentIDs).isEmpty
        case .open: isVisible = thread.root.status != .resolved
        case .resolved: isVisible = thread.root.status == .resolved
        case .all: isVisible = true
        }
        guard !isVisible else { return }
        presentationFilter = thread.root.status == .resolved ? .resolved : .open
    }

    private func rootOrder(_ lhs: MarginComment, _ rhs: MarginComment) -> Bool {
        let left = resolutions[lhs.id]?.range?.start ?? Int.max
        let right = resolutions[rhs.id]?.range?.start ?? Int.max
        if left != right { return left < right }
        if lhs.created != rhs.created { return lhs.created < rhs.created }
        return lhs.id < rhs.id
    }

    private func makeThreadView(
        _ thread: CommentInspectorIndex.Thread,
        isActive: Bool
    ) -> CommentThreadView {
        let root = thread.root
        let resolved = root.status == .resolved
        let expanded = expandedThreadIDs.contains(root.id)
        let container = CommentThreadView(active: isActive, resolved: resolved)
        container.identifier = NSUserInterfaceItemIdentifier(root.id)
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.button)
        let state = resolved ? "resolved" : "open"
        let contribution = root.reviewContributionKind.title.lowercased()
        let unread = thread.unreadIDs(in: unreadCommentIDs)
        let unreadPrefix = unread.isEmpty ? "" : "Unread, "
        let selectedSuffix = isActive ? ", selected" : ""
        container.setAccessibilityLabel("\(unreadPrefix)\(state) \(contribution) thread by \(root.creator.name)\(selectedSuffix)")
        container.setAccessibilityValue(root.body.value)
        container.setAccessibilityHelp("Press Return to select. Use Up and Down Arrow to move between threads.")

        container.onActivate = { [weak self] in self?.activateThread(root.id) }
        container.onMovePrevious = { [weak self] in self?.moveReviewSelection(by: -1) }
        container.onMoveNext = { [weak self] in self?.moveReviewSelection(by: 1) }
        container.onMoveFirst = { [weak self] in self?.moveReviewSelection(to: .first) }
        container.onMoveLast = { [weak self] in self?.moveReviewSelection(to: .last) }

        if let quote = rootQuote(root) {
            let quoteView = commentQuote(quote, compact: !isActive)
            container.addArrangedSubview(quoteView)
            quoteView.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        let rail = CommentConversationRailView(active: isActive, resolved: resolved)
        let rootContent = NSStackView()
        rootContent.orientation = .vertical
        rootContent.alignment = .leading
        rootContent.spacing = 6
        if let resolution = resolutions[root.id],
           resolution.state == .ambiguous || resolution.state == .orphaned {
            rootContent.addArrangedSubview(statusLabel(
                resolution.state == .ambiguous ? "Needs reattachment" : "Passage no longer found"
            ))
        }
        if root.reviewContributionKind != .comment {
            rootContent.addArrangedSubview(contributionKindLabel(root.reviewContributionKind))
        }
        rootContent.addArrangedSubview(commentHeader(root, unread: unread.contains(root.id)))
        let rootBody = commentBody(root, compact: !isActive, resolved: resolved && !isActive)
        rootContent.addArrangedSubview(rootBody)
        rootBody.widthAnchor.constraint(equalTo: rootContent.widthAnchor).isActive = true
        if let suggestion = root.reviewSuggestion {
            let comparison = suggestionComparison(suggestion)
            rootContent.addArrangedSubview(comparison)
            comparison.widthAnchor.constraint(equalTo: rootContent.widthAnchor).isActive = true
        }
        if let handoff = root.reviewHandoff {
            let summary = handoffSummary(handoff)
            rootContent.addArrangedSubview(summary)
            summary.widthAnchor.constraint(equalTo: rootContent.widthAnchor).isActive = true
        }

        if !isActive {
            let summary = threadSummary(thread, unreadCount: unread.count)
            if !summary.isEmpty {
                let summaryLabel = NSTextField(labelWithString: summary)
                summaryLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
                summaryLabel.textColor = .tertiaryLabelColor
                rootContent.addArrangedSubview(summaryLabel)
            }
        } else {
            rootContent.addArrangedSubview(rootActions(for: root))
        }
        rail.addRoot(rootContent)

        if isActive {
            appendActiveConversation(thread, to: rail, expanded: expanded)
        }
        container.addArrangedSubview(rail)
        rail.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private func appendActiveConversation(
        _ thread: CommentInspectorIndex.Thread,
        to rail: CommentConversationRailView,
        expanded: Bool
    ) {
        let resolved = thread.root.status == .resolved
        if resolved && !expanded {
            guard !thread.replies.isEmpty else { return }
            let title = thread.replies.count == 1 ? "Show reply" : "Show \(thread.replies.count) replies"
            rail.addDisclosure(disclosureButton(title, rootID: thread.root.id, expanded: false))
            return
        }

        let visibility = thread.visibility(
            isActive: true,
            isExpanded: expanded,
            selectedCommentID: selectedCommentID,
            unreadCommentIDs: unreadCommentIDs
        )
        var cursor = 0
        for index in visibility.visibleIndices {
            if cursor < index {
                addHiddenDisclosure(cursor..<index, rootID: thread.root.id, to: rail)
            }
            addReply(thread.replies[index], to: rail)
            cursor = index + 1
        }
        if cursor < thread.replies.count {
            addHiddenDisclosure(cursor..<thread.replies.count, rootID: thread.root.id, to: rail)
        }
        if visibility.canCollapse {
            rail.addDisclosure(disclosureButton("Show fewer", rootID: thread.root.id, expanded: true))
        }
    }

    private func addReply(
        _ reply: CommentInspectorIndex.Reply,
        to rail: CommentConversationRailView
    ) {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        if reply.needsLineageLabel {
            let lineage = NSTextField(labelWithString: "Replying to \(reply.parentAuthor)")
            lineage.font = .systemFont(ofSize: 10.5, weight: .medium)
            lineage.textColor = .tertiaryLabelColor
            content.addArrangedSubview(lineage)
        }

        content.addArrangedSubview(commentHeader(
            reply.comment,
            unread: unreadCommentIDs.contains(reply.comment.id)
        ))
        let body = commentBody(reply.comment, compact: false, resolved: false)
        content.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let actions = NSStackView()
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 3
        let primaryActions = NSStackView()
        primaryActions.orientation = .horizontal
        primaryActions.spacing = 8
        let replyButton = ClosureButton(title: "Reply") { [weak self] in
            self?.showComposer(quote: nil, parentID: reply.comment.id)
        }
        replyButton.controlSize = .mini
        replyButton.bezelStyle = .inline
        replyButton.setAccessibilityLabel("Reply to comment by \(reply.comment.creator.name)")
        primaryActions.addArrangedSubview(replyButton)
        actions.addArrangedSubview(primaryActions)
        if owns(reply.comment) {
            let ownerActions = NSStackView()
            ownerActions.orientation = .horizontal
            ownerActions.spacing = 8
            ownerActions.addArrangedSubview(editButton(for: reply.comment, controlSize: .mini))
            ownerActions.addArrangedSubview(deleteButton(
                for: reply.comment,
                rootID: inspectorIndex.rootID(containing: reply.comment.id) ?? reply.parentID,
                title: "Delete Reply",
                subtree: reply.hasReplies,
                controlSize: .mini
            ))
            actions.addArrangedSubview(ownerActions)
        }
        content.addArrangedSubview(actions)

        let selected = selectedCommentID == reply.comment.id
        let row = rail.addReply(content, depth: reply.visualDepth, selected: selected)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        let unreadPrefix = unreadCommentIDs.contains(reply.comment.id) ? "Unread " : ""
        let depthDetail = reply.needsLineageLabel
            ? ", level \(reply.depth), shown at indentation level 2, replying to \(reply.parentAuthor)"
            : ", level \(reply.depth)"
        row.setAccessibilityLabel("\(unreadPrefix)reply by \(reply.comment.creator.name)\(depthDetail)")
        row.setAccessibilityValue(reply.comment.body.value)
    }

    private func addHiddenDisclosure(
        _ range: Range<Int>,
        rootID: String,
        to rail: CommentConversationRailView
    ) {
        guard !range.isEmpty else { return }
        let title = range.count == 1 ? "Show hidden reply" : "Show \(range.count) hidden replies"
        rail.addDisclosure(disclosureButton(title, rootID: rootID, expanded: false))
    }

    private func disclosureButton(_ title: String, rootID: String, expanded: Bool) -> NSButton {
        let button = ClosureButton(title: title) { [weak self] in
            self?.setThread(rootID, expanded: !expanded)
        }
        button.controlSize = .small
        button.bezelStyle = .inline
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(expanded ? "Collapse this conversation." : "Expand this conversation.")
        return button
    }

    private func rootActions(for root: MarginComment) -> NSView {
        let actions = NSStackView()
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 3
        let primaryActions = NSStackView()
        primaryActions.orientation = .horizontal
        primaryActions.spacing = 10

        if root.reviewSuggestion?.status == .open,
           onAcceptSuggestion != nil || onRejectSuggestion != nil {
            let suggestionActions = NSStackView()
            suggestionActions.orientation = .horizontal
            suggestionActions.spacing = 10
            if onAcceptSuggestion != nil {
                let accept = ClosureButton(title: "Accept") { [weak self] in
                    self?.onAcceptSuggestion?(root.id)
                }
                accept.controlSize = .small
                accept.bezelStyle = .inline
                accept.setAccessibilityLabel("Accept suggestion by \(root.creator.name)")
                suggestionActions.addArrangedSubview(accept)
            }
            if onRejectSuggestion != nil {
                let reject = ClosureButton(title: "Reject") { [weak self] in
                    self?.onRejectSuggestion?(root.id)
                }
                reject.controlSize = .small
                reject.bezelStyle = .inline
                reject.contentTintColor = .secondaryLabelColor
                reject.setAccessibilityLabel("Reject suggestion by \(root.creator.name)")
                suggestionActions.addArrangedSubview(reject)
            }
            actions.addArrangedSubview(suggestionActions)
        }

        let reply = ClosureButton(title: "Reply") { [weak self] in
            self?.showComposer(quote: nil, parentID: root.id)
        }
        reply.controlSize = .small
        reply.bezelStyle = .inline
        reply.setAccessibilityLabel("Reply to comment by \(root.creator.name)")
        primaryActions.addArrangedSubview(reply)

        let resolved = root.status == .resolved
        let title = resolved ? "Reopen" : "Resolve"
        let stateButton = ClosureButton(title: title) { [weak self] in
            self?.changeState(of: root, resolved: !resolved)
        }
        stateButton.controlSize = .small
        stateButton.bezelStyle = .inline
        stateButton.setAccessibilityLabel("\(title) comment by \(root.creator.name)")
        primaryActions.addArrangedSubview(stateButton)
        actions.addArrangedSubview(primaryActions)
        if owns(root) {
            let ownerActions = NSStackView()
            ownerActions.orientation = .horizontal
            ownerActions.spacing = 10
            ownerActions.addArrangedSubview(editButton(for: root, controlSize: .small))
            ownerActions.addArrangedSubview(deleteButton(
                for: root,
                rootID: root.id,
                title: "Delete Thread",
                subtree: true,
                controlSize: .small
            ))
            actions.addArrangedSubview(ownerActions)
        }
        return actions
    }

    private func editButton(
        for comment: MarginComment,
        controlSize: NSControl.ControlSize
    ) -> NSButton {
        let button = ClosureButton(title: "Edit") { [weak self] in
            self?.showEditComposer(for: comment)
        }
        button.controlSize = controlSize
        button.bezelStyle = .inline
        button.setAccessibilityLabel("Edit comment by \(comment.creator.name)")
        return button
    }

    private func deleteButton(
        for comment: MarginComment,
        rootID: String,
        title: String,
        subtree: Bool,
        controlSize: NSControl.ControlSize
    ) -> NSButton {
        let button = ClosureButton(title: title) { [weak self] in
            self?.deleteComment(comment, rootID: rootID, subtree: subtree)
        }
        button.controlSize = controlSize
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(title)
        let help: String
        if title == "Delete Thread" {
            help = "Delete this comment and its complete reply tree."
        } else if subtree {
            help = "Delete this reply and its nested replies. The document host provides undo feedback."
        } else {
            help = "Delete this reply. The document host provides undo feedback."
        }
        button.setAccessibilityHelp(help)
        return button
    }

    private func owns(_ comment: MarginComment) -> Bool {
        guard let localActorID else { return false }
        return comment.creator.id == localActorID
    }

    private func threadSummary(
        _ thread: CommentInspectorIndex.Thread,
        unreadCount: Int
    ) -> String {
        var parts: [String] = []
        if !thread.replies.isEmpty {
            parts.append(thread.replies.count == 1 ? "1 reply" : "\(thread.replies.count) replies")
        }
        if unreadCount > 0 {
            parts.append(unreadCount == 1 ? "1 new" : "\(unreadCount) new")
        }
        return parts.joined(separator: " · ")
    }

    private func commentHeader(
        _ comment: MarginComment,
        unread: Bool
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        let symbol = NSImageView()
        let symbolName: String
        switch comment.creator.type {
        case .person: symbolName = "person.crop.circle"
        case .software: symbolName = "cpu"
        case .organization: symbolName = "building.2"
        }
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol.contentTintColor = .tertiaryLabelColor
        symbol.imageScaling = .scaleProportionallyDown
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.setAccessibilityElement(false)
        let author = NSTextField(labelWithString: comment.creator.name)
        author.font = .systemFont(ofSize: 11.75, weight: .semibold)
        let date = NSTextField(labelWithString: relativeDate(comment.created))
        date.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        date.textColor = .tertiaryLabelColor
        row.addArrangedSubview(symbol)
        row.addArrangedSubview(author)
        row.addArrangedSubview(date)
        if unread {
            let unreadLabel = NSTextField(labelWithString: "NEW")
            unreadLabel.attributedStringValue = MarginTheme.microLabel("NEW")
            unreadLabel.textColor = .controlAccentColor
            unreadLabel.setAccessibilityLabel("Unread")
            row.addArrangedSubview(unreadLabel)
        }
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 14),
            symbol.heightAnchor.constraint(equalToConstant: 14),
        ])
        return row
    }

    private func commentBody(
        _ comment: MarginComment,
        compact: Bool,
        resolved: Bool
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = CommentMarkdownRenderer.render(
            comment.body.value,
            foregroundColor: resolved ? .secondaryLabelColor : .labelColor
        )
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.maximumNumberOfLines = compact ? 3 : 0
        label.lineBreakMode = compact ? .byTruncatingTail : .byWordWrapping
        label.setAccessibilityLabel("\(comment.reviewContributionKind.title) by \(comment.creator.name)")
        label.setAccessibilityValue(comment.body.value)
        return label
    }

    private func commentQuote(_ quote: String, compact: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 6

        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "quote.opening", accessibilityDescription: nil)
        symbol.contentTintColor = .tertiaryLabelColor
        symbol.imageScaling = .scaleProportionallyDown
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.setAccessibilityElement(false)

        let label = NSTextField(wrappingLabelWithString: quote)
        let serif = MarginTheme.serifFont(ofSize: 12.25, weight: .regular)
        label.font = NSFontManager.shared.convert(serif, toHaveTrait: .italicFontMask)
        label.textColor = MarginTheme.secondaryInk
        label.maximumNumberOfLines = compact ? 1 : 3
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("Commented passage")
        label.setAccessibilityValue(quote)

        row.addArrangedSubview(symbol)
        row.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -20).isActive = true
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 13),
            symbol.heightAnchor.constraint(equalToConstant: 13),
        ])
        return row
    }

    private func rootQuote(_ comment: MarginComment) -> String? {
        guard case .selection(let target) = comment.target,
              let exact = target.quoteSelector?.exact else { return nil }
        let singleLine = exact.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 180 ? String(singleLine.prefix(177)) + "…" : singleLine
    }

    private func makeEmptyState() -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        symbol.contentTintColor = .tertiaryLabelColor
        symbol.imageScaling = .scaleProportionallyDown
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let titleText: String
        let detailText: String
        switch presentationFilter {
        case .new:
            titleText = "Nothing new"
            detailText = "New agent and collaborator comments will appear here."
        case .open:
            titleText = "No open threads"
            detailText = "Select a passage and press ⌘⌥M to begin."
        case .resolved:
            titleText = "No resolved threads"
            detailText = "Resolved conversations remain available here."
        case .all:
            titleText = "No review here"
            detailText = "Comments, questions, suggestions, and handoffs will appear here."
        }
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0

        let stack = NSStackView(views: [symbol, title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(11, after: symbol)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(titleText)
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 18),
            symbol.heightAnchor.constraint(equalToConstant: 18),
        ])
        return stack
    }

    private func statusLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .systemOrange
        label.setAccessibilityLabel(title)
        return label
    }

    private func contributionKindLabel(_ kind: ReviewContributionKind) -> NSTextField {
        let label = NSTextField(labelWithString: kind.title.uppercased())
        label.attributedStringValue = MarginTheme.microLabel(kind.title.uppercased())
        label.textColor = .secondaryLabelColor
        label.setAccessibilityLabel(kind.title)
        return label
    }

    private func suggestionComparison(_ suggestion: ReviewSuggestionPresentation) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 6
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.54).cgColor

        let expectedLine = suggestionLine(
            prefix: "−",
            text: suggestion.expected,
            color: .secondaryLabelColor
        )
        let replacementLine = suggestionLine(
            prefix: "+",
            text: suggestion.replacement,
            color: .systemGreen
        )
        stack.addArrangedSubview(expectedLine)
        stack.addArrangedSubview(replacementLine)
        NSLayoutConstraint.activate([
            expectedLine.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            replacementLine.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel("Suggested source replacement")
        stack.setAccessibilityValue("Replace \(suggestion.expected) with \(suggestion.replacement)")
        return stack
    }

    private func suggestionLine(prefix: String, text: String, color: NSColor) -> NSTextField {
        let flattened = text.replacingOccurrences(of: "\n", with: " ↩ ")
        let label = NSTextField(wrappingLabelWithString: "\(prefix) \(flattened)")
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        label.textColor = color
        label.maximumNumberOfLines = 5
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.identifier = NSUserInterfaceItemIdentifier(
            prefix == "−" ? "suggestion-expected" : "suggestion-replacement"
        )
        return label
    }

    private func handoffSummary(_ handoff: ReviewHandoffPresentation) -> NSTextField {
        var parts: [String] = []
        if !handoff.audience.isEmpty {
            parts.append("For \(handoff.audience.joined(separator: ", "))")
        }
        if !handoff.unresolvedIDs.isEmpty {
            let noun = handoff.unresolvedIDs.count == 1 ? "item" : "items"
            parts.append("\(handoff.unresolvedIDs.count) unresolved \(noun)")
        }
        if !handoff.touchedIDs.isEmpty {
            let noun = handoff.touchedIDs.count == 1 ? "change" : "changes"
            parts.append("\(handoff.touchedIDs.count) linked \(noun)")
        }
        let value = parts.isEmpty ? "Handoff context" : parts.joined(separator: "  ·  ")
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.identifier = NSUserInterfaceItemIdentifier("handoff-summary")
        label.setAccessibilityLabel("Handoff: \(value)")
        return label
    }

    private func relativeDate(_ raw: String) -> String {
        guard let date = Self.fractionalDateFormatter.date(from: raw)
                ?? Self.standardDateFormatter.date(from: raw)
        else { return raw }
        if abs(date.timeIntervalSinceNow) < 45 { return "now" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardDateFormatter = ISO8601DateFormatter()

    private enum ReviewBoundary {
        case first
        case last
    }

    private func activateThread(_ rootID: String) {
        selectedCommentID = rootID
        pendingFocusThreadID = rootID
        pendingFallbackFocusThreadID = nearestNeighbor(to: rootID)
        markThreadRead(rootID)
        onSelectComment?(rootID)
        reload()
    }

    private func moveReviewSelection(by offset: Int) {
        guard !orderedVisibleRootIDs.isEmpty else { return }
        let current = selectedRootCommentID.flatMap { orderedVisibleRootIDs.firstIndex(of: $0) }
        let proposed: Int
        if let current {
            proposed = min(max(current + offset, 0), orderedVisibleRootIDs.count - 1)
        } else {
            proposed = offset < 0 ? orderedVisibleRootIDs.count - 1 : 0
        }
        activateThread(orderedVisibleRootIDs[proposed])
    }

    private func moveReviewSelection(to boundary: ReviewBoundary) {
        guard let rootID = boundary == .first
            ? orderedVisibleRootIDs.first
            : orderedVisibleRootIDs.last else { return }
        activateThread(rootID)
    }

    private func setThread(_ rootID: String, expanded: Bool) {
        if expanded {
            expandedThreadIDs.insert(rootID)
        } else {
            expandedThreadIDs.remove(rootID)
        }
        pendingFocusThreadID = rootID
        pendingFallbackFocusThreadID = nearestNeighbor(to: rootID)
        reload()
    }

    private func changeState(of root: MarginComment, resolved: Bool) {
        pendingFocusThreadID = root.id
        pendingFallbackFocusThreadID = nearestNeighbor(to: root.id)
        if resolved { expandedThreadIDs.remove(root.id) }
        if resolved {
            onResolve?(root.id)
        } else {
            onReopen?(root.id)
        }
        // A host callback normally refreshes the model synchronously. Reload
        // as well so keyboard focus is restored when a standalone presenter
        // supplies no mutation callback.
        reload()
    }

    private func showEditComposer(for comment: MarginComment) {
        let composerRevision = commentRevision
        presentComposer(
            quote: nil,
            initialBody: comment.body.value,
            submitTitle: "Save",
            accessibilityLabel: "Save comment changes",
            accessibilityHelp: "Edit this Markdown comment. Press Command-Return to save or Escape to cancel."
        ) { [weak self] body in
            self?.onEditComment?(comment.id, body, composerRevision)
        }
    }

    private func deleteComment(
        _ comment: MarginComment,
        rootID: String,
        subtree: Bool
    ) {
        pendingFocusThreadID = subtree ? nil : rootID
        pendingFallbackFocusThreadID = nearestNeighbor(to: rootID)
        onDeleteComment?(comment.id, subtree)
        // Persistence and undo feedback are host responsibilities. A reload
        // still restores focus if the host mutates synchronously or declines.
        reload()
    }

    private func markThreadRead(_ rootID: String) {
        guard let thread = inspectorIndex.threadsByRootID[rootID] else { return }
        let removed = thread.unreadIDs(in: unreadCommentIDs)
        guard !removed.isEmpty else { return }
        unreadCommentIDs.subtract(removed)
        onMarkCommentsRead?(removed)
    }

    private func nearestNeighbor(to rootID: String) -> String? {
        guard let index = orderedVisibleRootIDs.firstIndex(of: rootID) else {
            return orderedVisibleRootIDs.first
        }
        if index + 1 < orderedVisibleRootIDs.count { return orderedVisibleRootIDs[index + 1] }
        if index > 0 { return orderedVisibleRootIDs[index - 1] }
        return nil
    }

    private func restorePendingFocus() {
        guard pendingFocusThreadID != nil || pendingFallbackFocusThreadID != nil else { return }
        let preferred = pendingFocusThreadID.flatMap { threadViews[$0] }
        let fallback = pendingFallbackFocusThreadID.flatMap { threadViews[$0] }
        let destination = preferred ?? fallback ?? orderedVisibleRootIDs.first.flatMap { threadViews[$0] }
        pendingFocusThreadID = nil
        pendingFallbackFocusThreadID = nil
        guard let destination else { return }
        DispatchQueue.main.async { [weak self, weak destination] in
            guard let self, let destination else { return }
            destination.scrollToVisible(destination.bounds)
            self.view.window?.makeFirstResponder(destination)
        }
    }

    private func showComposer(quote: String?, parentID: String?) {
        presentComposer(
            quote: quote,
            initialBody: "",
            submitTitle: "Comment",
            accessibilityLabel: "Submit comment",
            accessibilityHelp: "Write a Markdown comment. Press Command-Return to submit or Escape to cancel."
        ) { [weak self] body in
            guard let self else { return }
            if let parentID {
                self.onReply?(parentID, body)
            } else {
                self.onCreateComment?(body)
            }
        }
    }

    private func presentComposer(
        quote: String?,
        initialBody: String,
        submitTitle: String,
        accessibilityLabel: String,
        accessibilityHelp: String,
        onSubmit: @escaping (String) -> Void
    ) {
        composerHost.arrangedSubviews.forEach {
            composerHost.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let composer = CommentComposerView(
            quote: quote,
            initialBody: initialBody,
            submitTitle: submitTitle,
            submitAccessibilityLabel: accessibilityLabel,
            textAccessibilityHelp: accessibilityHelp
        )
        composer.onCancel = { [weak self] in self?.hideComposer() }
        composer.onSubmit = { [weak self] body in
            onSubmit(body)
            self?.hideComposer()
        }
        composerHost.addArrangedSubview(composer)
        composer.widthAnchor.constraint(equalTo: composerHost.widthAnchor).isActive = true
        view.window?.makeFirstResponder(composer.textView)
    }

    private func hideComposer() {
        let hadComposer = !composerHost.arrangedSubviews.isEmpty
        composerHost.arrangedSubviews.forEach {
            composerHost.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if hadComposer { onComposerDismiss?() }
    }

}

extension CommentsViewController: WorkspaceCommentsPresenting {
    func presentComments(for documentURL: URL?) {
        if documentURL == nil {
            display(comments: [], source: "")
        }
    }
}

private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(invoke)
        setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func invoke() { handler() }
}

private final class CommentComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command], (event.keyCode == 36 || event.keyCode == 76) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?(string)
    }
}

private final class CommentComposerView: NSView {
    let textView: CommentComposerTextView
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private weak var submitButton: NSButton?

    init(
        quote: String?,
        initialBody: String,
        submitTitle: String,
        submitAccessibilityLabel: String,
        textAccessibilityHelp: String
    ) {
        textView = CommentComposerTextView(frame: .zero)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 16, right: 0)
        addSubview(stack)

        if let quote, !quote.isEmpty {
            let normalized = quote.replacingOccurrences(of: "\n", with: " ")
            let ending = normalized.count > 140 ? "…”" : "”"
            let label = NSTextField(wrappingLabelWithString: "On “\(String(normalized.prefix(140)))\(ending)")
            let serif = MarginTheme.serifFont(ofSize: 11.5, weight: .regular)
            label.font = NSFontManager.shared.convert(serif, toHaveTrait: .italicFontMask)
            label.textColor = MarginTheme.secondaryInk
            label.maximumNumberOfLines = 2
            stack.addArrangedSubview(label)
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = MarginTheme.documentBackground
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = MarginTheme.documentBackground
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = MarginTheme.rule.cgColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = .systemFont(ofSize: 13)
        textView.backgroundColor = MarginTheme.documentBackground
        textView.textContainerInset = NSSize(width: 7, height: 7)
        textView.setAccessibilityLabel("Comment text")
        textView.setAccessibilityHelp(textAccessibilityHelp)
        textView.string = initialBody
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        scroll.documentView = textView
        stack.addArrangedSubview(scroll)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 7
        let submit = ClosureButton(title: submitTitle) { [weak self] in self?.submit() }
        submit.keyEquivalent = "\r"
        submit.isEnabled = !initialBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        submit.setAccessibilityLabel(submitAccessibilityLabel)
        let cancel = ClosureButton(title: "Cancel") { [weak self] in self?.onCancel?() }
        cancel.setAccessibilityLabel("Cancel comment")
        submit.bezelStyle = .rounded
        cancel.bezelStyle = .inline
        actions.addArrangedSubview(submit)
        actions.addArrangedSubview(cancel)
        stack.addArrangedSubview(actions)

        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onTextChange = { [weak self] value in
            self?.submitButton?.isEnabled = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        submitButton = submit

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 92),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func submit() {
        let body = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            NSSound.beep()
            return
        }
        onSubmit?(body)
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        MarginTheme.inspectorBackground.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
