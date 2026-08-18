import Foundation
import MarginCore

enum CLICommandAvailability: String, Encodable {
    case available
    case unsupported
}

struct CLIArgumentContract: Encodable, Equatable {
    let name: String
    let kind: String
    let required: Bool
    let variadic: Bool
    let description: String
}

struct CLIOptionContract: Encodable, Equatable {
    let names: [String]
    let value: String?
    let required: Bool
    let repeatable: Bool
    let choices: [String]?
    let description: String
}

struct CLIOutputContract: Encodable, Equatable {
    let encoding: String
    let framing: String
    let schema: String?
    let description: String
}

struct CLICommandContract: Encodable, Equatable {
    let path: [String]
    let aliases: [[String]]
    let availability: CLICommandAvailability
    let summary: String
    let usage: [String]
    let arguments: [CLIArgumentContract]
    let options: [CLIOptionContract]
    let output: CLIOutputContract
    let sideEffects: String
    let unavailableReason: String?

    var displayPath: String { (["margin"] + path).joined(separator: " ") }
}

struct CLICapabilitiesEnvelope: Encodable {
    struct CLIIdentity: Encodable {
        let name: String
        let version: String
    }

    struct Bounds: Encodable {
        let maxCommands: Int
        let maxOptionsPerCommand: Int
        let maxUsageFormsPerCommand: Int
        let maxEncodedBytes: Int
    }

    struct Cursor: Encodable {
        let tokenPrefix: String
        let version: Int
        let availability: CLICommandAvailability
        let description: String
    }

    struct ProtocolContract: Encodable {
        let commandEnvelope: String
        let commentsWatch: String
        let capabilities: String
        let logicalMarkdown: String
        let metadataLocation: String
        let networkRequired: Bool
    }

    struct StageIntentKind: Encodable {
        let kind: String
        let required: [String]
        let optional: [String]
        let choices: [String: [String]]
    }

    struct StageIntentContract: Encodable {
        let schema = "urn:margin:stage-intent:v1"
        let version = 1
        let encoding = "canonicalizable-json"
        let maxEncodedBytes = 16 * 1_024 * 1_024
        let maxOperations = 4_096
        let topLevelRequired = ["version", "operations"]
        let topLevelOptional = ["schema"]
        let commonOperationRequired = ["kind", "path"]
        let commonOperationOptional = ["operationID"]
        let contributionSelector = "At most one of range, quote (+ prefix/suffix/occurrence), or from+to; suggestion contributions require one. expectedText is an optional exact-match precondition."
        let rangeShape = ["start": "nonnegative Unicode-scalar offset", "end": "greater Unicode-scalar offset"]
        let fileResultShapes = [
            "write": #"{"kind":"write","data":"BASE64","permissions":UINT16?}"#,
            "remove": #"{"kind":"remove"}"#
        ]
        let operationKinds = [
            StageIntentKind(
                kind: "contribution",
                required: ["contributionKind", "body"],
                optional: ["contributionID", "range", "quote", "prefix", "suffix", "occurrence", "from", "to", "expectedText", "audience", "parentID", "answerContributionID", "issueState", "decisionStatus", "rationale", "taskState", "assignee", "priority", "approvalState", "subjectID", "replacementText", "startingCursor", "finishingCursor", "touchedAnnotationIDs", "unresolvedIDs", "intendedNextActors"],
                choices: ["contributionKind": ["comment", "question", "issue", "decision", "task", "suggestion", "handoff", "approval"]]
            ),
            StageIntentKind(
                kind: "status",
                required: ["annotationID", "status"],
                optional: [],
                choices: ["status": ["open", "resolved"]]
            ),
            StageIntentKind(
                kind: "suggestion-disposition",
                required: ["contributionID", "disposition"],
                optional: [],
                choices: ["disposition": ["accept", "reject"]]
            ),
            StageIntentKind(
                kind: "file",
                required: ["result"],
                optional: ["precondition"],
                choices: ["result.kind": ["write", "remove"]]
            )
        ]
    }

    static let maximumEncodedBytes = 131_072

    let schema = "urn:margin:capabilities:v1"
    let ok = true
    let command = "capabilities"
    let contractVersion = 1
    let cli: CLIIdentity
    let bounds = Bounds(
        maxCommands: 64,
        maxOptionsPerCommand: 32,
        maxUsageFormsPerCommand: 4,
        maxEncodedBytes: maximumEncodedBytes
    )
    let cursor = Cursor(
        tokenPrefix: "mcur1:",
        version: 1,
        availability: .available,
        description: "Canonical base64url collaboration cursor emitted by bounded reads and accepted by handoffs."
    )
    let protocols = ProtocolContract(
        commandEnvelope: "urn:margin:cli:v1",
        commentsWatch: "urn:margin:comments-watch:v1",
        capabilities: "urn:margin:capabilities:v1",
        logicalMarkdown: "UTF-8 Markdown",
        metadataLocation: "ignorable terminal Margin envelope",
        networkRequired: false
    )
    let stageIntent = StageIntentContract()
    let commands: [CLICommandContract]
}

enum CLICapabilityWorkflow: String, CaseIterable, Encodable {
    case review
    case staging
    case suggestions
    case handoff
    case merge

    var summary: String {
        switch self {
        case .review: return "Bounded document review, threaded comments, and inbox triage."
        case .staging: return "Intent-plan creation, immutable stage inspection, refresh, and atomic submission."
        case .suggestions: return "Resilient source suggestions and explicit accept or reject decisions."
        case .handoff: return "Cursor-bound handoffs, collaborators, and outstanding work."
        case .merge: return "Read-only reconciliation analysis and explicit semantic merge output."
        }
    }

    func includes(_ path: [String]) -> Bool {
        let key = path.joined(separator: " ")
        let shared = Set(["capabilities"])
        let selected: Set<String>
        switch self {
        case .review:
            selected = Set([
                "slice", "review", "context", "inbox", "comments add", "comments list",
                "comments reply", "comments resolve",
            ])
        case .staging:
            selected = Set([
                "workspace init", "context",
                "stage create", "stage list", "stage show", "stage refresh", "stage discard",
                "stage submit",
            ])
        case .suggestions:
            selected = Set([
                "context", "inbox", "suggest add", "suggest list",
                "suggest accept", "suggest reject",
            ])
        case .handoff:
            selected = Set([
                "context", "collaborators", "inbox", "handoff add", "handoff list",
            ])
        case .merge:
            selected = Set(["context", "reconcile", "merge"])
        }
        return shared.contains(key) || selected.contains(key)
    }
}

struct CLICapabilitiesProjectionEnvelope: Encodable {
    struct Projection: Encodable {
        let workflow: CLICapabilityWorkflow
        let parentSchema = "urn:margin:capabilities:v1"
        let complete = false
        let description: String
    }

    static let maximumEncodedBytes = 32_768

    let schema = "urn:margin:capabilities-projection:v1"
    let ok = true
    let command = "capabilities"
    let contractVersion = 1
    let cli: CLICapabilitiesEnvelope.CLIIdentity
    let bounds = CLICapabilitiesEnvelope.Bounds(
        maxCommands: 24,
        maxOptionsPerCommand: 32,
        maxUsageFormsPerCommand: 4,
        maxEncodedBytes: maximumEncodedBytes
    )
    let projection: Projection
    let cursor: CLICapabilitiesEnvelope.Cursor
    let protocols: CLICapabilitiesEnvelope.ProtocolContract
    let stageIntent: CLICapabilitiesEnvelope.StageIntentContract?
    let commands: [CLICommandContract]
}

enum CLICommandCatalog {
    private static let json = option("--json", description: "Emit one JSON object instead of human-readable text.")
    private static let pretty = option("--pretty", description: "Pretty-print JSON output.")
    private static let commentJSON = option("--json", description: "Accepted for uniform invocation; comment commands always emit JSON.")
    private static let file = argument("FILE", kind: "markdown-file", description: "Existing Markdown file.")
    private static let commentID = argument("ID", kind: "annotation-id", description: "Bare UUID or full urn:uuid annotation identifier.")
    private static let messageOptions = [
        option("-m", "--message", "--body", value: "TEXT", description: "Inline Markdown message; the three names are aliases."),
        option("--message-file", value: "PATH", description: "Read the message from PATH; use - for standard input."),
        option("--stdin", description: "Read the message from standard input.")
    ]
    private static let actorOptions = [
        option("--actor-id", value: "IRI", description: "Stable human, software-agent, or organization identity."),
        option("--actor-name", value: "NAME", description: "Display name; defaults to the configured environment or user."),
        option(
            "--actor-type",
            value: "TYPE",
            choices: ["person", "software", "agent", "organization"],
            description: "Actor type; agent is an alias for software."
        )
    ]
    private static let preconditionOptions = [
        option("--if-revision", value: "N", description: "Require the current comment revision to equal N."),
        option("--if-content-sha", value: "SHA", description: "Require the current logical-Markdown SHA-256 digest.")
    ]
    private static let typedContributionOptions = [
        option("--kind", value: "KIND", choices: ["comment", "question", "issue", "decision", "task", "approval"], description: "Typed contribution kind; defaults to the backward-compatible comment path."),
        option("--assignee", value: "ACTOR_ID", description: "Task assignee; valid only with --kind task."),
        option("--priority", value: "PRIORITY", choices: ["low", "normal", "high", "urgent"], description: "Task priority; defaults to normal and is valid only with --kind task."),
        option("--audience", value: "ACTOR_ID", repeatable: true, description: "Intended actor audience; repeat for several actors."),
        option("--request-id", value: "ID", description: "Idempotency identity for the typed transaction path."),
        option("--stage-id", value: "ID", description: "Transaction stage identity; otherwise derived from request id.")
    ]
    private static let anchorOptions = [
        option("--quote", value: "EXACT", description: "Anchor to an exact passage."),
        option("--prefix", value: "TEXT", description: "Disambiguating text immediately before --quote."),
        option("--suffix", value: "TEXT", description: "Disambiguating text immediately after --quote."),
        option("--occurrence", value: "N", description: "One-based occurrence for a duplicate quote."),
        option("--range", value: "START:END", description: "Half-open Unicode-scalar offsets."),
        option("--from", value: "LINE:COL", description: "One-based grapheme start position; requires --to."),
        option("--to", value: "LINE:COL", description: "One-based grapheme end position; requires --from."),
        option("--expect", value: "EXACT", description: "Require exact text at a range before writing."),
        option("--document", description: "Create a document-level annotation.")
    ]
    private static let commentPresentationOptions = [commentJSON, pretty]
    private static let commentMutationOptions = actorOptions + preconditionOptions + commentPresentationOptions

    static let commands: [CLICommandContract] = {
        let cliJSON = CLIOutputContract(
            encoding: "json",
            framing: "single-object-lf",
            schema: "urn:margin:cli:v1",
            description: "One sorted-key command envelope followed by LF."
        )
        let text = CLIOutputContract(
            encoding: "text",
            framing: "utf8-lf",
            schema: nil,
            description: "UTF-8 human-readable text."
        )
        let noOutput = CLIOutputContract(
            encoding: "none",
            framing: "none",
            schema: nil,
            description: "No standard output on success."
        )
        let textOrCLIJSON = CLIOutputContract(
            encoding: "text-or-json",
            framing: "utf8-lf-or-single-object-lf",
            schema: "urn:margin:cli:v1",
            description: "Human-readable UTF-8 by default, or one command envelope with --json."
        )
        let commentsJSON = CLIOutputContract(
            encoding: "json",
            framing: "single-object-lf",
            schema: "urn:margin:cli:v1",
            description: "Comment commands always emit one sorted-key JSON object followed by LF."
        )
        var result: [CLICommandContract] = [
            command(
                "help",
                aliases: [["-h"], ["--help"]],
                summary: "Show global, command, or subcommand help from the static command catalog.",
                usage: ["margin help [COMMAND [SUBCOMMAND]]", "margin COMMAND --help"],
                arguments: [argument("COMMAND", kind: "command-path", required: false, description: "Optional command or subcommand path.")],
                output: text
            ),
            command(
                "man",
                summary: "Teach Margin's safe human-agent workflows through concise progressive manual pages.",
                usage: ["margin man [TOPIC]", "margin man --list"],
                arguments: [argument("TOPIC", kind: "manual-topic", required: false, description: "One of review, comments, suggestions, staging, handoff, merge, or safety.")],
                options: [option("--list", description: "List canonical manual topics without loading a page.")],
                output: text
            ),
            command(
                "version",
                aliases: [["-v"], ["--version"]],
                summary: "Print the Margin CLI version.",
                usage: ["margin version", "margin --version"],
                output: text
            ),
            command(
                "capabilities",
                summary: "Emit the full bounded command contract or a small workflow projection without filesystem access.",
                usage: ["margin capabilities --json [--pretty]", "margin capabilities --json --for WORKFLOW [--pretty]"],
                options: [requiredOption("--json", description: "Emit the capabilities contract."), option("--for", value: "WORKFLOW", choices: CLICapabilityWorkflow.allCases.map(\.rawValue), description: "Return only commands relevant to review, staging, suggestions, handoff, or merge."), pretty],
                output: CLIOutputContract(
                    encoding: "json",
                    framing: "single-object-lf",
                    schema: "urn:margin:capabilities:v1",
                    description: "A bounded static full contract or identified workflow projection followed by LF."
                )
            ),
            command(
                "open",
                summary: "Open files or directories in Margin; this command is implicit for path-first invocation.",
                usage: ["margin open [FILE|DIRECTORY ...] [--wait]", "margin FILE|DIRECTORY ... [--wait]"],
                arguments: [argument("FILE_OR_DIRECTORY", kind: "path", required: false, variadic: true, description: "Path to open; a missing file is created when its parent exists.")],
                options: [option("--wait", description: "Wait until the opened Margin window closes."), option("--app", value: "PATH", description: "Use an explicit Margin application bundle path.")],
                sideEffects: "launches-application",
                output: noOutput
            ),
            command(
                "inspect",
                summary: "Inspect revision, size, outline, thread counts, and anchor health.",
                usage: ["margin inspect FILE [--json] [--pretty]"],
                arguments: [file],
                options: [json, pretty],
                sideEffects: "reads-file",
                output: textOrCLIJSON
            ),
            command(
                "outline",
                summary: "List stable heading identifiers and section line ranges.",
                usage: ["margin outline FILE [--json] [--pretty]"],
                arguments: [file],
                options: [json, pretty],
                sideEffects: "reads-file",
                output: textOrCLIJSON
            ),
            command(
                "read",
                aliases: [["show"], ["cat"]],
                summary: "Read literal Markdown with the terminal Margin metadata envelope removed.",
                usage: [
                    "margin read FILE [--json] [--with-comments] [--pretty]",
                    "margin show FILE [--json] [--with-comments] [--pretty]",
                    "margin cat FILE [--json] [--with-comments] [--pretty]",
                ],
                arguments: [file],
                options: [json, option("--with-comments", description: "Include the comment snapshot in JSON output."), pretty],
                sideEffects: "reads-file",
                output: textOrCLIJSON
            ),
            command(
                "slice",
                summary: "Read one bounded passage selected by lines, heading, or comment.",
                usage: ["margin slice FILE (--lines RANGE | --heading NAME | --comment ID) [--context N] [--json] [--pretty]"],
                arguments: [file],
                options: [
                    option("--lines", value: "RANGE", description: "One-based LINE:COL-LINE:COL range."),
                    option("--heading", value: "NAME", description: "Heading title or stable heading id."),
                    option("--comment", value: "ID", description: "Annotation ID whose resolved anchor selects the passage."),
                    option("--context", value: "N", description: "Add N surrounding lines; must be nonnegative."),
                    json,
                    pretty
                ],
                sideEffects: "reads-file",
                output: textOrCLIJSON
            ),
            command(
                "review",
                summary: "Return bounded outline, thread groups, excerpts, anchor health, and revision.",
                usage: ["margin review FILE [--json] [--since-revision N] [--pretty]"],
                arguments: [file],
                options: [option("--json", description: "Accepted for uniform invocation; review always emits JSON."), option("--since-revision", value: "N", description: "Return a not-modified projection when possible."), pretty],
                sideEffects: "reads-file",
                output: cliJSON
            ),
            command(
                "comments",
                aliases: [["comment"]],
                summary: "Read and mutate portable W3C Annotation comment threads.",
                usage: ["margin comments COMMAND ...", "margin comment COMMAND ..."],
                output: commentsJSON
            ),
            command(
                "comments", "add",
                summary: "Start a new passage- or document-level thread. To answer an existing thread, use comments reply instead.",
                usage: ["margin comments add FILE (-m TEXT | --message-file PATH | --stdin) ANCHOR [--kind KIND] [TYPED_OPTIONS] [MUTATION_OPTIONS]"],
                arguments: [file],
                options: messageOptions + anchorOptions + typedContributionOptions + [option("--id", value: "UUID", description: "Client-chosen annotation UUID and idempotency identity.")] + commentMutationOptions,
                sideEffects: "mutates-file",
                output: commentsJSON
            ),
            command(
                "comments", "list",
                summary: "List comment annotations, optionally filtered by status or thread.",
                usage: ["margin comments list FILE [--status open|resolved|all] [--thread ID] [--pretty]"],
                arguments: [file],
                options: [option("--status", value: "STATUS", choices: ["open", "resolved", "all"], description: "Filter by thread status; defaults to open."), option("--thread", value: "ID", description: "Return one complete thread."), commentJSON, pretty],
                sideEffects: "reads-file",
                output: commentsJSON
            ),
            command(
                "comments", "get",
                summary: "Get one annotation and its resolved anchor state.",
                usage: ["margin comments get FILE ID [--pretty]"],
                arguments: [file, commentID],
                options: commentPresentationOptions,
                sideEffects: "reads-file",
                output: commentsJSON
            ),
            command(
                "comments", "reply",
                summary: "Reply to any annotation in a comment tree. A reply never resolves the root thread; run comments resolve separately when the concern is closed.",
                usage: ["margin comments reply FILE PARENT (-m TEXT | --message-file PATH | --stdin) [--reopen] [MUTATION_OPTIONS]"],
                arguments: [file, argument("PARENT", kind: "annotation-id", description: "Parent annotation UUID or urn:uuid identifier.")],
                options: messageOptions + [option("--reopen", description: "Reopen the root thread while replying."), option("--id", value: "UUID", description: "Client-chosen annotation UUID and idempotency identity.")] + commentMutationOptions,
                sideEffects: "mutates-file",
                output: commentsJSON
            ),
            command(
                "comments", "edit",
                summary: "Edit a comment body while preserving identity, creator, anchor, and tree position.",
                usage: ["margin comments edit FILE ID (-m TEXT | --message-file PATH | --stdin) [MUTATION_OPTIONS]"],
                arguments: [file, commentID],
                options: messageOptions + commentMutationOptions,
                sideEffects: "mutates-file",
                output: commentsJSON
            ),
            command(
                "comments", "delete",
                summary: "Delete a leaf comment or, with explicit consent, its subtree.",
                usage: ["margin comments delete FILE ID [--subtree] [PRECONDITIONS]"],
                arguments: [file, commentID],
                options: [option("--subtree", description: "Delete the selected annotation and every descendant.")] + preconditionOptions + commentPresentationOptions,
                sideEffects: "mutates-file",
                output: commentsJSON
            ),
            statusCommand("resolve", summary: "Resolve the root thread containing an annotation.", output: commentsJSON),
            statusCommand("reopen", summary: "Reopen the root thread containing an annotation.", output: commentsJSON),
            command(
                "comments", "reanchor",
                summary: "Replace a root comment's text anchor.",
                usage: ["margin comments reanchor FILE ID TEXT_ANCHOR [PRECONDITIONS]"],
                arguments: [file, commentID],
                options: Array(anchorOptions.dropLast()) + preconditionOptions + commentPresentationOptions,
                sideEffects: "mutates-file",
                output: commentsJSON
            ),
            command(
                "comments", "validate",
                summary: "Validate the embedded comment envelope and anchor protocol state.",
                usage: ["margin comments validate FILE [--pretty]"],
                arguments: [file],
                options: commentPresentationOptions,
                sideEffects: "reads-file",
                output: commentsJSON
            ),
            command(
                "comments", "export",
                summary: "Export the annotation page as JSON-LD.",
                usage: ["margin comments export FILE [--format jsonld] [--pretty]"],
                arguments: [file],
                options: [option("--format", value: "FORMAT", choices: ["jsonld"], description: "Export format; defaults to jsonld."), commentJSON, pretty],
                sideEffects: "reads-file",
                output: CLIOutputContract(encoding: "jsonld", framing: "single-object-lf", schema: "http://www.w3.org/ns/anno.jsonld", description: "One W3C AnnotationPage followed by LF.")
            ),
            command(
                "comments", "watch",
                summary: "Stream bounded comment-state changes until interrupted.",
                usage: ["margin comments watch FILE --jsonl [--since-revision N]"],
                arguments: [file],
                options: [requiredOption("--jsonl", description: "Required JSON Lines event stream."), option("--since-revision", value: "N", description: "Seed ready/change semantics from a known nonnegative revision.")],
                sideEffects: "watches-file",
                output: CLIOutputContract(encoding: "jsonl", framing: "one-object-per-line", schema: "urn:margin:comments-watch:v1", description: "Bounded snapshot/ready, change, error, reconnect, and stopped events.")
            )
        ]

        result.append(contentsOf: collaborationCommands(output: cliJSON))
        return result
    }()

    static let topLevelAliases: [String: String] = [
        "comment": "comments",
        "show": "read",
        "cat": "read",
        "-h": "help",
        "--help": "help",
        "-v": "version",
        "--version": "version"
    ]

    static func canonicalTopLevel(_ value: String) -> String {
        topLevelAliases[value] ?? value
    }

    static func command(path: [String]) -> CLICommandContract? {
        let normalized = normalized(path)
        return commands.first { $0.path == normalized || $0.aliases.contains(normalized) }
    }

    static func capabilities(cliVersion: String) -> CLICapabilitiesEnvelope {
        CLICapabilitiesEnvelope(
            cli: .init(name: "margin", version: cliVersion),
            commands: commands
        )
    }

    static func capabilitiesProjection(
        cliVersion: String,
        workflow: CLICapabilityWorkflow
    ) -> CLICapabilitiesProjectionEnvelope {
        let full = capabilities(cliVersion: cliVersion)
        return CLICapabilitiesProjectionEnvelope(
            cli: full.cli,
            projection: .init(workflow: workflow, description: workflow.summary),
            cursor: full.cursor,
            protocols: full.protocols,
            stageIntent: workflow == .staging ? full.stageIntent : nil,
            commands: full.commands.filter { workflow.includes($0.path) }
        )
    }

    static func localHelp(path: [String]) -> String? {
        guard let command = command(path: path) else { return nil }
        var sections: [String] = [command.displayPath.uppercased(), "", command.summary]
        if command.availability == .unsupported {
            sections += ["", "AVAILABILITY", "  Unsupported in this build. \(command.unavailableReason ?? "No handler is installed.")"]
        }
        sections += ["", "USAGE"]
        sections += command.usage.map { "  \($0)" }
        if !command.aliases.isEmpty {
            sections += ["", "ALIASES"]
            sections += command.aliases.map { "  \((["margin"] + $0).joined(separator: " "))" }
        }
        if !command.arguments.isEmpty {
            sections += ["", "ARGUMENTS"]
            sections += command.arguments.map { argument in
                let cardinality = argument.variadic ? " (repeatable)" : argument.required ? "" : " (optional)"
                return "  \(argument.name)\(cardinality)  \(argument.description)"
            }
        }
        if !command.options.isEmpty {
            sections += ["", "OPTIONS"]
            sections += command.options.map { option in
                var signature = option.names.joined(separator: ", ")
                if let value = option.value { signature += " \(value)" }
                if option.required { signature += " (required)" }
                return "  \(signature)\n      \(option.description)"
            }
        }
        sections += ["", "OUTPUT", "  \(command.output.description)"]
        return sections.joined(separator: "\n")
    }

    private static func normalized(_ path: [String]) -> [String] {
        guard let first = path.first else { return path }
        return [canonicalTopLevel(first)] + path.dropFirst()
    }

    private static func collaborationCommands(output: CLIOutputContract) -> [CLICommandContract] {
        let target = argument("TARGET", kind: "file-or-directory", description: "Existing Markdown file or explicit directory root.")
        let root = argument("ROOT", kind: "file-or-directory", description: "Existing document or directory collaboration root.")
        let presentation = [option("--json", description: "Accepted for uniform invocation; collaboration commands always emit JSON."), pretty]
        let selection = [
            option("--root", value: "DIRECTORY", description: "Use an explicit directory boundary instead of workspace discovery."),
            option("--path", value: "RELATIVE_PATH", repeatable: true, description: "Select a root-relative Markdown path; repeat to select several."),
            option("--max-files", value: "N", description: "Bound discovered Markdown files; defaults to 128."),
            option("--max-bytes", value: "N", description: "Bound total discovered file bytes; defaults to 16777216."),
            option("--max-depth", value: "N", description: "Bound directory traversal depth; defaults to 32."),
            option("--max-headings", value: "N", description: "Bound headings returned per file; defaults to 32."),
            option("--max-contributions", value: "N", description: "Bound contributions returned per file after command filters; defaults to 64."),
            option("--max-preview-bytes", value: "N", description: "Bound each contribution body preview; defaults to 240 bytes.")
        ]
        let mutationTarget = [
            option("--root", value: "DIRECTORY", description: "Use an explicit directory collaboration boundary."),
            option("--path", value: "RELATIVE_PATH", description: "Required for a directory TARGET; inferred for a file TARGET.")
        ]
        let identities = [
            option("--request-id", value: "ID", description: "Idempotency identity; derived transaction identities remain stable across retries."),
            option("--stage-id", value: "ID", description: "Explicit stage identity; otherwise derived from the request id.")
        ]
        let fileOrStdin = argument("JSON_OR_-", kind: "json-file-or-stdin", description: "JSON file path, or - for standard input.")
        let workspaceAndReadCommands: [CLICommandContract] = [
            command(
                "workspace",
                summary: "Initialize or inspect a portable directory collaboration workspace.",
                usage: ["margin workspace COMMAND ..."],
                arguments: [argument("COMMAND", kind: "subcommand", description: "init or show.")],
                output: output
            ),
            command(
                "workspace", "init",
                summary: "Create a canonical .margin/workspace.json without replacing conflicting metadata.",
                usage: ["margin workspace init DIRECTORY [--id ID] [--include GLOB ...] [--exclude GLOB ...] [--pretty]"],
                arguments: [argument("DIRECTORY", kind: "directory", description: "Existing directory to initialize.")],
                options: [option("--id", value: "ID", description: "Stable workspace identifier; defaults to a new urn:uuid."), option("--include", value: "GLOB", repeatable: true, description: "Relative Markdown inclusion pattern; safe Markdown defaults apply when omitted."), option("--exclude", value: "GLOB", repeatable: true, description: "Relative exclusion pattern; build, VCS, node_modules, and vendor defaults apply when omitted.")] + presentation,
                sideEffects: "creates-workspace-manifest",
                output: output
            ),
            command(
                "workspace", "show",
                summary: "Show the validated workspace root and manifest.",
                usage: ["margin workspace show DIRECTORY [--pretty]"],
                arguments: [argument("DIRECTORY", kind: "directory", description: "Initialized workspace directory.")],
                options: presentation,
                sideEffects: "reads-workspace-manifest",
                output: output
            ),
            command(
                "context",
                summary: "Return bounded context with root thread IDs, current revisions, exact available command paths, argument guidance, and an mcur1 cursor.",
                usage: ["margin context TARGET [--json] [SELECTION_OPTIONS] [--pretty]"],
                arguments: [target],
                options: selection + [option("--json", description: "Accepted for uniform invocation; context always emits JSON."), pretty],
                sideEffects: "reads-selected-files",
                output: output
            ),
            command(
                "collaborators",
                summary: "Project durable collaborator identities and activity from bounded context.",
                usage: ["margin collaborators TARGET [SELECTION_OPTIONS] [--pretty]"],
                arguments: [target],
                options: selection + presentation,
                sideEffects: "reads-selected-files",
                output: output
            ),
            command(
                "inbox",
                summary: "Filter contribution work first, then return a bounded result with matching omissions.",
                usage: ["margin inbox TARGET [--status open|resolved|all] [--kind KIND ...] [SELECTION_OPTIONS] [--pretty]"],
                arguments: [target],
                options: [option("--status", value: "STATUS", choices: ["open", "resolved", "all"], description: "Filter by root thread status; defaults to open."), option("--kind", value: "KIND", repeatable: true, choices: CollaborationContributionKind.allCases.map(\.rawValue), description: "Filter by typed contribution kind."), option("--actor", value: "ID", description: "Filter by creator actor id."), option("--assignee", value: "ID", description: "Filter by assignee actor id.")] + selection + presentation,
                sideEffects: "reads-selected-files",
                output: output
            )
        ]
        let stageCommands: [CLICommandContract] = [
            command(
                "stage",
                summary: "Create, inspect, refresh, discard, or atomically submit immutable change sets.",
                usage: ["margin stage COMMAND ..."],
                arguments: [argument("COMMAND", kind: "subcommand", description: "create, list, show, refresh, discard, or submit.")],
                output: output
            ),
            command(
                "stage", "create",
                summary: "Capture one current cursor and turn a small intent plan into a canonical immutable change set.",
                usage: ["margin stage create ROOT --operations-file PLAN_JSON_OR_- [ACTOR_OPTIONS] [IDENTITY_OPTIONS] [--pretty]", "margin stage create ROOT --change-set-file CHANGESET_JSON_OR_- [--pretty]"],
                arguments: [root],
                options: [option("--operations-file", value: "PLAN_JSON_OR_-", description: "Primary one-of input: versioned intent-plan JSON path, or - for standard input."), option("--change-set-file", value: "CHANGESET_JSON_OR_-", description: "Advanced one-of input: import a complete serialized CollaborationChangeSet instead."), option("--id", value: "ID", description: "Change-set identity; otherwise derived from request id.")] + actorOptions + identities + presentation,
                sideEffects: "creates-immutable-stage",
                output: output
            ),
            command(
                "stage", "list",
                summary: "List bounded staged metadata without contribution bodies or file images.",
                usage: ["margin stage list ROOT [--limit N] [--max-bytes N] [--pretty]"],
                arguments: [root],
                options: [option("--limit", value: "N", description: "Maximum summaries to return; 0 to 4096, default 128."), option("--max-bytes", value: "N", description: "Maximum aggregate canonical stage bytes decoded; 0 to 268435456, default 67108864. Byte omissions are reported.")] + presentation,
                sideEffects: "reads-stages",
                output: output
            ),
            command(
                "stage", "show",
                summary: "Show bounded review previews and operation metadata without raw bodies or base64 file images.",
                usage: ["margin stage show ROOT STAGE_ID [--max-preview-bytes N] [--pretty]"],
                arguments: [root, argument("STAGE_ID", kind: "identifier", description: "Staged change-set identity.")],
                options: [option("--max-preview-bytes", value: "N", description: "Per-field UTF-8 preview budget; 0 to 4096, default 240. Aggregate output remains capped at 1 MiB.")] + presentation,
                sideEffects: "reads-stage",
                output: output
            ),
            command(
                "stage", "refresh",
                summary: "Create a new immutable stage against current metadata while preserving the prior stage and exact operation payloads.",
                usage: ["margin stage refresh ROOT STAGE_ID [--id NEW_STAGE_ID] [--pretty]"],
                arguments: [root, argument("STAGE_ID", kind: "identifier", description: "Prior immutable stage; retained unchanged.")],
                options: [option("--id", value: "NEW_STAGE_ID", description: "Caller-selected new immutable id; otherwise derived deterministically from the prior stage and current cursor.")] + presentation,
                sideEffects: "creates-new-immutable-stage-and-preserves-prior",
                output: output
            ),
            command(
                "stage", "discard",
                summary: "Remove one pending immutable stage; repeated discard is safe.",
                usage: ["margin stage discard ROOT STAGE_ID [--pretty]"],
                arguments: [root, argument("STAGE_ID", kind: "identifier", description: "Stage to remove.")],
                options: presentation,
                sideEffects: "removes-stage",
                output: output
            ),
            command(
                "stage", "submit",
                summary: "Evaluate and atomically submit a stage, then report transaction and cleanup outcomes separately.",
                usage: ["margin stage submit ROOT STAGE_ID [--pretty]"],
                arguments: [root, argument("STAGE_ID", kind: "identifier", description: "Stage to submit.")],
                options: presentation,
                sideEffects: "mutates-selected-files-and-removes-stage",
                output: output
            ),
            command(
                "transact",
                summary: "Advanced: evaluate and atomically submit a complete serialized change set.",
                usage: ["margin transact ROOT CHANGESET_JSON_OR_- [--pretty]"],
                arguments: [root, fileOrStdin],
                options: presentation,
                sideEffects: "mutates-selected-files",
                output: output
            )
        ]
        let contributionCommands: [CLICommandContract] = [
            command(
                "suggest",
                summary: "Create, list, accept, or reject source replacement suggestions.",
                usage: ["margin suggest COMMAND ..."],
                arguments: [argument("COMMAND", kind: "subcommand", description: "add, list, accept, or reject.")],
                output: output
            ),
            command(
                "suggest", "add",
                summary: "Add a resilient passage replacement suggestion with base provenance.",
                usage: ["margin suggest add TARGET (--quote EXACT [--prefix P --suffix S] [--occurrence N] | --range START:END | --from LINE:COL --to LINE:COL) [--expect TEXT] --replacement TEXT -m MESSAGE [OPTIONS]"],
                arguments: [target],
                options: mutationTarget + [option("--quote", value: "EXACT", description: "Resolve a unique exact passage without coordinate arithmetic."), option("--prefix", value: "TEXT", description: "Text immediately before --quote for disambiguation."), option("--suffix", value: "TEXT", description: "Text immediately after --quote for disambiguation."), option("--occurrence", value: "N", description: "One-based duplicate quote occurrence."), option("--range", value: "START:END", description: "Half-open Unicode-scalar range."), option("--from", value: "LINE:COL", description: "One-based grapheme start; requires --to."), option("--to", value: "LINE:COL", description: "One-based grapheme end; requires --from."), option("--expect", value: "TEXT", description: "Optional exact-match precondition; derived from the resolved passage when omitted."), requiredOption("--replacement", value: "TEXT", description: "Replacement logical Markdown."), option("--id", value: "ID", description: "Stable contribution and retry identity."), option("--audience", value: "ACTOR_ID", repeatable: true, description: "Intended actor audience.")] + messageOptions + actorOptions + identities + presentation,
                sideEffects: "mutates-file-metadata",
                output: output
            ),
            command(
                "suggest", "list",
                summary: "Filter suggestions first, then return a bounded result with matching omissions and an mcur1 cursor.",
                usage: ["margin suggest list TARGET [SELECTION_OPTIONS] [--pretty]"],
                arguments: [target],
                options: selection + presentation,
                sideEffects: "reads-selected-files",
                output: output
            ),
            suggestionDispositionCommand("accept", output: output, mutationTarget: mutationTarget, actor: actorOptions, identities: identities, presentation: presentation),
            suggestionDispositionCommand("reject", output: output, mutationTarget: mutationTarget, actor: actorOptions, identities: identities, presentation: presentation),
            command(
                "handoff",
                summary: "Record or list cursor-bound collaboration handoffs.",
                usage: ["margin handoff COMMAND ..."],
                arguments: [argument("COMMAND", kind: "subcommand", description: "add or list.")],
                output: output
            ),
            command(
                "handoff", "add",
                summary: "Record a handoff with start/finish cursors and explicit follow-up references.",
                usage: ["margin handoff add TARGET -m MESSAGE [HANDOFF_OPTIONS] [ACTOR_OPTIONS] [IDENTITY_OPTIONS]"],
                arguments: [target],
                options: mutationTarget + [option("--starting-cursor", value: "MCUR1", description: "Starting cursor; defaults to the captured current cursor and remains stable on fixed-id replay."), option("--finishing-cursor", value: "MCUR1", description: "Optional finishing cursor."), option("--touched", value: "ID", repeatable: true, description: "Touched annotation id."), option("--unresolved", value: "ID", repeatable: true, description: "Unresolved contribution or issue id."), option("--next-actor", value: "ID", repeatable: true, description: "Intended next actor id."), option("--audience", value: "ID", repeatable: true, description: "Intended audience actor id."), option("--id", value: "ID", description: "Stable handoff contribution and retry identity.")] + messageOptions + actorOptions + identities + presentation,
                sideEffects: "mutates-file-metadata",
                output: output
            ),
            command(
                "handoff", "list",
                summary: "Filter handoffs first, then return a bounded result with matching omissions and cursor tokens.",
                usage: ["margin handoff list TARGET [SELECTION_OPTIONS] [--pretty]"],
                arguments: [target],
                options: selection + presentation,
                sideEffects: "reads-selected-files",
                output: output
            )
        ]
        let recoveryCommands: [CLICommandContract] = [
            command(
                "reconcile",
                summary: "Analyze stale embedded anchors, or explicitly apply a chosen recovery policy.",
                usage: ["margin reconcile CURRENT --from PREVIOUS [--pretty]", "margin reconcile CURRENT --from PREVIOUS --apply --policy require-all|preserve-unresolved [--pretty]"],
                arguments: [argument("CURRENT", kind: "markdown-file", description: "Current out-of-band-edited file.")],
                options: [requiredOption("--from", value: "PREVIOUS", description: "Known-good previous Margin document."), option("--apply", description: "Mutate CURRENT; requires an explicit --policy."), option("--policy", value: "POLICY", choices: ["require-all", "preserve-unresolved"], description: "Required with --apply; strict or unresolved-preserving behavior.")] + presentation,
                sideEffects: "reads-files-or-explicitly-reconciles-current",
                output: output
            ),
            command(
                "merge",
                summary: "Semantically merge three Margin documents without emitting document bytes in JSON.",
                usage: ["margin merge BASE OURS THEIRS [--merged-body FILE] [--resolve ID=CHOICE ...] [--output PATH [--force]] [--pretty]"],
                arguments: [argument("BASE", kind: "markdown-file", description: "Base document."), argument("OURS", kind: "markdown-file", description: "Local document."), argument("THEIRS", kind: "markdown-file", description: "Incoming document.")],
                options: [option("--merged-body", value: "FILE", description: "Explicit UTF-8 logical Markdown chosen by an external text merge."), option("--resolve", value: "ID=CHOICE", repeatable: true, choices: ["base", "ours", "theirs", "delete"], description: "Resolve an annotation conflict by stable id."), option("--output", value: "PATH", description: "Create a new clean merge output; omitted for read-only analysis."), option("--force", description: "With --output, atomically replace an existing regular file.")] + presentation,
                sideEffects: "reads-inputs-and-optionally-writes-output",
                output: output
            )
        ]
        return workspaceAndReadCommands + stageCommands + contributionCommands + recoveryCommands
    }

    private static func suggestionDispositionCommand(
        _ name: String,
        output: CLIOutputContract,
        mutationTarget: [CLIOptionContract],
        actor: [CLIOptionContract],
        identities: [CLIOptionContract],
        presentation: [CLIOptionContract]
    ) -> CLICommandContract {
        command(
            "suggest", name,
            summary: "\(name.capitalized) a proposed suggestion through the shared semantic transaction evaluator.",
            usage: ["margin suggest \(name) TARGET ID [OPTIONS]"],
            arguments: [argument("TARGET", kind: "file-or-directory", description: "Target file or root."), argument("ID", kind: "contribution-id", description: "Suggestion contribution id.")],
            options: mutationTarget + actor + identities + presentation,
            sideEffects: name == "accept" ? "mutates-logical-markdown-and-metadata" : "mutates-file-metadata",
            output: output
        )
    }

    private static func statusCommand(
        _ name: String,
        summary: String,
        output: CLIOutputContract
    ) -> CLICommandContract {
        command(
            "comments", name,
            summary: summary,
            usage: ["margin comments \(name) FILE ID [MUTATION_OPTIONS]"],
            arguments: [file, commentID],
            options: commentMutationOptions,
            sideEffects: "mutates-file",
            output: output
        )
    }

    private static func command(
        _ path: String...,
        aliases: [[String]] = [],
        availability: CLICommandAvailability = .available,
        summary: String,
        usage: [String],
        arguments: [CLIArgumentContract] = [],
        options: [CLIOptionContract] = [],
        sideEffects: String = "none",
        output: CLIOutputContract,
        unavailableReason: String? = nil
    ) -> CLICommandContract {
        CLICommandContract(
            path: path,
            aliases: aliases,
            availability: availability,
            summary: summary,
            usage: usage,
            arguments: arguments,
            options: options,
            output: output,
            sideEffects: sideEffects,
            unavailableReason: unavailableReason
        )
    }

    private static func argument(
        _ name: String,
        kind: String,
        required: Bool = true,
        variadic: Bool = false,
        description: String
    ) -> CLIArgumentContract {
        CLIArgumentContract(
            name: name,
            kind: kind,
            required: required,
            variadic: variadic,
            description: description
        )
    }

    private static func option(
        _ names: String...,
        value: String? = nil,
        required: Bool = false,
        repeatable: Bool = false,
        choices: [String]? = nil,
        description: String
    ) -> CLIOptionContract {
        CLIOptionContract(
            names: names,
            value: value,
            required: required,
            repeatable: repeatable,
            choices: choices,
            description: description
        )
    }

    private static func requiredOption(
        _ name: String,
        value: String? = nil,
        description: String
    ) -> CLIOptionContract {
        option(name, value: value, required: true, description: description)
    }
}
