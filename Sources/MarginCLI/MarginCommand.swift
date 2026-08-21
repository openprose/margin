import Foundation
import MarginCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum MarginCommand {
    static let version = "0.4.0"
    static let service = CommentService()
    static let reviewService = ReviewService()
    static let codec = EmbeddedCommentCodec()

    static func run(arguments: [String]) -> Int32 {
        let firstCommand = arguments.first.map(CLICommandCatalog.canonicalTopLevel)
        let wantsJSON = arguments.contains("--json") || arguments.contains("--jsonl") ||
            firstCommand == "comments" || firstCommand.map(CollaborationCLICommand.names.contains) == true
        do {
            try dispatch(arguments)
            return CLIExit.success.rawValue
        } catch let error as CLIError {
            CLIOutput.error(error, asJSON: wantsJSON)
            return error.exit.rawValue
        } catch let error as CommentProtocolError {
            let mapped = mapProtocolError(error)
            CLIOutput.error(mapped, asJSON: wantsJSON)
            return mapped.exit.rawValue
        } catch let error as CollaborationError {
            let mapped = mapCollaborationError(error)
            CLIOutput.error(mapped, asJSON: wantsJSON)
            return mapped.exit.rawValue
        } catch let error as ReconciliationError {
            let mapped = CLIError(error.code, error.localizedDescription, exit: .data)
            CLIOutput.error(mapped, asJSON: wantsJSON)
            return mapped.exit.rawValue
        } catch {
            let mapped = CLIError("INTERNAL_ERROR", error.localizedDescription, exit: .software)
            CLIOutput.error(mapped, asJSON: wantsJSON)
            return mapped.exit.rawValue
        }
    }

    private static func dispatch(_ arguments: [String]) throws {
        guard !arguments.isEmpty else {
            try AppLauncher.open(nil, wait: false, appOverride: nil)
            return
        }

        var cursor = ArgumentCursor(arguments)
        let rawCommand = try cursor.require("command or path")
        let command = CLICommandCatalog.canonicalTopLevel(rawCommand)

        if command != "comments", cursor.takeFlag(["--help", "-h"]) {
            var helpPath = [command]
            if let subcommand = cursor.first,
               CLICommandCatalog.command(path: [command, subcommand]) != nil {
                helpPath.append(subcommand)
            }
            guard let localHelp = help(path: helpPath, fallBackToMain: false) else {
                throw CLIError.usage("Unknown command '\(rawCommand)'. Run 'margin --help'.")
            }
            try CLIOutput.text(localHelp)
            return
        }

        switch command {
        case "help":
            let path = cursor.takeRemaining()
            try CLIOutput.text(help(path: path, fallBackToMain: true) ?? mainHelp)
        case "man":
            try runManual(&cursor)
        case "version":
            try cursor.rejectRemaining()
            try CLIOutput.text("Margin \(version)")
        case "capabilities":
            try runCapabilities(&cursor)
        case "open":
            try runOpen(&cursor)
        case "inspect":
            try runInspect(&cursor)
        case "outline":
            try runOutline(&cursor)
        case "read":
            try runRead(&cursor)
        case "slice":
            try runSlice(&cursor)
        case "review":
            try runReview(&cursor)
        case "comments", "comment":
            try runComments(&cursor)
        case let collaboration where CollaborationCLICommand.names.contains(collaboration):
            try CollaborationCLI.run(command: collaboration, cursor: &cursor)
        case "--wait":
            let appOverride = try cursor.takeValue("--app")
            let paths = try takeOpenPaths(&cursor, requiringOne: true)
            let items = try paths.map(PathResolver.openableItem)
            try AppLauncher.open(items, wait: true, appOverride: appOverride)
        default:
            guard !command.hasPrefix("-") else {
                throw CLIError.usage("Unknown option '\(command)'. Run 'margin --help'.")
            }
            let wait = cursor.takeFlag("--wait")
            let appOverride = try cursor.takeValue("--app")
            let paths = [command] + (try takeOpenPaths(&cursor, requiringOne: false))
            let items = try paths.map(PathResolver.openableItem)
            try AppLauncher.open(items, wait: wait, appOverride: appOverride)
        }
    }

    private static func runCapabilities(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        let brief = cursor.takeFlag("--brief")
        let rawWorkflow = try cursor.takeValue("--for")
        guard cursor.takeFlag("--json") else {
            throw CLIError.usage("capabilities requires --json. Run 'margin capabilities --help'.")
        }
        try cursor.rejectRemaining()
        if let rawWorkflow {
            guard let workflow = CLICapabilityWorkflow.parse(rawWorkflow) else {
                let choices = CLICapabilityWorkflow.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError.usage("--for must be one of: \(choices).")
            }
            if brief {
                try CLIOutput.json(
                    CLICommandCatalog.capabilitiesBriefProjection(
                        cliVersion: version,
                        workflow: workflow
                    ),
                    pretty: pretty,
                    maximumBytes: CLICapabilitiesBriefProjectionEnvelope.maximumEncodedBytes
                )
            } else {
                try CLIOutput.json(
                    CLICommandCatalog.capabilitiesProjection(cliVersion: version, workflow: workflow),
                    pretty: pretty,
                    maximumBytes: CLICapabilitiesProjectionEnvelope.maximumEncodedBytes
                )
            }
        } else {
            if brief {
                throw CLIError.usage("--brief requires --for WORKFLOW.")
            }
            try CLIOutput.json(
                CLICommandCatalog.capabilities(cliVersion: version),
                pretty: pretty,
                maximumBytes: CLICapabilitiesEnvelope.maximumEncodedBytes
            )
        }
    }

    private static func runManual(_ cursor: inout ArgumentCursor) throws {
        let json = cursor.takeFlag("--json")
        let pretty = cursor.takeFlag("--pretty")
        if pretty, !json {
            throw CLIError.usage("--pretty requires --json. Run 'margin man --help'.")
        }

        func write(
            kind: String,
            query: [String],
            content: String,
            contractPaths: [[String]],
            nextQueries: [[String]]
        ) throws {
            if json {
                try CLIOutput.json(
                    MarginManualEnvelope(
                        kind: kind,
                        query: query,
                        content: content,
                        contracts: contractPaths.compactMap(CLICommandCatalog.command(path:)),
                        nextQueries: nextQueries
                    ),
                    pretty: pretty,
                    maximumBytes: MarginManualEnvelope.maximumEncodedBytes
                )
            } else {
                try CLIOutput.text(content)
            }
        }

        let listOnly = cursor.takeFlag("--list")
        if listOnly {
            try cursor.rejectRemaining()
            try write(
                kind: "topic-list",
                query: [],
                content: MarginManual.topicList,
                contractPaths: [],
                nextQueries: MarginManual.canonicalTopics.map { [$0] }
            )
            return
        }

        let topics = cursor.takeRemaining()
        if topics.count > 1, let commandHelp = CLICommandCatalog.localHelp(path: topics) {
            try write(
                kind: "command-help",
                query: topics,
                content: commandHelp,
                contractPaths: [topics],
                nextQueries: []
            )
            return
        }
        let topic = topics.first
        guard topics.count <= 1, let page = MarginManual.page(for: topic) else {
            let choices = MarginManual.canonicalTopics.joined(separator: ", ")
            throw CLIError.usage(
                "Unknown manual topic or command '\(topics.joined(separator: " "))'. " +
                    "Choose a topic from: \(choices); or use 'margin man COMMAND SUBCOMMAND'. " +
                    "Run 'margin man --list' for topics."
            )
        }
        try write(
            kind: "workflow",
            query: topics,
            content: page,
            contractPaths: MarginManual.contractPaths(for: topic),
            nextQueries: MarginManual.nextQueries(for: topic)
        )
    }

    private static func runOpen(_ cursor: inout ArgumentCursor) throws {
        let wait = cursor.takeFlag("--wait")
        let appOverride = try cursor.takeValue("--app")
        let paths = try takeOpenPaths(&cursor, requiringOne: false)
        let items = try paths.map(PathResolver.openableItem)
        try AppLauncher.open(items, wait: wait, appOverride: appOverride)
    }

    private static func takeOpenPaths(
        _ cursor: inout ArgumentCursor,
        requiringOne: Bool
    ) throws -> [String] {
        var paths: [String] = []
        while let value = cursor.pop() {
            guard !value.hasPrefix("-") else {
                throw CLIError.usage("Unknown option '\(value)'. Run 'margin --help'.")
            }
            paths.append(value)
        }
        if requiringOne, paths.isEmpty {
            throw CLIError.usage("Missing file or directory.")
        }
        return paths
    }

    private static func runInspect(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        let json = cursor.takeFlag("--json")
        let fileArgument = try cursor.require("Markdown file")
        let file = try PathResolver.existingFile(fileArgument)
        try cursor.rejectRemaining()
        let document = try loadDocument(file)
        let comments = try service.list(at: file)
        let result = InspectionResult(
            document: DocumentInspection(path: file.path, body: document.body),
            documentID: comments.documentID,
            commentRevision: comments.revision,
            openThreads: Set(comments.comments.filter { $0.depth == 0 && $0.threadStatus == .open }.map(\.rootID)).count,
            resolvedThreads: Set(comments.comments.filter { $0.depth == 0 && $0.threadStatus == .resolved }.map(\.rootID)).count,
            annotations: comments.comments.count,
            ambiguousAnchors: comments.comments.filter { $0.depth == 0 && $0.anchor?.state == .ambiguous }.count,
            orphanedAnchors: comments.comments.filter { $0.depth == 0 && $0.anchor?.state == .orphaned }.count
        )
        if json {
            try CLIOutput.json(CommandEnvelope(command: "inspect", file: file.path, result: result), pretty: pretty)
        } else {
            try CLIOutput.text(humanInspection(result))
        }
    }

    private static func runOutline(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        let json = cursor.takeFlag("--json")
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        try cursor.rejectRemaining()
        let document = try loadDocument(file)
        let outline = MarkdownOutline(markdown: document.body)
        if json {
            try CLIOutput.json(CommandEnvelope(command: "outline", file: file.path, result: outline), pretty: pretty)
        } else if outline.headings.isEmpty {
            try CLIOutput.text("(no headings)")
        } else {
            let lines = outline.headings.map { heading in
                "\(String(repeating: "  ", count: max(0, heading.level - 1)))\(heading.title)  [\(heading.id), lines \(heading.line)-\(heading.sectionEndLine)]"
            }
            try CLIOutput.text(lines.joined(separator: "\n"))
        }
    }

    private static func runRead(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        let json = cursor.takeFlag("--json")
        let includeComments = cursor.takeFlag("--with-comments")
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        try cursor.rejectRemaining()
        let document = try loadDocument(file)
        if json {
            let comments = includeComments ? try service.list(at: file) : nil
            let result = ReadResult(
                body: document.body,
                revision: DocumentRevision(data: document.bodyData),
                comments: comments
            )
            try CLIOutput.json(CommandEnvelope(command: "read", file: file.path, result: result), pretty: pretty)
        } else {
            try FileHandle.standardOutput.write(contentsOf: document.bodyData)
        }
    }

    private static func runSlice(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        let json = cursor.takeFlag("--json")
        let context = try cursor.takeInt("--context") ?? 0
        guard context >= 0 else { throw CLIError.usage("--context must be nonnegative.") }
        let linesValue = try cursor.takeValue("--lines")
        let headingValue = try cursor.takeValue("--heading")
        let commentValue = try cursor.takeValue("--comment")
        let selectors = [linesValue, headingValue, commentValue].compactMap { $0 }
        guard selectors.count == 1 else {
            throw CLIError.usage("slice requires exactly one of --lines, --heading, or --comment.")
        }
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        try cursor.rejectRemaining()
        let document = try loadDocument(file)
        let slice: DocumentSlice

        if let linesValue {
            var span = try TextSpan(parsing: linesValue)
            span = try expanded(span, contextLines: context, in: document.body)
            slice = try DocumentSlice(body: document.body, range: span)
        } else if let headingValue {
            let outline = MarkdownOutline(markdown: document.body)
            guard let heading = outline.heading(matching: headingValue) else {
                throw CLIError.notFound("No heading matches '\(headingValue)'. Use 'margin outline \(file.path)'.")
            }
            slice = try DocumentSlice(body: document.body, heading: heading, contextLines: context)
        } else if let commentValue {
            let listed = try service.get(commentValue, at: file)
            guard let scalarRange = listed.anchor?.range else {
                throw CLIError("COMMENT_NOT_ANCHORED", "Comment '\(commentValue)' has no unambiguous text anchor.", exit: .data)
            }
            let projection = AnchorResolver.normalizedProjection(document.body)
            guard let start = TextCoordinates.index(atUnicodeScalarOffset: scalarRange.start, in: projection),
                  let end = TextCoordinates.index(atUnicodeScalarOffset: scalarRange.end, in: projection) else {
                throw CLIError("INVALID_ANCHOR", "Comment '\(commentValue)' points outside the document.", exit: .data)
            }
            var span = try TextCoordinates.span(for: start..<end, in: projection)
            span = try expanded(span, contextLines: context, in: projection)
            slice = try DocumentSlice(body: projection, range: span)
        } else {
            fatalError("validated selector")
        }

        if json {
            try CLIOutput.json(CommandEnvelope(command: "slice", file: file.path, result: slice), pretty: pretty)
        } else {
            try FileHandle.standardOutput.write(contentsOf: Data(slice.text.utf8))
            if !slice.text.hasSuffix("\n") { try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8)) }
        }
    }

    private static func runReview(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let sinceRevision = try cursor.takeInt("--since-revision")
        if let sinceRevision, sinceRevision < 0 {
            throw CLIError.usage("--since-revision must be nonnegative.")
        }
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        try cursor.rejectRemaining()
        let review = try reviewService.review(at: file, sinceRevision: sinceRevision)
        try CLIOutput.json(
            CommandEnvelope(command: "review", file: file.path, result: review),
            pretty: pretty
        )
    }

    private static func runComments(_ cursor: inout ArgumentCursor) throws {
        if let first = cursor.first, ["--help", "-h"].contains(first) {
            _ = cursor.pop()
            try cursor.rejectRemaining()
            try CLIOutput.text(commentsHelp)
            return
        }
        let subcommand = try cursor.require("comments subcommand")
        if subcommand == "suggest" {
            throw CLIError.usage(
                "'suggest' is a top-level command, not a comments subcommand. " +
                    "Run 'margin suggest add --help'."
            )
        }
        if subcommand == "help" {
            let topic = cursor.pop()
            try cursor.rejectRemaining()
            if let topic,
               let localHelp = help(path: ["comments", topic], fallBackToMain: false) {
                try CLIOutput.text(localHelp)
            } else {
                try CLIOutput.text(commentsHelp)
            }
            return
        }
        if cursor.takeFlag(["--help", "-h"]) {
            guard let localHelp = help(path: ["comments", subcommand], fallBackToMain: false) else {
                throw CLIError.usage("Unknown comments subcommand '\(subcommand)'. Run 'margin help comments'.")
            }
            try CLIOutput.text(localHelp)
            return
        }
        switch subcommand {
        case "add": try commentsAdd(&cursor)
        case "list": try commentsList(&cursor)
        case "get": try commentsGet(&cursor)
        case "reply": try commentsReply(&cursor)
        case "edit": try commentsEdit(&cursor)
        case "delete": try commentsDelete(&cursor)
        case "resolve": try commentsSetStatus(&cursor, resolved: true)
        case "reopen": try commentsSetStatus(&cursor, resolved: false)
        case "reanchor": try commentsReanchor(&cursor)
        case "validate": try commentsValidate(&cursor)
        case "export": try commentsExport(&cursor)
        case "watch": try commentsWatch(&cursor)
        default:
            throw CLIError.usage("Unknown comments subcommand '\(subcommand)'. Run 'margin help comments'.")
        }
    }

    private static func commentsAdd(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let requestedKind = (try cursor.takeValue("--kind") ?? "comment").lowercased()
        let rawKind = requestedKind == "finding" ? "issue" : requestedKind
        guard let kind = CollaborationContributionKind(rawValue: rawKind),
              [.comment, .question, .issue, .decision, .task, .approval].contains(kind) else {
            throw CLIError.usage("--kind must be comment, question, issue (or finding), decision, task, or approval; use suggest or handoff for those dedicated kinds.")
        }
        let assignee = try cursor.takeValue("--assignee")
        let rawPriority = try cursor.takeValue("--priority")
        let audience = try cursor.takeValues("--audience")
        let requestID = try cursor.takeValue("--request-id")
        let stageID = try cursor.takeValue("--stage-id")
        let parentID = try cursor.takeValue("--parent")
        let reopenParent = cursor.takeFlag("--reopen")
        let resolveParent = cursor.takeFlag("--resolve")
        guard !(reopenParent && resolveParent) else {
            throw CLIError.usage("A reply cannot combine --reopen and --resolve.")
        }
        if parentID == nil, reopenParent || resolveParent {
            throw CLIError.usage(
                "--reopen and --resolve apply only to replies. Add --parent PARENT, " +
                    "or use 'margin comments reply --help'."
            )
        }
        if kind != .task, assignee != nil || rawPriority != nil {
            throw CLIError.usage("--assignee and --priority apply only to --kind task.")
        }
        let priority: CollaborationPriority
        if let rawPriority {
            guard let value = CollaborationPriority(rawValue: rawPriority.lowercased()) else {
                throw CLIError.usage("--priority must be low, normal, high, or urgent.")
            }
            priority = value
        } else {
            priority = .normal
        }
        let message = try takeMessage(cursor: &cursor)
        let creator = try takeActor(cursor: &cursor)
        let annotationID = try cursor.takeValue(["--id", "--contribution-id", "--mutation-id"])
        let preconditions = try takePreconditions(cursor: &cursor)
        if let parentID {
            guard kind == .comment,
                  assignee == nil,
                  rawPriority == nil,
                  audience.isEmpty,
                  requestID == nil,
                  stageID == nil else {
                throw CLIError.usage(
                    "--parent is reply shorthand and cannot be combined with typed-contribution options."
                )
            }
            let file = try PathResolver.existingFile(cursor.require("Markdown file"))
            try cursor.rejectRemaining()
            let receipt = try service.reply(
                at: file,
                parentID: parentID,
                message: message,
                creator: creator,
                annotationID: annotationID,
                reopen: reopenParent,
                resolveAfterReply: resolveParent,
                preconditions: preconditions
            )
            try writeCommentSuccess(
                command: "comments.reply",
                file: file,
                receipt: receipt,
                pretty: pretty
            )
            return
        }
        let anchorArguments = try takeAnchorArguments(cursor: &cursor)
        let fileArgument = try cursor.require("Markdown file")
        let file = try PathResolver.existingFile(fileArgument)
        try cursor.rejectRemaining()
        let document = try loadDocument(file)
        let anchor = try anchorArguments.resolve(in: document.body)
        let useTypedTransaction = kind != .comment || !audience.isEmpty || requestID != nil || stageID != nil
        if useTypedTransaction {
            let range: UnicodeScalarRange?
            switch try AnchorResolver().target(
                for: anchor,
                documentID: document.envelope?.document.id ?? MarginID.document(),
                in: document.body
            ) {
            case .resource:
                range = nil
            case .selection(let target):
                range = try AnchorResolver().resolve(target, in: document.body).range
            }
            try CollaborationCLI.addTypedContribution(
                file: file,
                fileArgument: fileArgument,
                message: message,
                creator: creator,
                kind: kind,
                range: range,
                assignee: assignee,
                priority: priority,
                audience: audience,
                annotationID: annotationID,
                requestID: requestID,
                stageID: stageID,
                expectedBaseContentSha256: DocumentRevision(data: document.bodyData).sha256,
                preconditions: preconditions,
                pretty: pretty
            )
            return
        }
        let receipt = try service.add(
            at: file,
            message: message,
            creator: creator,
            anchor: anchor,
            annotationID: annotationID,
            preconditions: preconditions
        )
        try writeCommentSuccess(command: "comments.add", file: file, receipt: receipt, pretty: pretty)
    }

    private static func commentsList(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let status = try cursor.takeValue("--status") ?? "open"
        let requestedThread = try cursor.takeValue("--thread").map { MarginID.annotation($0) }
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        try cursor.rejectRemaining()
        guard ["open", "resolved", "all"].contains(status) else {
            throw CLIError.usage("--status must be open, resolved, or all.")
        }
        var snapshot = try service.list(at: file)
        let selectedRoot: String?
        if let requestedThread {
            guard let selected = snapshot.comments.first(where: { $0.annotation.id == requestedThread }) else {
                throw CommentProtocolError.commentNotFound(requestedThread)
            }
            selectedRoot = selected.rootID
        } else {
            selectedRoot = nil
        }
        snapshot.comments = snapshot.comments.filter { listed in
            let statusMatches = status == "all" || listed.threadStatus.rawValue == status
            let threadMatches = selectedRoot == nil || listed.rootID == selectedRoot
            return statusMatches && threadMatches
        }
        let openSelectedRoot = selectedRoot.flatMap { rootID in
            snapshot.comments.first { $0.rootID == rootID && $0.threadStatus == .open }?.rootID
        }
        let notice = openSelectedRoot.map { _ in
            "Verified thread is still open. If the task requires closure, resolve it with the concrete next action before declaring completion."
        }
        let nextActions = openSelectedRoot.map { rootID in
            [CommentNextAction(
                condition: "when the assigned task requires this verified thread to be resolved or closed",
                command: "comments resolve",
                arguments: [file.path, rootID, "--if-revision", String(snapshot.revision)]
            )]
        }
        try CLIOutput.json(
            CommentCommandEnvelope(
                command: "comments.list",
                file: file.path,
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                contentSha256: snapshot.contentSha256,
                result: snapshot,
                notice: notice,
                nextActions: nextActions
            ),
            pretty: pretty
        )
    }

    private static func commentsGet(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        try cursor.rejectRemaining()
        let listed = try service.get(id, at: file)
        let snapshot = try service.list(at: file)
        try CLIOutput.json(
            CommentCommandEnvelope(
                command: "comments.get",
                file: file.path,
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                contentSha256: snapshot.contentSha256,
                result: listed
            ),
            pretty: pretty
        )
    }

    private static func commentsReply(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        if try cursor.takeValue("--request-id") != nil {
            throw CLIError.usage(
                "--request-id belongs to handoff and staged transaction commands. " +
                    "For an idempotent comment reply, replace it with --id UUID " +
                    "(or --mutation-id UUID)."
            )
        }
        let reopen = cursor.takeFlag("--reopen")
        let resolveAfterReply = cursor.takeFlag("--resolve")
        guard !(reopen && resolveAfterReply) else {
            throw CLIError.usage("comments reply cannot combine --reopen and --resolve.")
        }
        let message = try takeMessage(cursor: &cursor)
        let creator = try takeActor(cursor: &cursor)
        let annotationID = try cursor.takeValue(["--id", "--mutation-id"])
        let preconditions = try takePreconditions(cursor: &cursor)
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let parentID = try cursor.require("parent comment id")
        try cursor.rejectRemaining()
        let receipt = try service.reply(
            at: file,
            parentID: parentID,
            message: message,
            creator: creator,
            annotationID: annotationID,
            reopen: reopen,
            resolveAfterReply: resolveAfterReply,
            preconditions: preconditions
        )
        try writeCommentSuccess(command: "comments.reply", file: file, receipt: receipt, pretty: pretty)
    }

    private static func commentsEdit(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let message = try takeMessage(cursor: &cursor)
        let editor = try takeActor(cursor: &cursor)
        let preconditions = try takePreconditions(cursor: &cursor)
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        try cursor.rejectRemaining()
        let receipt = try service.edit(
            at: file,
            id: id,
            message: message,
            editor: editor,
            preconditions: preconditions
        )
        try writeCommentSuccess(
            command: "comments.edit",
            file: file,
            documentID: receipt.documentID,
            revision: receipt.revision,
            contentSha256: receipt.contentSha256,
            result: receipt,
            pretty: pretty
        )
    }

    private static func commentsDelete(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let subtree = cursor.takeFlag("--subtree")
        let preconditions = try takePreconditions(cursor: &cursor)
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        try cursor.rejectRemaining()
        let receipt = try service.delete(
            at: file,
            id: id,
            subtree: subtree,
            preconditions: preconditions
        )
        try writeCommentSuccess(
            command: "comments.delete",
            file: file,
            documentID: receipt.documentID,
            revision: receipt.revision,
            contentSha256: receipt.contentSha256,
            result: receipt,
            pretty: pretty
        )
    }

    private static func commentsSetStatus(_ cursor: inout ArgumentCursor, resolved: Bool) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let actor = try takeActor(cursor: &cursor)
        let preconditions = try takePreconditions(cursor: &cursor)
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        try cursor.rejectRemaining()
        let receipt = resolved
            ? try service.resolve(at: file, id: id, actor: actor, preconditions: preconditions)
            : try service.reopen(at: file, id: id, actor: actor, preconditions: preconditions)
        try writeCommentSuccess(command: resolved ? "comments.resolve" : "comments.reopen", file: file, receipt: receipt, pretty: pretty)
    }

    private static func commentsReanchor(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let preconditions = try takePreconditions(cursor: &cursor)
        let anchorArguments = try takeAnchorArguments(cursor: &cursor, allowDocument: false)
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        try cursor.rejectRemaining()
        let document = try loadDocument(file)
        let anchor = try anchorArguments.resolve(in: document.body)
        let receipt = try service.reanchor(at: file, id: id, anchor: anchor, preconditions: preconditions)
        try writeCommentSuccess(command: "comments.reanchor", file: file, receipt: receipt, pretty: pretty)
    }

    private static func commentsValidate(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        try cursor.rejectRemaining()
        let validation = try service.validate(at: file)
        try CLIOutput.json(
            CommentCommandEnvelope(
                command: "comments.validate",
                file: file.path,
                documentID: nil,
                revision: validation.revision,
                contentSha256: validation.contentSha256,
                result: validation
            ),
            pretty: pretty
        )
    }

    private static func commentsExport(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let format = try cursor.takeValue("--format") ?? "jsonld"
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        try cursor.rejectRemaining()
        guard format == "jsonld" else { throw CLIError.usage("Only --format jsonld is supported.") }
        if let data = try service.exportJSONLD(at: file, prettyPrinted: pretty) {
            try FileHandle.standardOutput.write(contentsOf: data)
            try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
        } else {
            let empty = JSONValue.object([
                "@context": .string("http://www.w3.org/ns/anno.jsonld"),
                "type": .string("AnnotationPage"),
                "items": .array([])
            ])
            try CLIOutput.json(empty, pretty: pretty)
        }
    }

    private static func commentsWatch(_ cursor: inout ArgumentCursor) throws {
        guard cursor.takeFlag("--jsonl") else {
            throw CLIError.usage("comments watch requires --jsonl.")
        }
        let sinceRevision = try cursor.takeInt("--since-revision")
        if let sinceRevision, sinceRevision < 0 {
            throw CLIError.usage("--since-revision must be nonnegative.")
        }
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        try cursor.rejectRemaining()
        let session = CommentWatchSession(file: file)
        try session.run(sinceRevision: sinceRevision) { event in
            // Each write is one complete, sorted-key JSON object followed by LF.
            // Filesystem and protocol failures are represented by watch events.
            try? CLIOutput.json(event)
        }
    }

    private static func writeCommentSuccess(
        command: String,
        file: URL,
        receipt: CommentMutationReceipt,
        pretty: Bool
    ) throws {
        let nextActions: [CommentNextAction]?
        let notice: String?
        if command == "comments.reply" {
            if receipt.threadStatus == .resolved {
                notice = "Reply saved and the root thread resolved atomically. Verify the durable thread before declaring completion."
                nextActions = [
                    CommentNextAction(
                        condition: "always verify the durable resolved thread",
                        command: "comments list",
                        arguments: [file.path, "--thread", receipt.rootID, "--status", "all"]
                    ),
                ]
            } else {
                notice = "Reply saved; the root thread remains open. If the task says resolve or close, run comments resolve now, or use comments reply --resolve when the reply and closure should succeed together."
                nextActions = [
                    CommentNextAction(
                        condition: "when the task asks to resolve or close, or the reply addresses the concern",
                        command: "comments resolve",
                        arguments: [file.path, receipt.rootID, "--if-revision", String(receipt.revision)]
                    ),
                    CommentNextAction(
                        condition: "always verify the durable thread",
                        command: "comments list",
                        arguments: [file.path, "--thread", receipt.rootID, "--status", "all"]
                    ),
                ]
            }
        } else {
            notice = nil
            nextActions = nil
        }
        try CLIOutput.json(
            CommentCommandEnvelope(
                command: command,
                file: file.path,
                documentID: receipt.documentID,
                revision: receipt.revision,
                contentSha256: receipt.contentSha256,
                result: receipt,
                notice: notice,
                nextActions: nextActions
            ),
            pretty: pretty
        )
    }

    private static func writeCommentSuccess<Result: Encodable>(
        command: String,
        file: URL,
        documentID: String?,
        revision: Int,
        contentSha256: String,
        result: Result,
        pretty: Bool
    ) throws {
        try CLIOutput.json(
            CommentCommandEnvelope(
                command: command,
                file: file.path,
                documentID: documentID,
                revision: revision,
                contentSha256: contentSha256,
                result: result
            ),
            pretty: pretty
        )
    }

    private static func takeMessage(cursor: inout ArgumentCursor) throws -> String {
        let short = try cursor.takeValue("-m")
        let long = try cursor.takeValue("--message")
        let body = try cursor.takeValue("--body")
        let directValues = [short, long, body].compactMap { $0 }
        guard directValues.count <= 1 else { throw CLIError.usage("Use only one message option.") }
        let direct = directValues.first
        let messageFile = try cursor.takeValue("--message-file")
        let explicitStdin = cursor.takeFlag("--stdin")
        let choices = [direct != nil, messageFile != nil, explicitStdin].filter { $0 }.count
        guard choices <= 1 else {
            throw CLIError.usage("Use only one of -m/--message, --message-file, or --stdin.")
        }
        if let direct { return direct }
        if let messageFile {
            if messageFile == "-" { return try readStandardInput() }
            let url = PathResolver.resolved(messageFile)
            do { return try String(contentsOf: url, encoding: .utf8) }
            catch { throw CLIError("MESSAGE_READ_FAILED", "Could not read \(url.path): \(error.localizedDescription)", exit: .io) }
        }
        if explicitStdin || isatty(STDIN_FILENO) == 0 { return try readStandardInput() }
        throw CLIError.usage("A comment message is required. Use -m TEXT, --message-file PATH, or --stdin.")
    }

    private static func readStandardInput() throws -> String {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        guard let value = String(data: data, encoding: .utf8) else {
            throw CLIError("INVALID_STDIN", "Standard input is not valid UTF-8.", exit: .data)
        }
        return value.trimmingCharacters(in: .newlines)
    }

    private static func takeActor(cursor: inout ArgumentCursor) throws -> MarginActor {
        let environment = ProcessInfo.processInfo.environment
        let flagName = try cursor.takeValue("--actor-name")
        let name = flagName ?? environment["MARGIN_ACTOR_NAME"] ?? environment["USER"] ?? "Margin collaborator"
        let flagType = try cursor.takeValue("--actor-type")
        let typeRaw = (flagType ?? environment["MARGIN_ACTOR_TYPE"] ?? "person").lowercased()
        let type: MarginActorType
        switch typeRaw {
        case "person": type = .person
        case "software", "agent": type = .software
        case "organization": type = .organization
        default: throw CLIError("INVALID_ACTOR", "Actor type must be person, software, or organization.", exit: .configuration)
        }
        let defaultID = "urn:margin:\(typeRaw):\(slug(name))"
        let flagID = try cursor.takeValue("--actor-id")
        let id = flagID ?? environment["MARGIN_ACTOR_ID"] ?? defaultID
        return MarginActor(id: id, type: type, name: name)
    }

    private static func takePreconditions(cursor: inout ArgumentCursor) throws -> CommentMutationPreconditions {
        CommentMutationPreconditions(
            revision: try cursor.takeInt("--if-revision"),
            contentSha256: try cursor.takeValue("--if-content-sha")
        )
    }

    private static func takeAnchorArguments(
        cursor: inout ArgumentCursor,
        allowDocument: Bool = true
    ) throws -> AnchorArguments {
        let document = cursor.takeFlag("--document")
        let quote = try cursor.takeValue("--quote")
        let scalarRange = try cursor.takeValue("--range")
        let from = try cursor.takeValue("--from")
        let to = try cursor.takeValue("--to")
        let modes = [document, quote != nil, scalarRange != nil, from != nil || to != nil].filter { $0 }.count
        guard modes == 1 else {
            throw CLIError.usage("Choose exactly one anchor: --quote, --range, --from with --to, or --document.")
        }

        if document {
            guard allowDocument else { throw CLIError.usage("This command requires a text anchor.") }
            return .document
        }
        if let quote {
            return .quote(
                exact: quote,
                prefix: try cursor.takeValue("--prefix"),
                suffix: try cursor.takeValue("--suffix"),
                occurrence: try cursor.takeInt("--occurrence")
            )
        }
        let expected = try cursor.takeValue("--expect")
        if let scalarRange {
            let components = scalarRange.split(separator: ":", maxSplits: 1)
            guard components.count == 2,
                  let start = Int(components[0]),
                  let end = Int(components[1]) else {
                throw CLIError.usage("--range expects half-open Unicode-scalar offsets START:END.")
            }
            return .range(start: start, end: end, expectedExact: expected)
        }
        guard let from, let to else {
            throw CLIError.usage("--from and --to must be provided together as LINE:COLUMN.")
        }
        return .coordinates(from: from, to: to, expectedExact: expected)
    }

    private static func loadDocument(_ url: URL) throws -> EmbeddedCommentDocument {
        do { return try codec.decode(Data(contentsOf: url, options: .mappedIfSafe)) }
        catch let error as CommentProtocolError { throw error }
        catch { throw CLIError("FILE_READ_FAILED", "Could not read \(url.path): \(error.localizedDescription)", exit: .io) }
    }

    private static func expanded(_ span: TextSpan, contextLines: Int, in body: String) throws -> TextSpan {
        guard contextLines > 0 else { return span }
        let lineCount = TextCoordinates.lineCount(in: body)
        let startLine = max(1, span.start.line - contextLines)
        let endLine = min(lineCount, span.end.line + contextLines)
        let start = try TextCoordinates.index(for: TextPoint(line: endLine, column: 1), in: body)
        var end = start
        while end < body.endIndex, !body[end].isNewline { end = body.index(after: end) }
        let endColumn = body.distance(from: start, to: end) + 1
        return TextSpan(start: TextPoint(line: startLine, column: 1), end: TextPoint(line: endLine, column: endColumn))
    }

    private static func slug(_ value: String) -> String {
        let parts = value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
        return parts.joined().split(separator: "-").joined(separator: "-")
    }

    private static func mapProtocolError(_ error: CommentProtocolError) -> CLIError {
        let exit = CLIExit(rawValue: error.suggestedExitCode) ?? .data
        var details: [String: String]?
        if case .anchorAmbiguous(let candidates) = error {
            details = [
                "candidateCount": String(candidates.count),
                "ranges": candidates.map { "\($0.range.start):\($0.range.end)" }.joined(separator: ",")
            ]
        }
        return CLIError(error.code, error.localizedDescription, exit: exit, details: details)
    }

    private static func mapCollaborationError(_ error: CollaborationError) -> CLIError {
        let exit: CLIExit
        switch error {
        case .preconditionFailed, .lockTimeout:
            exit = .temporaryFailure
        case .stageNotFound:
            exit = .notFound
        case .io, .transactionFailed, .rollbackFailed, .recoveryFailed:
            exit = .io
        case .pathEscapesRoot, .symlinkNotAllowed:
            exit = .permission
        default:
            exit = .data
        }
        return CLIError(error.code, error.localizedDescription, exit: exit)
    }

    private static func humanInspection(_ result: InspectionResult) -> String {
        let document = result.document
        return """
        \(document.path)
        \(document.lines) lines, \(document.words) words, \(document.bytes) bytes
        revision \(document.revision.sha256)
        \(document.outline.headings.count) headings
        \(result.openThreads) open threads, \(result.resolvedThreads) resolved, \(result.annotations) annotations
        \(result.ambiguousAnchors) ambiguous anchors, \(result.orphanedAnchors) orphaned
        """
    }

    private static func help(path: [String], fallBackToMain: Bool) -> String? {
        guard !path.isEmpty else { return mainHelp }
        let normalized = path.enumerated().map { index, component in
            index == 0 ? CLICommandCatalog.canonicalTopLevel(component) : component
        }
        if normalized == ["comments"] { return commentsHelp }
        if normalized == ["agents"] { return MarginManual.overview }
        if let local = CLICommandCatalog.localHelp(path: normalized) { return local }
        return fallBackToMain ? mainHelp : nil
    }
}

private struct CommandEnvelope<Result: Encodable>: Encodable {
    let schema = "urn:margin:cli:v1"
    let ok = true
    let command: String
    let file: String
    let result: Result
}

private struct CommentCommandEnvelope<Result: Encodable>: Encodable {
    let schema = "urn:margin:cli:v1"
    let ok = true
    let command: String
    let file: String
    let documentID: String?
    let revision: Int
    let contentSha256: String
    let result: Result
    var notice: String? = nil
    var nextActions: [CommentNextAction]? = nil
}

private struct CommentNextAction: Encodable {
    let condition: String
    let command: String
    let arguments: [String]
    let argv: [String]

    init(condition: String, command: String, arguments: [String]) {
        self.condition = condition
        self.command = command
        self.arguments = arguments
        self.argv = command.split(separator: " ").map(String.init) + arguments
    }
}

private struct InspectionResult: Encodable {
    let document: DocumentInspection
    let documentID: String?
    let commentRevision: Int
    let openThreads: Int
    let resolvedThreads: Int
    let annotations: Int
    let ambiguousAnchors: Int
    let orphanedAnchors: Int
}

private struct ReadResult: Encodable {
    let body: String
    let revision: DocumentRevision
    let comments: CommentDocumentSnapshot?
}

private enum AnchorArguments {
    case document
    case quote(exact: String, prefix: String?, suffix: String?, occurrence: Int?)
    case range(start: Int, end: Int, expectedExact: String?)
    case coordinates(from: String, to: String, expectedExact: String?)

    func resolve(in body: String) throws -> CommentAnchorInput {
        switch self {
        case .document:
            return .document
        case .quote(let exact, let prefix, let suffix, let occurrence):
            return .quote(exact: exact, prefix: prefix, suffix: suffix, occurrence: occurrence)
        case .range(let start, let end, let expectedExact):
            return .range(start: start, end: end, expectedExact: expectedExact)
        case .coordinates(let from, let to, let expectedExact):
            let projection = AnchorResolver.normalizedProjection(body)
            let startPoint = try TextSpan(parsing: "\(from)-\(from)").start
            let endPoint = try TextSpan(parsing: "\(to)-\(to)").start
            let startIndex = try TextCoordinates.index(for: startPoint, in: projection)
            let endIndex = try TextCoordinates.index(for: endPoint, in: projection)
            let startOffset = TextCoordinates.unicodeScalarOffset(of: startIndex, in: projection)
            let endOffset = TextCoordinates.unicodeScalarOffset(of: endIndex, in: projection)
            return .range(start: startOffset, end: endOffset, expectedExact: expectedExact)
        }
    }
}

private extension MarginCommand {
    static let mainHelp = """
    Margin \(version), a fast native Markdown editor and human-agent review protocol.

    USAGE
      margin [FILE|DIRECTORY ...] [--wait]
      margin open [FILE|DIRECTORY ...] [--wait]
      margin inspect FILE [--json] [--pretty]
      margin outline FILE [--json] [--pretty]
      margin read FILE [--json] [--with-comments] [--pretty]
      margin slice FILE (--lines RANGE | --heading NAME | --comment ID) [--context N] [--json] [--pretty]
      margin review FILE --json [--since-revision N] [--pretty]
      margin comments COMMAND ...
      margin context FILE_OR_DIRECTORY --json [BOUNDS]
      margin workspace init|show ...
      margin collaborators|inbox FILE_OR_DIRECTORY ...
      margin stage create|list|show|refresh|discard|submit ...
      margin suggest add|batch|list|wait|accept|reject ...
      margin handoff add|list ...
      margin reconcile CURRENT --from PREVIOUS ...
      margin merge BASE OURS THEIRS ...
      margin capabilities --json --for review|staging|suggestions|handoff|merge --brief [--pretty]
      margin man [agents|review|comments|suggestions|staging|handoff|merge|safety] [--json]
      margin help [COMMAND [SUBCOMMAND]]

    LEARN MARGIN
      Agents with a known target should start with context TARGET --json --brief
      and act from its concrete workflowGuidance. Use margin man agents when the
      target or workflow is unclear, then at most one task-specific page.
      Use capabilities --json --for WORKFLOW --brief only when context does not
      expose the needed action and a small machine contract is useful.
      The unfiltered capabilities catalog is for integrations, not task orientation.
      margin COMMAND --help is the exact local grammar.

    AGENT READING
      inspect   Revision, size, outline, thread counts, and anchor health.
      outline   Stable heading ids and section line ranges.
      read      Literal Markdown body with Margin metadata removed.
      slice     A bounded passage by 1-based line/column range, heading, or comment.
      review    Bounded outline, thread groups, excerpts, anchor health, and revision.

    DISCOVERY
      capabilities --for WORKFLOW --brief gives the small machine-readable task index.
      COMMAND --help and COMMAND SUBCOMMAND --help show command-local grammar.
      context --brief is the compact agent entry; omit it only when a cursor,
      collaborator activity, or extended metadata is required.
      All collaboration commands are local and emit one JSON object.

    ALIASES
      comment = comments
      show = read
      cat = read
      -h = --help
      -v = --version

    EXAMPLES
      margin architecture.md
      margin brief.md architecture.md
      margin new-draft.md        # creates an empty file when its parent exists
      margin .
      margin inspect architecture.md --json --pretty
      margin review architecture.md --json --since-revision 12
      margin slice architecture.md --heading "Failure modes" --context 2
      margin slice architecture.md --lines 20:1-45:1 --json
      margin slice --help
      margin comments add --help
      margin context architecture.md --json --brief --max-files 1
      margin stage create . --operations-file plan.json
      margin suggest add architecture.md --quote "# Design" \
        --replacement "# Architecture" -m "Use the established term"
      margin suggest batch architecture.md --items-file suggestions.json
      margin suggest wait architecture.md UUID UUID --timeout 20
      margin capabilities --json --for review --brief
      margin man
      margin man staging
      margin man comments add --json
      margin help comments
      margin help agents

    Margin writes comment operations as one JSON object. Errors go to stderr and
    use stable codes and sysexits-compatible statuses.
    """

    static let commentsHelp = """
    MARGIN COMMENTS

      margin comments add FILE (-m TEXT | --message TEXT | --body TEXT | --message-file PATH | --stdin)
        (--quote EXACT [--prefix P --suffix S] [--occurrence N]
         | --range START:END [--expect EXACT]
         | --from LINE:COL --to LINE:COL [--expect EXACT]
         | --document)
        [--kind comment|question|issue|decision|task|approval]
        [--assignee ACTOR_ID] [--priority low|normal|high|urgent]
        [--audience ACTOR_ID ...]

      margin comments list FILE [--status open|resolved|all] [--thread ID]
      margin comments get FILE ID
      margin comments reply FILE PARENT (-m TEXT | --message TEXT | --body TEXT | --message-file PATH | --stdin) [--reopen | --resolve]
      margin comments edit FILE ID (-m TEXT | --message TEXT | --body TEXT | --message-file PATH | --stdin)
      margin comments delete FILE ID [--subtree]
      margin comments resolve FILE ID
      margin comments reopen FILE ID
      margin comments reanchor FILE ID (--quote ... | --range ... | --from ... --to ...)
      margin comments validate FILE
      margin comments export FILE --format jsonld
      margin comments watch FILE --jsonl [--since-revision N]

    DISCOVERY AND ORDERING
      Run margin comments COMMAND --help for the complete local contract.
      Named options may appear before, between, or after positionals. Positional
      arguments keep their documented relative order. comment is an alias for
      comments; -m, --message, and --body are message-option aliases.

    MUTATION OPTIONS
      --id, --mutation-id UUID  Idempotency key; becomes urn:uuid:UUID.
      --if-revision N          Compare-and-swap comment revision.
      --if-content-sha SHA     Refuse if Markdown content changed.
      --actor-id IRI           Stable human, agent, or organization identity.
      --actor-name NAME        Display name.
      --actor-type TYPE        person, software, or organization.
      --pretty                 Pretty-print JSON.

    TYPED CONTRIBUTIONS
      add defaults to the existing comment behavior. question, issue, decision,
      task, and approval use the shared collaboration transaction evaluator;
      task accepts --assignee and --priority. --audience is repeatable. Use the
      dedicated suggest and handoff commands for those provenance-rich kinds.

    EDIT AND DELETE
      edit preserves the comment id, creator, creation time, anchor, and tree
      position. Its receipt includes the previous annotation and an undo edit.
      delete removes a leaf by default. A comment with replies is rejected with
      COMMENT_HAS_REPLIES unless --subtree explicitly removes all descendants.
      Its receipt contains exact deleted annotations and their original indexes.

    WATCH
      watch emits one compact JSON object per line for snapshot/ready, change,
      recoverable error, reconnect, and stopped events. It observes atomic file
      replacement without polling and exits cleanly on SIGINT or SIGTERM.

    RANGES
      --range uses half-open Unicode code-point offsets in newline-normalized
      literal Markdown. --from/--to use 1-based grapheme line/column positions.
      --quote is safest across edits. Duplicate quotes require context or occurrence.

    IDS AND DIGESTS
      Mutation receipts return result.rootID and result.annotation.id as urn:uuid
      values. Later commands accept either the full urn:uuid value or its UUID.
      contentSha256 uses the sha256: prefix for compare-and-swap. Read/slice
      revision.sha256 is the same logical-Markdown digest without that prefix.

    Every comment command emits JSON. A thread is a W3C Annotation root; replies
    may target any annotation, so trees can be arbitrarily deep.
    """

}
