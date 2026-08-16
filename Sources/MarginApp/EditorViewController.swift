import AppKit
import MarginCore

final class EditorViewController: NSViewController,
    WorkspaceDocumentPresenting,
    WorkspaceReaderModeToggling,
    WorkspaceDocumentSaving,
    WorkspaceContinuityProviding,
    NSMenuItemValidation,
    NSTextViewDelegate
{
    struct HeadingDestination {
        let id: String
        let title: String
        let level: Int
        let line: Int
        let range: NSRange
    }

    struct CommentDestination {
        let id: String
        let title: String
        let author: String
        let status: MarginCommentStatus
        let line: Int?
        let needsAttention: Bool

        var isResolved: Bool { status == .resolved }
        var sourceLine: Int? { line }
    }

    enum CommentsChangeOrigin: Equatable {
        case initialLoad
        case localMutation
        case externalRefresh
    }

    struct CommentsChange: Equatable {
        let origin: CommentsChangeOrigin
        let rootCommentIDs: [String]
        let openRootCommentIDs: [String]
        let openCount: Int
        let newOpenRootIDs: [String]
        let newAnnotationIDs: [String]
        let externallyChangedRootIDs: [String]
    }

    private struct ComposerSelection {
        var sourceRange: NSRange
    }

    private let textView: MarkdownTextView
    private let editorScrollView = NSScrollView()
    private var readerViewController: ReaderViewController?
    private let contentView = NSView()
    private let banner = NSStackView()
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    private var highlighter: MarkdownHighlighter?
    private weak var commentsViewController: CommentsViewController?
    private var documentURL: URL?
    private var lastSavedBodyData = Data()
    private var isApplyingDocument = false
    private var isDirty = false
    private var isReaderMode = false
    private var loadGeneration = UUID()
    private var saveWorkItem: DispatchWorkItem?
    private var fileWatcher: FileSystemWatcher?
    private var anchorRanges: [String: NSRange] = [:]
    private var anchorsDeletedByEdit = Set<String>()
    private var pendingCommentAnchor: CommentAnchorInput?
    private var selectedThreadID: String?
    private var currentComments: [MarginComment] = []
    private var currentCommentRevision = 0
    private var selectionAffordance: SelectionCommentAffordance?
    private var composerSelection: ComposerSelection?
    private var pendingContinuityState: EditorContinuityState?
    private var isDocumentLoaded = false

    private let codec = EmbeddedCommentCodec()
    private let resolver = AnchorResolver()
    private let store = AtomicDocumentStore()
    private let commentService = CommentService()

    var isReaderModeActive: Bool { isReaderMode }
    var onCommentAvailabilityChanged: ((Bool) -> Void)?
    var onCommentsChanged: ((CommentsChange) -> Void)?

    var rootCommentIDsInSourceOrder: [String] {
        orderedRootComments().map(\.id)
    }

    var openRootCommentIDsInSourceOrder: [String] {
        orderedRootComments().filter { $0.status != .resolved }.map(\.id)
    }

    var selectedCommentThreadID: String? { selectedThreadID }
    var canNavigateComments: Bool { !openRootCommentIDsInSourceOrder.isEmpty }

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textView = MarkdownTextView(frame: .zero, textContainer: textContainer)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = MarginSurfaceView(fillColor: MarginTheme.documentBackground)
        view = root

        configureBanner()
        configureEditor()
        configureStatus()

        banner.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(banner)
        root.addSubview(contentView)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
        ])

        clearDocument()
        DispatchQueue.main.async { [weak self] in
            self?.installHighlighterIfNeeded()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        selectionAffordance?.updatePosition()
    }

    func connectComments(_ controller: CommentsViewController) {
        commentsViewController = controller
        controller.setLocalActorID(currentActor.id)
        controller.onCreateComment = { [weak self] body in self?.createComment(body) }
        controller.onReply = { [weak self] parent, body in self?.reply(to: parent, body: body) }
        controller.onResolve = { [weak self] id in _ = self?.setResolved(true, id: id) }
        controller.onReopen = { [weak self] id in _ = self?.setResolved(false, id: id) }
        controller.onSelectComment = { [weak self] id in self?.selectThread(id) }
        controller.onEditComment = { [weak self] id, body, displayedRevision in
            self?.editComment(id: id, body: body, displayedRevision: displayedRevision)
        }
        controller.onDeleteComment = { [weak self] id, subtree in
            self?.deleteComment(id: id, subtree: subtree)
        }
        controller.onComposerDismiss = { [weak self] in
            guard let self else { return }
            self.restoreComposerSelectionAndFocus()
        }
        refreshCommentsPresentation()
    }

    func presentDocument(at url: URL) {
        _ = view
        guard prepareToClose() else { return }
        saveWorkItem?.cancel()
        fileWatcher?.stop()
        fileWatcher = nil

        documentURL = url.standardizedFileURL
        isDocumentLoaded = false
        pendingContinuityState = nil
        selectedThreadID = nil
        currentComments = []
        currentCommentRevision = 0
        selectionAffordance?.reset()
        composerSelection = nil
        loadGeneration = UUID()
        let generation = loadGeneration
        hideBanner()

        guard FileManager.default.fileExists(atPath: url.path) else {
            applyLoadedDocument(body: "", bodyData: Data(), comments: [], commentRevision: 0)
            textView.isEditable = true
            watchDocument(url)
            textView.window?.makeFirstResponder(textView)
            return
        }

        textView.isEditable = false
        statusLabel.stringValue = "Opening…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> (EmbeddedCommentDocument, [MarginComment]) in
                guard let self else { throw EditorError.cancelled }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let decoded = try self.codec.decode(data)
                let comments = decoded.envelope?.items ?? []
                return (decoded, comments)
            }
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                switch result {
                case .success(let value):
                    self.applyLoadedDocument(
                        body: value.0.body,
                        bodyData: value.0.bodyData,
                        comments: value.1,
                        commentRevision: value.0.envelope?.revision ?? 0
                    )
                    self.textView.isEditable = FileManager.default.isWritableFile(atPath: url.path)
                    self.watchDocument(url)
                    self.textView.window?.makeFirstResponder(
                        self.isReaderMode ? (self.readerViewController?.textView ?? self.textView) : self.textView
                    )
                case .failure(let error):
                    self.showBanner("Margin could not safely open this document: \(error.localizedDescription)")
                    self.textView.isEditable = false
                    self.statusLabel.stringValue = "Could not open"
                }
            }
        }
    }

    func clearDocument() {
        _ = view
        guard prepareToClose() else { return }
        saveWorkItem?.cancel()
        fileWatcher?.stop()
        fileWatcher = nil
        documentURL = nil
        isDocumentLoaded = false
        pendingContinuityState = nil
        selectedThreadID = nil
        currentComments = []
        currentCommentRevision = 0
        selectionAffordance?.reset()
        composerSelection = nil
        lastSavedBodyData = Data()
        anchorRanges.removeAll()
        anchorsDeletedByEdit.removeAll()
        isApplyingDocument = true
        textView.string = "Open a Markdown file or folder to begin."
        isApplyingDocument = false
        textView.isEditable = false
        textView.setAccessibilityHelp("Use File, Open to choose a Markdown document or directory")
        highlighter?.invalidate()
        readerViewController?.render(markdown: "", baseURL: nil)
        commentsViewController?.display(comments: [], source: "", commentRevision: 0)
        onCommentAvailabilityChanged?(false)
        setDirty(false)
        statusLabel.stringValue = ""
        hideBanner()
    }

    func toggleReaderMode() {
        _ = view
        guard documentURL != nil else { return }
        if isDirty { saveDocument(nil) }
        let sourceSelection = textView.selectedRange()
        isReaderMode.toggle()
        if isReaderMode {
            let reader = ensureReaderViewController()
            editorScrollView.isHidden = true
            reader.view.isHidden = false
            view.window?.makeFirstResponder(reader.textView)
            statusLabel.stringValue = "Preparing reader…"
            reader.renderAsync(
                markdown: textView.string,
                baseURL: documentURL?.deletingLastPathComponent(),
                preferredSourceSelection: sourceSelection
            ) { [weak self] applied in
                guard let self, applied, self.isReaderMode else { return }
                self.updateReaderHighlights()
                self.applyPendingContinuityStateIfPossible()
                self.view.window?.makeFirstResponder(reader.textView)
                self.statusLabel.stringValue = "Reader"
            }
        } else {
            selectionAffordance?.hide()
            let readerSelection = readerViewController?.selectedSourceRange
            readerViewController?.view.isHidden = true
            editorScrollView.isHidden = false
            if let readerSelection { textView.setSelectedRange(clamped(readerSelection, limit: textView.string.utf16.count)) }
            view.window?.makeFirstResponder(textView)
            updateStatus()
        }
    }

    @objc func toggleReaderMode(_ sender: Any?) {
        toggleReaderMode()
    }

    @objc func saveDocument(_ sender: Any?) {
        saveWorkItem?.cancel()
        guard let url = documentURL, textView.isEditable || isDirty else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                showBanner("Could not create \(url.lastPathComponent).")
                return
            }
        }

        let source = textView.string
        let bodyData = Data(source.utf8)
        if source.contains(EmbeddedCommentCodec.openingMarker) {
            showBanner("The literal sequence '\(EmbeddedCommentCodec.openingMarker.trimmingCharacters(in: .newlines))' is reserved for Margin metadata.")
            return
        }

        do {
            let saved: SavedDocument = try store.transaction(at: url) { [self] diskData in
                let disk = try codec.decode(diskData)
                if disk.bodyData != lastSavedBodyData && isDirty {
                    throw EditorError.externalConflict
                }

                var envelope = disk.envelope
                if var value = envelope {
                    let originalItems = value.items
                    for index in value.items.indices where value.items[index].motivation == "commenting" {
                        let id = value.items[index].id
                        guard let range = anchorRanges[id], !anchorsDeletedByEdit.contains(id), range.length > 0,
                              let target = try? selectionTarget(for: range, documentID: value.document.id, in: source) else {
                            continue
                        }
                        value.items[index].target = target
                    }
                    if bodyData != disk.bodyData || value.items != originalItems {
                        value.revision += 1
                        value.modified = Self.timestamp()
                    }
                    envelope = value
                }
                let output = try codec.encode(bodyData: bodyData, envelope: envelope)
                return AtomicDocumentMutation(
                    data: output,
                    result: SavedDocument(
                        bodyData: bodyData,
                        comments: envelope?.items ?? [],
                        commentRevision: envelope?.revision ?? 0
                    )
                )
            }
            lastSavedBodyData = saved.bodyData
            setDirty(false)
            applyComments(
                saved.comments,
                revision: saved.commentRevision,
                origin: .localMutation
            )
            updateStatus(savedMessage: true)
        } catch EditorError.externalConflict {
            showConflictBanner()
        } catch {
            showBanner("Could not save: \(error.localizedDescription)")
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveDocument(_:)) {
            return documentURL != nil
        }
        return true
    }

    /// Flushes the current edit buffer before a destructive navigation or close.
    /// A caller must veto the operation when this returns false, because Margin
    /// still owns unsaved text after a conflict or write failure.
    func prepareToClose() -> Bool {
        _ = view
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if isDirty { saveDocument(nil) }
        return !isDirty
    }

    func focusEditor() {
        _ = view
        view.window?.makeFirstResponder(
            isReaderMode ? (readerViewController?.textView ?? textView) : textView
        )
    }

    func captureContinuityState() -> EditorContinuityState {
        _ = view
        let selection = isReaderMode
            ? (readerViewController?.selectedSourceRange ?? textView.selectedRange())
            : textView.selectedRange()
        return EditorContinuityState(
            selectionLocation: selection.location == NSNotFound ? 0 : selection.location,
            selectionLength: selection.location == NSNotFound ? 0 : selection.length,
            scrollFraction: isReaderMode
                ? (readerViewController?.scrollFraction ?? 0)
                : sourceScrollFraction,
            selectedThreadID: selectedThreadID
        )
    }

    func restoreContinuityState(_ state: EditorContinuityState) {
        _ = view
        pendingContinuityState = state
        applyPendingContinuityStateIfPossible()
    }

    /// Explicit refresh seam for hosts that receive their own metadata-change
    /// signal. The file watcher calls the same path automatically.
    func refreshCommentsFromDisk() {
        refreshFromDisk(metadataOnly: true, origin: .externalRefresh)
    }

    @objc func selectPreviousOpenComment(_ sender: Any?) {
        moveOpenCommentSelection(by: -1)
    }

    @objc func selectNextOpenComment(_ sender: Any?) {
        moveOpenCommentSelection(by: 1)
    }

    @objc func resolveSelectedComment(_ sender: Any?) {
        let openIDs = openRootCommentIDsInSourceOrder
        guard let selectedThreadID,
              let selectedIndex = openIDs.firstIndex(of: selectedThreadID) else { return }
        let nextID = openIDs.count > 1
            ? openIDs[(selectedIndex + 1) % openIDs.count]
            : nil
        guard setResolved(true, id: selectedThreadID) else { return }
        if let nextID, openRootCommentIDsInSourceOrder.contains(nextID) {
            selectThread(nextID)
        } else {
            self.selectedThreadID = nil
            commentsViewController?.selectComment(nil)
            updateCommentHighlights()
            focusEditor()
        }
    }

    func headingDestinations() -> [HeadingDestination] {
        let source = textView.string
        let outline = MarkdownOutline(markdown: source)
        return outline.headings.compactMap { heading in
            guard let range = sourceRange(forLine: heading.line, in: source) else { return nil }
            return HeadingDestination(
                id: heading.id,
                title: heading.title,
                level: heading.level,
                line: heading.line,
                range: range
            )
        }
    }

    /// Builds the on-demand palette model from already-loaded comments and
    /// anchors. No extra document indexing is performed during launch.
    func commentDestinations() -> [CommentDestination] {
        orderedRootComments().map { comment in
            let range = anchorRanges[comment.id]
            let title = range.flatMap { commentQuote(in: $0) }
                ?? conciseCommentText(comment.body.value)
                ?? "Comment"
            let isSelectionTarget: Bool
            if case .selection = comment.target {
                isSelectionTarget = true
            } else {
                isSelectionTarget = false
            }
            return CommentDestination(
                id: comment.id,
                title: title,
                author: comment.creator.name,
                status: comment.status == .resolved ? .resolved : .open,
                line: range.map { sourceLine(atUTF16Location: $0.location) },
                needsAttention: isSelectionTarget && range == nil
            )
        }
    }

    func revealComment(id: String) {
        guard currentComments.contains(where: {
            $0.motivation == "commenting" && $0.id == id
        }) else { return }
        selectThread(id)
    }

    func revealHeading(_ destination: HeadingDestination) {
        _ = view
        if isReaderMode {
            readerViewController?.selectSourceRange(destination.range)
            view.window?.makeFirstResponder(readerViewController?.textView)
        } else {
            textView.setSelectedRange(destination.range)
            textView.scrollRangeToVisible(destination.range)
            view.window?.makeFirstResponder(textView)
            updateStatus()
        }
    }

    @objc func beginComment(_ sender: Any?) {
        guard documentURL != nil else { return }
        let selected: NSRange
        if isReaderMode {
            selected = readerViewController?.selectedSourceRange ?? NSRange(location: 0, length: 0)
        } else {
            selected = textView.selectedRange()
        }

        composerSelection = ComposerSelection(
            sourceRange: clamped(selected, limit: textView.string.utf16.count)
        )
        selectionAffordance?.hide()

        let anchorRange = selected.length > 0 ? selected : currentParagraphRange(at: selected.location)
        if anchorRange.length > 0,
           let anchor = try? anchorInput(for: anchorRange, in: textView.string) {
            pendingCommentAnchor = anchor
        } else {
            pendingCommentAnchor = .document
        }

        if let workspace = view.window?.windowController as? WorkspaceWindowController,
           !workspace.isCommentsVisible {
            workspace.toggleComments(nil)
        }
        let quote = anchorRange.length > 0
            ? (textView.string as NSString).substring(with: clamped(anchorRange, limit: textView.string.utf16.count))
            : ""
        commentsViewController?.beginNewComment(quotedText: quote)
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingDocument else { return }
        setDirty(true)
        updateCommentHighlights()
        scheduleSave()
        updateStatus()
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard !isApplyingDocument else { return true }
        migrateAnchors(through: affectedCharRange, replacementUTF16Length: replacementString?.utf16.count ?? 0)
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingDocument, !isReaderMode else { return }
        handleSelectionChange(in: textView)
        let location = textView.selectedRange().location
        let next = anchorRanges
            .filter { !anchorsDeletedByEdit.contains($0.key) && NSLocationInRange(location, $0.value) }
            .sorted { $0.value.length < $1.value.length }
            .first?.key
        if next != selectedThreadID {
            selectedThreadID = next
            commentsViewController?.selectComment(next, markingRead: next != nil)
            updateCommentHighlights()
        }
        updateStatus()
    }

    private func configureBanner() {
        banner.orientation = .horizontal
        banner.alignment = .centerY
        banner.spacing = 10
        banner.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.11).cgColor
        bannerLabel.font = .systemFont(ofSize: 12)
        bannerLabel.textColor = .labelColor
        bannerLabel.maximumNumberOfLines = 2
        banner.addArrangedSubview(bannerLabel)
        banner.isHidden = true
        banner.setAccessibilityRole(.group)
        banner.setAccessibilityLabel("Document warning")
    }

    private func configureEditor() {
        textView.delegate = self
        textView.onCommentOnSelection = { [weak self, weak textView] range in
            guard let self, let textView else { return }
            textView.setSelectedRange(range)
            self.beginComment(textView)
        }
        textView.onCommentHighlightClick = { [weak self] location in
            self?.activateSourceCommentHighlight(at: location) ?? false
        }
        MarkdownHighlighter.prepare(textView)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        editorScrollView.translatesAutoresizingMaskIntoConstraints = false
        editorScrollView.documentView = textView
        editorScrollView.hasVerticalScroller = true
        editorScrollView.autohidesScrollers = true
        editorScrollView.borderType = .noBorder
        editorScrollView.drawsBackground = true
        editorScrollView.backgroundColor = MarginTheme.documentBackground
        contentView.addSubview(editorScrollView)
        NSLayoutConstraint.activate([
            editorScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            editorScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            editorScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            editorScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func ensureReaderViewController() -> ReaderViewController {
        if let readerViewController { return readerViewController }
        let controller = ReaderViewController()
        addChild(controller)
        let readerView = controller.view
        readerView.translatesAutoresizingMaskIntoConstraints = false
        readerView.isHidden = true
        contentView.addSubview(readerView)
        NSLayoutConstraint.activate([
            readerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            readerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        controller.onSelectionChanged = { [weak self] textView in
            self?.handleSelectionChange(in: textView)
        }
        controller.onCommentOnSelection = { [weak self] in
            guard let self else { return }
            self.beginComment(self.readerViewController?.textView)
        }
        controller.onSelectComment = { [weak self] id in
            self?.selectThread(id)
        }
        readerViewController = controller
        return controller
    }

    private func installHighlighterIfNeeded() {
        guard highlighter == nil else { return }
        highlighter = MarkdownHighlighter(textView: textView)
    }

    private func configureStatus() {
        statusLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setAccessibilityLabel("Document status")
    }

    private func applyLoadedDocument(
        body: String,
        bodyData: Data,
        comments: [MarginComment],
        commentRevision: Int,
        commentsOrigin: CommentsChangeOrigin = .initialLoad
    ) {
        isApplyingDocument = true
        textView.string = body
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        isApplyingDocument = false
        isDocumentLoaded = true
        let name = documentURL?.lastPathComponent ?? "Markdown document"
        textView.setAccessibilityHelp("Editing \(name) as literal Markdown. Formatting marks remain visible.")
        lastSavedBodyData = bodyData
        setDirty(false)
        installHighlighterIfNeeded()
        highlighter?.invalidate()
        applyComments(comments, revision: commentRevision, origin: commentsOrigin)
        if isReaderMode {
            statusLabel.stringValue = "Preparing reader…"
            ensureReaderViewController().renderAsync(
                markdown: body,
                baseURL: documentURL?.deletingLastPathComponent()
            ) { [weak self] applied in
                guard let self, applied, self.isReaderMode else { return }
                self.updateReaderHighlights()
                self.applyPendingContinuityStateIfPossible()
                self.statusLabel.stringValue = "Reader"
            }
        } else {
            applyPendingContinuityStateIfPossible()
        }
        updateStatus()
        hideBanner()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveDocument(nil) }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(550), execute: item)
    }

    private func setDirty(_ value: Bool) {
        isDirty = value
        view.window?.isDocumentEdited = value
    }

    private func updateStatus(savedMessage: Bool = false) {
        if isReaderMode { return }
        guard documentURL != nil else {
            statusLabel.stringValue = ""
            return
        }
        let selection = textView.selectedRange()
        let nsText = textView.string as NSString
        let location = min(selection.location, nsText.length)
        let prefix = nsText.substring(to: location)
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let lineStart = (prefix as NSString).range(of: "\n", options: .backwards).location
        let column = lineStart == NSNotFound ? location + 1 : location - lineStart
        let state = savedMessage ? "Saved" : (isDirty ? "Edited" : "")
        let coordinate = "Ln \(line)  ·  Col \(column)"
        statusLabel.stringValue = state.isEmpty ? coordinate : "\(coordinate)  ·  \(state)"
        if savedMessage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.updateStatus() }
        }
    }

    private func rebuildAnchors(from comments: [MarginComment]) {
        anchorRanges.removeAll()
        anchorsDeletedByEdit.removeAll()
        for comment in comments where comment.motivation == "commenting" {
            guard case .selection(let target) = comment.target,
                  let resolution = try? resolver.resolve(target, in: textView.string),
                  let scalarRange = resolution.range,
                  let range = sourceRange(for: scalarRange, in: textView.string) else { continue }
            anchorRanges[comment.id] = range
        }
        updateCommentHighlights()
    }

    private func applyComments(
        _ comments: [MarginComment],
        revision: Int,
        origin: CommentsChangeOrigin
    ) {
        let priorOpenIDs = Set(openRootCommentIDsInSourceOrder)
        let priorAnnotationIDs = Set(currentComments.map(\.id))
        currentComments = comments
        currentCommentRevision = revision
        rebuildAnchors(from: comments)
        refreshCommentsPresentation(comments: comments)

        let rootIDs = rootCommentIDsInSourceOrder
        let openIDs = openRootCommentIDsInSourceOrder
        let isExternal = origin == .externalRefresh
        let newOpenIDs = isExternal
            ? openIDs.filter { !priorOpenIDs.contains($0) }
            : []
        let newAnnotationIDs = isExternal
            ? comments.map(\.id).filter { !priorAnnotationIDs.contains($0) }
            : []
        let changedRootSet = Set(
            newAnnotationIDs.compactMap { rootID(containing: $0, in: comments) }
        )
        let externallyChangedRootIDs = rootIDs.filter { changedRootSet.contains($0) }
        onCommentsChanged?(
            CommentsChange(
                origin: origin,
                rootCommentIDs: rootIDs,
                openRootCommentIDs: openIDs,
                openCount: openIDs.count,
                newOpenRootIDs: newOpenIDs,
                newAnnotationIDs: newAnnotationIDs,
                externallyChangedRootIDs: externallyChangedRootIDs
            )
        )
    }

    private func orderedRootComments() -> [MarginComment] {
        currentComments
            .filter { $0.motivation == "commenting" }
            .sorted { lhs, rhs in
                let leftLocation = anchorRanges[lhs.id]?.location ?? Int.max
                let rightLocation = anchorRanges[rhs.id]?.location ?? Int.max
                if leftLocation != rightLocation { return leftLocation < rightLocation }
                if lhs.created != rhs.created { return lhs.created < rhs.created }
                return lhs.id < rhs.id
            }
    }

    private func rootID(
        containing commentID: String,
        in comments: [MarginComment]
    ) -> String? {
        let index = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0) })
        var currentID = commentID
        var visited = Set<String>()
        while visited.insert(currentID).inserted, let comment = index[currentID] {
            if comment.motivation == "commenting" { return comment.id }
            guard case .resource(let parentID) = comment.target else { return nil }
            currentID = parentID
        }
        return nil
    }

    private func migrateAnchors(through edit: NSRange, replacementUTF16Length: Int) {
        let oldEnd = NSMaxRange(edit)
        let delta = replacementUTF16Length - edit.length
        for (id, anchor) in Array(anchorRanges) {
            let anchorEnd = NSMaxRange(anchor)
            let migrated: NSRange
            if edit.length == 0 {
                if edit.location <= anchor.location {
                    migrated = NSRange(location: anchor.location + replacementUTF16Length, length: anchor.length)
                } else if edit.location < anchorEnd {
                    migrated = NSRange(location: anchor.location, length: anchor.length + replacementUTF16Length)
                } else {
                    migrated = anchor
                }
            } else if oldEnd <= anchor.location {
                migrated = NSRange(location: max(0, anchor.location + delta), length: anchor.length)
            } else if edit.location >= anchorEnd {
                migrated = anchor
            } else {
                let overlapStart = max(edit.location, anchor.location)
                let overlapEnd = min(oldEnd, anchorEnd)
                let removed = max(0, overlapEnd - overlapStart)
                let startsInside = edit.location >= anchor.location
                let newStart = startsInside ? anchor.location : edit.location
                let newLength = max(0, anchor.length - removed + replacementUTF16Length)
                migrated = NSRange(location: max(0, newStart), length: newLength)
            }
            if migrated.length == 0 {
                anchorsDeletedByEdit.insert(id)
                anchorRanges.removeValue(forKey: id)
            } else {
                anchorRanges[id] = migrated
            }
        }
    }

    private func updateCommentHighlights() {
        guard let layout = textView.layoutManager else { return }
        let entire = NSRange(location: 0, length: textView.string.utf16.count)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: entire)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: entire)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: entire)
        for (id, rawRange) in anchorRanges where !anchorsDeletedByEdit.contains(id) {
            let range = clamped(rawRange, limit: entire.length)
            guard range.length > 0 else { continue }
            let active = id == selectedThreadID
            let resolved = currentComments.first(where: { $0.id == id })?.status == .resolved
            let baseColor = resolved ? NSColor.tertiaryLabelColor : NSColor.controlAccentColor
            let color = baseColor.withAlphaComponent(active ? 0.15 : 0.075)
            layout.addTemporaryAttributes([
                .backgroundColor: color,
                .underlineColor: baseColor.withAlphaComponent(active ? 0.90 : 0.48),
                .underlineStyle: active ? NSUnderlineStyle.thick.rawValue : NSUnderlineStyle.single.rawValue,
            ], forCharacterRange: range)
        }
        updateReaderHighlights()
    }

    private func updateReaderHighlights() {
        guard isReaderMode, let readerViewController else { return }
        let values = anchorRanges.compactMap { id, range -> ReaderViewController.CommentHighlight? in
            guard !anchorsDeletedByEdit.contains(id) else { return nil }
            let comment = currentComments.first(where: { $0.id == id })
            let state: ReaderViewController.CommentHighlight.State
            if id == selectedThreadID {
                state = .active
            } else if comment?.status == .resolved {
                state = .resolved
            } else {
                state = .normal
            }
            return .init(
                id: id,
                sourceRange: range,
                state: state,
                summary: commentSummary(comment)
            )
        }
        readerViewController.setCommentHighlights(values)
    }

    private func createComment(_ body: String) {
        guard let url = documentURL, let anchor = pendingCommentAnchor else { return }
        guard prepareToClose() else { return }
        do {
            let receipt = try commentService.add(
                at: url,
                message: body,
                creator: currentActor,
                anchor: anchor
            )
            selectedThreadID = receipt.rootID
            pendingCommentAnchor = nil
            refreshFromDisk(metadataOnly: true, origin: .localMutation)
        } catch {
            showBanner("Could not add comment: \(error.localizedDescription)")
        }
    }

    private func reply(to parentID: String, body: String) {
        guard let url = documentURL else { return }
        guard prepareToClose() else { return }
        do {
            let receipt = try commentService.reply(
                at: url,
                parentID: parentID,
                message: body,
                creator: currentActor
            )
            selectedThreadID = receipt.rootID
            refreshFromDisk(metadataOnly: true, origin: .localMutation)
        } catch {
            showBanner("Could not reply: \(error.localizedDescription)")
        }
    }

    private func editComment(id: String, body: String, displayedRevision: Int) {
        guard let url = documentURL else { return }
        guard prepareToClose() else { return }
        do {
            let receipt = try commentService.edit(
                at: url,
                id: id,
                message: body,
                editor: currentActor,
                preconditions: CommentMutationPreconditions(revision: displayedRevision)
            )
            selectedThreadID = receipt.rootID
            refreshFromDisk(metadataOnly: true, origin: .localMutation)
            guard receipt.changed else { return }
            showBanner("Comment updated.", actions: [
                ("Undo", { [weak self] in self?.undoCommentEdit(receipt.undo) }),
            ])
        } catch {
            showBanner("Could not edit comment: \(error.localizedDescription)")
        }
    }

    private func undoCommentEdit(_ undo: CommentEditUndo) {
        guard let url = documentURL else { return }
        guard prepareToClose() else { return }
        do {
            let receipt = try commentService.edit(
                at: url,
                id: undo.id,
                message: undo.message,
                editor: currentActor,
                preconditions: CommentMutationPreconditions(revision: undo.ifRevision)
            )
            selectedThreadID = receipt.rootID
            refreshFromDisk(metadataOnly: true, origin: .localMutation)
            showBanner("Comment edit undone.")
        } catch {
            showBanner("Could not undo the edit because the thread changed: \(error.localizedDescription)")
        }
    }

    private func deleteComment(id: String, subtree: Bool) {
        guard let url = documentURL else { return }
        guard prepareToClose() else { return }
        let displayedRevision = currentCommentRevision
        do {
            let receipt = try commentService.delete(
                at: url,
                id: id,
                subtree: subtree,
                preconditions: CommentMutationPreconditions(revision: displayedRevision)
            )
            selectedThreadID = id == receipt.rootID ? nil : receipt.rootID
            refreshFromDisk(metadataOnly: true, origin: .localMutation)
            let noun = receipt.deletedCount == 1 ? "Comment" : "Thread"
            showBanner("\(noun) deleted.", actions: [
                ("Undo", { [weak self] in
                    self?.undoCommentDeletion(receipt.undo, rootID: receipt.rootID)
                }),
            ])
        } catch {
            showBanner("Could not delete comment: \(error.localizedDescription)")
        }
    }

    private func undoCommentDeletion(_ undo: CommentDeleteUndo, rootID: String) {
        guard let url = documentURL else { return }
        guard prepareToClose() else { return }
        do {
            _ = try commentService.restoreDeletion(at: url, undo: undo)
            selectedThreadID = rootID
            refreshFromDisk(metadataOnly: true, origin: .localMutation)
            showBanner("Deleted comment restored.")
        } catch {
            showBanner("Could not undo the deletion because the document changed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func setResolved(_ resolved: Bool, id: String) -> Bool {
        guard let url = documentURL else { return false }
        guard prepareToClose() else { return false }
        do {
            if resolved {
                _ = try commentService.resolve(at: url, id: id, actor: currentActor)
            } else {
                _ = try commentService.reopen(at: url, id: id, actor: currentActor)
            }
            refreshFromDisk(metadataOnly: true, origin: .localMutation)
            return true
        } catch {
            showBanner("Could not update thread: \(error.localizedDescription)")
            return false
        }
    }

    private func selectThread(_ id: String) {
        selectedThreadID = id
        selectionAffordance?.hide()
        if let workspace = view.window?.windowController as? WorkspaceWindowController,
           !workspace.isCommentsVisible {
            workspace.toggleComments(nil)
        }
        commentsViewController?.selectComment(id, markingRead: true)
        guard let range = anchorRanges[id] else {
            updateCommentHighlights()
            return
        }
        if isReaderMode {
            readerViewController?.selectSourceRange(range)
            view.window?.makeFirstResponder(readerViewController?.textView)
        } else {
            isApplyingDocument = true
            textView.setSelectedRange(range)
            isApplyingDocument = false
            textView.scrollRangeToVisible(range)
            view.window?.makeFirstResponder(textView)
        }
        updateCommentHighlights()
    }

    private func moveOpenCommentSelection(by offset: Int) {
        let ids = openRootCommentIDsInSourceOrder
        guard !ids.isEmpty else { return }
        let nextIndex: Int
        if let selectedThreadID,
           let currentIndex = ids.firstIndex(of: selectedThreadID) {
            nextIndex = (currentIndex + offset + ids.count) % ids.count
        } else {
            nextIndex = offset < 0 ? ids.count - 1 : 0
        }
        selectThread(ids[nextIndex])
    }

    @discardableResult
    private func activateSourceCommentHighlight(at location: Int) -> Bool {
        let ids = anchorRanges
            .filter {
                !anchorsDeletedByEdit.contains($0.key)
                    && NSLocationInRange(location, $0.value)
            }
            .sorted { lhs, rhs in
                if lhs.value.length != rhs.value.length {
                    return lhs.value.length < rhs.value.length
                }
                if lhs.value.location != rhs.value.location {
                    return lhs.value.location < rhs.value.location
                }
                return lhs.key < rhs.key
            }
            .map(\.key)
        guard !ids.isEmpty else { return false }
        let nextID: String
        if let selectedThreadID,
           let currentIndex = ids.firstIndex(of: selectedThreadID),
           ids.count > 1 {
            nextID = ids[(currentIndex + 1) % ids.count]
        } else {
            nextID = ids[0]
        }
        selectThread(nextID)
        return true
    }

    private func handleSelectionChange(in textView: NSTextView) {
        let selection = textView.selectedRange()
        guard documentURL != nil,
              selection.location != NSNotFound,
              selection.length > 0 else {
            selectionAffordance?.hide()
            return
        }
        if selectionAffordance == nil {
            selectionAffordance = SelectionCommentAffordance(
                hostView: contentView
            ) { [weak self] in
                self?.beginComment(nil)
            }
        }
        selectionAffordance?.selectionDidChange(in: textView)
    }

    private func restoreComposerSelectionAndFocus() {
        if let composerSelection {
            let range = clamped(
                composerSelection.sourceRange,
                limit: textView.string.utf16.count
            )
            if isReaderMode {
                readerViewController?.selectSourceRange(range, scrollToVisible: true)
            } else {
                isApplyingDocument = true
                textView.setSelectedRange(range)
                isApplyingDocument = false
                textView.scrollRangeToVisible(range)
            }
        }
        composerSelection = nil
        focusEditor()
    }

    private func commentSummary(_ comment: MarginComment?) -> String {
        guard let comment else { return "Comment thread" }
        let body = comment.body.value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = body.count > 96
            ? String(body.prefix(93)) + "…"
            : body
        let state = comment.status == .resolved ? "Resolved comment" : "Open comment"
        return excerpt.isEmpty
            ? "\(state) by \(comment.creator.name)"
            : "\(state) by \(comment.creator.name): \(excerpt)"
    }

    private func commentQuote(in range: NSRange) -> String? {
        let safeRange = clamped(range, limit: textView.string.utf16.count)
        guard safeRange.length > 0 else { return nil }
        let value = (textView.string as NSString)
            .substring(with: safeRange)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let excerpt = value.count > 72 ? String(value.prefix(69)) + "…" : value
        return "“\(excerpt)”"
    }

    private func conciseCommentText(_ value: String) -> String? {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return nil }
        return flattened.count > 72
            ? String(flattened.prefix(69)) + "…"
            : flattened
    }

    private func sourceLine(atUTF16Location location: Int) -> Int {
        let text = textView.string as NSString
        let safeLocation = min(max(location, 0), text.length)
        let prefix = text.substring(to: safeLocation)
        return prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private var sourceScrollFraction: Double {
        let clip = editorScrollView.contentView
        let documentHeight = editorScrollView.documentView?.bounds.height ?? 0
        let maximum = max(documentHeight - clip.bounds.height, 0)
        guard maximum > 0 else { return 0 }
        return Double(min(max(clip.bounds.minY / maximum, 0), 1))
    }

    private func restoreSourceScrollFraction(_ fraction: Double) {
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        let clip = editorScrollView.contentView
        let documentHeight = editorScrollView.documentView?.bounds.height ?? 0
        let maximum = max(documentHeight - clip.bounds.height, 0)
        clip.scroll(
            to: NSPoint(
                x: clip.bounds.minX,
                y: maximum * CGFloat(min(max(fraction, 0), 1))
            )
        )
        editorScrollView.reflectScrolledClipView(clip)
    }

    private func applyPendingContinuityStateIfPossible() {
        guard isDocumentLoaded, let state = pendingContinuityState else { return }
        if isReaderMode {
            guard let reader = readerViewController,
                  reader.renderResult != nil,
                  reader.markdown == textView.string else { return }
        }

        pendingContinuityState = nil
        if let id = state.selectedThreadID,
           currentComments.contains(where: { $0.motivation == "commenting" && $0.id == id }) {
            selectedThreadID = id
        } else {
            selectedThreadID = nil
        }
        commentsViewController?.selectComment(selectedThreadID)
        updateCommentHighlights()

        let range = clamped(
            NSRange(
                location: max(0, state.selectionLocation),
                length: max(0, state.selectionLength)
            ),
            limit: textView.string.utf16.count
        )
        if isReaderMode {
            readerViewController?.selectSourceRange(range, scrollToVisible: false)
            readerViewController?.restoreScrollFraction(state.scrollFraction)
        } else {
            isApplyingDocument = true
            textView.setSelectedRange(range)
            isApplyingDocument = false
            restoreSourceScrollFraction(state.scrollFraction)
            updateStatus()
        }
    }

    private func refreshCommentsPresentation(comments: [MarginComment]? = nil) {
        guard let controller = commentsViewController else { return }
        if let comments {
            controller.display(
                comments: comments,
                source: textView.string,
                selectedCommentID: selectedThreadID,
                commentRevision: currentCommentRevision
            )
            onCommentAvailabilityChanged?(!comments.isEmpty)
            return
        }
        guard documentURL != nil else {
            controller.display(comments: [], source: "", commentRevision: 0)
            onCommentAvailabilityChanged?(false)
            return
        }
        controller.display(
            comments: currentComments,
            source: textView.string,
            selectedCommentID: selectedThreadID,
            commentRevision: currentCommentRevision
        )
        onCommentAvailabilityChanged?(!currentComments.isEmpty)
    }

    private func watchDocument(_ url: URL) {
        let watcher = FileSystemWatcher(url: url.deletingLastPathComponent()) { [weak self] _ in
            self?.refreshFromDisk(metadataOnly: false, origin: .externalRefresh)
        }
        fileWatcher = watcher
        watcher.start()
    }

    private func refreshFromDisk(
        metadataOnly: Bool,
        origin: CommentsChangeOrigin
    ) {
        guard let url = documentURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoded = try codec.decode(Data(contentsOf: url, options: .mappedIfSafe))
            if decoded.bodyData == lastSavedBodyData || metadataOnly {
                applyComments(
                    decoded.envelope?.items ?? [],
                    revision: decoded.envelope?.revision ?? 0,
                    origin: origin
                )
            } else if !isDirty {
                let selection = textView.selectedRange()
                applyLoadedDocument(
                    body: decoded.body,
                    bodyData: decoded.bodyData,
                    comments: decoded.envelope?.items ?? [],
                    commentRevision: decoded.envelope?.revision ?? 0,
                    commentsOrigin: origin
                )
                textView.setSelectedRange(clamped(selection, limit: textView.string.utf16.count))
            } else {
                showConflictBanner()
            }
        } catch {
            // Atomic replacements can momentarily invalidate a directory event.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
                guard let self, self.documentURL == url else { return }
                if let decoded = try? self.codec.decode(Data(contentsOf: url, options: .mappedIfSafe)),
                   decoded.bodyData == self.lastSavedBodyData {
                    self.applyComments(
                        decoded.envelope?.items ?? [],
                        revision: decoded.envelope?.revision ?? 0,
                        origin: origin
                    )
                }
            }
        }
    }

    private func showConflictBanner() {
        showBanner("This file changed outside Margin. Reload it, or keep your edited version.", actions: [
            ("Reload", { [weak self] in
                guard let self, let url = self.documentURL else { return }
                self.setDirty(false)
                self.presentDocument(at: url)
            }),
            ("Keep Mine", { [weak self] in
                guard let self, let url = self.documentURL,
                      let decoded = try? self.codec.decode(Data(contentsOf: url, options: .mappedIfSafe)) else { return }
                self.lastSavedBodyData = decoded.bodyData
                self.saveDocument(nil)
            }),
        ])
    }

    private func showBanner(_ message: String, actions: [(String, () -> Void)] = []) {
        banner.arrangedSubviews.dropFirst().forEach {
            banner.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        bannerLabel.stringValue = message
        banner.setAccessibilityValue(message)
        for action in actions {
            let button = EditorActionButton(title: action.0, handler: action.1)
            button.controlSize = .small
            button.bezelStyle = .inline
            banner.addArrangedSubview(button)
        }
        banner.isHidden = false
        NSAccessibility.post(element: banner, notification: .layoutChanged)
    }

    private func hideBanner() {
        banner.isHidden = true
        banner.setAccessibilityValue(nil)
    }

    private func currentParagraphRange(at location: Int) -> NSRange {
        let nsText = textView.string as NSString
        let safe = min(max(0, location), nsText.length)
        var range = nsText.paragraphRange(for: NSRange(location: safe, length: 0))
        while range.length > 0 {
            let last = nsText.character(at: NSMaxRange(range) - 1)
            if last == 0x0A || last == 0x0D { range.length -= 1 } else { break }
        }
        return range
    }

    private func sourceRange(forLine targetLine: Int, in source: String) -> NSRange? {
        guard targetLine > 0 else { return nil }
        let text = source as NSString
        var line = 1
        var location = 0
        while line < targetLine, location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(range)
            guard next > location else { return nil }
            location = next
            line += 1
        }
        guard line == targetLine, location <= text.length else { return nil }
        var range = text.lineRange(for: NSRange(location: location, length: 0))
        while range.length > 0 {
            let scalar = text.character(at: NSMaxRange(range) - 1)
            if scalar == 0x0A || scalar == 0x0D {
                range.length -= 1
            } else {
                break
            }
        }
        return range
    }

    private func anchorInput(for range: NSRange, in source: String) throws -> CommentAnchorInput {
        guard let swiftRange = Range(range, in: source), !swiftRange.isEmpty else {
            return .document
        }
        let prefix = String(source[..<swiftRange.lowerBound])
        let exact = String(source[swiftRange])
        let start = AnchorResolver.normalizedProjection(prefix).unicodeScalars.count
        let length = AnchorResolver.normalizedProjection(exact).unicodeScalars.count
        return .range(start: start, end: start + length, expectedExact: AnchorResolver.normalizedProjection(exact))
    }

    private func selectionTarget(for range: NSRange, documentID: String, in source: String) throws -> CommentTarget {
        let input = try anchorInput(for: range, in: source)
        return try resolver.target(for: input, documentID: documentID, in: source)
    }

    private func sourceRange(for scalarRange: UnicodeScalarRange, in source: String) -> NSRange? {
        let scalars = Array(source.unicodeScalars)
        guard scalarRange.start >= 0, scalarRange.end >= scalarRange.start else { return nil }
        var boundaries: [Int] = [0]
        boundaries.reserveCapacity(scalars.count + 1)
        var utf16 = 0
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 13, index + 1 < scalars.count, scalars[index + 1].value == 10 {
                utf16 += 2
                index += 2
            } else {
                utf16 += scalar.value > 0xFFFF ? 2 : 1
                index += 1
            }
            boundaries.append(utf16)
        }
        guard scalarRange.end < boundaries.count else { return nil }
        return NSRange(
            location: boundaries[scalarRange.start],
            length: boundaries[scalarRange.end] - boundaries[scalarRange.start]
        )
    }

    private var currentActor: MarginActor {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? NSUserName() : name
        let slug = displayName.lowercased().replacingOccurrences(of: " ", with: "-")
        return MarginActor(id: "urn:margin:person:\(slug)", type: .person, name: displayName)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private struct SavedDocument {
    let bodyData: Data
    let comments: [MarginComment]
    let commentRevision: Int
}

private enum EditorError: Error, LocalizedError {
    case externalConflict
    case cancelled

    var errorDescription: String? {
        switch self {
        case .externalConflict: return "The file changed outside Margin."
        case .cancelled: return "The document load was cancelled."
        }
    }
}

private final class EditorActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler() }
}

private func clamped(_ range: NSRange, limit: Int) -> NSRange {
    let location = min(max(0, range.location), limit)
    return NSRange(location: location, length: min(max(0, range.length), limit - location))
}
