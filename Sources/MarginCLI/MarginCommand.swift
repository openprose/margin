import Darwin
import Foundation
import MarginCore

enum MarginCommand {
    static let version = "0.2.0"
    static let service = CommentService()
    static let reviewService = ReviewService()
    static let codec = EmbeddedCommentCodec()

    static func run(arguments: [String]) -> Int32 {
        let wantsJSON = arguments.contains("--json") || arguments.contains("--jsonl") ||
            arguments.first == "comments" || arguments.first == "comment"
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
        let command = try cursor.require("command or path")
        switch command {
        case "-h", "--help", "help":
            let topic = cursor.pop()
            try cursor.rejectRemaining()
            try CLIOutput.text(help(topic: topic))
        case "-v", "--version", "version":
            try cursor.rejectRemaining()
            try CLIOutput.text("Margin \(version)")
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
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
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
        guard cursor.takeFlag("--json") else {
            throw CLIError.usage("review requires --json so its bounded result is unambiguous for agents.")
        }
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
        let subcommand = try cursor.require("comments subcommand")
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
        case "help", "--help", "-h":
            try cursor.rejectRemaining()
            try CLIOutput.text(help(topic: "comments"))
        default:
            throw CLIError.usage("Unknown comments subcommand '\(subcommand)'. Run 'margin help comments'.")
        }
    }

    private static func commentsAdd(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let document = try loadDocument(file)
        let message = try takeMessage(cursor: &cursor)
        let creator = try takeActor(cursor: &cursor)
        let annotationID = try cursor.takeValue("--id")
        let preconditions = try takePreconditions(cursor: &cursor)
        let anchor = try takeAnchor(cursor: &cursor, body: document.body)
        try cursor.rejectRemaining()
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
        try CLIOutput.json(
            CommentCommandEnvelope(
                command: "comments.list",
                file: file.path,
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                contentSha256: snapshot.contentSha256,
                result: snapshot
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
        let reopen = cursor.takeFlag("--reopen")
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let parentID = try cursor.require("parent comment id")
        let message = try takeMessage(cursor: &cursor)
        let creator = try takeActor(cursor: &cursor)
        let annotationID = try cursor.takeValue("--id")
        let preconditions = try takePreconditions(cursor: &cursor)
        try cursor.rejectRemaining()
        let receipt = try service.reply(
            at: file,
            parentID: parentID,
            message: message,
            creator: creator,
            annotationID: annotationID,
            reopen: reopen,
            preconditions: preconditions
        )
        try writeCommentSuccess(command: "comments.reply", file: file, receipt: receipt, pretty: pretty)
    }

    private static func commentsEdit(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        let message = try takeMessage(cursor: &cursor)
        let editor = try takeActor(cursor: &cursor)
        let preconditions = try takePreconditions(cursor: &cursor)
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
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        let preconditions = try takePreconditions(cursor: &cursor)
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
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        let actor = try takeActor(cursor: &cursor)
        let preconditions = try takePreconditions(cursor: &cursor)
        try cursor.rejectRemaining()
        let receipt = resolved
            ? try service.resolve(at: file, id: id, actor: actor, preconditions: preconditions)
            : try service.reopen(at: file, id: id, actor: actor, preconditions: preconditions)
        try writeCommentSuccess(command: resolved ? "comments.resolve" : "comments.reopen", file: file, receipt: receipt, pretty: pretty)
    }

    private static func commentsReanchor(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let file = try PathResolver.existingFile(cursor.require("Markdown file"))
        let id = try cursor.require("comment id")
        let document = try loadDocument(file)
        let preconditions = try takePreconditions(cursor: &cursor)
        let anchor = try takeAnchor(cursor: &cursor, body: document.body, allowDocument: false)
        try cursor.rejectRemaining()
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
        try CLIOutput.json(
            CommentCommandEnvelope(
                command: command,
                file: file.path,
                documentID: receipt.documentID,
                revision: receipt.revision,
                contentSha256: receipt.contentSha256,
                result: receipt
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

    private static func takeAnchor(
        cursor: inout ArgumentCursor,
        body: String,
        allowDocument: Bool = true
    ) throws -> CommentAnchorInput {
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
        let projection = AnchorResolver.normalizedProjection(body)
        let startPoint = try TextSpan(parsing: "\(from)-\(from)").start
        let endPoint = try TextSpan(parsing: "\(to)-\(to)").start
        let startIndex = try TextCoordinates.index(for: startPoint, in: projection)
        let endIndex = try TextCoordinates.index(for: endPoint, in: projection)
        let startOffset = TextCoordinates.unicodeScalarOffset(of: startIndex, in: projection)
        let endOffset = TextCoordinates.unicodeScalarOffset(of: endIndex, in: projection)
        return .range(start: startOffset, end: endOffset, expectedExact: expected)
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

    private static func help(topic: String?) -> String {
        if topic == "comments" || topic == "comment" { return commentsHelp }
        if topic == "agents" { return agentHelp }
        return mainHelp
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

    AGENT READING
      inspect   Revision, size, outline, thread counts, and anchor health.
      outline   Stable heading ids and section line ranges.
      read      Literal Markdown body with Margin metadata removed.
      slice     A bounded passage by 1-based line/column range, heading, or comment.
      review    Bounded outline, thread groups, excerpts, anchor health, and revision.

    EXAMPLES
      margin architecture.md
      margin brief.md architecture.md
      margin new-draft.md        # creates an empty file when its parent exists
      margin .
      margin inspect architecture.md --json --pretty
      margin review architecture.md --json --since-revision 12
      margin slice architecture.md --heading "Failure modes" --context 2
      margin slice architecture.md --lines 20:1-45:1 --json
      margin help comments
      margin help agents

    Margin writes comment operations as one JSON object. Errors go to stderr and
    use stable codes and sysexits-compatible statuses.
    """

    static let commentsHelp = """
    MARGIN COMMENTS

      margin comments add FILE (-m TEXT | --message-file PATH | --stdin)
        (--quote EXACT [--prefix P --suffix S] [--occurrence N]
         | --range START:END [--expect EXACT]
         | --from LINE:COL --to LINE:COL [--expect EXACT]
         | --document)

      margin comments list FILE [--status open|resolved|all] [--thread ID]
      margin comments get FILE ID
      margin comments reply FILE PARENT (-m TEXT | --message-file PATH | --stdin) [--reopen]
      margin comments edit FILE ID (-m TEXT | --message-file PATH | --stdin)
      margin comments delete FILE ID [--subtree]
      margin comments resolve FILE ID
      margin comments reopen FILE ID
      margin comments reanchor FILE ID (--quote ... | --range ... | --from ... --to ...)
      margin comments validate FILE
      margin comments export FILE --format jsonld
      margin comments watch FILE --jsonl [--since-revision N]

    MUTATION OPTIONS
      --id UUID                 Idempotency key; becomes urn:uuid:UUID.
      --if-revision N          Compare-and-swap comment revision.
      --if-content-sha SHA     Refuse if Markdown content changed.
      --actor-id IRI           Stable human, agent, or organization identity.
      --actor-name NAME        Display name.
      --actor-type TYPE        person, software, or organization.
      --pretty                 Pretty-print JSON.

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

    static let agentHelp = """
    AGENT QUICKSTART

      1. margin review FILE --json
      2. margin slice FILE --heading HEADING --context 2
      3. margin comments watch FILE --jsonl --since-revision REVISION
      4. margin comments add FILE --quote "exact passage" -m "Finding" \\
           --actor-type software --actor-name "reviewer" --id UUID
      5. margin comments list FILE --status all --pretty

    Copy result.rootID from add into reply/resolve, and result.annotation.id into
    edit/delete. Both full urn:uuid values and bare UUIDs are accepted. Prefer
    --quote for resilient anchors, --id for retries, and compare-and-swap flags
    when several agents may write concurrently. Use document-level comments for
    synthesis that is not tied to one passage. The Markdown file is the only
    authority; no service or sidecar database is required.
    """
}
