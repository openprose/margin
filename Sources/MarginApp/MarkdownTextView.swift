import AppKit

final class MarkdownTextView: NSTextView {
    static let addCommentSelector = NSSelectorFromString("beginComment:")
    static let toggleReaderSelector = NSSelectorFromString("toggleReaderMode:")

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureForMarkdown()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureForMarkdown()
    }

    private func configureForMarkdown() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesInspectorBar = false
        textContainerInset = NSSize(width: 42, height: 52)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        insertionPointColor = .controlAccentColor
        setAccessibilityLabel("Markdown editor")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        if flags == [.command], characters == "b" {
            toggleMarkdown(open: "**", close: "**")
            return true
        }
        if flags == [.command], characters == "i" {
            toggleMarkdown(open: "*", close: "*")
            return true
        }
        if flags == [.command], characters == "k" {
            insertMarkdownLink()
            return true
        }
        if flags == [.command, .option], characters == "m" {
            return NSApp.sendAction(Self.addCommentSelector, to: nil, from: self)
        }
        if flags == [.command, .shift], characters == "r" {
            return NSApp.sendAction(Self.toggleReaderSelector, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    @IBAction func toggleBold(_ sender: Any?) {
        toggleMarkdown(open: "**", close: "**")
    }

    @IBAction func toggleItalic(_ sender: Any?) {
        toggleMarkdown(open: "*", close: "*")
    }

    @IBAction func insertLink(_ sender: Any?) {
        insertMarkdownLink()
    }

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        guard selection.length == 0, selection.location <= source.length else {
            super.insertNewline(sender)
            return
        }

        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let beforeCaret = source.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
        guard let continuation = listContinuation(for: beforeCaret) else {
            super.insertNewline(sender)
            return
        }

        if continuation.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let markerRange = NSRange(location: lineRange.location, length: continuation.prefix.utf16.count)
            replace(range: markerRange, with: "")
            super.insertNewline(sender)
        } else {
            replace(range: selection, with: "\n\(continuation.nextPrefix)", selectionOffset: continuation.nextPrefix.utf16.count + 1)
        }
    }

    override func insertTab(_ sender: Any?) {
        indentSelectedLines(removing: false)
    }

    override func insertBacktab(_ sender: Any?) {
        indentSelectedLines(removing: true)
    }

    override func deleteBackward(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        if selection.length == 0, selection.location > 0 {
            let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
            let beforeCaretRange = NSRange(location: lineRange.location, length: selection.location - lineRange.location)
            let beforeCaret = source.substring(with: beforeCaretRange)
            if let continuation = listContinuation(for: beforeCaret),
               continuation.content.isEmpty,
               continuation.prefix.utf16.count == beforeCaretRange.length {
                replace(range: beforeCaretRange, with: "")
                return
            }
        }
        super.deleteBackward(sender)
    }

    private func toggleMarkdown(open: String, close: String) {
        let source = string as NSString
        let selection = selectedRange()
        let openLength = open.utf16.count
        let closeLength = close.utf16.count
        let hasOuterMarkers = selection.location >= openLength
            && NSMaxRange(selection) + closeLength <= source.length
            && source.substring(with: NSRange(location: selection.location - openLength, length: openLength)) == open
            && source.substring(with: NSRange(location: NSMaxRange(selection), length: closeLength)) == close

        if hasOuterMarkers {
            let fullRange = NSRange(location: selection.location - openLength, length: openLength + selection.length + closeLength)
            let selected = source.substring(with: selection)
            replace(range: fullRange, with: selected, selection: NSRange(location: selection.location - openLength, length: selection.length))
            return
        }

        let selected = source.substring(with: selection)
        let replacement = open + selected + close
        let newSelection = selection.length == 0
            ? NSRange(location: selection.location + openLength, length: 0)
            : NSRange(location: selection.location + openLength, length: selection.length)
        replace(range: selection, with: replacement, selection: newSelection)
    }

    private func insertMarkdownLink() {
        let source = string as NSString
        let selection = selectedRange()
        let selected = source.substring(with: selection)
        let label = selected.isEmpty ? "link text" : selected
        let replacement = "[\(label)](https://)"
        let newSelection: NSRange
        if selected.isEmpty {
            newSelection = NSRange(location: selection.location + 1, length: label.utf16.count)
        } else {
            newSelection = NSRange(location: selection.location + replacement.utf16.count - "https://".utf16.count - 1, length: "https://".utf16.count)
        }
        replace(range: selection, with: replacement, selection: newSelection)
    }

    private func indentSelectedLines(removing: Bool) {
        let source = string as NSString
        let selection = selectedRange()
        let lineSelection = selection.length > 0
            ? NSRange(location: selection.location, length: selection.length - 1)
            : selection
        let lines = source.lineRange(for: lineSelection)
        var text = source.substring(with: lines)
        let original = text

        if removing {
            text = text.replacingOccurrences(of: "(?m)^( {1,2}|\t)", with: "", options: .regularExpression)
        } else {
            text = text.replacingOccurrences(of: "(?m)^", with: "  ", options: .regularExpression)
        }
        guard text != original else { return }
        replace(range: lines, with: text, selection: NSRange(location: lines.location, length: text.utf16.count))
    }

    private struct Continuation {
        let prefix: String
        let nextPrefix: String
        let content: String
    }

    private func listContinuation(for line: String) -> Continuation? {
        let pattern = #"^(\s*)(?:(\d+)([.)])|([-+*]))\s+(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            let nsLine = line as NSString
            let indentation = nsLine.substring(with: match.range(at: 1))
            var content = nsLine.substring(with: match.range(at: 5))
            let prefix: String
            var nextPrefix: String
            if match.range(at: 2).location != NSNotFound,
               let number = Int(nsLine.substring(with: match.range(at: 2))) {
                let punctuation = nsLine.substring(with: match.range(at: 3))
                prefix = "\(indentation)\(number)\(punctuation) "
                nextPrefix = "\(indentation)\(number + 1)\(punctuation) "
            } else {
                let marker = nsLine.substring(with: match.range(at: 4))
                prefix = "\(indentation)\(marker) "
                nextPrefix = prefix
            }
            var completePrefix = prefix
            let taskPattern = #"^(\[[ xX]\](?:[ \t]+|$))(.*)$"#
            if let taskRegex = try? NSRegularExpression(pattern: taskPattern),
               let task = taskRegex.firstMatch(
                   in: content,
                   range: NSRange(location: 0, length: (content as NSString).length)
               ) {
                let taskContent = content as NSString
                completePrefix += taskContent.substring(with: task.range(at: 1))
                nextPrefix += "[ ] "
                content = taskContent.substring(with: task.range(at: 2))
            }
            return Continuation(prefix: completePrefix, nextPrefix: nextPrefix, content: content)
        }

        let quotePattern = #"^(\s*>\s?)(.*)$"#
        if let regex = try? NSRegularExpression(pattern: quotePattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            let nsLine = line as NSString
            let prefix = nsLine.substring(with: match.range(at: 1))
            return Continuation(prefix: prefix, nextPrefix: prefix, content: nsLine.substring(with: match.range(at: 2)))
        }
        return nil
    }

    private func replace(range: NSRange, with value: String, selectionOffset: Int) {
        replace(range: range, with: value, selection: NSRange(location: range.location + selectionOffset, length: 0))
    }

    private func replace(range: NSRange, with value: String, selection: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: value) else { return }
        textStorage?.replaceCharacters(in: range, with: value)
        didChangeText()
        setSelectedRange(selection ?? NSRange(location: range.location + value.utf16.count, length: 0))
    }
}
