import Foundation
import MarginCore

enum ComparisonCommands {
    static let defaultMaximumBlocks = 64
    static let maximumBlocks = 256
    static let defaultMaximumPreviewBytes = 512
    static let maximumPreviewBytes = 4_096

    typealias RequestLauncher = (Data, Bool, String?) throws -> Void
    typealias ItemLauncher = (URL, Bool, String?) throws -> Void

    static func help(path: [String]) -> String? {
        switch path {
        case []:
            return """
            MARGIN COMPARE

            Compare two explicit Markdown states, save a durable review, or work
            with review threads. Sources are never discovered implicitly.

            USAGE
              margin compare LEFT RIGHT [OPTIONS]
              margin compare [OPTIONS] -- LEFT RIGHT
              margin compare open REVIEW [--wait] [--app PATH]
              margin compare comments COMMAND ...

            OPTIONS
              --label-left TEXT; --label-right TEXT
              --json [--pretty] [--max-blocks N] [--max-preview-bytes N]
                [--after-block ID]
              --save-review PATH
              --wait; --app PATH (native app form only)
              --if-left-sha SHA256; --if-right-sha SHA256

            INPUTS
              Exactly one source may be - for bounded UTF-8 standard input.
              Use -- before source names that begin with a dash.

            OUTPUT
              Without --json, macOS opens the native comparison. --json emits one
              bounded changed-block page and never launches the app. Replay nextArgv
              unchanged; continuations pin both source hashes.

            SUBCOMMANDS
              open       Validate and open a saved .marginreview artifact.
              comments   List and mutate portable comparison-review threads.

            MORE
              margin compare open --help
              margin compare comments --help
              margin man comparison
            """
        case ["open"]:
            return """
            MARGIN COMPARE OPEN

            USAGE
              margin compare open REVIEW [--wait] [--app PATH]
              margin compare open [--wait] [--app PATH] -- REVIEW

            Validates the explicit review as bounded inert data, then passes only
            that review path to Margin.app. Embedded paths and instructions are not
            followed. Available on macOS.
            """
        case ["comments"]:
            return """
            MARGIN COMPARE COMMENTS

            USAGE
              margin compare comments list REVIEW [OPTIONS]
              margin compare comments add REVIEW ANCHOR -m TEXT [OPTIONS]
              margin compare comments reply REVIEW PARENT -m TEXT [OPTIONS]
              margin compare comments resolve REVIEW THREAD [OPTIONS]
              margin compare comments reopen REVIEW THREAD [OPTIONS]

            Every command emits bounded JSON. Reuse a caller-chosen --id for safe
            add/reply retries and use --if-revision to detect concurrent changes.
            Use -- before positional values that would otherwise look like options.

            Run any command above with --help for its exact grammar.
            """
        case ["comments", "list"]:
            return """
            MARGIN COMPARE COMMENTS LIST

            USAGE
              margin compare comments list [--status open|resolved|all]
                [--max-threads N] [--max-body-bytes N] [--after-thread ID]
                [--if-revision N] [--json] [--pretty] [--] REVIEW

            Emits a bounded thread page. A returned nextArgv is directly replayable
            and pins the review revision so concurrent writes fail explicitly.
            """
        case ["comments", "add"]:
            return """
            MARGIN COMPARE COMMENTS ADD

            USAGE
              margin compare comments add --side left|right ANCHOR MESSAGE
                [--block ID] [--id ID] [--if-revision N] [ACTOR_OPTIONS]
                [--json] [--pretty] [--] REVIEW

            ANCHOR
              --quote TEXT [--prefix TEXT] [--suffix TEXT] [--occurrence N]
              --range START:END [--expect TEXT]
              --from LINE:COLUMN --to LINE:COLUMN [--expect TEXT]

            MESSAGE
              -m TEXT | --message TEXT | --body TEXT | --message-file PATH | --stdin

            ACTOR_OPTIONS
              --actor-id ID [--actor-name NAME] [--actor-type person|software|organization]

            A repeated --id with the same actor, target, and body is a no-op; reuse
            with different content fails. Message files must be regular files.
            """
        case ["comments", "reply"]:
            return """
            MARGIN COMPARE COMMENTS REPLY

            USAGE
              margin compare comments reply MESSAGE [--id ID] [--if-revision N]
                [ACTOR_OPTIONS] [--json] [--pretty] [--] REVIEW PARENT

            MESSAGE
              -m TEXT | --message TEXT | --body TEXT | --message-file PATH | --stdin

            ACTOR_OPTIONS
              --actor-id ID [--actor-name NAME] [--actor-type person|software|organization]

            A repeated --id with identical reply content is a no-op, including after
            later replies or status changes. Different content fails closed.
            """
        case ["comments", "resolve"], ["comments", "reopen"]:
            let verb = path[1].uppercased()
            return """
            MARGIN COMPARE COMMENTS \(verb)

            USAGE
              margin compare comments \(path[1]) [--if-revision N]
                [--actor-id ID] [--actor-name NAME]
                [--actor-type person|software|organization] [--json] [--pretty]
                [--] REVIEW THREAD

            Changes only the thread status. Repeating the current status is a no-op;
            --if-revision turns a stale write into an explicit revision conflict.
            """
        default:
            return nil
        }
    }

    static func run(
        _ cursor: inout ArgumentCursor,
        standardInput: () throws -> Data = readBoundedStandardInput,
        launchRequest: RequestLauncher = { data, wait, appOverride in
            try AppLauncher.openComparisonRequest(
                data,
                wait: wait,
                appOverride: appOverride
            )
        },
        launchItem: ItemLauncher = { item, wait, appOverride in
            try AppLauncher.open(item, wait: wait, appOverride: appOverride)
        }
    ) throws {
        if cursor.first == "open" {
            _ = cursor.pop()
            try runOpen(&cursor, launchItem: launchItem)
            return
        }
        if cursor.first == "comments" {
            _ = cursor.pop()
            try ComparisonReviewCommands.run(&cursor)
            return
        }

        let invocation = try parse(cursor.takeRemaining())
        if invocation.pretty && !invocation.json {
            throw CLIError.usage("--pretty requires --json. Run 'margin compare --help'.")
        }
        if !invocation.json,
           invocation.maximumBlocksWasSpecified || invocation.maximumPreviewBytesWasSpecified ||
            invocation.afterBlock != nil {
            throw CLIError.usage(
                "--max-blocks, --max-preview-bytes, and --after-block require --json."
            )
        }
        if invocation.json, invocation.wait || invocation.appOverride != nil {
            throw CLIError.usage("--wait and --app cannot be combined with --json.")
        }
        guard invocation.left != "-" || invocation.right != "-" else {
            throw CLIError.usage("Exactly one comparison side may read from standard input.")
        }
#if !os(macOS)
        if !invocation.json, invocation.wait || invocation.appOverride != nil {
            throw CLIError(
                "APP_UNAVAILABLE",
                "--wait and --app require Margin's macOS application.",
                exit: .unavailable
            )
        }
        if !invocation.json, invocation.saveReview == nil {
            throw CLIError(
                "APP_UNAVAILABLE",
                "Margin's comparison app is available on macOS. On Linux, use --json or --save-review PATH.",
                exit: .unavailable
            )
        }
#endif

        let inputData = (invocation.left == "-" || invocation.right == "-")
            ? try standardInput()
            : nil
        let left = try snapshot(
            source: invocation.left,
            label: invocation.labelLeft,
            standardInput: inputData
        )
        let right = try snapshot(
            source: invocation.right,
            label: invocation.labelRight,
            standardInput: inputData
        )
        let pair = try ComparisonSnapshotPair(left: left, right: right)
        try validateSnapshotPrecondition(
            invocation.expectedLeftSHA256,
            snapshot: pair.left,
            source: invocation.left
        )
        try validateSnapshotPrecondition(
            invocation.expectedRightSHA256,
            snapshot: pair.right,
            source: invocation.right
        )

        if invocation.json {
            let result = try ComparisonEngine().compare(pair)
            let projected = try projection(
                pair: pair,
                result: result,
                invocation: invocation,
                savedReview: nil
            )
            let savedReview = try saveReviewIfRequested(invocation.saveReview, pair: pair)
            let envelope = projected.withSavedReview(savedReview?.path)
            try CLIOutput.json(
                envelope,
                pretty: invocation.pretty,
                maximumBytes: ComparisonCLIEnvelope.maximumEncodedBytes
            )
            return
        }

        let savedReview = try saveReviewIfRequested(invocation.saveReview, pair: pair)

#if os(macOS)
        if let savedReview {
            try launchItem(savedReview, invocation.wait, invocation.appOverride)
        } else {
            let request = try openRequest(pair: pair)
            let encoded = try ComparisonOpenRequestCodec.encode(
                request,
                maximumBytes: AppLauncher.maximumComparisonRequestBytes
            )
            try launchRequest(encoded, invocation.wait, invocation.appOverride)
        }
#else
        if let savedReview {
            try CLIOutput.text(savedReview.path)
        } else {
            throw CLIError(
                "APP_UNAVAILABLE",
                "Margin's comparison app is available on macOS. On Linux, use --json or --save-review PATH.",
                exit: .unavailable
            )
        }
#endif
    }

    static func mapError(_ error: ComparisonError) -> CLIError {
        let exit: CLIExit
        switch error {
        case .reviewNotFound, .inputNotFound:
            exit = .notFound
        case .symbolicLink, .invalidPortablePath:
            exit = .permission
        case .reviewAlreadyExists:
            exit = .cannotCreate
        case .revisionConflict, .concurrentModification, .cancelled, .inputChanged:
            exit = .temporaryFailure
        case .io:
            exit = .io
        default:
            exit = .data
        }
        return CLIError(error.code, error.localizedDescription, exit: exit)
    }

    static func parse(_ arguments: [String]) throws -> ComparisonInvocation {
        var positionals: [String] = []
        var labelLeft: String?
        var labelRight: String?
        var saveReview: String?
        var afterBlock: String?
        var expectedLeftSHA256: String?
        var expectedRightSHA256: String?
        var maximumBlocks: Int?
        var maximumPreviewBytes: Int?
        var appOverride: String?
        var json = false
        var pretty = false
        var wait = false
        var optionsEnabled = true
        var index = 0

        func duplicate(_ name: String) -> CLIError {
            CLIError.usage("Option \(name) may be provided only once.")
        }

        while index < arguments.count {
            let value = arguments[index]
            if optionsEnabled, value == "--" {
                optionsEnabled = false
                index += 1
                continue
            }
            if optionsEnabled, value.hasPrefix("-") && value != "-" {
                switch value {
                case "--json":
                    if json { throw duplicate(value) }
                    json = true
                case "--pretty":
                    if pretty { throw duplicate(value) }
                    pretty = true
                case "--wait":
                    if wait { throw duplicate(value) }
                    wait = true
                case "--label-left", "--label-right", "--save-review", "--after-block",
                     "--if-left-sha", "--if-right-sha",
                     "--max-blocks", "--max-preview-bytes", "--app":
                    let valueIndex = index + 1
                    guard valueIndex < arguments.count else {
                        throw CLIError.usage("Option \(value) requires a value.")
                    }
                    let optionValue = arguments[valueIndex]
                    switch value {
                    case "--label-left":
                        if labelLeft != nil { throw duplicate(value) }
                        labelLeft = optionValue
                    case "--label-right":
                        if labelRight != nil { throw duplicate(value) }
                        labelRight = optionValue
                    case "--save-review":
                        if saveReview != nil { throw duplicate(value) }
                        saveReview = optionValue
                    case "--after-block":
                        if afterBlock != nil { throw duplicate(value) }
                        afterBlock = optionValue
                    case "--if-left-sha":
                        if expectedLeftSHA256 != nil { throw duplicate(value) }
                        expectedLeftSHA256 = try validatedSHA256(optionValue, option: value)
                    case "--if-right-sha":
                        if expectedRightSHA256 != nil { throw duplicate(value) }
                        expectedRightSHA256 = try validatedSHA256(optionValue, option: value)
                    case "--max-blocks":
                        if maximumBlocks != nil { throw duplicate(value) }
                        guard let parsed = Int(optionValue), parsed > 0 else {
                            throw CLIError.usage("--max-blocks must be a positive integer.")
                        }
                        maximumBlocks = min(parsed, Self.maximumBlocks)
                    case "--max-preview-bytes":
                        if maximumPreviewBytes != nil { throw duplicate(value) }
                        guard let parsed = Int(optionValue), parsed >= 0 else {
                            throw CLIError.usage("--max-preview-bytes must be nonnegative.")
                        }
                        maximumPreviewBytes = min(parsed, Self.maximumPreviewBytes)
                    case "--app":
                        if appOverride != nil { throw duplicate(value) }
                        appOverride = optionValue
                    default:
                        break
                    }
                    index = valueIndex
                default:
                    throw CLIError.usage(
                        "Unknown compare option '\(value)'. Run 'margin compare --help'."
                    )
                }
            } else {
                positionals.append(value)
            }
            index += 1
        }

        guard positionals.count >= 2 else {
            throw CLIError.usage("compare requires LEFT and RIGHT Markdown sources.")
        }
        guard positionals.count == 2 else {
            throw CLIError.usage("Unexpected comparison source '\(positionals[2])'.")
        }
        if let afterBlock,
           afterBlock.isEmpty || afterBlock.utf8.count > ComparisonHardLimits.identifierUTF8Bytes {
            throw CLIError.usage("--after-block is empty or too long.")
        }

        return ComparisonInvocation(
            left: positionals[0],
            right: positionals[1],
            labelLeft: labelLeft,
            labelRight: labelRight,
            saveReview: saveReview,
            json: json,
            pretty: pretty,
            wait: wait,
            appOverride: appOverride,
            maximumBlocks: maximumBlocks ?? defaultMaximumBlocks,
            maximumBlocksWasSpecified: maximumBlocks != nil,
            maximumPreviewBytes: maximumPreviewBytes ?? defaultMaximumPreviewBytes,
            maximumPreviewBytesWasSpecified: maximumPreviewBytes != nil,
            afterBlock: afterBlock,
            expectedLeftSHA256: expectedLeftSHA256,
            expectedRightSHA256: expectedRightSHA256
        )
    }

    private static func validatedSHA256(_ raw: String, option: String) throws -> String {
        let normalized = raw.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw CLIError.usage("\(option) requires a 64-character hexadecimal SHA-256 digest.")
        }
        return normalized
    }

    private static func runOpen(
        _ cursor: inout ArgumentCursor,
        launchItem: ItemLauncher
    ) throws {
#if !os(macOS)
        throw CLIError(
            "APP_UNAVAILABLE",
            "Opening a comparison review requires Margin's macOS application.",
            exit: .unavailable
        )
#else
        let protectedPositionals = splitEndOfOptions(
            cursor: &cursor,
            valueOptions: ["--app"]
        )
        let wait = cursor.takeFlag("--wait")
        let appOverride = try cursor.takeValue("--app")
        let positionals = cursor.takeRemaining() + protectedPositionals
        guard let reviewArgument = positionals.first, !reviewArgument.isEmpty else {
            throw CLIError.usage("Missing comparison review.")
        }
        guard positionals.count == 1 else {
            throw CLIError.usage("Unexpected argument '\(positionals[1])'.")
        }
        let reviewURL = try reviewURL(reviewArgument)
        _ = try ComparisonReviewStore().load(at: reviewURL)
        try launchItem(reviewURL, wait, appOverride)
#endif
    }

    private static func splitEndOfOptions(
        cursor: inout ArgumentCursor,
        valueOptions: Set<String>
    ) -> [String] {
        let values = cursor.takeRemaining()
        var separator: Int?
        var index = 0
        while index < values.count {
            if values[index] == "--" {
                separator = index
                break
            }
            index += valueOptions.contains(values[index]) ? 2 : 1
        }
        guard let separator else {
            cursor = ArgumentCursor(values)
            return []
        }
        cursor = ArgumentCursor(Array(values[..<separator]))
        return Array(values[values.index(after: separator)...])
    }

    private static func snapshot(
        source: String,
        label: String?,
        standardInput: Data?
    ) throws -> ComparisonSnapshot {
        if source == "-" {
            guard let standardInput else {
                throw CLIError("STDIN_READ_FAILED", "Standard input was not available.", exit: .io)
            }
            return try ComparisonSnapshot(
                markdownDocumentData: standardInput,
                label: label ?? "Standard Input"
            )
        }
        let url = PathResolver.resolvedPreservingFinalComponent(source)
        return try ComparisonSnapshot.readMarkdownFile(
            at: url,
            label: label,
            pathHint: url.lastPathComponent
        )
    }

    private static func validateSnapshotPrecondition(
        _ expectedSHA256: String?,
        snapshot: ComparisonSnapshot,
        source: String
    ) throws {
        guard let expectedSHA256, snapshot.sha256 != expectedSHA256 else { return }
        throw ComparisonError.inputChanged(source)
    }

    private static func readBoundedStandardInput() throws -> Data {
        let limit = ComparisonHardLimits.rawDocumentBytes
        var result = Data()
        do {
            while result.count <= limit {
                let remaining = limit + 1 - result.count
                guard let chunk = try FileHandle.standardInput.read(
                    upToCount: min(64 * 1_024, remaining)
                ), !chunk.isEmpty else { break }
                result.append(chunk)
            }
        } catch {
            throw CLIError(
                "STDIN_READ_FAILED",
                "Could not read comparison input from standard input: \(error.localizedDescription)",
                exit: .io
            )
        }
        guard result.count <= limit else {
            throw ComparisonError.resourceLimit(
                name: "standard-input bytes",
                limit: limit,
                actual: result.count
            )
        }
        return result
    }

    private static func projection(
        pair: ComparisonSnapshotPair,
        result: ComparisonDiffResult,
        invocation: ComparisonInvocation,
        savedReview: URL?
    ) throws -> ComparisonCLIEnvelope {
        let changed = result.changedBlocks
        let start: Int
        if let after = invocation.afterBlock {
            guard let index = changed.firstIndex(where: { $0.id == after }) else {
                throw CLIError(
                    "COMPARISON_BLOCK_NOT_FOUND",
                    "No changed comparison block has id '\(after)'.",
                    exit: .notFound
                )
            }
            start = index + 1
        } else {
            start = 0
        }
        let end = min(changed.count, start + invocation.maximumBlocks)
        let page = changed[start..<end]
        let blocks = try page.map { block in
            try ComparisonBlockProjection(
                block: block,
                left: pair.left,
                right: pair.right,
                maximumPreviewBytes: invocation.maximumPreviewBytes
            )
        }
        let nextArgv: [String]?
        if end < changed.count, let lastID = blocks.last?.id {
            nextArgv = continuationArguments(
                invocation: invocation,
                pair: pair,
                after: lastID
            )
        } else {
            nextArgv = nil
        }
        return ComparisonCLIEnvelope(
            pair: ComparisonPairProjection(pair),
            isCoarse: result.isCoarse,
            coarseReasons: result.coarseReasons,
            total: changed.count,
            included: blocks.count,
            omitted: changed.count - blocks.count,
            truncated: start > 0 || end < changed.count,
            blocks: blocks,
            nextArgv: nextArgv,
            nextRequiresSameStandardInput: nextArgv != nil &&
                (invocation.left == "-" || invocation.right == "-"),
            savedReview: savedReview?.path
        )
    }

    private static func continuationArguments(
        invocation: ComparisonInvocation,
        pair: ComparisonSnapshotPair,
        after blockID: String
    ) -> [String] {
        var options = [
            "--json",
            "--max-blocks", String(invocation.maximumBlocks),
            "--max-preview-bytes", String(invocation.maximumPreviewBytes),
            "--after-block", blockID,
            "--if-left-sha", pair.left.sha256,
            "--if-right-sha", pair.right.sha256,
        ]
        if invocation.pretty { options.append("--pretty") }
        if let label = invocation.labelLeft {
            options += ["--label-left", label]
        }
        if let label = invocation.labelRight {
            options += ["--label-right", label]
        }
        if [invocation.left, invocation.right].contains(where: {
            $0.hasPrefix("-") && $0 != "-"
        }) {
            return ["compare"] + options + ["--", invocation.left, invocation.right]
        }
        return ["compare", invocation.left, invocation.right] + options
    }

    private static func openRequest(pair: ComparisonSnapshotPair) throws -> ComparisonOpenRequest {
        return try ComparisonOpenRequest(
            requestID: "urn:uuid:\(UUID().uuidString.lowercased())",
            created: ISO8601DateFormatter().string(from: Date()),
            left: pair.left,
            right: pair.right
        )
    }

    private static func saveReviewIfRequested(
        _ rawPath: String?,
        pair: ComparisonSnapshotPair
    ) throws -> URL? {
        guard let rawPath else { return nil }
        let url = try reviewURL(rawPath)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let review = try ComparisonReview(
            id: "urn:uuid:\(UUID().uuidString.lowercased())",
            created: timestamp,
            modified: timestamp,
            snapshots: pair
        )
        _ = try ComparisonReviewStore().create(review, at: url)
        return url
    }

    private static func reviewURL(_ rawPath: String) throws -> URL {
        let url = PathResolver.resolvedPreservingFinalComponent(rawPath)
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".marginreview") || name.hasSuffix(".margin-review.json") else {
            throw CLIError.usage(
                "Comparison reviews must use .marginreview or .margin-review.json so Margin opens them as reviews."
            )
        }
        return url
    }
}

struct ComparisonInvocation: Equatable {
    let left: String
    let right: String
    let labelLeft: String?
    let labelRight: String?
    let saveReview: String?
    let json: Bool
    let pretty: Bool
    let wait: Bool
    let appOverride: String?
    let maximumBlocks: Int
    let maximumBlocksWasSpecified: Bool
    let maximumPreviewBytes: Int
    let maximumPreviewBytesWasSpecified: Bool
    let afterBlock: String?
    let expectedLeftSHA256: String?
    let expectedRightSHA256: String?
}

struct ComparisonCLIEnvelope: Encodable {
    static let maximumEncodedBytes = 16 * 1_024 * 1_024

    let schema = "urn:margin:comparison-result:v1"
    let ok = true
    let command = "compare"
    let pair: ComparisonPairProjection
    let algorithm = "margin-line-diff-v1"
    let isCoarse: Bool
    let coarseReasons: [ComparisonCoarseReason]
    let total: Int
    let included: Int
    let omitted: Int
    let truncated: Bool
    let blocks: [ComparisonBlockProjection]
    let nextArgv: [String]?
    let nextRequiresSameStandardInput: Bool
    let savedReview: String?

    func withSavedReview(_ path: String?) -> ComparisonCLIEnvelope {
        ComparisonCLIEnvelope(
            pair: pair,
            isCoarse: isCoarse,
            coarseReasons: coarseReasons,
            total: total,
            included: included,
            omitted: omitted,
            truncated: truncated,
            blocks: blocks,
            nextArgv: nextArgv,
            nextRequiresSameStandardInput: nextRequiresSameStandardInput,
            savedReview: path
        )
    }
}

struct ComparisonPairProjection: Encodable {
    let id: String
    let generation: Int
    let left: ComparisonSnapshotProjection
    let right: ComparisonSnapshotProjection

    init(_ pair: ComparisonSnapshotPair) {
        id = pair.id
        generation = pair.generation
        left = ComparisonSnapshotProjection(pair.left)
        right = ComparisonSnapshotProjection(pair.right)
    }
}

struct ComparisonSnapshotProjection: Encodable {
    let label: String
    let mediaType: String
    let utf8ByteCount: Int
    let unicodeScalarCount: Int
    let sha256: String
    let pathHint: String?

    init(_ snapshot: ComparisonSnapshot) {
        label = snapshot.label
        mediaType = snapshot.mediaType
        utf8ByteCount = snapshot.utf8ByteCount
        unicodeScalarCount = snapshot.unicodeScalarCount
        sha256 = snapshot.sha256
        pathHint = snapshot.pathHint
    }
}

struct ComparisonBlockProjection: Encodable {
    let id: String
    let kind: ComparisonBlockKind
    let leftRange: ComparisonTextRange
    let rightRange: ComparisonTextRange
    let leftPreview: String
    let rightPreview: String
    let leftPreviewTruncated: Bool
    let rightPreviewTruncated: Bool
    let hasWordDiff: Bool

    init(
        block: ComparisonBlock,
        left: ComparisonSnapshot,
        right: ComparisonSnapshot,
        maximumPreviewBytes: Int
    ) throws {
        guard let id = block.id else {
            throw ComparisonError.invalidSnapshot("A changed block has no identifier.")
        }
        let leftValue = try Self.preview(
            snapshot: left,
            range: block.left,
            maximumBytes: maximumPreviewBytes
        )
        let rightValue = try Self.preview(
            snapshot: right,
            range: block.right,
            maximumBytes: maximumPreviewBytes
        )
        self.id = id
        kind = block.kind
        leftRange = block.left
        rightRange = block.right
        leftPreview = leftValue.text
        rightPreview = rightValue.text
        leftPreviewTruncated = leftValue.truncated
        rightPreviewTruncated = rightValue.truncated
        hasWordDiff = !block.wordDiffs.isEmpty
    }

    private static func preview(
        snapshot: ComparisonSnapshot,
        range: ComparisonTextRange,
        maximumBytes: Int
    ) throws -> (text: String, truncated: Bool) {
        let data = snapshot.bodyData
        let start = range.utf8ByteStart
        let end = start + range.utf8ByteLength
        guard start >= 0, end >= start, end <= data.count else {
            throw ComparisonError.invalidSnapshot("A changed block addresses bytes outside its snapshot.")
        }
        let value = data.subdata(in: start..<end)
        guard value.count > maximumBytes else {
            guard let text = String(data: value, encoding: .utf8) else {
                throw ComparisonError.invalidUTF8
            }
            return (text, false)
        }
        var boundary = min(maximumBytes, value.count)
        while boundary > 0,
              String(data: value.prefix(boundary), encoding: .utf8) == nil {
            boundary -= 1
        }
        let prefix = value.prefix(boundary)
        guard let text = String(data: prefix, encoding: .utf8) else {
            throw ComparisonError.invalidUTF8
        }
        return (text, true)
    }
}
