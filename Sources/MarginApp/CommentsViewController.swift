import AppKit
import MarginCore

final class CommentsViewController: NSViewController {
    enum Filter: Int {
        case open
        case resolved
        case all
    }

    var onCreateComment: ((String) -> Void)?
    var onReply: ((String, String) -> Void)?
    var onResolve: ((String) -> Void)?
    var onReopen: ((String) -> Void)?
    var onSelectComment: ((String) -> Void)?
    var onComposerDismiss: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "Comments")
    private let countLabel = NSTextField(labelWithString: "")
    private lazy var filterControl = NSSegmentedControl(
        labels: ["Open", "Resolved", "All"],
        trackingMode: .selectOne,
        target: self,
        action: #selector(filterChanged(_:))
    )
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let composerHost = NSStackView()

    private var source = ""
    private var comments: [MarginComment] = []
    private var resolutions: [String: AnchorResolution] = [:]
    private var selectedCommentID: String?
    private var composerWidthConstraint: NSLayoutConstraint?

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityLabel("Document comments")

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterControl.segmentStyle = .automatic
        filterControl.selectedSegment = Filter.open.rawValue
        filterControl.controlSize = .small
        filterControl.setAccessibilityLabel("Comment filter")

        header.addSubview(headerLabel)
        header.addSubview(countLabel)
        header.addSubview(filterControl)

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
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

        composerHost.orientation = .vertical
        composerHost.alignment = .leading
        composerHost.spacing = 0

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

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    func display(comments: [MarginComment], source: String, selectedCommentID: String? = nil) {
        self.comments = comments
        self.source = source
        self.selectedCommentID = selectedCommentID
        let resolver = AnchorResolver()
        resolutions = Dictionary(uniqueKeysWithValues: comments.compactMap { comment in
            guard case .selection(let target) = comment.target else { return nil }
            return (comment.id, (try? resolver.resolve(target, in: source)) ?? AnchorResolution(state: .orphaned))
        })
        reload()
    }

    func selectComment(_ id: String?) {
        selectedCommentID = id
        reload()
    }

    func beginNewComment(quotedText: String) {
        showComposer(quote: quotedText, parentID: nil)
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        reload()
    }

    private func reload() {
        guard isViewLoaded else { return }
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        contentStack.addArrangedSubview(composerHost)
        if composerWidthConstraint == nil {
            let constraint = composerHost.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36)
            constraint.isActive = true
            composerWidthConstraint = constraint
        }

        let roots = comments.filter { $0.motivation == "commenting" }
        let visibleRoots = roots.filter { root in
            switch currentFilter {
            case .open: return root.status != .resolved
            case .resolved: return root.status == .resolved
            case .all: return true
            }
        }.sorted(by: rootOrder)

        let openCount = roots.filter { $0.status != .resolved }.count
        countLabel.stringValue = roots.isEmpty ? "" : "\(openCount) open"

        if visibleRoots.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: currentFilter == .open
                ? "Select a passage and press ⌘⌥M to begin a precise conversation."
                : "No comments in this view.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 13)
            empty.maximumNumberOfLines = 0
            empty.preferredMaxLayoutWidth = 250
            empty.setAccessibilityLabel("No comments")
            contentStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36).isActive = true
            return
        }

        let byParent = Dictionary(grouping: comments.filter { $0.motivation == "replying" }) { comment -> String in
            if case .resource(let id) = comment.target { return id }
            return ""
        }

        var selectedThreadView: NSView?
        for root in visibleRoots {
            let thread = makeThreadView(root: root, replies: byParent)
            contentStack.addArrangedSubview(thread)
            thread.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36).isActive = true
            if root.id == selectedCommentID { selectedThreadView = thread }
        }

        if let selectedThreadView {
            DispatchQueue.main.async { [weak selectedThreadView] in
                guard let selectedThreadView else { return }
                selectedThreadView.scrollToVisible(selectedThreadView.bounds)
            }
        }
    }

    private var currentFilter: Filter {
        Filter(rawValue: max(0, filterControl.selectedSegment)) ?? .open
    }

    private func rootOrder(_ lhs: MarginComment, _ rhs: MarginComment) -> Bool {
        let left = resolutions[lhs.id]?.range?.start ?? Int.max
        let right = resolutions[rhs.id]?.range?.start ?? Int.max
        if left != right { return left < right }
        return lhs.created < rhs.created
    }

    private func makeThreadView(root: MarginComment, replies: [String: [MarginComment]]) -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 9
        container.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("Comment by \(root.creator.name)")
        container.setAccessibilityValue(root.body.value)

        if let quote = rootQuote(root) {
            let quoteLabel = NSTextField(wrappingLabelWithString: "“\(quote)”")
            quoteLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            quoteLabel.textColor = .secondaryLabelColor
            quoteLabel.maximumNumberOfLines = 3
            quoteLabel.lineBreakMode = .byTruncatingTail
            container.addArrangedSubview(quoteLabel)
            quoteLabel.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        if let resolution = resolutions[root.id], resolution.state == .ambiguous || resolution.state == .orphaned {
            let anchorState = statusLabel(resolution.state == .ambiguous ? "Needs reattachment" : "Passage no longer found")
            container.addArrangedSubview(anchorState)
        }

        container.addArrangedSubview(commentHeader(root))
        let body = commentBody(root)
        container.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        var visited = Set<String>([root.id])
        appendReplies(parentID: root.id, depth: 1, replies: replies, to: container, visited: &visited)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        let reply = ClosureButton(title: "Reply") { [weak self] in
            self?.showComposer(quote: nil, parentID: root.id)
        }
        reply.controlSize = .small
        reply.bezelStyle = .inline
        reply.setAccessibilityLabel("Reply to comment by \(root.creator.name)")
        actions.addArrangedSubview(reply)

        let stateButton = ClosureButton(title: root.status == .resolved ? "Reopen" : "Resolve") { [weak self] in
            if root.status == .resolved {
                self?.onReopen?(root.id)
            } else {
                self?.onResolve?(root.id)
            }
        }
        stateButton.controlSize = .small
        stateButton.bezelStyle = .inline
        stateButton.setAccessibilityLabel("\(root.status == .resolved ? "Reopen" : "Resolve") comment by \(root.creator.name)")
        actions.addArrangedSubview(stateButton)
        container.addArrangedSubview(actions)

        let click = NSClickGestureRecognizer(target: self, action: #selector(threadClicked(_:)))
        click.buttonMask = 0x1
        container.identifier = NSUserInterfaceItemIdentifier(root.id)
        container.addGestureRecognizer(click)

        if selectedCommentID == root.id {
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor
            container.layer?.cornerRadius = 7
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private func appendReplies(
        parentID: String,
        depth: Int,
        replies: [String: [MarginComment]],
        to stack: NSStackView,
        visited: inout Set<String>
    ) {
        for reply in (replies[parentID] ?? []).sorted(by: { $0.created < $1.created }) {
            guard visited.insert(reply.id).inserted else { continue }
            let replyView = NSStackView()
            replyView.orientation = .vertical
            replyView.alignment = .leading
            replyView.spacing = 5
            replyView.edgeInsets = NSEdgeInsets(top: 5, left: CGFloat(min(depth, 2) * 12), bottom: 5, right: 0)
            if depth > 2, let parent = comments.first(where: { $0.id == parentID }) {
                let lineage = NSTextField(labelWithString: "Replying to \(parent.creator.name)")
                lineage.font = .systemFont(ofSize: 10.5)
                lineage.textColor = .tertiaryLabelColor
                replyView.addArrangedSubview(lineage)
            }
            replyView.addArrangedSubview(commentHeader(reply))
            let body = commentBody(reply)
            replyView.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: replyView.widthAnchor, constant: -CGFloat(min(depth, 2) * 12)).isActive = true
            let replyAction = ClosureButton(title: "Reply") { [weak self] in
                self?.showComposer(quote: nil, parentID: reply.id)
            }
            replyAction.controlSize = .mini
            replyAction.bezelStyle = .inline
            replyAction.setAccessibilityLabel("Reply to comment by \(reply.creator.name)")
            replyView.addArrangedSubview(replyAction)
            stack.addArrangedSubview(replyView)
            replyView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            appendReplies(parentID: reply.id, depth: depth + 1, replies: replies, to: stack, visited: &visited)
        }
    }

    private func commentHeader(_ comment: MarginComment) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        let author = NSTextField(labelWithString: comment.creator.name)
        author.font = .systemFont(ofSize: 11.5, weight: .semibold)
        let date = NSTextField(labelWithString: relativeDate(comment.created))
        date.font = .systemFont(ofSize: 10.5)
        date.textColor = .secondaryLabelColor
        row.addArrangedSubview(author)
        row.addArrangedSubview(date)
        return row
    }

    private func commentBody(_ comment: MarginComment) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: comment.body.value)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        return label
    }

    private func rootQuote(_ comment: MarginComment) -> String? {
        guard case .selection(let target) = comment.target,
              let exact = target.quoteSelector?.exact else { return nil }
        let singleLine = exact.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 180 ? String(singleLine.prefix(177)) + "…" : singleLine
    }

    private func statusLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .systemOrange
        label.setAccessibilityLabel(title)
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

    private func showComposer(quote: String?, parentID: String?) {
        composerHost.arrangedSubviews.forEach {
            composerHost.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let composer = CommentComposerView(quote: quote)
        composer.onCancel = { [weak self] in self?.hideComposer() }
        composer.onSubmit = { [weak self] body in
            guard let self else { return }
            if let parentID {
                self.onReply?(parentID, body)
            } else {
                self.onCreateComment?(body)
            }
            self.hideComposer()
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

    @objc private func threadClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let id = recognizer.view?.identifier?.rawValue else { return }
        selectedCommentID = id
        onSelectComment?(id)
        reload()
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

    init(quote: String?) {
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
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 2
            stack.addArrangedSubview(label)
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 7, height: 7)
        textView.setAccessibilityLabel("Comment text")
        textView.setAccessibilityHelp("Write a Markdown comment. Press Command-Return to submit or Escape to cancel.")
        scroll.documentView = textView
        stack.addArrangedSubview(scroll)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 7
        let submit = ClosureButton(title: "Comment") { [weak self] in self?.submit() }
        submit.keyEquivalent = "\r"
        submit.isEnabled = false
        submit.setAccessibilityLabel("Submit comment")
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
}
