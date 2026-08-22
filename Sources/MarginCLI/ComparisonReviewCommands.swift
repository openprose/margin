import Foundation
import MarginCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum ComparisonReviewCommands {
    // A thread may contain 256 comments whose bounded identifiers, actors, and
    // previews still expand when JSON-escaped. Sixteen such worst-case threads
    // fit beneath maximumOutputBytes, including pretty-printing overhead.
    static let defaultMaximumThreads = 16
    static let maximumThreads = 16
    static let defaultMaximumBodyBytes = 512
    static let maximumBodyBytes = 512
    static let maximumOutputBytes = 32 * 1_024 * 1_024

    static func run(_ cursor: inout ArgumentCursor) throws {
        let subcommand = try cursor.require("compare comments subcommand")
        switch subcommand {
        case "list": try list(&cursor)
        case "add": try add(&cursor)
        case "reply": try reply(&cursor)
        case "resolve": try setStatus(.resolved, name: "resolve", cursor: &cursor)
        case "reopen": try setStatus(.open, name: "reopen", cursor: &cursor)
        default:
            throw CLIError.usage(
                "Unknown compare comments subcommand '\(subcommand)'. " +
                    "Choose list, add, reply, resolve, or reopen."
            )
        }
    }

    private static func list(_ cursor: inout ArgumentCursor) throws {
        let protectedPositionals = splitEndOfOptions(
            cursor: &cursor,
            valueOptions: [
                "--status", "--max-threads", "--max-body-bytes", "--after-thread",
                "--if-revision",
            ]
        )
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let statusRaw = try cursor.takeValue("--status") ?? "open"
        let status: MarginCommentStatus?
        switch statusRaw {
        case "open": status = .open
        case "resolved": status = .resolved
        case "all": status = nil
        default: throw CLIError.usage("--status must be open, resolved, or all.")
        }
        let maximumThreads = try boundedInteger(
            cursor.takeInt("--max-threads"),
            default: defaultMaximumThreads,
            maximum: Self.maximumThreads,
            option: "--max-threads",
            permitsZero: false
        )
        let maximumBodyBytes = try boundedInteger(
            cursor.takeInt("--max-body-bytes"),
            default: defaultMaximumBodyBytes,
            maximum: Self.maximumBodyBytes,
            option: "--max-body-bytes",
            permitsZero: true
        )
        let afterThread = try cursor.takeValue("--after-thread")
        let expectedRevision = try takeRevision(cursor: &cursor)
        let positionals = try takePositionals(
            cursor: &cursor,
            protected: protectedPositionals,
            expected: ["comparison review"]
        )
        let reviewURL = PathResolver.resolvedPreservingFinalComponent(positionals[0])

        let review = try ComparisonReviewStore().load(at: reviewURL)
        if let expectedRevision, review.revision != expectedRevision {
            throw ComparisonError.revisionConflict(
                expected: expectedRevision,
                actual: review.revision
            )
        }
        let matching = review.threads.filter { status == nil || $0.status == status }
        let start: Int
        if let afterThread {
            guard let index = matching.firstIndex(where: { $0.id == normalizeID(afterThread) }) else {
                throw CLIError(
                    "COMPARISON_THREAD_NOT_FOUND",
                    "No matching comparison thread has id '\(afterThread)'.",
                    exit: .notFound
                )
            }
            start = index + 1
        } else {
            start = 0
        }
        let end = min(matching.count, start + maximumThreads)
        let threads = matching[start..<end].map {
            ComparisonThreadProjection($0, maximumBodyBytes: maximumBodyBytes)
        }
        let nextArgv: [String]?
        if end < matching.count, let last = threads.last {
            var arguments = [
                "compare", "comments", "list", reviewURL.path,
                "--status", statusRaw,
                "--max-threads", String(maximumThreads),
                "--max-body-bytes", String(maximumBodyBytes),
                "--after-thread", last.id,
                "--if-revision", String(review.revision),
            ]
            if pretty { arguments.append("--pretty") }
            nextArgv = arguments
        } else {
            nextArgv = nil
        }
        try CLIOutput.json(
            ComparisonThreadListEnvelope(
                review: ComparisonReviewIdentity(review),
                reviewPath: reviewURL.path,
                status: statusRaw,
                total: matching.count,
                included: threads.count,
                omitted: matching.count - threads.count,
                truncated: start > 0 || end < matching.count,
                threads: threads,
                nextArgv: nextArgv
            ),
            pretty: pretty,
            maximumBytes: maximumOutputBytes
        )
    }

    private static func add(_ cursor: inout ArgumentCursor) throws {
        let protectedPositionals = splitEndOfOptions(
            cursor: &cursor,
            valueOptions: [
                "-m", "--message", "--body", "--message-file",
                "--actor-name", "--actor-type", "--actor-id", "--if-revision",
                "--id", "--comment-id", "--request-id", "--side", "--block",
                "--quote", "--range", "--from", "--to", "--occurrence", "--prefix",
                "--suffix", "--expect",
            ]
        )
        let pretty = presentation(cursor: &cursor)
        let message = try takeMessage(cursor: &cursor)
        let actor = try takeActor(cursor: &cursor)
        let expectedRevision = try takeRevision(cursor: &cursor)
        let rawID = try cursor.takeValue(["--id", "--comment-id", "--request-id"])
        let sideRaw = try cursor.takeValue("--side")
        let changedBlockID = try cursor.takeValue("--block")
        let anchorInput = try takeAnchor(cursor: &cursor)
        let positionals = try takePositionals(
            cursor: &cursor,
            protected: protectedPositionals,
            expected: ["comparison review"]
        )
        let reviewURL = PathResolver.resolvedPreservingFinalComponent(positionals[0])

        let store = ComparisonReviewStore()
        let current = try store.load(at: reviewURL)
        let side: ComparisonReviewSide
        let snapshot: ComparisonSnapshot
        switch sideRaw {
        case "left":
            side = .left
            snapshot = current.snapshots.left
        case "right":
            side = .right
            snapshot = current.snapshots.right
        case nil:
            throw CLIError.usage("compare comments add requires --side left or --side right.")
        default:
            throw CLIError.usage("--side must be left or right.")
        }
        if let changedBlockID {
            let result = try ComparisonEngine().compare(current.snapshots)
            guard result.changedBlocks.contains(where: { $0.id == changedBlockID }) else {
                throw CLIError(
                    "COMPARISON_BLOCK_NOT_FOUND",
                    "No changed comparison block has id '\(changedBlockID)'.",
                    exit: .notFound
                )
            }
        }
        let anchor = try ComparisonReviewAnchor(
            snapshot: snapshot,
            input: try anchorInput.resolve(in: snapshot.content)
        )
        let target = try ComparisonReviewTarget(
            side: side,
            left: side == .left ? anchor : nil,
            right: side == .right ? anchor : nil,
            changedBlockID: changedBlockID
        )
        let id = normalizeID(rawID ?? UUID().uuidString)
        let timestamp = now()
        let root = try ComparisonReviewComment(
            id: id,
            creator: actor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: message)
        )
        let thread = try ComparisonReviewThread(
            id: id,
            target: target,
            statusModified: timestamp,
            statusModifiedBy: actor,
            comments: [root]
        )
        let receipt: ComparisonReviewMutationReceipt
        if let existing = current.threads.first(where: { $0.id == id }) {
            guard semanticallyMatches(existing, new: thread) else {
                throw ComparisonError.idConflict(id)
            }
            receipt = unchangedReceipt(current)
        } else {
            do {
                receipt = try store.update(
                    at: reviewURL,
                    expectedRevision: expectedRevision ?? current.revision,
                    modified: timestamp
                ) { review in
                    try review.addThread(thread)
                }
            } catch ComparisonError.revisionConflict {
                let latest = try store.load(at: reviewURL)
                if let existing = latest.threads.first(where: { $0.id == id }) {
                    guard semanticallyMatches(existing, new: thread) else {
                        throw ComparisonError.idConflict(id)
                    }
                    receipt = unchangedReceipt(latest)
                } else {
                    throw ComparisonError.revisionConflict(
                        expected: expectedRevision ?? current.revision,
                        actual: latest.revision
                    )
                }
            }
        }
        let persisted = try requireThread(id, in: receipt.review)
        try writeMutation(
            command: "compare.comments.add",
            reviewURL: reviewURL,
            receipt: receipt,
            thread: persisted,
            pretty: pretty
        )
    }

    private static func reply(_ cursor: inout ArgumentCursor) throws {
        let protectedPositionals = splitEndOfOptions(
            cursor: &cursor,
            valueOptions: [
                "-m", "--message", "--body", "--message-file",
                "--actor-name", "--actor-type", "--actor-id", "--if-revision",
                "--id", "--comment-id", "--request-id",
            ]
        )
        let pretty = presentation(cursor: &cursor)
        let message = try takeMessage(cursor: &cursor)
        let actor = try takeActor(cursor: &cursor)
        let expectedRevision = try takeRevision(cursor: &cursor)
        let rawID = try cursor.takeValue(["--id", "--comment-id", "--request-id"])
        let positionals = try takePositionals(
            cursor: &cursor,
            protected: protectedPositionals,
            expected: ["comparison review", "parent comment id"]
        )
        let reviewURL = PathResolver.resolvedPreservingFinalComponent(positionals[0])
        let parentID = normalizeID(positionals[1])

        let store = ComparisonReviewStore()
        let current = try store.load(at: reviewURL)
        guard let currentThread = current.threads.first(where: {
            $0.comments.contains(where: { $0.id == parentID })
        }) else {
            throw CLIError(
                "COMPARISON_COMMENT_NOT_FOUND",
                "No comparison comment has id '\(parentID)'.",
                exit: .notFound
            )
        }
        let id = normalizeID(rawID ?? UUID().uuidString)
        let timestamp = now()
        let comment = try ComparisonReviewComment(
            id: id,
            parentID: parentID,
            creator: actor,
            created: timestamp,
            modified: timestamp,
            body: MarginCommentBody(value: message)
        )
        let receipt: ComparisonReviewMutationReceipt
        if let existing = current.threads.flatMap(\.comments).first(where: { $0.id == id }) {
            guard semanticallyMatches(existing, new: comment),
                  currentThread.comments.contains(where: { $0.id == id }) else {
                throw ComparisonError.idConflict(id)
            }
            receipt = unchangedReceipt(current)
        } else {
            do {
                receipt = try store.update(
                    at: reviewURL,
                    expectedRevision: expectedRevision ?? current.revision,
                    modified: timestamp
                ) { review in
                    try review.addComment(comment, to: currentThread.id)
                }
            } catch ComparisonError.revisionConflict {
                let latest = try store.load(at: reviewURL)
                if let existing = latest.threads.flatMap(\.comments)
                    .first(where: { $0.id == id }) {
                    guard semanticallyMatches(existing, new: comment),
                          latest.threads.first(where: { $0.id == currentThread.id })?
                            .comments.contains(where: { $0.id == id }) == true else {
                        throw ComparisonError.idConflict(id)
                    }
                    receipt = unchangedReceipt(latest)
                } else {
                    throw ComparisonError.revisionConflict(
                        expected: expectedRevision ?? current.revision,
                        actual: latest.revision
                    )
                }
            }
        }
        let persisted = try requireThread(currentThread.id, in: receipt.review)
        try writeMutation(
            command: "compare.comments.reply",
            reviewURL: reviewURL,
            receipt: receipt,
            thread: persisted,
            pretty: pretty
        )
    }

    private static func setStatus(
        _ status: MarginCommentStatus,
        name: String,
        cursor: inout ArgumentCursor
    ) throws {
        let protectedPositionals = splitEndOfOptions(
            cursor: &cursor,
            valueOptions: ["--actor-name", "--actor-type", "--actor-id", "--if-revision"]
        )
        let pretty = presentation(cursor: &cursor)
        let actor = try takeActor(cursor: &cursor)
        let expectedRevision = try takeRevision(cursor: &cursor)
        let positionals = try takePositionals(
            cursor: &cursor,
            protected: protectedPositionals,
            expected: ["comparison review", "thread id"]
        )
        let reviewURL = PathResolver.resolvedPreservingFinalComponent(positionals[0])
        let threadID = normalizeID(positionals[1])

        let store = ComparisonReviewStore()
        let current = try store.load(at: reviewURL)
        let currentThread = try requireThread(threadID, in: current)
        let timestamp = now()
        let receipt: ComparisonReviewMutationReceipt
        if currentThread.status == status {
            // A retried desired-state operation is already complete. Return the
            // current revision even when the caller only knows the old one.
            receipt = unchangedReceipt(current)
        } else {
            receipt = try store.update(
                at: reviewURL,
                expectedRevision: expectedRevision ?? current.revision,
                modified: timestamp
            ) { review in
                try review.setThreadStatus(
                    status,
                    threadID: threadID,
                    modified: timestamp,
                    actor: actor
                )
            }
        }
        let persisted = try requireThread(threadID, in: receipt.review)
        try writeMutation(
            command: "compare.comments.\(name)",
            reviewURL: reviewURL,
            receipt: receipt,
            thread: persisted,
            pretty: pretty
        )
    }

    private static func writeMutation(
        command: String,
        reviewURL: URL,
        receipt: ComparisonReviewMutationReceipt,
        thread: ComparisonReviewThread,
        pretty: Bool
    ) throws {
        try CLIOutput.json(
            ComparisonThreadMutationEnvelope(
                command: command,
                reviewPath: reviewURL.path,
                reviewID: receipt.review.id,
                previousRevision: receipt.previousRevision,
                revision: receipt.revision,
                changed: receipt.changed,
                thread: ComparisonThreadProjection(
                    thread,
                    maximumBodyBytes: defaultMaximumBodyBytes
                ),
                nextArgv: [
                    "compare", "comments", "list", reviewURL.path,
                    "--status", "all",
                    "--if-revision", String(receipt.revision),
                ]
            ),
            pretty: pretty,
            maximumBytes: maximumOutputBytes
        )
    }

    private static func presentation(cursor: inout ArgumentCursor) -> Bool {
        _ = cursor.takeFlag("--json")
        return cursor.takeFlag("--pretty")
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

    private static func takePositionals(
        cursor: inout ArgumentCursor,
        protected: [String],
        expected: [String]
    ) throws -> [String] {
        let values = cursor.takeRemaining() + protected
        guard values.count >= expected.count else {
            throw CLIError.usage("Missing \(expected[values.count]).")
        }
        guard values.count == expected.count else {
            throw CLIError.usage("Unexpected argument '\(values[expected.count])'.")
        }
        guard !values.contains(where: \.isEmpty) else {
            let index = values.firstIndex(where: \.isEmpty) ?? 0
            throw CLIError.usage("Missing \(expected[index]).")
        }
        return values
    }

    private static func takeRevision(cursor: inout ArgumentCursor) throws -> Int? {
        let revision = try cursor.takeInt("--if-revision")
        if let revision, revision < 0 {
            throw CLIError.usage("--if-revision must be nonnegative.")
        }
        return revision
    }

    private static func takeMessage(cursor: inout ArgumentCursor) throws -> String {
        let direct = try cursor.takeValue(["-m", "--message", "--body"])
        let messageFile = try cursor.takeValue("--message-file")
        let stdin = cursor.takeFlag("--stdin")
        guard [direct != nil, messageFile != nil, stdin].filter({ $0 }).count == 1 else {
            throw CLIError.usage(
                "Choose exactly one of -m/--message/--body, --message-file PATH, or --stdin."
            )
        }
        let value: String
        if let direct {
            value = direct
        } else if let messageFile {
            value = messageFile == "-"
                ? try readMessage(.standardInput)
                : try readMessageFile(messageFile)
        } else {
            value = try readMessage(.standardInput)
        }
        guard !value.isEmpty,
              value.utf8.count <= ComparisonHardLimits.commentBodyUTF8Bytes else {
            throw CLIError(
                "INVALID_COMMENT_BODY",
                "A comparison comment must contain 1...\(ComparisonHardLimits.commentBodyUTF8Bytes) UTF-8 bytes.",
                exit: .data
            )
        }
        return value
    }

    private static func readMessage(_ handle: FileHandle?) throws -> String {
        guard let handle else {
            throw CLIError.notFound("The comparison comment message file does not exist.")
        }
        var data = Data()
        let limit = ComparisonHardLimits.commentBodyUTF8Bytes
        do {
            while data.count <= limit {
                let remaining = limit + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(16 * 1_024, remaining)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
            if handle !== FileHandle.standardInput { try? handle.close() }
        } catch {
            throw CLIError(
                "MESSAGE_READ_FAILED",
                "Could not read the comparison comment message: \(error.localizedDescription)",
                exit: .io
            )
        }
        guard data.count <= limit else {
            throw CLIError(
                "INVALID_COMMENT_BODY",
                "The comparison comment exceeds \(limit) UTF-8 bytes.",
                exit: .data
            )
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CLIError("INVALID_STDIN", "The comparison comment is not valid UTF-8.", exit: .data)
        }
        return value.trimmingCharacters(in: .newlines)
    }

    private static func readMessageFile(_ rawPath: String) throws -> String {
        let url = PathResolver.resolvedPreservingFinalComponent(rawPath)
        let descriptor = url.path.withCString { path in
#if canImport(Darwin)
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
#elseif canImport(Glibc)
            Glibc.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
#else
            -1
#endif
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw CLIError.notFound(
                    "The comparison comment message file does not exist: \(url.path)."
                )
            }
            if errno == ELOOP {
                throw CLIError(
                    "SYMBOLIC_LINK",
                    "The comparison comment message file must not be a symbolic link.",
                    exit: .permission
                )
            }
            throw CLIError(
                "MESSAGE_READ_FAILED",
                "Could not open the comparison comment message file.",
                exit: .io
            )
        }
        defer {
#if canImport(Darwin)
            _ = Darwin.close(descriptor)
#elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
#endif
        }

        var information = stat()
#if canImport(Darwin)
        let inspected = Darwin.fstat(descriptor, &information)
#elseif canImport(Glibc)
        let inspected = Glibc.fstat(descriptor, &information)
#else
        let inspected = -1
#endif
        guard inspected == 0 else {
            throw CLIError(
                "MESSAGE_READ_FAILED",
                "Could not inspect the comparison comment message file.",
                exit: .io
            )
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw CLIError(
                "NOT_REGULAR_FILE",
                "The comparison comment message path is not a regular file.",
                exit: .data
            )
        }

        let limit = ComparisonHardLimits.commentBodyUTF8Bytes
        guard information.st_size >= 0, UInt64(information.st_size) <= UInt64(limit) else {
            throw invalidCommentBodyTooLarge(limit: limit)
        }
        var data = Data()
        data.reserveCapacity(Int(information.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16 * 1_024, limit + 1))
        while data.count <= limit {
            let requested = min(buffer.count, limit + 1 - data.count)
#if canImport(Darwin)
            let count = Darwin.read(descriptor, &buffer, requested)
#elseif canImport(Glibc)
            let count = Glibc.read(descriptor, &buffer, requested)
#else
            let count = -1
#endif
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw CLIError(
                    "MESSAGE_READ_FAILED",
                    "Could not read the comparison comment message file.",
                    exit: .io
                )
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        guard data.count <= limit else { throw invalidCommentBodyTooLarge(limit: limit) }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CLIError(
                "INVALID_MESSAGE_FILE",
                "The comparison comment message file is not valid UTF-8.",
                exit: .data
            )
        }
        return value.trimmingCharacters(in: .newlines)
    }

    private static func invalidCommentBodyTooLarge(limit: Int) -> CLIError {
        CLIError(
            "INVALID_COMMENT_BODY",
            "The comparison comment exceeds \(limit) UTF-8 bytes.",
            exit: .data
        )
    }

    private static func takeActor(cursor: inout ArgumentCursor) throws -> MarginActor {
        let environment = ProcessInfo.processInfo.environment
        let name = try cursor.takeValue("--actor-name")
            ?? environment["MARGIN_ACTOR_NAME"]
            ?? environment["USER"]
            ?? "Margin collaborator"
        guard !name.isEmpty,
              name.utf8.count <= ComparisonHardLimits.actorNameUTF8Bytes,
              !name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CLIError(
                "INVALID_ACTOR",
                "Actor name must contain 1...\(ComparisonHardLimits.actorNameUTF8Bytes) UTF-8 bytes and no control characters.",
                exit: .configuration
            )
        }
        let rawType = (try cursor.takeValue("--actor-type")
            ?? environment["MARGIN_ACTOR_TYPE"]
            ?? "person").lowercased()
        let type: MarginActorType
        switch rawType {
        case "person": type = .person
        case "software", "agent": type = .software
        case "organization": type = .organization
        default:
            throw CLIError(
                "INVALID_ACTOR",
                "Actor type must be person, software (or agent), or organization.",
                exit: .configuration
            )
        }
        let id = try cursor.takeValue("--actor-id")
            ?? environment["MARGIN_ACTOR_ID"]
            ?? defaultActorID(type: rawType, name: name)
        guard !id.isEmpty,
              id.utf8.count <= ComparisonHardLimits.identifierUTF8Bytes,
              !id.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CLIError(
                "INVALID_ACTOR",
                "Actor ID must contain 1...\(ComparisonHardLimits.identifierUTF8Bytes) UTF-8 bytes and no control characters.",
                exit: .configuration
            )
        }
        return MarginActor(id: id, type: type, name: name)
    }

    private static func defaultActorID(type: String, name: String) -> String {
        let prefix = "urn:margin:\(type):"
        let candidate = slug(name)
        let maximum = ComparisonHardLimits.identifierUTF8Bytes - prefix.utf8.count
        guard candidate.utf8.count > maximum else { return prefix + candidate }

        let digest = String(
            CollaborationCanonicalJSON.sha256(of: Data(name.utf8)).prefix(32)
        )
        let slugBudget = maximum - digest.utf8.count - 1
        let bounded = boundedPreview(candidate, maximumBytes: slugBudget).text
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return prefix + (bounded.isEmpty ? "collaborator" : bounded) + "-" + digest
    }

    private static func takeAnchor(
        cursor: inout ArgumentCursor
    ) throws -> ComparisonReviewAnchorArguments {
        let quote = try cursor.takeValue("--quote")
        let range = try cursor.takeValue("--range")
        let from = try cursor.takeValue("--from")
        let to = try cursor.takeValue("--to")
        let coordinateMode = from != nil || to != nil
        guard [quote != nil, range != nil, coordinateMode].filter({ $0 }).count == 1 else {
            throw CLIError.usage(
                "Choose exactly one text anchor: --quote, --range, or --from with --to."
            )
        }
        if let quote {
            let occurrence = try cursor.takeInt("--occurrence")
            if let occurrence, occurrence <= 0 {
                throw CLIError.usage("--occurrence must be a positive integer.")
            }
            return .quote(
                exact: quote,
                prefix: try cursor.takeValue("--prefix"),
                suffix: try cursor.takeValue("--suffix"),
                occurrence: occurrence
            )
        }
        let expected = try cursor.takeValue("--expect")
        if let range {
            let components = range.split(separator: ":", maxSplits: 1)
            guard components.count == 2,
                  let start = Int(components[0]),
                  let end = Int(components[1]),
                  start >= 0, end > start else {
                throw CLIError.usage(
                    "--range expects nonempty half-open Unicode-scalar offsets START:END."
                )
            }
            return .range(start: start, end: end, expectedExact: expected)
        }
        guard let from, let to else {
            throw CLIError.usage("--from and --to must be provided together as LINE:COLUMN.")
        }
        return .coordinates(from: from, to: to, expectedExact: expected)
    }

    private static func boundedInteger(
        _ value: Int?,
        default defaultValue: Int,
        maximum: Int,
        option: String,
        permitsZero: Bool
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard permitsZero ? value >= 0 : value > 0 else {
            throw CLIError.usage("\(option) must be \(permitsZero ? "nonnegative" : "positive").")
        }
        return min(value, maximum)
    }

    private static func requireThread(
        _ id: String,
        in review: ComparisonReview
    ) throws -> ComparisonReviewThread {
        guard let thread = review.threads.first(where: { $0.id == id }) else {
            throw CLIError(
                "COMPARISON_THREAD_NOT_FOUND",
                "No comparison thread has id '\(id)'.",
                exit: .notFound
            )
        }
        return thread
    }

    private static func unchangedReceipt(
        _ review: ComparisonReview
    ) -> ComparisonReviewMutationReceipt {
        ComparisonReviewMutationReceipt(
            review: review,
            previousRevision: review.revision,
            revision: review.revision,
            changed: false
        )
    }

    private static func semanticallyMatches(
        _ existing: ComparisonReviewThread,
        new candidate: ComparisonReviewThread
    ) -> Bool {
        guard existing.id == candidate.id,
              existing.target == candidate.target,
              let root = candidate.comments.first,
              candidate.comments.count == 1,
              let persistedRoot = existing.comments.first(where: { $0.id == root.id }) else {
            return false
        }
        return semanticallyMatches(persistedRoot, new: root)
    }

    private static func semanticallyMatches(
        _ existing: ComparisonReviewComment,
        new candidate: ComparisonReviewComment
    ) -> Bool {
        existing.id == candidate.id
            && existing.parentID == candidate.parentID
            && existing.creator == candidate.creator
            && existing.body == candidate.body
            && existing.extensions == candidate.extensions
    }

    private static func normalizeID(_ raw: String) -> String {
        UUID(uuidString: raw) == nil ? raw : "urn:uuid:\(raw.lowercased())"
    }

    private static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let compacted = String(mapped).split(separator: "-").joined(separator: "-")
        return compacted.isEmpty ? "collaborator" : compacted
    }
}

private enum ComparisonReviewAnchorArguments {
    case quote(exact: String, prefix: String?, suffix: String?, occurrence: Int?)
    case range(start: Int, end: Int, expectedExact: String?)
    case coordinates(from: String, to: String, expectedExact: String?)

    func resolve(in body: String) throws -> CommentAnchorInput {
        switch self {
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
            return .range(
                start: TextCoordinates.unicodeScalarOffset(of: startIndex, in: projection),
                end: TextCoordinates.unicodeScalarOffset(of: endIndex, in: projection),
                expectedExact: expectedExact
            )
        }
    }
}

private struct ComparisonReviewIdentity: Encodable {
    let id: String
    let revision: Int
    let snapshotPairID: String
    let snapshotGeneration: Int

    init(_ review: ComparisonReview) {
        id = review.id
        revision = review.revision
        snapshotPairID = review.snapshots.id
        snapshotGeneration = review.snapshots.generation
    }
}

private struct ComparisonThreadListEnvelope: Encodable {
    let schema = "urn:margin:comparison-review-cli:v1"
    let ok = true
    let command = "compare.comments.list"
    let review: ComparisonReviewIdentity
    let reviewPath: String
    let status: String
    let total: Int
    let included: Int
    let omitted: Int
    let truncated: Bool
    let threads: [ComparisonThreadProjection]
    let nextArgv: [String]?
}

private struct ComparisonThreadMutationEnvelope: Encodable {
    let schema = "urn:margin:comparison-review-cli:v1"
    let ok = true
    let command: String
    let reviewPath: String
    let reviewID: String
    let previousRevision: Int
    let revision: Int
    let changed: Bool
    let thread: ComparisonThreadProjection
    let nextArgv: [String]
}

private struct ComparisonThreadProjection: Encodable {
    let id: String
    let side: ComparisonReviewSide
    let changedBlockID: String?
    let status: MarginCommentStatus
    let statusModified: String
    let statusModifiedBy: MarginActor
    let leftAnchor: ComparisonAnchorProjection?
    let rightAnchor: ComparisonAnchorProjection?
    let comments: [ComparisonCommentProjection]

    init(_ thread: ComparisonReviewThread, maximumBodyBytes: Int) {
        id = thread.id
        side = thread.target.side
        changedBlockID = thread.target.changedBlockID
        status = thread.status
        statusModified = thread.statusModified
        statusModifiedBy = thread.statusModifiedBy
        leftAnchor = thread.target.left.map {
            ComparisonAnchorProjection($0, maximumBytes: maximumBodyBytes)
        }
        rightAnchor = thread.target.right.map {
            ComparisonAnchorProjection($0, maximumBytes: maximumBodyBytes)
        }
        comments = thread.comments.map {
            ComparisonCommentProjection($0, maximumBytes: maximumBodyBytes)
        }
    }
}

private struct ComparisonAnchorProjection: Encodable {
    struct Position: Encodable {
        let start: Int
        let end: Int
    }

    let snapshotSHA256: String
    let state: ComparisonReviewAnchorState
    let exactPreview: String
    let exactPreviewTruncated: Bool
    let position: Position?

    init(_ anchor: ComparisonReviewAnchor, maximumBytes: Int) {
        snapshotSHA256 = anchor.snapshotSHA256
        state = anchor.state
        let preview = boundedPreview(
            anchor.selector.quoteSelector?.exact ?? "",
            maximumBytes: maximumBytes
        )
        exactPreview = preview.text
        exactPreviewTruncated = preview.truncated
        position = anchor.selector.positionSelector.map {
            Position(start: $0.start, end: $0.end)
        }
    }
}

private struct ComparisonCommentProjection: Encodable {
    let id: String
    let parentID: String?
    let creator: MarginActor
    let created: String
    let modified: String
    let bodyPreview: String
    let bodyPreviewTruncated: Bool

    init(_ comment: ComparisonReviewComment, maximumBytes: Int) {
        id = comment.id
        parentID = comment.parentID
        creator = comment.creator
        created = comment.created
        modified = comment.modified
        let preview = boundedPreview(comment.body.value, maximumBytes: maximumBytes)
        bodyPreview = preview.text
        bodyPreviewTruncated = preview.truncated
    }
}

private func boundedPreview(_ value: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
    let data = Data(value.utf8)
    guard data.count > maximumBytes else { return (value, false) }
    var boundary = min(maximumBytes, data.count)
    while boundary > 0, String(data: data.prefix(boundary), encoding: .utf8) == nil {
        boundary -= 1
    }
    return (String(data: data.prefix(boundary), encoding: .utf8) ?? "", true)
}
