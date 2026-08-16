import AppKit
import MarginCore

final class EditorViewController: NSViewController,
    WorkspaceDocumentPresenting,
    WorkspaceReaderModeToggling,
    WorkspaceDocumentSaving,
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

    private let codec = EmbeddedCommentCodec()
    private let resolver = AnchorResolver()
    private let store = AtomicDocumentStore()
    private let commentService = CommentService()

    var isReaderModeActive: Bool { isReaderMode }
    var onCommentAvailabilityChanged: ((Bool) -> Void)?

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
            banner.topAnchor.constraint(equalTo: root.topAnchor),
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

    func connectComments(_ controller: CommentsViewController) {
        commentsViewController = controller
        controller.onCreateComment = { [weak self] body in self?.createComment(body) }
        controller.onReply = { [weak self] parent, body in self?.reply(to: parent, body: body) }
        controller.onResolve = { [weak self] id in self?.setResolved(true, id: id) }
        controller.onReopen = { [weak self] id in self?.setResolved(false, id: id) }
        controller.onSelectComment = { [weak self] id in self?.selectThread(id) }
        controller.onComposerDismiss = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(
                self.isReaderMode ? (self.readerViewController?.textView ?? self.textView) : self.textView
            )
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
        loadGeneration = UUID()
        let generation = loadGeneration
        hideBanner()

        guard FileManager.default.fileExists(atPath: url.path) else {
            applyLoadedDocument(body: "", bodyData: Data(), comments: [])
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
                    self.applyLoadedDocument(body: value.0.body, bodyData: value.0.bodyData, comments: value.1)
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
        commentsViewController?.display(comments: [], source: "")
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
                self.view.window?.makeFirstResponder(reader.textView)
                self.statusLabel.stringValue = "Reader"
            }
        } else {
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
                    result: SavedDocument(bodyData: bodyData, comments: envelope?.items ?? [])
                )
            }
            lastSavedBodyData = saved.bodyData
            setDirty(false)
            rebuildAnchors(from: saved.comments)
            refreshCommentsPresentation(comments: saved.comments)
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
        let location = textView.selectedRange().location
        let next = anchorRanges
            .filter { !anchorsDeletedByEdit.contains($0.key) && NSLocationInRange(location, $0.value) }
            .sorted { $0.value.length < $1.value.length }
            .first?.key
        if next != selectedThreadID {
            selectedThreadID = next
            commentsViewController?.selectComment(next)
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

    private func applyLoadedDocument(body: String, bodyData: Data, comments: [MarginComment]) {
        isApplyingDocument = true
        textView.string = body
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        isApplyingDocument = false
        let name = documentURL?.lastPathComponent ?? "Markdown document"
        textView.setAccessibilityHelp("Editing \(name) as literal Markdown. Formatting marks remain visible.")
        lastSavedBodyData = bodyData
        setDirty(false)
        installHighlighterIfNeeded()
        highlighter?.invalidate()
        rebuildAnchors(from: comments)
        refreshCommentsPresentation(comments: comments)
        if isReaderMode {
            statusLabel.stringValue = "Preparing reader…"
            ensureReaderViewController().renderAsync(
                markdown: body,
                baseURL: documentURL?.deletingLastPathComponent()
            ) { [weak self] applied in
                guard let self, applied, self.isReaderMode else { return }
                self.updateReaderHighlights()
                self.statusLabel.stringValue = "Reader"
            }
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
            let baseColor = NSColor.controlAccentColor
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
            return .init(id: id, sourceRange: range, state: id == selectedThreadID ? .active : .normal)
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
            refreshFromDisk(metadataOnly: true)
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
            refreshFromDisk(metadataOnly: true)
        } catch {
            showBanner("Could not reply: \(error.localizedDescription)")
        }
    }

    private func setResolved(_ resolved: Bool, id: String) {
        guard let url = documentURL else { return }
        guard prepareToClose() else { return }
        do {
            if resolved {
                _ = try commentService.resolve(at: url, id: id, actor: currentActor)
            } else {
                _ = try commentService.reopen(at: url, id: id, actor: currentActor)
            }
            refreshFromDisk(metadataOnly: true)
        } catch {
            showBanner("Could not update thread: \(error.localizedDescription)")
        }
    }

    private func selectThread(_ id: String) {
        selectedThreadID = id
        guard let range = anchorRanges[id] else { return }
        if isReaderMode {
            readerViewController?.selectSourceRange(range)
        } else {
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            view.window?.makeFirstResponder(textView)
        }
        updateCommentHighlights()
    }

    private func refreshCommentsPresentation(comments: [MarginComment]? = nil) {
        guard let controller = commentsViewController else { return }
        if let comments {
            controller.display(comments: comments, source: textView.string, selectedCommentID: selectedThreadID)
            onCommentAvailabilityChanged?(!comments.isEmpty)
            return
        }
        guard let url = documentURL else {
            controller.display(comments: [], source: "")
            onCommentAvailabilityChanged?(false)
            return
        }
        if let decoded = try? codec.decode(Data(contentsOf: url, options: .mappedIfSafe)) {
            let comments = decoded.envelope?.items ?? []
            controller.display(comments: comments, source: textView.string, selectedCommentID: selectedThreadID)
            onCommentAvailabilityChanged?(!comments.isEmpty)
        }
    }

    private func watchDocument(_ url: URL) {
        let watcher = FileSystemWatcher(url: url.deletingLastPathComponent()) { [weak self] _ in
            self?.refreshFromDisk(metadataOnly: false)
        }
        fileWatcher = watcher
        watcher.start()
    }

    private func refreshFromDisk(metadataOnly: Bool) {
        guard let url = documentURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoded = try codec.decode(Data(contentsOf: url, options: .mappedIfSafe))
            if decoded.bodyData == lastSavedBodyData || metadataOnly {
                rebuildAnchors(from: decoded.envelope?.items ?? [])
                refreshCommentsPresentation(comments: decoded.envelope?.items ?? [])
                hideBanner()
            } else if !isDirty {
                let selection = textView.selectedRange()
                applyLoadedDocument(body: decoded.body, bodyData: decoded.bodyData, comments: decoded.envelope?.items ?? [])
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
                    self.rebuildAnchors(from: decoded.envelope?.items ?? [])
                    self.refreshCommentsPresentation(comments: decoded.envelope?.items ?? [])
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
