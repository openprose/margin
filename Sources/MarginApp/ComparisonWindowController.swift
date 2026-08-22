import AppKit
import MarginCore
import UniformTypeIdentifiers

final class ComparisonWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onCommentRequest: ((ComparisonSelectionRequest) -> Void)?
    var onApplyRequest: ((ComparisonApplyDirection, [String]?, ComparisonPresentation) -> Void)?

    let comparisonViewController: ComparisonViewController
    let commentsViewController = ComparisonCommentsViewController()
    private let splitViewController = NSSplitViewController()
    private let comparisonItem: NSSplitViewItem
    private let commentsItem: NSSplitViewItem
    private let reviewStore: ComparisonReviewStore
    private let initialRequest: AppComparisonRequest
    private let externalRefreshRequestProvider: (() -> AppComparisonRequest?)?
    private var hasOrderedWindow = false
    private var isExplicitlyTabbed = false
    private var currentPresentation: ComparisonPresentation?
    private var currentReview: ComparisonReview?
    private var currentReviewURL: URL?
    private var isReviewInspectorSuppressed = false
    private var displaySaveGeneration = UUID()

    init(
        request: AppComparisonRequest,
        loader: any ComparisonLoading = CoreComparisonLoader(),
        reviewStore: ComparisonReviewStore = ComparisonReviewStore(),
        refreshRequestProvider: (() -> AppComparisonRequest?)? = nil
    ) {
        comparisonViewController = ComparisonViewController(request: request, loader: loader)
        comparisonItem = NSSplitViewItem(viewController: comparisonViewController)
        commentsItem = NSSplitViewItem(inspectorWithViewController: commentsViewController)
        self.reviewStore = reviewStore
        initialRequest = request
        externalRefreshRequestProvider = refreshRequestProvider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configure(window)
        configureSplitView()
        configureReviewCallbacks()
        window.contentViewController = splitViewController
        comparisonViewController.onPresentationChanged = { [weak self] presentation in
            self?.accept(presentation)
        }
        comparisonViewController.onCommentRequest = { [weak self] request in
            self?.beginComment(request)
        }
        comparisonViewController.onDisplayOptionsChanged = { [weak self] layout, whitespace in
            self?.persistDisplayOptions(layout: layout, showWhitespace: whitespace)
        }
        comparisonViewController.onApplyRequest = { [weak self] direction, blockIDs in
            guard let self, let presentation = self.currentPresentation else { return }
            self.onApplyRequest?(direction, blockIDs, presentation)
        }
        if request.supportsRefresh || refreshRequestProvider != nil {
            comparisonViewController.onRefreshRequest = { [weak self] in
                self?.nextRefreshRequest()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !hasOrderedWindow else { return }
        hasOrderedWindow = true
        ComparisonPerformanceSignal.record(.tabVisible)
        DispatchQueue.main.async { [weak self] in
            self?.comparisonViewController.beginLoadingIfNeeded()
        }
    }

    override func close() {
        comparisonViewController.cancelLoading()
        window?.animationBehavior = .none
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        comparisonViewController.cancelLoading()
        onClose?()
    }

    func prepareForTabAttachment() {
        isExplicitlyTabbed = true
    }

    func refreshTabPresentation() {
        guard isExplicitlyTabbed, let window else { return }
        window.tab.toolTip = window.subtitle.isEmpty
            ? "Comparison"
            : window.subtitle
    }

    var canNavigateChanges: Bool { comparisonViewController.canNavigateChanges }
    var isCommentsVisible: Bool { !commentsItem.isCollapsed }
    var canShowComments: Bool { currentPresentation != nil }
    var canRefresh: Bool { comparisonViewController.canRefresh }
    var canApplyChanges: Bool { comparisonViewController.canApplyChanges }
    var canApplySelectedChange: Bool { comparisonViewController.canApplySelectedChange }
    var isSideBySidePreferred: Bool { comparisonViewController.isSideBySidePreferred }
    var isWhitespaceShown: Bool { comparisonViewController.isWhitespaceShown }
    var canSwapSides: Bool { comparisonViewController.canSwapSides }
    var canChangeDisplayOptions: Bool { comparisonViewController.canChangeDisplayOptions }
    var canRefreshAfterSuccessfulApply: Bool {
        currentReviewURL == nil && comparisonViewController.canRefreshAfterSuccessfulApply
    }
    var currentReviewForTesting: ComparisonReview? { currentReview }
    var canNavigateComments: Bool { commentsViewController.canNavigateOpenThreads }
    var canResolveCurrentComment: Bool { commentsViewController.canResolveSelectedThread }

    @objc func previousChange(_ sender: Any?) {
        comparisonViewController.previousChange(sender)
    }

    @objc func nextChange(_ sender: Any?) {
        comparisonViewController.nextChange(sender)
    }

    @objc func toggleComments(_ sender: Any?) {
        guard canShowComments else { return }
        let willCollapse = !commentsItem.isCollapsed
        isReviewInspectorSuppressed = willCollapse
        commentsItem.animator().isCollapsed = willCollapse
    }

    @objc func focusComments(_ sender: Any?) {
        guard canShowComments else { return }
        isReviewInspectorSuppressed = false
        commentsItem.isCollapsed = false
        DispatchQueue.main.async { [weak self] in self?.commentsViewController.focusComments() }
    }

    @objc func focusComparison(_ sender: Any?) {
        comparisonViewController.focusComparison()
    }

    @objc func previousOpenComment(_ sender: Any?) {
        guard canShowComments else { return }
        isReviewInspectorSuppressed = false
        commentsItem.isCollapsed = false
        commentsViewController.navigateOpenThread(forward: false)
    }

    @objc func nextOpenComment(_ sender: Any?) {
        guard canShowComments else { return }
        isReviewInspectorSuppressed = false
        commentsItem.isCollapsed = false
        commentsViewController.navigateOpenThread(forward: true)
    }

    @objc func resolveCurrentComment(_ sender: Any?) {
        commentsViewController.resolveSelectedThread()
    }

    @objc func refreshComparison(_ sender: Any?) {
        comparisonViewController.refreshComparison(sender)
    }

    func refreshAfterSuccessfulApplyIfSafe() {
        guard currentReviewURL == nil else { return }
        comparisonViewController.refreshAfterSuccessfulApplyIfSafe()
    }

    @objc func swapSides(_ sender: Any?) {
        comparisonViewController.swapSides(sender)
    }

    @objc func toggleSideBySide(_ sender: Any?) {
        comparisonViewController.toggleSideBySide(sender)
    }

    @objc func toggleWhitespace(_ sender: Any?) {
        comparisonViewController.toggleWhitespace(sender)
    }

    func apply(
        visualDirection: ComparisonApplyDirection,
        selectedOnly: Bool
    ) {
        comparisonViewController.requestApply(
            visualDirection: visualDirection,
            selectedOnly: selectedOnly
        )
    }

    func beginCommentForTesting(_ request: ComparisonSelectionRequest) {
        beginComment(request)
    }

    func submitCommentForTesting(
        target: ComparisonCommentsViewController.ComposerTarget,
        body: String
    ) {
        submitComment(target: target, body: body)
    }

    func setThreadStatusForTesting(_ status: MarginCommentStatus, threadID: String) {
        setThreadStatus(threadID: threadID, status: status)
    }

    private func configure(_ window: NSWindow) {
        window.delegate = self
        window.title = "Comparison"
        window.subtitle = "Loading snapshots"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "ink.margin.workspace"
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 620, height: 460)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("MarginComparisonWindow")

        if let visible = NSScreen.main?.visibleFrame {
            let width = min(1180, max(620, visible.width - 96))
            let height = min(780, max(460, visible.height - 96))
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
        }
        window.setAccessibilityLabel("Margin comparison")
    }

    private func configureSplitView() {
        comparisonItem.minimumThickness = 320
        comparisonItem.holdingPriority = .defaultLow
        commentsItem.minimumThickness = 260
        commentsItem.maximumThickness = 420
        commentsItem.canCollapse = true
        splitViewController.addSplitViewItem(comparisonItem)
        splitViewController.addSplitViewItem(commentsItem)
        // NSSplitViewController may restore an inspector item's default
        // expansion while it is being attached. Set the quiet initial state
        // after insertion so an empty review never steals writing space.
        commentsItem.isCollapsed = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.setAccessibilityLabel("Comparison and review")
    }

    private func configureReviewCallbacks() {
        commentsViewController.onClose = { [weak self] in
            guard let self, self.isCommentsVisible else { return }
            self.isReviewInspectorSuppressed = true
            self.commentsItem.animator().isCollapsed = true
        }
        commentsViewController.onSubmit = { [weak self] target, body in
            self?.submitComment(target: target, body: body)
        }
        commentsViewController.onSetThreadStatus = { [weak self] threadID, status in
            self?.setThreadStatus(threadID: threadID, status: status)
        }
    }

    private func accept(_ presentation: ComparisonPresentation) {
        currentPresentation = presentation
        let loadedReview = presentation.review
        let loadedURL = presentation.reviewURL?.standardizedFileURL
        if let loadedReview, let loadedURL {
            let shouldKeepNewerInMemoryReview = currentReviewURL?.standardizedFileURL == loadedURL
                && (currentReview?.revision ?? -1) > loadedReview.revision
            if !shouldKeepNewerInMemoryReview {
                currentReview = loadedReview
                currentReviewURL = loadedURL
            }
        }
        commentsViewController.display(review: currentReview)
        if currentReview?.threads.isEmpty == false, !isReviewInspectorSuppressed {
            commentsItem.isCollapsed = false
        }
        updateTitle(left: presentation.pair.left.label, right: presentation.pair.right.label)
    }

    private func nextRefreshRequest() -> AppComparisonRequest? {
        // Once a review exists, its artifact is the collaboration identity.
        // Refresh must reload that explicit artifact (including external
        // comments/status changes), never silently reinterpret portable path
        // hints as authority to reread source files.
        if let currentReviewURL {
            return .review(currentReviewURL)
        }
        return externalRefreshRequestProvider?()
            ?? (initialRequest.supportsRefresh ? initialRequest : nil)
    }

    private func beginComment(_ request: ComparisonSelectionRequest) {
        guard currentPresentation != nil else { return }
        isReviewInspectorSuppressed = false
        commentsItem.isCollapsed = false
        commentsViewController.beginNewComment(request)
        onCommentRequest?(request)
    }

    private func submitComment(
        target: ComparisonCommentsViewController.ComposerTarget,
        body: String
    ) {
        guard let presentation = currentPresentation else { return }
        commentsViewController.setMutationInProgress(true)
        if let review = currentReview, let url = currentReviewURL {
            mutateExistingReview(review: review, url: url, dismissesComposer: true) { value in
                try Self.addComment(target: target, body: body, to: &value)
            }
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Comparison Review"
        panel.prompt = "Save Review"
        panel.nameFieldStringValue = Self.reviewFilename(for: presentation)
        panel.allowedContentTypes = [
            UTType(filenameExtension: "marginreview") ?? .json,
        ]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.commentsViewController.setMutationInProgress(false)
                return
            }
            self.createReview(at: url, presentation: presentation) { review in
                try Self.addComment(target: target, body: body, to: &review)
            }
        }
    }

    private func setThreadStatus(threadID: String, status: MarginCommentStatus) {
        guard let review = currentReview, let url = currentReviewURL else { return }
        commentsViewController.setMutationInProgress(true)
        mutateExistingReview(review: review, url: url, dismissesComposer: false) { value in
            _ = try value.setThreadStatus(
                status,
                threadID: threadID,
                modified: Self.timestamp(),
                actor: Self.localActor()
            )
        }
    }

    private func createReview(
        at url: URL,
        presentation: ComparisonPresentation,
        mutation: @escaping (inout ComparisonReview) throws -> Void
    ) {
        let store = reviewStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> ComparisonReview in
                let timestamp = Self.timestamp()
                var review = try ComparisonReview(
                    id: MarginID.annotation(),
                    created: timestamp,
                    modified: timestamp,
                    snapshots: presentation.pair
                )
                try mutation(&review)
                return try store.create(review, at: url.standardizedFileURL).review
            }
            DispatchQueue.main.async { self?.finishReviewMutation(result, url: url) }
        }
    }

    private func mutateExistingReview(
        review: ComparisonReview,
        url: URL,
        dismissesComposer: Bool,
        mutation: @escaping (inout ComparisonReview) throws -> Void
    ) {
        let store = reviewStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Self.updateReviewWithOneConflictRetry(
                    store: store,
                    url: url,
                    expectedRevision: review.revision,
                    mutation: mutation
                )
            }
            DispatchQueue.main.async {
                self?.finishReviewMutation(
                    result,
                    url: url,
                    dismissesComposer: dismissesComposer
                )
            }
        }
    }

    private func finishReviewMutation(
        _ result: Result<ComparisonReview, Error>,
        url: URL,
        dismissesComposer: Bool = true
    ) {
        switch result {
        case .success(let review):
            let installed = installReviewUnlessOlder(review, url: url)
            commentsViewController.finishMutation(
                review: installed,
                dismissesComposer: dismissesComposer
            )
            comparisonViewController.showOperationStatus("Comparison review saved.")
        case .failure(let error):
            commentsViewController.showMutationError(error.localizedDescription)
            comparisonViewController.showOperationStatus(
                error.localizedDescription,
                isError: true
            )
        }
    }

    private func persistDisplayOptions(
        layout: ComparisonPresentationLayout,
        showWhitespace: Bool
    ) {
        guard currentReview != nil, currentReviewURL != nil else { return }
        displaySaveGeneration = UUID()
        let generation = displaySaveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self,
                  self.displaySaveGeneration == generation,
                  let review = self.currentReview,
                  let url = self.currentReviewURL else { return }
            let store = self.reviewStore
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result {
                    try Self.updateReviewWithOneConflictRetry(
                        store: store,
                        url: url,
                        expectedRevision: review.revision
                    ) { value in
                        value.display.layout = layout == .sideBySide ? .sideBySide : .inline
                        value.display.showWhitespace = showWhitespace
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.displaySaveGeneration == generation else { return }
                    switch result {
                    case .success(let updated):
                        let installed = self.installReviewUnlessOlder(updated, url: url)
                        self.commentsViewController.display(review: installed)
                    case .failure(let error):
                        self.comparisonViewController.showOperationStatus(
                            "Could not save comparison display settings: \(error.localizedDescription)",
                            isError: true
                        )
                    }
                }
            }
        }
    }

    @discardableResult
    private func installReviewUnlessOlder(
        _ candidate: ComparisonReview,
        url: URL
    ) -> ComparisonReview {
        let standardizedURL = url.standardizedFileURL
        if currentReviewURL?.standardizedFileURL == standardizedURL,
           let currentReview,
           currentReview.revision > candidate.revision {
            return currentReview
        }
        currentReview = candidate
        currentReviewURL = standardizedURL
        return candidate
    }

    private static func updateReviewWithOneConflictRetry(
        store: ComparisonReviewStore,
        url: URL,
        expectedRevision: Int,
        mutation: (inout ComparisonReview) throws -> Void
    ) throws -> ComparisonReview {
        do {
            return try store.update(
                at: url,
                expectedRevision: expectedRevision,
                modified: timestamp(),
                mutation
            ).review
        } catch ComparisonError.revisionConflict {
            let latest = try store.load(at: url)
            return try store.update(
                at: url,
                expectedRevision: latest.revision,
                modified: timestamp(),
                mutation
            ).review
        }
    }

    private static func addComment(
        target: ComparisonCommentsViewController.ComposerTarget,
        body: String,
        to review: inout ComparisonReview
    ) throws {
        let timestamp = Self.timestamp()
        let actor = Self.localActor()
        switch target {
        case .selection(let selection):
            let snapshot: ComparisonSnapshot
            let reviewSide: ComparisonReviewSide
            switch selection.side {
            case .left:
                snapshot = review.snapshots.left
                reviewSide = .left
            case .right:
                snapshot = review.snapshots.right
                reviewSide = .right
            }
            guard snapshot.sha256 == selection.snapshotSHA256 else {
                throw ComparisonError.concurrentModification
            }
            let anchor = try ComparisonReviewAnchor(
                snapshot: snapshot,
                input: .range(
                    start: selection.unicodeScalarRange.start,
                    end: selection.unicodeScalarRange.end,
                    expectedExact: selection.quote
                )
            )
            let reviewTarget = try ComparisonReviewTarget(
                side: reviewSide,
                left: reviewSide == .left ? anchor : nil,
                right: reviewSide == .right ? anchor : nil,
                changedBlockID: selection.blockID
            )
            let id = MarginID.annotation()
            let comment = try ComparisonReviewComment(
                id: id,
                creator: actor,
                created: timestamp,
                modified: timestamp,
                body: MarginCommentBody(value: body, purpose: "commenting")
            )
            let thread = try ComparisonReviewThread(
                id: id,
                target: reviewTarget,
                statusModified: timestamp,
                statusModifiedBy: actor,
                comments: [comment]
            )
            _ = try review.addThread(thread)

        case .reply(let threadID, let parentID):
            let comment = try ComparisonReviewComment(
                id: MarginID.annotation(),
                parentID: parentID,
                creator: actor,
                created: timestamp,
                modified: timestamp,
                body: MarginCommentBody(value: body, purpose: "commenting")
            )
            _ = try review.addComment(comment, to: threadID)
        }
    }

    private static func reviewFilename(for presentation: ComparisonPresentation) -> String {
        let base = presentation.pair.right.label
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: ".markdown", with: "")
        return "\(base.isEmpty ? "comparison" : base).marginreview"
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func localActor() -> MarginActor {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? "Margin User" : name
        let slug = displayName.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
        return MarginActor(
            id: "urn:margin:person:\(slug)",
            type: .person,
            name: displayName
        )
    }

    private func updateTitle(left: String, right: String) {
        guard let window else { return }
        window.title = "\(left) and \(right)"
        window.subtitle = "Comparison"
        refreshTabPresentation()
    }
}
