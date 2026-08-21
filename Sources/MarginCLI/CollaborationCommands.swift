import Foundation
import MarginCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum CollaborationCLICommand: String, CaseIterable {
    case workspace
    case context
    case collaborators
    case inbox
    case stage
    case transact
    case suggest
    case handoff
    case reconcile
    case merge

    static let names = Set(allCases.map(\.rawValue))
}

enum CollaborationCLI {
    private static let rootResolver = CollaborationRootResolver()
    private static let cursorService = CollaborationCursorService()
    private static let contextService = CollaborationContextService()
    private static let stageStore = CollaborationStageStore()
    private static let stageRefreshService = CollaborationStageRefreshService()
    private static let transactionEngine = CollaborationTransactionEngine()
    private static let evaluator = CollaborationChangeSetEvaluator()
    private static let workspaceService = CollaborationWorkspaceService()
    private static let codec = EmbeddedCommentCodec()
    private static let commentService = CommentService()

    static func run(command: String, cursor: inout ArgumentCursor) throws {
        guard let command = CollaborationCLICommand(rawValue: command) else {
            throw CLIError.usage("Unknown collaboration command '\(command)'.")
        }
        switch command {
        case .workspace: try runWorkspace(&cursor)
        case .context: try runContext(&cursor)
        case .collaborators: try runCollaborators(&cursor)
        case .inbox: try runInbox(&cursor)
        case .stage: try runStage(&cursor)
        case .transact: try runTransact(&cursor)
        case .suggest: try runSuggest(&cursor)
        case .handoff: try runHandoff(&cursor)
        case .reconcile: try runReconcile(&cursor)
        case .merge: try runMerge(&cursor)
        }
    }

    static func addTypedContribution(
        file: URL,
        fileArgument: String,
        message: String,
        creator: MarginActor,
        kind: CollaborationContributionKind,
        range: UnicodeScalarRange?,
        assignee: String?,
        priority: CollaborationPriority,
        audience: [String],
        annotationID: String?,
        requestID requestedRequestID: String?,
        stageID requestedStageID: String?,
        expectedBaseContentSha256: String,
        preconditions: CommentMutationPreconditions,
        pretty: Bool
    ) throws {
        let root = try rootResolver.resolve(target: file)
        let path = try relativePath(for: file, root: root)
        let loadedBase = try loadDocumentBase(root: root, path: path)
        let baseCursor = loadedBase.cursor
        guard let fileCursor = baseCursor[path] else {
            throw CollaborationError.invalidCursor("The typed contribution target is not cursor-bound.")
        }
        guard fileCursor.contentSha256 == expectedBaseContentSha256 else {
            throw CollaborationError.preconditionFailed(
                path: path,
                reason: "The document changed while the typed selector was being resolved."
            )
        }
        if let revision = preconditions.revision, revision != fileCursor.annotationRevision {
            throw CollaborationError.preconditionFailed(
                path: path,
                reason: "Expected annotation revision \(revision), found \(fileCursor.annotationRevision)."
            )
        }
        if let expected = preconditions.contentSha256 {
            let normalized = expected.hasPrefix("sha256:") ? String(expected.dropFirst(7)) : expected
            guard normalized == fileCursor.contentSha256 else {
                throw CollaborationError.preconditionFailed(
                    path: path,
                    reason: "The logical Markdown digest no longer matches --if-content-sha."
                )
            }
        }
        let actor = try CollaborationActor(creator)
        let normalizedContributionID = annotationID.map(MarginID.annotation)
        let requestID: String
        if let requestedRequestID {
            requestID = MarginID.annotation(requestedRequestID)
        } else if let normalizedContributionID {
            requestID = "\(normalizedContributionID)#request"
        } else {
            requestID = MarginID.annotation()
        }
        let stageID = MarginID.annotation(requestedStageID ?? "\(requestID)#stage")
        let normalizedID = normalizedContributionID ?? "\(requestID)#contribution"
        let existing = try contributionPayload(
            in: loadedBase.document,
            id: normalizedID
        )
        let details: CollaborationContributionDetails
        switch kind {
        case .comment:
            details = .comment(CollaborationCommentDetails())
        case .question:
            details = .question(CollaborationQuestionDetails())
        case .issue:
            details = .issue(CollaborationIssueDetails())
        case .decision:
            details = .decision(CollaborationDecisionDetails())
        case .task:
            details = .task(CollaborationTaskDetails(assignee: assignee, priority: priority))
        case .approval:
            details = .approval(CollaborationApprovalDetails())
        case .suggestion, .handoff:
            throw CLIError.usage("Suggestions and handoffs use their dedicated commands.")
        }
        let contribution = try CollaborationContribution(
            id: normalizedID,
            actorID: actor.id,
            created: existing?.created ?? CollaborationTimestamp.string(),
            body: message,
            target: CollaborationTarget(path: path, range: range),
            audience: audience,
            details: details
        )
        let identities = RequestIdentities(requestID: requestID, stageID: stageID)
        var currentCursor = baseCursor
        let maximumAnnotationOnlyAttempts = 8
        for attempt in 0..<maximumAnnotationOnlyAttempts {
            let changeSet = try makeChangeSet(
                root: root,
                cursor: currentCursor,
                actor: actor,
                identities: identities,
                created: contribution.created,
                operation: .contribution(
                    id: "\(requestID)#operation",
                    CollaborationContributionOperation(contribution: contribution)
                )
            )
            do {
                let receipt = try submit(changeSet)
                try write(
                    command: "comments.add",
                    root: root,
                    result: ContributionMutationResult(
                        contribution: contribution,
                        transaction: receipt
                    ),
                    pretty: pretty,
                    notice: "Typed \(kind.rawValue) saved. Verification commands use read-only arguments; do not carry --document or --kind into comments get/list.",
                    nextActions: [
                        CollaborationNextAction(
                            condition: "verify the exact durable contribution",
                            command: "comments get",
                            arguments: [fileArgument, normalizedID]
                        ),
                        CollaborationNextAction(
                            condition: "observe concurrent work in the document",
                            command: "comments list",
                            arguments: [fileArgument, "--status", "all"]
                        ),
                    ]
                )
                return
            } catch let error as CollaborationError {
                guard case .preconditionFailed = error,
                      preconditions.revision == nil,
                      attempt + 1 < maximumAnnotationOnlyAttempts else {
                    throw error
                }

                // Independent annotation-only writes are safe to rebase when
                // the logical Markdown is byte-for-byte unchanged. Explicit
                // revision guards still fail immediately, and source edits can
                // never be hidden by this bounded retry.
                let refreshed = try loadDocumentBase(root: root, path: path)
                guard let refreshedFile = refreshed.cursor[path],
                      refreshedFile.contentSha256 == expectedBaseContentSha256 else {
                    throw CollaborationError.preconditionFailed(
                        path: path,
                        reason: "The logical Markdown changed during a concurrent contribution."
                    )
                }
                currentCursor = refreshed.cursor
            }
        }
        throw CollaborationError.transactionFailed(
            "The typed contribution did not converge after \(maximumAnnotationOnlyAttempts) annotation-only attempts."
        )
    }

    // MARK: - Workspace

    private static func runWorkspace(_ cursor: inout ArgumentCursor) throws {
        let subcommand = try cursor.require("workspace subcommand")
        switch subcommand {
        case "init":
            let pretty = cursor.takeFlag("--pretty")
            _ = cursor.takeFlag("--json")
            let requestedID = try cursor.takeValue("--id").map(MarginID.annotation)
            let requestedIncludes = try cursor.takeValues("--include")
            let excludes = try cursor.takeValues("--exclude")
            let directory = try existingDirectory(cursor.require("workspace directory"))
            try cursor.rejectRemaining()
            let receipt = try workspaceService.initialize(
                at: directory,
                id: requestedID,
                include: requestedIncludes.isEmpty
                    ? CollaborationWorkspaceManifest.defaultInclude
                    : requestedIncludes,
                exclude: excludes.isEmpty
                    ? CollaborationWorkspaceManifest.defaultExclude
                    : excludes
            )
            try write(
                command: "workspace.init",
                root: receipt.root,
                result: receipt,
                pretty: pretty
            )

        case "show":
            let pretty = cursor.takeFlag("--pretty")
            _ = cursor.takeFlag("--json")
            let directory = try existingDirectory(cursor.require("workspace directory"))
            try cursor.rejectRemaining()
            let root = try rootResolver.directory(at: directory)
            guard let manifest = try rootResolver.manifest(for: root) else {
                throw CLIError.notFound("No .margin/workspace.json exists below \(directory.path).")
            }
            try write(command: "workspace.show", root: root, result: manifest, pretty: pretty)

        default:
            throw CLIError.usage("Unknown workspace subcommand '\(subcommand)'. Run 'margin workspace --help'.")
        }
    }

    // MARK: - Bounded reads

    private static func runContext(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let brief = cursor.takeFlag("--brief")
        let options = try takeContextOptions(&cursor, brief: brief)
        let targetArgument = try cursor.require("file or directory")
        let target = try PathResolver.existingItem(targetArgument)
        try cursor.rejectRemaining()
        let invocationTargetIsDirectory = targetIsDirectory(target)
        let selection = try resolveSelection(target: target, options: options)
        let snapshot = try contextService.context(
            root: selection.root,
            paths: selection.paths,
            limits: options.limits
        )
        let directTarget = directContextTarget(
            invocationTarget: targetArgument,
            targetIsDirectory: invocationTargetIsDirectory,
            root: selection.root,
            files: snapshot.files
        )
        let pathSemantics = contextPathSemantics(
            invocationTargetIsDirectory: invocationTargetIsDirectory,
            hasDirectFileTarget: directTarget != nil
        )
        let workflowGuidance = ContextWorkflowHint.forSnapshot(
            snapshot,
            directTarget: directTarget,
            invocationTarget: targetArgument,
            invocationTargetIsDirectory: invocationTargetIsDirectory
        )
        let notice: String
        let omittedFileCountIsLowerBound =
            snapshot.truncation.discovery.omittedFileCountIsLowerBound == true
        if brief {
            if snapshot.truncation.isTruncated {
                notice = omittedFileCountIsLowerBound
                    ? "Brief context is truncated; omittedFileCount is a lower bound. Execute workflowGuidance; replace only requiredReplacements. Request only omitted detail."
                    : "Brief context is truncated. Execute workflowGuidance; replace only requiredReplacements. Request only omitted detail."
            } else {
                notice = "Brief context is complete. Execute workflowGuidance; replace only requiredReplacements. Use full context only for cursor, activity, or extended metadata."
            }
        } else {
            if snapshot.truncation.isTruncated {
                notice = omittedFileCountIsLowerBound
                    ? "This context is intentionally truncated; omittedFileCount is a lower bound. Use targeted read or filtered inbox commands only for the omitted detail you need; use --brief for a smaller orientation view."
                    : "This context is intentionally truncated. Use targeted read or filtered inbox commands only for the omitted detail you need; use --brief for a smaller orientation view."
            } else {
                notice = "This context contains the complete selected workspace snapshot. Act from workflowGuidance before opening inbox; use inbox only when you need a filtered work queue. Use --brief for future orientation reads."
            }
        }
        if brief {
            let maximumBriefGuidance = 5
            let briefGuidance = Array(workflowGuidance.prefix(maximumBriefGuidance))
            try write(
                command: "context",
                root: selection.root,
                result: ContextBriefResult(
                    invocationTarget: targetArgument,
                    directFileTarget: directTarget,
                    files: snapshot.files.map {
                        ContextBriefFile(file: $0, root: selection.root)
                    },
                    work: snapshot.files.flatMap { file in
                        let action = ContextFileAction(file: file, root: selection.root)
                        return file.contributions.map {
                            ContextBriefContribution(
                                contribution: $0,
                                actionPath: action.actionPath,
                                annotationRevision: action.annotationRevision
                            )
                        }
                    },
                    truncation: ContextBriefTruncation(snapshot.truncation),
                    workflowGuidance: briefGuidance.map(ContextBriefWorkflowHint.init),
                    omittedWorkflowGuidanceCount: workflowGuidance.count - briefGuidance.count
                ),
                pretty: pretty,
                notice: notice
            )
        } else {
            try write(
                command: "context",
                root: selection.root,
                result: ContextResult(
                    invocationTarget: targetArgument,
                    directFileTarget: directTarget,
                    pathSemantics: pathSemantics,
                    cursor: try snapshot.cursor.token(),
                    files: snapshot.files,
                    fileActions: snapshot.files.map {
                        ContextFileAction(file: $0, root: selection.root)
                    },
                    actors: snapshot.actors,
                    activity: snapshot.activity,
                    truncation: snapshot.truncation,
                    availableActions: snapshot.availableActions,
                    workflowGuidance: workflowGuidance
                ),
                pretty: pretty,
                notice: notice
            )
        }
    }

    private static func runCollaborators(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let options = try takeContextOptions(&cursor)
        let targetArgument = try cursor.require("file or directory")
        let target = try PathResolver.existingItem(targetArgument)
        try cursor.rejectRemaining()
        let selection = try resolveSelection(target: target, options: options)
        let snapshot = try contextService.context(
            root: selection.root,
            paths: selection.paths,
            limits: options.limits
        )
        let result = CollaboratorsResult(
            cursor: try snapshot.cursor.token(),
            collaborators: snapshot.actors,
            activity: snapshot.activity,
            truncation: snapshot.truncation
        )
        try write(command: "collaborators", root: selection.root, result: result, pretty: pretty)
    }

    private static func runInbox(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let brief = cursor.takeFlag("--brief")
        let rawStatus = (try cursor.takeValue("--status") ?? "open").lowercased()
        guard ["open", "resolved", "all"].contains(rawStatus) else {
            throw CLIError.usage("--status must be open, resolved, or all.")
        }
        let rawKinds = try cursor.takeValues("--kind")
        let kinds = try Set(rawKinds.map { raw -> CollaborationContributionKind in
            guard let value = CollaborationContributionKind(rawValue: raw.lowercased()) else {
                throw CLIError.usage("Unknown contribution kind '\(raw)'.")
            }
            return value
        })
        let actorID = try cursor.takeValue("--actor")
        let assigneeID = try cursor.takeValue("--assignee")
        let options = try takeContextOptions(&cursor)
        let target = try PathResolver.existingItem(cursor.require("file or directory"))
        try cursor.rejectRemaining()
        let selection = try resolveSelection(target: target, options: options)
        let loaded = try loadAnnotations(
            root: selection.root,
            paths: selection.paths,
            limits: options.limits
        ) { listed in
            let annotation = listed.annotation
            let kind = contributionKind(annotation)
            let assignee = stringValue(annotation.extensions["margin:assignee"])
            let statusMatches = rawStatus == "all" || listed.threadStatus.rawValue == rawStatus
            let kindMatches = kinds.isEmpty || kinds.contains(kind)
            let actorMatches = actorID == nil || annotation.creator.id == actorID
            let assigneeMatches = assigneeID == nil || assignee == assigneeID
            return statusMatches && kindMatches && actorMatches && assigneeMatches
        }
        var usedReferences = Set<String>()
        let items = loaded.files.flatMap { file in
            file.comments.map { listed in
                let annotation = listed.annotation
                let actionURL = selection.root.kind == .document
                    ? URL(fileURLWithPath: selection.root.path, isDirectory: false)
                    : URL(fileURLWithPath: selection.root.path, isDirectory: true)
                        .appendingPathComponent(file.path, isDirectory: false)
                return InboxItem(
                    reference: shortReference(
                        path: file.path,
                        annotationID: annotation.id,
                        used: &usedReferences
                    ),
                    id: annotation.id,
                    rootID: listed.rootID,
                    parentID: listed.parentID,
                    path: file.path,
                    actionPath: pathRelativeToCurrentDirectoryIfPossible(actionURL.path),
                    kind: contributionKind(annotation),
                    actorID: annotation.creator.id,
                    actorName: annotation.creator.name,
                    bodyPreview: preview(
                        annotation.body.value,
                        maximumBytes: options.limits.maxBodyPreviewBytes
                    ),
                    created: annotation.created,
                    modified: annotation.modified,
                    annotationRevision: file.annotationRevision,
                    threadStatus: listed.threadStatus,
                    range: listed.anchor?.range,
                    anchorState: listed.anchor?.state,
                    assigneeID: stringValue(annotation.extensions["margin:assignee"]),
                    priority: stringValue(annotation.extensions["margin:priority"])
                        .flatMap(CollaborationPriority.init(rawValue:))
                )
            }
        }
        let filter = InboxFilter(
            status: rawStatus,
            kinds: kinds.map(\.rawValue).sorted(),
            actorID: actorID,
            assigneeID: assigneeID
        )
        let guidance = items.first.map(ContextWorkflowHint.forInboxItem) ?? []
        let notice: String
        if items.isEmpty {
            notice = "No matching work is visible in this bounded inbox. Use context only if the task requires broader source or workspace context."
        } else if brief {
            notice = "Brief inbox omits the workspace cursor. Act from each item's actionPath and annotationRevision; use full inbox only when a cursor is required."
        } else {
            notice = "Act from this filtered work queue before opening context. Use context only when the task requires broader source or workspace context."
        }
        if brief {
            try write(
                command: "inbox",
                root: selection.root,
                result: InboxBriefResult(
                    cursorOmitted: true,
                    filter: filter,
                    items: items,
                    workflowGuidance: guidance,
                    truncation: loaded.truncation
                ),
                pretty: pretty,
                notice: notice
            )
        } else {
            try write(
                command: "inbox",
                root: selection.root,
                result: InboxResult(
                    cursor: try loaded.cursor.token(),
                    filter: filter,
                    items: items,
                    workflowGuidance: guidance,
                    truncation: loaded.truncation
                ),
                pretty: pretty,
                notice: notice
            )
        }
    }

    // MARK: - Staging and transactions

    private static func runStage(_ cursor: inout ArgumentCursor) throws {
        let subcommand = try cursor.require("stage subcommand")
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        switch subcommand {
        case "create":
            let operationsInput = try cursor.takeValue("--operations-file")
            let changeSetInput = try cursor.takeValue("--change-set-file")
            guard (operationsInput != nil) != (changeSetInput != nil) else {
                throw CLIError.usage(
                    "Use exactly one of --operations-file PLAN_JSON_OR_- or --change-set-file CHANGESET_JSON_OR_. For inline plan JSON, use --operations-file - and send the JSON through standard input; do not pass JSON as a positional argument."
                )
            }
            let requestedChangeSetID = try cursor.takeValue("--id")
            if changeSetInput != nil, requestedChangeSetID != nil {
                throw CLIError.usage("--id applies to --operations-file; a complete change set already contains its identity.")
            }
            let actor = operationsInput == nil ? nil : try takeActor(cursor: &cursor)
            let identities = operationsInput == nil ? nil : try takeIdentities(cursor: &cursor)
            guard let rawRoot = cursor.pop() else {
                throw CLIError.usage(
                    "Missing ROOT. Use '.' for the current directory, for example: margin stage create . --operations-file -"
                )
            }
            let root = try resolveRoot(rawRoot)
            try cursor.rejectRemaining()
            let changeSet: CollaborationChangeSet
            if let operationsInput, let actor, let identities {
                let plan = try readStageIntentPlan(operationsInput)
                changeSet = try makeChangeSet(
                    plan: plan,
                    root: root,
                    actor: actor,
                    identities: identities,
                    requestedID: requestedChangeSetID
                )
            } else if let changeSetInput {
                changeSet = try readChangeSet(changeSetInput)
            } else {
                preconditionFailure("validated stage input")
            }
            guard changeSet.root == root else {
                throw CLIError("ROOT_MISMATCH", "The change set belongs to another collaboration root.", exit: .data)
            }
            let receipt = try stageStore.stage(changeSet)
            try write(
                command: "stage.create",
                root: root,
                result: receipt,
                pretty: pretty,
                notice: "Stage saved immutably. Review it before submitting the all-or-nothing transaction.",
                nextActions: stageReviewActions(root: root, stageID: receipt.stageID)
            )

        case "list":
            let limit = try cursor.takeInt("--limit") ?? 128
            guard (0...4_096).contains(limit) else {
                throw CLIError.usage("--limit must be between 0 and 4096.")
            }
            let maximumAggregateBytes = try cursor.takeInt("--max-bytes")
                ?? CollaborationStageStore.defaultListAggregateBytes
            guard (0...CollaborationStageStore.maximumListAggregateBytes).contains(maximumAggregateBytes) else {
                throw CLIError.usage("--max-bytes must be between 0 and 268435456.")
            }
            let root: CollaborationRoot
            if let rawRoot = cursor.pop() {
                do {
                    root = try resolveRoot(rawRoot)
                } catch let error as CLIError where error.code == "NOT_FOUND" {
                    throw CLIError.usage(
                        "The optional ROOT for 'stage list' must be an existing directory, not a stage id. Omit ROOT to use the current workspace, or run 'margin stage show ROOT STAGE_ID' to inspect one stage."
                    )
                }
            } else {
                root = try resolveDefaultRoot()
            }
            try cursor.rejectRemaining()
            let listing = try stageStore.list(
                root: root,
                limit: limit,
                maximumAggregateBytes: maximumAggregateBytes
            )
            let stages = try listing.stages.map { try StageSummary($0) }
            let nextActions = stages.first.map {
                stageReviewActions(root: root, stageID: $0.stageID)
            }
            try write(
                command: "stage.list",
                root: root,
                result: StageListResult(
                    stages: stages,
                    omittedStageCount: listing.omittedCount,
                    maximumAggregateBytes: maximumAggregateBytes,
                    selectedCanonicalBytes: listing.selectedCanonicalBytes,
                    omittedCanonicalBytes: listing.omittedCanonicalBytes,
                    hitAggregateByteLimit: listing.omittedCanonicalBytes > 0,
                    isTruncated: listing.isTruncated
                ),
                pretty: pretty,
                notice: nextActions == nil
                    ? "No pending stage is available."
                    : "Newest pending stage selected for exact review actions.",
                nextActions: nextActions
            )

        case "show":
            let maxPreviewBytes = try cursor.takeInt("--max-preview-bytes") ?? 240
            guard (0...4_096).contains(maxPreviewBytes) else {
                throw CLIError.usage("--max-preview-bytes must be between 0 and 4096.")
            }
            let root = try resolveRoot(cursor.require("root"))
            let stageID = try cursor.require("stage id")
            try cursor.rejectRemaining()
            let changeSet = try loadStage(
                stageID: MarginID.annotation(stageID),
                root: root
            )
            let detail = try boundedStageDetail(
                changeSet,
                root: root,
                maxPreviewBytes: maxPreviewBytes,
                pretty: pretty
            )
            try write(
                command: "stage.show",
                root: root,
                result: detail,
                pretty: pretty,
                maximumBytes: StageDetail.maximumEncodedBytes,
                notice: "Review the bounded operation summary, then submit this exact stage or refresh it if current files have changed.",
                nextActions: stageReviewActions(root: root, stageID: changeSet.stageID)
            )

        case "refresh":
            let requestedID = try cursor.takeValue("--id").map(MarginID.annotation)
            let submitImmediately = cursor.takeFlag("--submit")
            let root = try resolveRoot(cursor.require("root"))
            let stageID = MarginID.annotation(try cursor.require("stage id"))
            try cursor.rejectRemaining()
            let receipt: CollaborationStageRefreshReceipt
            do {
                receipt = try stageRefreshService.refresh(
                    stageID: stageID,
                    root: root,
                    newStageID: requestedID
                )
            } catch let error as CollaborationError {
                if case .stageNotFound = error {
                    throw stageNotFoundError(error, root: root, stageID: stageID)
                }
                throw error
            }
            if submitImmediately {
                let refreshed = try loadStage(
                    stageID: receipt.refreshedStageID,
                    root: root
                )
                let submission = try submitStage(
                    refreshed,
                    root: root,
                    stageID: receipt.refreshedStageID
                )
                try write(
                    command: "stage.refresh-submit",
                    root: root,
                    result: StageRefreshSubmitResult(
                        refresh: receipt,
                        submission: submission
                    ),
                    pretty: pretty,
                    notice: submission.stageRemoved
                        ? "The preserved operation payload was refreshed and submitted atomically. The prior stage remains available for audit."
                        : "The preserved operation payload was refreshed and submitted atomically, but refreshed-stage cleanup needs attention. The prior stage remains available for audit."
                )
            } else {
                try write(
                    command: "stage.refresh",
                    root: root,
                    result: receipt,
                    pretty: pretty,
                    notice: "A new immutable stage was created; the prior stage remains available for audit.",
                    nextActions: stageReviewActions(
                        root: root,
                        stageID: receipt.refreshedStageID
                    )
                )
            }

        case "discard":
            let root = try resolveRoot(cursor.require("root"))
            let stageID = MarginID.annotation(try cursor.require("stage id"))
            try cursor.rejectRemaining()
            try stageStore.remove(stageID: stageID, root: root)
            try write(
                command: "stage.discard",
                root: root,
                result: StageDiscardResult(stageID: stageID, discarded: true),
                pretty: pretty
            )

        case "submit":
            let root = try resolveRoot(cursor.require("root"))
            let stageID = MarginID.annotation(try cursor.require("stage id"))
            try cursor.rejectRemaining()
            let changeSet = try loadStage(stageID: stageID, root: root)
            let result = try submitStage(changeSet, root: root, stageID: stageID)
            try write(
                command: "stage.submit",
                root: root,
                result: result,
                pretty: pretty
            )

        default:
            throw CLIError.usage("Unknown stage subcommand '\(subcommand)'. Run 'margin stage --help'.")
        }
    }

    private static func boundedStageDetail(
        _ changeSet: CollaborationChangeSet,
        root: CollaborationRoot,
        maxPreviewBytes: Int,
        pretty: Bool
    ) throws -> StageDetail {
        let operationSummaries = changeSet.operations.map {
            StageOperationSummary($0, maxPreviewBytes: maxPreviewBytes)
        }
        let baseCursorPaths = changeSet.baseCursor.files.map(\.path)
        var includedCount = operationSummaries.count
        var includedPathCount = baseCursorPaths.count
        while true {
            let detail = try StageDetail(
                changeSet,
                operations: Array(operationSummaries.prefix(includedCount)),
                baseCursorPaths: Array(baseCursorPaths.prefix(includedPathCount)),
                maxPreviewBytes: maxPreviewBytes,
                hitOutputByteLimit: includedCount < operationSummaries.count
                    || includedPathCount < baseCursorPaths.count
            )
            let envelope = CollaborationCommandEnvelope(
                command: "stage.show",
                root: root,
                result: detail,
                notice: "Review the bounded operation summary, then submit this exact stage or refresh it if current files have changed.",
                nextActions: stageReviewActions(root: root, stageID: changeSet.stageID)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = pretty
                ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                : [.sortedKeys, .withoutEscapingSlashes]
            if try encoder.encode(envelope).count + 1 <= StageDetail.maximumEncodedBytes {
                return detail
            }
            if includedCount > 0 {
                includedCount = includedCount == 1 ? 0 : includedCount / 2
                continue
            }
            if includedPathCount > 0 {
                includedPathCount = includedPathCount == 1 ? 0 : includedPathCount / 2
                continue
            }
            throw CLIError(
                "STAGE_SHOW_TOO_LARGE",
                "The minimum stage metadata exceeds the 1 MiB stage-show output budget.",
                exit: .data
            )
        }
    }

    private static func runTransact(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let root = try resolveRoot(cursor.require("root"))
        let input = try cursor.require("change-set JSON path or -")
        try cursor.rejectRemaining()
        let changeSet = try readChangeSet(input)
        guard changeSet.root == root else {
            throw CLIError("ROOT_MISMATCH", "The change set belongs to another collaboration root.", exit: .data)
        }
        let receipt = try submit(changeSet)
        try write(command: "transact", root: root, result: receipt, pretty: pretty)
    }

    // MARK: - Suggestions

    private static func runSuggest(_ cursor: inout ArgumentCursor) throws {
        let subcommand = try cursor.require("suggest subcommand")
        switch subcommand {
        case "add": try suggestAdd(&cursor)
        case "list": try suggestList(&cursor)
        case "accept": try suggestDisposition(&cursor, disposition: .accept)
        case "reject": try suggestDisposition(&cursor, disposition: .reject)
        default:
            throw CLIError.usage("Unknown suggest subcommand '\(subcommand)'. Run 'margin suggest --help'.")
        }
    }

    private static func suggestAdd(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let explicitRoot = try cursor.takeValue("--root")
        let explicitPath = try cursor.takeValue("--path")
        let selector = try takeSuggestionSelector(cursor: &cursor)
        let replacement = try requiredValue("--replacement", cursor: &cursor)
        let message = try takeMessage(cursor: &cursor)
        let actor = try takeActor(cursor: &cursor)
        let audience = try cursor.takeValues("--audience")
        let requestedContributionID = try cursor.takeValue(["--id", "--contribution-id"])
        let normalizedContributionID = requestedContributionID.map(MarginID.annotation)
        let identities = try takeIdentities(
            cursor: &cursor,
            fallbackContributionID: normalizedContributionID
        )
        let targetArgument = try cursor.require("file or directory")
        let target = try PathResolver.existingItem(targetArgument)
        try cursor.rejectRemaining()
        let selection = try resolveMutationSelection(
            target: target,
            explicitRoot: explicitRoot,
            explicitPath: explicitPath
        )
        let base = try loadDocumentBase(root: selection.root, path: selection.path)
        let resolvedSelector = try selector.resolve(in: base.document.body)
        let baseCursor = base.cursor
        let contributionID = normalizedContributionID ?? "\(identities.requestID)#contribution"
        let existing = try contributionPayload(in: base.document, id: contributionID)
        let contribution = try CollaborationContributionFactory.suggestion(
            actor: actor,
            path: selection.path,
            range: resolvedSelector.range,
            message: message,
            expectedText: resolvedSelector.expectedText,
            replacementText: replacement,
            baseCursor: baseCursor,
            created: existing?.created ?? CollaborationTimestamp.string(),
            id: contributionID,
            audience: audience
        )
        let changeSet = try makeChangeSet(
            root: selection.root,
            cursor: baseCursor,
            actor: actor,
            identities: identities,
            created: contribution.created,
            operation: .contribution(
                id: "\(identities.requestID)#operation",
                CollaborationContributionOperation(contribution: contribution)
            )
        )
        let receipt = try submit(changeSet)
        try write(
            command: "suggest.add",
            root: selection.root,
            result: ContributionMutationResult(contribution: contribution, transaction: receipt),
            pretty: pretty,
            notice: "Suggestion saved without changing source. Review and disposition commands require the target before the suggestion ID.",
            nextActions: [
                CollaborationNextAction(
                    condition: "always verify the durable suggestion",
                    command: "suggest list",
                    arguments: [targetArgument]
                ),
                CollaborationNextAction(
                    condition: "inspect the exact annotation and anchor",
                    command: "comments get",
                    arguments: [targetArgument, contributionID]
                ),
            ]
        )
    }

    private static func suggestList(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let options = try takeContextOptions(&cursor)
        let target = try PathResolver.existingItem(cursor.require("file or directory"))
        try cursor.rejectRemaining()
        let selection = try resolveSelection(target: target, options: options)
        let loaded = try loadAnnotations(
            root: selection.root,
            paths: selection.paths,
            limits: options.limits
        ) { listed in
            let annotation = listed.annotation
            guard stringValue(annotation.extensions["margin:kind"])
                    == CollaborationContributionKind.suggestion.rawValue else {
                return false
            }
            if case .object? = annotation.extensions["margin:suggestion"] { return true }
            return false
        }
        var items: [SuggestionListItem] = []
        for file in loaded.files {
            for listed in file.comments {
                let annotation = listed.annotation
                guard stringValue(annotation.extensions["margin:kind"]) == CollaborationContributionKind.suggestion.rawValue,
                      case .object(let details)? = annotation.extensions["margin:suggestion"] else { continue }
                items.append(SuggestionListItem(
                    id: annotation.id,
                    path: file.path,
                    actorID: annotation.creator.id,
                    actorName: annotation.creator.name,
                    body: preview(annotation.body.value, maximumBytes: options.limits.maxBodyPreviewBytes),
                    created: annotation.created,
                    modified: annotation.modified,
                    range: listed.anchor?.range,
                    anchorState: listed.anchor?.state,
                    threadStatus: listed.threadStatus,
                    status: stringValue(details["status"]),
                    expectedText: stringValue(details["expectedText"]),
                    replacementText: stringValue(details["replacementText"]),
                    baseContentSha256: stringValue(details["baseContentSha256"])
                ))
            }
        }
        let result = SuggestionListResult(
            cursor: try loaded.cursor.token(),
            suggestions: items,
            truncation: loaded.truncation
        )
        try write(command: "suggest.list", root: selection.root, result: result, pretty: pretty)
    }

    private static func suggestDisposition(
        _ cursor: inout ArgumentCursor,
        disposition: CollaborationSuggestionDisposition
    ) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let explicitRoot = try cursor.takeValue("--root")
        let explicitPath = try cursor.takeValue("--path")
        let actor = try takeActor(cursor: &cursor)
        let identities = try takeIdentities(cursor: &cursor)
        let targetArgument = try cursor.require("file or directory")
        let target = try PathResolver.existingItem(targetArgument)
        let contributionID = MarginID.annotation(try cursor.require("suggestion id"))
        try cursor.rejectRemaining()
        let selection = try resolveMutationSelection(
            target: target,
            explicitRoot: explicitRoot,
            explicitPath: explicitPath
        )
        let baseCursor = try cursorService.capture(root: selection.root, paths: [selection.path])
        let operation = CollaborationOperation.suggestionDisposition(
            id: "\(identities.requestID)#operation",
            CollaborationSuggestionDispositionOperation(
                path: selection.path,
                contributionID: contributionID,
                disposition: disposition
            )
        )
        let changeSet = try makeChangeSet(
            root: selection.root,
            cursor: baseCursor,
            actor: actor,
            identities: identities,
            operation: operation
        )
        let receipt = try submit(changeSet)
        try write(
            command: "suggest.\(disposition.rawValue)",
            root: selection.root,
            result: SuggestionDispositionResult(
                contributionID: contributionID,
                disposition: disposition,
                transaction: receipt
            ),
            pretty: pretty,
            notice: "Suggestion \(disposition.rawValue). Verify the Markdown source and embedded annotation state separately.",
            nextActions: [
                CollaborationNextAction(
                    condition: "verify the source after the disposition",
                    command: "read",
                    arguments: [targetArgument, "--json"]
                ),
                CollaborationNextAction(
                    condition: "always validate the embedded annotation graph",
                    command: "comments validate",
                    arguments: [targetArgument]
                ),
            ]
        )
    }

    // MARK: - Handoffs

    private static func runHandoff(_ cursor: inout ArgumentCursor) throws {
        let subcommand = try cursor.require("handoff subcommand")
        switch subcommand {
        case "add": try handoffAdd(&cursor)
        case "list": try handoffList(&cursor)
        default:
            throw CLIError.usage("Unknown handoff subcommand '\(subcommand)'. Run 'margin handoff --help'.")
        }
    }

    private static func handoffAdd(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        _ = cursor.takeFlag("--document")
        if let explicitKind = try cursor.takeValue("--kind"), explicitKind != "handoff" {
            throw CLIError.usage("Option --kind must be 'handoff' for handoff add.")
        }
        let targetRevision = try cursor.takeInt("--if-revision")
        guard targetRevision.map({ $0 >= 0 }) ?? true else {
            throw CLIError.usage("Option --if-revision expects a nonnegative integer.")
        }
        let targetContentSHA = try cursor.takeValue("--if-content-sha")
        let explicitRoot = try cursor.takeValue("--root")
        let explicitPath = try cursor.takeValue("--path")
        let message = try takeMessage(cursor: &cursor)
        let actor = try takeActor(cursor: &cursor)
        let audience = try cursor.takeValues("--audience")
        let touched = try cursor.takeValues("--touched")
        let unresolved = try cursor.takeValues("--unresolved")
        let nextActors = try cursor.takeValues("--next-actor") + cursor.takeValues("--to")
        let startingToken = try cursor.takeValue("--starting-cursor")
        let finishingToken = try cursor.takeValue("--finishing-cursor")
        let requestedContributionID = try cursor.takeValue(["--id", "--contribution-id"])
        let normalizedContributionID = requestedContributionID.map(MarginID.annotation)
        let identities = try takeIdentities(
            cursor: &cursor,
            fallbackContributionID: normalizedContributionID
        )
        let targetArgument = try cursor.require("file or directory")
        let target = try PathResolver.existingItem(targetArgument)
        try cursor.rejectRemaining()
        let selection = try resolveMutationSelection(
            target: target,
            explicitRoot: explicitRoot,
            explicitPath: explicitPath
        )
        let loadedBase = try loadDocumentBase(root: selection.root, path: selection.path)
        let baseCursor = loadedBase.cursor
        let contributionID = normalizedContributionID ?? "\(identities.requestID)#contribution"
        let existing = try contributionPayload(in: loadedBase.document, id: contributionID)
        if existing == nil, let fileCursor = baseCursor[selection.path] {
            if let targetRevision, targetRevision != fileCursor.annotationRevision {
                throw CollaborationError.preconditionFailed(
                    path: selection.path,
                    reason: "Expected annotation revision \(targetRevision), found \(fileCursor.annotationRevision)."
                )
            }
            if let targetContentSHA {
                let normalized = targetContentSHA.hasPrefix("sha256:")
                    ? String(targetContentSHA.dropFirst(7))
                    : targetContentSHA
                guard normalized == fileCursor.contentSha256 else {
                    throw CollaborationError.preconditionFailed(
                        path: selection.path,
                        reason: "The logical Markdown digest no longer matches --if-content-sha."
                    )
                }
            }
        }
        let existingStartingCursor: CollaborationCursor?
        if let existing, case .handoff(let details) = existing.details {
            existingStartingCursor = try CollaborationCursor(token: details.startingCursor)
        } else {
            existingStartingCursor = nil
        }
        let startingCursor = try startingToken.map(CollaborationCursor.init(token:))
            ?? existingStartingCursor
            ?? baseCursor
        let finishingCursor = try finishingToken.map(CollaborationCursor.init(token:))
        guard startingCursor.root == selection.root,
              finishingCursor.map({ $0.root == selection.root }) ?? true else {
            throw CLIError("ROOT_MISMATCH", "Handoff cursors must belong to the selected root.", exit: .data)
        }
        let contribution = try CollaborationContributionFactory.handoff(
            actor: actor,
            path: selection.path,
            message: message,
            startingCursor: startingCursor,
            finishingCursor: finishingCursor,
            touchedAnnotationIDs: touched.map(MarginID.annotation),
            unresolvedIDs: unresolved.map(MarginID.annotation),
            intendedNextActors: nextActors,
            created: existing?.created ?? CollaborationTimestamp.string(),
            id: contributionID,
            audience: audience
        )
        let changeSet = try makeChangeSet(
            root: selection.root,
            cursor: baseCursor,
            actor: actor,
            identities: identities,
            created: contribution.created,
            operation: .contribution(
                id: "\(identities.requestID)#operation",
                CollaborationContributionOperation(contribution: contribution)
            )
        )
        let receipt = try submit(changeSet)
        try write(
            command: "handoff.add",
            root: selection.root,
            result: ContributionMutationResult(contribution: contribution, transaction: receipt),
            pretty: pretty,
            notice: "Handoff saved as durable document state. The next collaborator can discover it without this transcript.",
            nextActions: [
                CollaborationNextAction(
                    condition: "always verify the durable handoff",
                    command: "handoff list",
                    arguments: [targetArgument]
                ),
                CollaborationNextAction(
                    condition: "inspect the handoff annotation by id",
                    command: "comments get",
                    arguments: [targetArgument, contributionID]
                ),
            ]
        )
    }

    private static func handoffList(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let options = try takeContextOptions(&cursor)
        let target = try PathResolver.existingItem(cursor.require("file or directory"))
        try cursor.rejectRemaining()
        let selection = try resolveSelection(target: target, options: options)
        let loaded = try loadAnnotations(
            root: selection.root,
            paths: selection.paths,
            limits: options.limits
        ) { listed in
            let annotation = listed.annotation
            guard stringValue(annotation.extensions["margin:kind"])
                    == CollaborationContributionKind.handoff.rawValue,
                  case .object(let details)? = annotation.extensions["margin:handoff"] else {
                return false
            }
            return stringValue(details["startingCursor"]) != nil
        }
        var items: [HandoffListItem] = []
        for file in loaded.files {
            for listed in file.comments {
                let annotation = listed.annotation
                guard stringValue(annotation.extensions["margin:kind"]) == CollaborationContributionKind.handoff.rawValue,
                      case .object(let details)? = annotation.extensions["margin:handoff"],
                      let startingCursor = stringValue(details["startingCursor"]) else { continue }
                items.append(HandoffListItem(
                    id: annotation.id,
                    path: file.path,
                    actorID: annotation.creator.id,
                    actorName: annotation.creator.name,
                    body: preview(annotation.body.value, maximumBytes: options.limits.maxBodyPreviewBytes),
                    created: annotation.created,
                    startingCursor: startingCursor,
                    finishingCursor: stringValue(details["finishingCursor"]),
                    touchedAnnotationIDs: stringArray(details["touchedAnnotationIDs"]),
                    unresolvedIDs: stringArray(details["unresolvedIDs"]),
                    intendedNextActors: stringArray(details["intendedNextActors"])
                ))
            }
        }
        let result = HandoffListResult(
            cursor: try loaded.cursor.token(),
            handoffs: items,
            truncation: loaded.truncation
        )
        try write(command: "handoff.list", root: selection.root, result: result, pretty: pretty)
    }

    // MARK: - Recovery and merge

    private static func runReconcile(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let apply = cursor.takeFlag("--apply")
        let previousRaw = try requiredValue("--from", cursor: &cursor)
        let suppliedPolicy = try cursor.takeValue("--policy")
        if apply, suppliedPolicy == nil {
            throw CLIError.usage("--apply requires an explicit --policy require-all|preserve-unresolved.")
        }
        let rawPolicy = suppliedPolicy ?? "require-all"
        let policy: ReconciliationPolicy
        switch rawPolicy {
        case "require-all", "requireAllAnchored": policy = .requireAllAnchored
        case "preserve-unresolved", "preserveUnresolved": policy = .preserveUnresolved
        default: throw CLIError.usage("--policy must be require-all or preserve-unresolved.")
        }
        let current = try PathResolver.existingFile(cursor.require("current Markdown file"))
        let previous = try PathResolver.existingFile(previousRaw)
        try cursor.rejectRemaining()
        let service = ReconciliationService()
        if apply {
            let receipt = try service.apply(at: current, from: previous, policy: policy)
            try write(
                command: "reconcile",
                root: try rootResolver.document(at: current),
                result: ReconcileResult(mode: "apply", analysis: nil, receipt: receipt),
                pretty: pretty
            )
        } else {
            let analysis = try service.analyze(at: current, from: previous)
            try write(
                command: "reconcile",
                root: try rootResolver.document(at: current),
                result: ReconcileResult(mode: "analyze", analysis: analysis, receipt: nil),
                pretty: pretty
            )
        }
    }

    private static func runMerge(_ cursor: inout ArgumentCursor) throws {
        let pretty = cursor.takeFlag("--pretty")
        _ = cursor.takeFlag("--json")
        let mergedBodyPath = try cursor.takeValue("--merged-body")
        let outputPath = try cursor.takeValue("--output")
        let force = cursor.takeFlag("--force")
        if force, outputPath == nil {
            throw CLIError.usage("--force requires --output PATH.")
        }
        let rawResolutions = try cursor.takeValues("--resolve")
        var resolutions: [String: SemanticMergeChoice] = [:]
        for raw in rawResolutions {
            let pieces = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let choice = SemanticMergeChoice(rawValue: pieces[1]) else {
                throw CLIError.usage("--resolve expects ID=base|ours|theirs|delete.")
            }
            guard resolutions.updateValue(choice, forKey: MarginID.annotation(pieces[0])) == nil else {
                throw CLIError.usage("A merge resolution id may be supplied only once.")
            }
        }
        let baseURL = try PathResolver.existingFile(cursor.require("base Markdown file"))
        let oursURL = try PathResolver.existingFile(cursor.require("ours Markdown file"))
        let theirsURL = try PathResolver.existingFile(cursor.require("theirs Markdown file"))
        try cursor.rejectRemaining()
        let result = try SemanticMergeService().merge(
            base: try readBounded(baseURL, maximumBytes: 128 * 1_024 * 1_024),
            ours: try readBounded(oursURL, maximumBytes: 128 * 1_024 * 1_024),
            theirs: try readBounded(theirsURL, maximumBytes: 128 * 1_024 * 1_024),
            mergedBody: try mergedBodyPath.map {
                try readBounded(PathResolver.existingFile($0), maximumBytes: 128 * 1_024 * 1_024)
            },
            annotationResolutions: resolutions
        )
        var writtenTo: String?
        if let outputPath, let data = result.data {
            let output = PathResolver.resolved(outputPath)
            try writeMergeOutput(data, to: output, force: force)
            writtenTo = output.path
        }
        let summary = MergeResult(
            clean: result.clean,
            writtenTo: writtenTo,
            documentID: result.documentID,
            revision: result.revision,
            annotationCount: result.annotationCount,
            contentSha256: result.contentSha256,
            conflicts: result.conflicts,
            anchorsNeedingAttention: result.anchorsNeedingAttention
        )
        try write(command: "merge", root: nil, result: summary, pretty: pretty)
    }

    // MARK: - Shared parsing and Core seams

    private static func resolveRoot(_ raw: String) throws -> CollaborationRoot {
        try rootResolver.resolve(target: PathResolver.existingItem(raw))
    }

    private static func resolveDefaultRoot() throws -> CollaborationRoot {
        let current = try PathResolver.existingItem(FileManager.default.currentDirectoryPath)
        let fallback = try rootResolver.directory(at: current)
        let startingDevice = try FileManager.default
            .attributesOfItem(atPath: current.path)[.systemNumber] as? NSNumber
        var directory = current
        while true {
            let candidate = try rootResolver.directory(at: directory)
            if candidate.workspaceID != nil { return candidate }
            if directory.path == "/" { break }
            let parentPath = (directory.path as NSString).deletingLastPathComponent
            let normalizedParent = parentPath.isEmpty ? "/" : parentPath
            let parent = URL(fileURLWithPath: normalizedParent, isDirectory: true).standardizedFileURL
            guard parent.path.count < directory.path.count else { break }
            let parentDevice = try FileManager.default
                .attributesOfItem(atPath: parent.path)[.systemNumber] as? NSNumber
            guard startingDevice == nil || parentDevice == startingDevice else { break }
            directory = parent
        }
        return fallback
    }

    private static func resolveSelection(
        target: URL,
        options: ContextOptions
    ) throws -> ResolvedSelection {
        let explicitRoot = try options.explicitRoot.map { try existingDirectory($0) }
        let root = try rootResolver.resolve(target: target, explicitRoot: explicitRoot)
        let paths: [String]?
        if !options.paths.isEmpty {
            paths = options.paths
        } else if isDirectory(target) {
            paths = nil
        } else {
            paths = [try relativePath(for: target, root: root)]
        }
        return ResolvedSelection(root: root, paths: paths)
    }

    private static func resolveMutationSelection(
        target: URL,
        explicitRoot: String?,
        explicitPath: String?
    ) throws -> MutationSelection {
        let rootURL = try explicitRoot.map { try existingDirectory($0) }
        let root = try rootResolver.resolve(target: target, explicitRoot: rootURL)
        if let explicitPath {
            return MutationSelection(root: root, path: explicitPath)
        }
        guard !isDirectory(target) else {
            throw CLIError.usage("A directory target requires --path RELATIVE_MARKDOWN_PATH.")
        }
        return MutationSelection(root: root, path: try relativePath(for: target, root: root))
    }

    private static func relativePath(for file: URL, root: CollaborationRoot) throws -> String {
        if root.kind == .document { return "." }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else { throw CollaborationError.pathEscapesRoot(file.path) }
        return String(file.path.dropFirst(prefix.count))
    }

    private static func takeContextOptions(
        _ cursor: inout ArgumentCursor,
        brief: Bool = false
    ) throws -> ContextOptions {
        let explicitRoot = try cursor.takeValue("--root")
        let paths = try cursor.takeValues("--path")
        let defaults = CollaborationContextLimits.default
        let maxFiles = try cursor.takeInt("--max-files")
            ?? (brief ? 4 : defaults.discovery.maxFiles)
        let maxBytes = try cursor.takeInt("--max-bytes")
            ?? (brief ? 2 * 1_024 * 1_024 : defaults.discovery.maxBytes)
        let maxDepth = try cursor.takeInt("--max-depth")
            ?? (brief ? 8 : defaults.discovery.maxDepth)
        let maxHeadings = try cursor.takeInt("--max-headings")
            ?? (brief ? 4 : defaults.maxHeadingsPerFile)
        let maxContributions = try cursor.takeInt("--max-contributions")
            ?? (brief ? 1 : defaults.maxContributionsPerFile)
        let maxPreviewBytes = try cursor.takeInt("--max-preview-bytes") ?? defaults.maxBodyPreviewBytes
        let maxSourceBytes = try cursor.takeInt("--max-source-bytes")
            ?? (brief ? 512 : defaults.maxSourcePreviewBytes)
        let limits = CollaborationContextLimits(
            discovery: CollaborationDiscoveryLimits(
                maxFiles: maxFiles,
                maxBytes: maxBytes,
                maxDepth: maxDepth
            ),
            maxHeadingsPerFile: maxHeadings,
            maxContributionsPerFile: maxContributions,
            maxBodyPreviewBytes: maxPreviewBytes,
            maxSourcePreviewBytes: maxSourceBytes,
            maxActivityRecords: brief ? 0 : defaults.maxActivityRecords
        )
        try limits.validate()
        return ContextOptions(explicitRoot: explicitRoot, paths: paths, limits: limits)
    }

    private static func takeActor(cursor: inout ArgumentCursor) throws -> CollaborationActor {
        let environment = ProcessInfo.processInfo.environment
        let name = try cursor.takeValue("--actor-name")
            ?? environment["MARGIN_ACTOR_NAME"]
            ?? environment["USER"]
            ?? "Margin collaborator"
        let rawType = (try cursor.takeValue("--actor-type")
            ?? environment["MARGIN_ACTOR_TYPE"]
            ?? "person").lowercased()
        let type: MarginActorType
        switch rawType {
        case "person": type = .person
        case "software", "agent": type = .software
        case "organization": type = .organization
        default:
            throw CLIError("INVALID_ACTOR", "Actor type must be person, software, agent, or organization.", exit: .configuration)
        }
        let defaultID = "urn:margin:\(rawType):\(slug(name))"
        let id = try cursor.takeValue("--actor-id") ?? environment["MARGIN_ACTOR_ID"] ?? defaultID
        return try CollaborationActor(id: id, type: type, name: name)
    }

    private static func takeMessage(cursor: inout ArgumentCursor) throws -> String {
        let direct = try [cursor.takeValue("-m"), cursor.takeValue("--message"), cursor.takeValue("--body")]
            .compactMap { $0 }
        guard direct.count <= 1 else { throw CLIError.usage("Use only one message option.") }
        let messageFile = try cursor.takeValue("--message-file")
        let stdin = cursor.takeFlag("--stdin")
        guard [!direct.isEmpty, messageFile != nil, stdin].filter({ $0 }).count == 1 else {
            throw CLIError.usage("Use exactly one of -m/--message/--body, --message-file, or --stdin.")
        }
        if let message = direct.first { return message }
        if let messageFile {
            if messageFile == "-" { return try readUTF8StandardInput(maximumBytes: 1_048_576) }
            let data = try readBounded(PathResolver.existingFile(messageFile), maximumBytes: 1_048_576)
            guard let value = String(data: data, encoding: .utf8) else {
                throw CLIError("INVALID_MESSAGE", "The message file is not valid UTF-8.", exit: .data)
            }
            return value.trimmingCharacters(in: .newlines)
        }
        return try readUTF8StandardInput(maximumBytes: 1_048_576)
    }

    private static func takeIdentities(
        cursor: inout ArgumentCursor,
        fallbackContributionID: String? = nil
    ) throws -> RequestIdentities {
        let explicitRequestID = try cursor.takeValue("--request-id")
        let requestID: String
        if let explicitRequestID {
            requestID = MarginID.annotation(explicitRequestID)
        } else if let fallbackContributionID {
            requestID = "\(fallbackContributionID)#request"
        } else {
            requestID = MarginID.annotation()
        }
        let stageID = MarginID.annotation(try cursor.takeValue("--stage-id") ?? "\(requestID)#stage")
        return RequestIdentities(requestID: requestID, stageID: stageID)
    }

    private static func makeChangeSet(
        root: CollaborationRoot,
        cursor: CollaborationCursor,
        actor: CollaborationActor,
        identities: RequestIdentities,
        created: String = CollaborationTimestamp.string(),
        operation: CollaborationOperation
    ) throws -> CollaborationChangeSet {
        try CollaborationChangeSet(
            id: "\(identities.requestID)#changeset",
            root: root,
            baseCursor: cursor,
            actor: actor,
            requestID: identities.requestID,
            stageID: identities.stageID,
            created: created,
            operations: [operation]
        )
    }

    private static func submit(_ changeSet: CollaborationChangeSet) throws -> CollaborationTransactionReceipt {
        if changeSet.operations.allSatisfy({ operation in
            if case .file = operation { return true }
            return false
        }) {
            return try transactionEngine.submit(changeSet)
        }
        let mutations = try evaluator.evaluate(changeSet)
        return try transactionEngine.submit(changeSet, evaluatedMutations: mutations)
    }

    private static func readChangeSet(_ raw: String) throws -> CollaborationChangeSet {
        let data: Data
        if raw == "-" {
            data = try readStandardInput(maximumBytes: 256 * 1_024 * 1_024)
        } else {
            data = try readBounded(PathResolver.existingFile(raw), maximumBytes: 256 * 1_024 * 1_024)
        }
        do {
            let value = try JSONDecoder().decode(CollaborationChangeSet.self, from: data)
            try value.validate()
            return value
        } catch let error as CollaborationError {
            throw error
        } catch {
            throw CLIError("INVALID_CHANGE_SET_JSON", "Could not decode the collaboration change set: \(error.localizedDescription)", exit: .data)
        }
    }

    private static func readStageIntentPlan(_ raw: String) throws -> StageIntentPlan {
        let data: Data
        if raw == "-" {
            data = try readStandardInput(maximumBytes: 16 * 1_024 * 1_024)
        } else {
            do {
                data = try readBounded(
                    PathResolver.existingFile(raw),
                    maximumBytes: 16 * 1_024 * 1_024
                )
            } catch let error as CLIError where error.code == "NOT_FOUND" {
                throw CLIError.notFound(
                    "\(error.message) For inline plan JSON, use --operations-file - and send the JSON through standard input; do not pass JSON as a positional argument."
                )
            }
        }
        do {
            let plan = try JSONDecoder().decode(StageIntentPlan.self, from: data)
            guard plan.version == 1,
                  plan.schema == nil || plan.schema == "urn:margin:stage-intent:v1",
                  (1...4_096).contains(plan.operations.count) else {
                throw CLIError(
                    "INVALID_STAGE_INTENT",
                    "The plan must use version 1, the urn:margin:stage-intent:v1 schema, and contain 1 to 4096 operations.",
                    exit: .data
                )
            }
            return plan
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError("INVALID_STAGE_INTENT", "Could not decode the stage intent plan: \(error.localizedDescription)", exit: .data)
        }
    }

    private static func makeChangeSet(
        plan: StageIntentPlan,
        root: CollaborationRoot,
        actor: CollaborationActor,
        identities: RequestIdentities,
        requestedID: String?
    ) throws -> CollaborationChangeSet {
        let paths = Array(Set(plan.operations.map(\.path))).sorted()
        let loaded = try loadDocumentBases(root: root, paths: paths)
        let baseCursor = loaded.cursor
        let created = CollaborationTimestamp.string()
        let operations = try plan.operations.enumerated().map { offset, intent in
            try operation(
                from: intent,
                offset: offset,
                actor: actor,
                baseCursor: baseCursor,
                documents: loaded.documents,
                created: created,
                requestID: identities.requestID
            )
        }
        return try CollaborationChangeSet(
            id: MarginID.annotation(requestedID ?? "\(identities.requestID)#changeset"),
            root: root,
            baseCursor: baseCursor,
            actor: actor,
            requestID: identities.requestID,
            stageID: identities.stageID,
            created: created,
            operations: operations
        )
    }

    private static func operation(
        from intent: StageIntentOperation,
        offset: Int,
        actor: CollaborationActor,
        baseCursor: CollaborationCursor,
        documents: [String: EmbeddedCommentDocument],
        created: String,
        requestID: String
    ) throws -> CollaborationOperation {
        let operationID = MarginID.annotation(intent.operationID ?? "\(requestID)#operation-\(offset + 1)")
        switch intent.kind {
        case "contribution":
            guard let rawKind = intent.contributionKind,
                  let kind = CollaborationContributionKind(rawValue: rawKind),
                  let body = intent.body else {
                throw CLIError.usage("A contribution intent requires contributionKind and body.")
            }
            let contributionID = MarginID.annotation(
                intent.contributionID ?? "\(requestID)#contribution-\(offset + 1)"
            )
            guard let document = documents[intent.path] else {
                throw CollaborationError.invalidCursor("The intent path '\(intent.path)' has no loaded base document.")
            }
            let resolvedSelector = try resolveIntentSelector(intent, in: document.body)
            let contribution: CollaborationContribution
            switch kind {
            case .suggestion:
                guard let resolvedSelector,
                      let replacement = intent.replacementText else {
                    throw CLIError.usage("A suggestion contribution requires one passage selector and replacementText.")
                }
                contribution = try CollaborationContributionFactory.suggestion(
                    actor: actor,
                    path: intent.path,
                    range: resolvedSelector.range,
                    message: body,
                    expectedText: resolvedSelector.expectedText,
                    replacementText: replacement,
                    baseCursor: baseCursor,
                    created: created,
                    id: contributionID,
                    audience: intent.audience ?? []
                )
            case .handoff:
                let starting = try intent.startingCursor.map { try CollaborationCursor(token: $0) } ?? baseCursor
                let finishing = try intent.finishingCursor.map { try CollaborationCursor(token: $0) }
                contribution = try CollaborationContributionFactory.handoff(
                    actor: actor,
                    path: intent.path,
                    message: body,
                    startingCursor: starting,
                    finishingCursor: finishing,
                    touchedAnnotationIDs: (intent.touchedAnnotationIDs ?? []).map(MarginID.annotation),
                    unresolvedIDs: (intent.unresolvedIDs ?? []).map(MarginID.annotation),
                    intendedNextActors: intent.intendedNextActors ?? [],
                    created: created,
                    id: contributionID,
                    audience: intent.audience ?? []
                )
            default:
                let details = try contributionDetails(kind: kind, intent: intent)
                contribution = try CollaborationContribution(
                    id: contributionID,
                    actorID: actor.id,
                    created: created,
                    body: body,
                    target: CollaborationTarget(
                        path: intent.path,
                        annotationID: intent.parentID.map(MarginID.annotation),
                        range: resolvedSelector?.range
                    ),
                    audience: intent.audience ?? [],
                    details: details
                )
            }
            return .contribution(
                id: operationID,
                CollaborationContributionOperation(contribution: contribution)
            )

        case "status":
            guard let annotationID = intent.annotationID,
                  let rawStatus = intent.status,
                  let status = MarginCommentStatus(rawValue: rawStatus) else {
                throw CLIError.usage("A status intent requires annotationID and status open|resolved.")
            }
            return .status(
                id: operationID,
                CollaborationStatusOperation(
                    path: intent.path,
                    annotationID: MarginID.annotation(annotationID),
                    status: status
                )
            )

        case "suggestion-disposition":
            guard let contributionID = intent.contributionID,
                  let rawDisposition = intent.disposition,
                  let disposition = CollaborationSuggestionDisposition(rawValue: rawDisposition) else {
                throw CLIError.usage("A suggestion-disposition intent requires contributionID and disposition accept|reject.")
            }
            return .suggestionDisposition(
                id: operationID,
                CollaborationSuggestionDispositionOperation(
                    path: intent.path,
                    contributionID: MarginID.annotation(contributionID),
                    disposition: disposition
                )
            )

        case "file":
            guard let result = intent.result, let cursor = baseCursor[intent.path] else {
                throw CLIError.usage("A file intent requires result and must target an existing cursor-bound path.")
            }
            let mutation = try CollaborationFileMutation(
                id: "\(operationID)#mutation",
                path: intent.path,
                precondition: intent.precondition ?? .exact(cursor),
                result: result
            )
            return .file(id: operationID, mutation)

        default:
            throw CLIError.usage("Unknown stage intent kind '\(intent.kind)'.")
        }
    }

    private static func contributionDetails(
        kind: CollaborationContributionKind,
        intent: StageIntentOperation
    ) throws -> CollaborationContributionDetails {
        switch kind {
        case .comment:
            return .comment(CollaborationCommentDetails(parentID: intent.parentID.map(MarginID.annotation)))
        case .question:
            return .question(CollaborationQuestionDetails(
                answerContributionID: intent.answerContributionID.map(MarginID.annotation)
            ))
        case .issue:
            guard let state = CollaborationIssueState(rawValue: intent.issueState ?? "open") else {
                throw CLIError.usage("issueState must be open, resolved, or wont-fix.")
            }
            return .issue(CollaborationIssueDetails(state: state))
        case .decision:
            guard let status = CollaborationDecisionStatus(rawValue: intent.decisionStatus ?? "proposed") else {
                throw CLIError.usage("decisionStatus must be proposed, accepted, or superseded.")
            }
            return .decision(CollaborationDecisionDetails(status: status, rationale: intent.rationale))
        case .task:
            guard let state = CollaborationTaskState(rawValue: intent.taskState ?? "open"),
                  let priority = CollaborationPriority(rawValue: intent.priority ?? "normal") else {
                throw CLIError.usage("taskState or priority is invalid.")
            }
            return .task(CollaborationTaskDetails(
                state: state,
                assignee: intent.assignee,
                priority: priority
            ))
        case .approval:
            guard let state = CollaborationApprovalState(rawValue: intent.approvalState ?? "requested") else {
                throw CLIError.usage("approvalState must be requested, approved, or changes-requested.")
            }
            return .approval(CollaborationApprovalDetails(
                state: state,
                subjectID: intent.subjectID.map(MarginID.annotation)
            ))
        case .suggestion, .handoff:
            preconditionFailure("factory-backed contribution kind")
        }
    }

    private static func resolveIntentSelector(
        _ intent: StageIntentOperation,
        in body: String
    ) throws -> ResolvedSuggestionSelector? {
        let modes = [intent.quote != nil, intent.range != nil, intent.from != nil || intent.to != nil]
            .filter { $0 }.count
        guard modes <= 1 else {
            throw CLIError.usage("A contribution intent may use only one of quote, range, or from/to.")
        }
        if let quote = intent.quote {
            return try SuggestionSelectorArguments.quote(
                exact: quote,
                prefix: intent.prefix,
                suffix: intent.suffix,
                occurrence: intent.occurrence,
                expected: intent.expectedText
            ).resolve(in: body)
        }
        if let range = intent.range {
            return try SuggestionSelectorArguments.range(
                range,
                expected: intent.expectedText
            ).resolve(in: body)
        }
        if intent.from != nil || intent.to != nil {
            guard let from = intent.from, let to = intent.to else {
                throw CLIError.usage("A contribution intent must supply from and to together.")
            }
            return try SuggestionSelectorArguments.coordinates(
                from: from,
                to: to,
                expected: intent.expectedText
            ).resolve(in: body)
        }
        guard intent.prefix == nil, intent.suffix == nil, intent.occurrence == nil,
              intent.expectedText == nil else {
            throw CLIError.usage("prefix, suffix, occurrence, and expectedText require a passage selector.")
        }
        return nil
    }

    private static func loadAnnotations(
        root: CollaborationRoot,
        paths: [String]?,
        limits: CollaborationContextLimits,
        matching: (ListedComment) -> Bool = { _ in true }
    ) throws -> LoadedAnnotations {
        let discovery = try cursorService.discover(root: root, paths: paths, limits: limits.discovery)
        guard !discovery.paths.isEmpty else {
            throw CollaborationError.invalidCursor("The bounded selection contains no Markdown document.")
        }
        let locked = try transactionEngine.read(root: root, paths: discovery.paths)
        var files: [LoadedAnnotationFile] = []
        var cursors: [CollaborationFileCursor] = []
        var omitted = 0
        for file in locked {
            let decoded = try codec.decode(file.data)
            let snapshot = try commentService.snapshot(from: decoded)
            let matches = snapshot.comments.filter(matching)
            let selected = Array(matches.prefix(limits.maxContributionsPerFile))
            omitted += max(0, matches.count - selected.count)
            files.append(LoadedAnnotationFile(
                path: file.path,
                annotationRevision: snapshot.revision,
                comments: selected
            ))
            cursors.append(try CollaborationFileCursor(
                path: file.path,
                documentID: decoded.envelope?.document.id,
                contentSha256: DocumentRevision(data: decoded.bodyData).sha256,
                annotationRevision: decoded.envelope?.revision ?? 0,
                annotationSha256: try CollaborationCanonicalJSON.sha256(of: decoded.envelope?.items ?? []),
                wholeFileSha256: CollaborationCanonicalJSON.sha256(of: file.data)
            ))
        }
        return LoadedAnnotations(
            cursor: try CollaborationCursor(root: root, files: cursors),
            files: files,
            truncation: ListTruncation(discovery: discovery, omittedContributionCount: omitted)
        )
    }

    private static func contributionKind(_ annotation: MarginComment) -> CollaborationContributionKind {
        guard let raw = stringValue(annotation.extensions["margin:kind"]),
              let kind = CollaborationContributionKind(rawValue: raw) else {
            return .comment
        }
        return kind
    }

    private static func shortReference(
        path: String,
        annotationID: String,
        used: inout Set<String>
    ) -> String {
        let name = path == "."
            ? "document"
            : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let stem = name.isEmpty ? "document" : name
        let digest = CollaborationCanonicalJSON.sha256(of: Data(annotationID.utf8))
        for length in stride(from: 8, through: 64, by: 4) {
            let candidate = "\(stem)#\(digest.prefix(length))"
            if used.insert(candidate).inserted { return candidate }
        }
        let secondary = CollaborationCanonicalJSON.sha256(of: Data("\(path)\0\(annotationID)".utf8))
        var ordinal = 1
        while true {
            let candidate = "\(stem)#\(digest)-\(secondary.prefix(12))-\(ordinal)"
            if used.insert(candidate).inserted { return candidate }
            ordinal += 1
        }
    }

    private static func requiredValue(_ name: String, cursor: inout ArgumentCursor) throws -> String {
        guard let value = try cursor.takeValue(name) else {
            throw CLIError.usage("Option \(name) is required.")
        }
        return value
    }

    private static func parseRange(_ raw: String) throws -> UnicodeScalarRange {
        let values = raw.split(separator: ":", maxSplits: 1)
        guard values.count == 2,
              let start = Int(values[0]),
              let end = Int(values[1]),
              start >= 0,
              end > start else {
            throw CLIError.usage("--range expects nonnegative half-open Unicode-scalar offsets START:END.")
        }
        return UnicodeScalarRange(start: start, end: end)
    }

    private static func takeSuggestionSelector(
        cursor: inout ArgumentCursor
    ) throws -> SuggestionSelectorArguments {
        let quote = try cursor.takeValue("--quote")
        let rawRange = try cursor.takeValue("--range")
        let from = try cursor.takeValue("--from")
        let to = try cursor.takeValue("--to")
        let expected = try cursor.takeValue("--expect")
        let prefix = try cursor.takeValue("--prefix")
        let suffix = try cursor.takeValue("--suffix")
        let occurrence = try cursor.takeInt("--occurrence")
        let modes = [quote != nil, rawRange != nil, from != nil || to != nil].filter { $0 }.count
        guard modes == 1 else {
            throw CLIError.usage("Choose exactly one selector: --quote, --range, or --from with --to.")
        }
        if let quote {
            return .quote(
                exact: quote,
                prefix: prefix,
                suffix: suffix,
                occurrence: occurrence,
                expected: expected
            )
        }
        guard prefix == nil, suffix == nil, occurrence == nil else {
            throw CLIError.usage("--prefix, --suffix, and --occurrence require --quote.")
        }
        if let rawRange {
            return .range(try parseRange(rawRange), expected: expected)
        }
        guard let from, let to else {
            throw CLIError.usage("--from and --to must be provided together as LINE:COLUMN.")
        }
        return .coordinates(from: from, to: to, expected: expected)
    }

    private static func loadDocumentBase(
        root: CollaborationRoot,
        path: String
    ) throws -> LoadedDocumentBase {
        let loaded = try loadDocumentBases(root: root, paths: [path])
        guard let document = loaded.documents[path] else {
            throw CollaborationError.invalidCursor("The selected document could not be decoded.")
        }
        return LoadedDocumentBase(
            document: document,
            cursor: loaded.cursor
        )
    }

    private static func loadDocumentBases(
        root: CollaborationRoot,
        paths: [String]
    ) throws -> LoadedDocumentBases {
        let locked = try transactionEngine.read(root: root, paths: paths)
        var documents: [String: EmbeddedCommentDocument] = [:]
        var cursors: [CollaborationFileCursor] = []
        for file in locked {
            let document = try codec.decode(file.data)
            documents[file.path] = document
            cursors.append(try CollaborationFileCursor(
                path: file.path,
                documentID: document.envelope?.document.id,
                contentSha256: DocumentRevision(data: document.bodyData).sha256,
                annotationRevision: document.envelope?.revision ?? 0,
                annotationSha256: try CollaborationCanonicalJSON.sha256(of: document.envelope?.items ?? []),
                wholeFileSha256: CollaborationCanonicalJSON.sha256(of: file.data)
            ))
        }
        return LoadedDocumentBases(
            documents: documents,
            cursor: try CollaborationCursor(root: root, files: cursors)
        )
    }

    private static func existingDirectory(_ raw: String) throws -> URL {
        let url = try PathResolver.existingItem(raw)
        guard isDirectory(url) else { throw CLIError.usage("Expected a directory at \(url.path).") }
        return url
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var value: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
    }

    private static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes {
            throw CLIError("INPUT_TOO_LARGE", "Input exceeds the \(maximumBytes)-byte limit: \(url.path)", exit: .data)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else {
            throw CLIError("INPUT_TOO_LARGE", "Input exceeds the \(maximumBytes)-byte limit: \(url.path)", exit: .data)
        }
        return data
    }

    private static func writeMergeOutput(_ data: Data, to url: URL, force: Bool) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw CLIError("OUTPUT_IS_DIRECTORY", "Merge output is a directory: \(url.path)", exit: .cannotCreate)
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CLIError(
                    "UNSAFE_OUTPUT",
                    "Merge output must be a regular file and cannot be a symbolic link: \(url.path)",
                    exit: .permission
                )
            }
            guard force else {
                throw CLIError(
                    "OUTPUT_EXISTS",
                    "Merge output already exists; pass --force to replace it atomically: \(url.path)",
                    exit: .cannotCreate
                )
            }
            _ = try AtomicDocumentStore().transaction(at: url) { _ in
                AtomicDocumentMutation(data: data, result: true)
            }
            return
        }
        let parent = url.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw CLIError.notFound("The merge output parent directory does not exist: \(parent.path)")
        }
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw CLIError(
                    "OUTPUT_EXISTS",
                    "Merge output was created concurrently; pass --force to replace an existing file: \(url.path)",
                    exit: .cannotCreate
                )
            }
            throw CLIError(
                "OUTPUT_CREATE_FAILED",
                "Could not create merge output: \(String(cString: strerror(errno))).",
                exit: .cannotCreate
            )
        }
        var completed = false
        defer {
            _ = close(descriptor)
            if !completed { _ = unlink(url.path) }
        }
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return data.isEmpty }
            var remaining = buffer.count
            while remaining > 0 {
                let count = marginCLIPOSIXWrite(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
        guard wrote, fsync(descriptor) == 0 else {
            throw CLIError("OUTPUT_WRITE_FAILED", "Could not durably write merge output.", exit: .io)
        }
        completed = true
        let parentDescriptor = open(parent.path, O_RDONLY)
        if parentDescriptor >= 0 {
            _ = fsync(parentDescriptor)
            _ = close(parentDescriptor)
        }
    }

    private static func readStandardInput(maximumBytes: Int) throws -> Data {
        let data = try FileHandle.standardInput.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw CLIError("INPUT_TOO_LARGE", "Standard input exceeds the \(maximumBytes)-byte limit.", exit: .data)
        }
        return data
    }

    private static func readUTF8StandardInput(maximumBytes: Int) throws -> String {
        let data = try readStandardInput(maximumBytes: maximumBytes)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CLIError("INVALID_STDIN", "Standard input is not valid UTF-8.", exit: .data)
        }
        return value.trimmingCharacters(in: .newlines)
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let result)? = value else { return nil }
        return result
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(stringValue)
    }

    private static func contributionPayload(
        in document: EmbeddedCommentDocument,
        id: String
    ) throws -> CollaborationContribution? {
        guard let annotation = document.envelope?.items.first(where: { $0.id == id }) else {
            return nil
        }
        guard let payload = annotation.extensions["margin:contributionPayload"] else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                CollaborationContribution.self,
                from: JSONEncoder().encode(payload)
            )
        } catch {
            throw CollaborationError.invalidContribution(
                "Existing contribution '\(id)' has an invalid immutable payload."
            )
        }
    }

    private static func preview(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        guard maximumBytes > 0 else { return "" }
        var end = value.startIndex
        var count = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let bytes = value[end..<next].utf8.count
            if count + bytes > maximumBytes { break }
            count += bytes
            end = next
        }
        return String(value[..<end]) + "…"
    }

    private static func targetIsDirectory(_ target: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func directContextTarget(
        invocationTarget: String,
        targetIsDirectory: Bool,
        root: CollaborationRoot,
        files: [CollaborationContextFile]
    ) -> String? {
        guard targetIsDirectory else { return invocationTarget }
        guard files.count == 1, let path = files.first?.path else { return nil }
        let target: URL
        if root.kind == .document || path == "." {
            target = URL(fileURLWithPath: root.path, isDirectory: false)
        } else {
            target = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent(path, isDirectory: false)
        }
        return pathRelativeToCurrentDirectoryIfPossible(target.path)
    }

    /// Keep bounded context directly actionable without unnecessarily turning a
    /// caller-relative workspace path into a machine-specific absolute path.
    /// Absolute paths remain the fallback when the selected document is outside
    /// the current directory.
    static func pathRelativeToCurrentDirectoryIfPossible(
        _ absolutePath: String,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> String {
        let current = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: absolutePath, isDirectory: false)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = current.hasSuffix("/") ? current : current + "/"
        guard target.hasPrefix(prefix) else { return target }
        let relative = String(target.dropFirst(prefix.count))
        return relative.isEmpty ? "." : relative
    }

    private static func contextPathSemantics(
        invocationTargetIsDirectory: Bool,
        hasDirectFileTarget: Bool
    ) -> String {
        if !invocationTargetIsDirectory {
            return "invocationTarget is a file and is directly reusable. files[].path is relative to the collaboration root; fileActions[].actionPath is reusable by file-only commands."
        }
        if hasDirectFileTarget {
            return "invocationTarget is a directory and is not valid for file-only comment commands. directFileTarget and fileActions[].actionPath are caller-relative when safe and directly reusable."
        }
        return "invocationTarget is a directory. files[].path is relative to root; use the matching fileActions[].actionPath for file-only commands."
    }

    private static func stageReviewActions(
        root: CollaborationRoot,
        stageID: String
    ) -> [CollaborationNextAction] {
        [
            CollaborationNextAction(
                condition: "review this exact immutable stage before deciding",
                command: "stage show",
                arguments: [root.path, stageID]
            ),
            CollaborationNextAction(
                condition: "submit only after the bounded stage review is accepted",
                command: "stage submit",
                arguments: [root.path, stageID]
            ),
            CollaborationNextAction(
                condition: "if submit reports stale metadata, derive and atomically submit a new immutable stage while retaining the prior stage",
                command: "stage refresh",
                arguments: [root.path, stageID, "--submit"]
            ),
        ]
    }

    private static func submitStage(
        _ changeSet: CollaborationChangeSet,
        root: CollaborationRoot,
        stageID: String
    ) throws -> StageSubmitResult {
        let receipt: CollaborationTransactionReceipt
        do {
            receipt = try submit(changeSet)
        } catch let error as CollaborationError {
            guard case .preconditionFailed = error else { throw error }
            throw CLIError(
                error.code,
                "\(error.localizedDescription) The immutable stage was retained. Refresh and submit it in one retry; add --id NEW_STAGE_ID when a stable handoff identity is required.",
                exit: .temporaryFailure,
                details: [
                    "stageID": stageID,
                    "stageRetained": "true",
                    "recoveryCommand": "margin stage refresh ROOT STAGE_ID --submit",
                    "recoveryRoot": root.path,
                    "recoveryStageID": stageID,
                ]
            )
        }
        var stageRemoved = true
        var cleanupWarning: String?
        do {
            try stageStore.remove(stageID: stageID, root: root)
        } catch {
            stageRemoved = false
            cleanupWarning = "The transaction committed, but pending stage cleanup failed: \(error.localizedDescription)"
        }
        return StageSubmitResult(
            transaction: receipt,
            stageRemoved: stageRemoved,
            cleanupWarning: cleanupWarning
        )
    }

    private static func loadStage(
        stageID: String,
        root: CollaborationRoot
    ) throws -> CollaborationChangeSet {
        do {
            return try stageStore.load(stageID: stageID, root: root)
        } catch let error as CollaborationError {
            guard case .stageNotFound = error else { throw error }
            throw stageNotFoundError(error, root: root, stageID: stageID)
        }
    }

    private static func stageNotFoundError(
        _ error: CollaborationError,
        root: CollaborationRoot,
        stageID: String
    ) -> CLIError {
        CLIError(
            error.code,
            error.localizedDescription,
            exit: .notFound,
            details: [
                "requestedStageID": stageID,
                "recoveryCommand": "margin stage list ROOT",
                "recoveryRoot": root.path,
            ]
        )
    }

    private static func slug(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars
        let mapped = scalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let joined = String(mapped)
        return joined.split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
    }

    private static func write<Result: Encodable>(
        command: String,
        root: CollaborationRoot?,
        result: Result,
        pretty: Bool,
        maximumBytes: Int? = nil,
        notice: String? = nil,
        nextActions: [CollaborationNextAction]? = nil
    ) throws {
        try CLIOutput.json(
            CollaborationCommandEnvelope(
                command: command,
                root: root,
                result: result,
                notice: notice,
                nextActions: nextActions
            ),
            pretty: pretty,
            maximumBytes: maximumBytes
        )
    }
}

private struct CollaborationCommandEnvelope<Result: Encodable>: Encodable {
    let schema = "urn:margin:cli:v1"
    let ok = true
    let command: String
    let root: CollaborationRoot?
    let result: Result
    var notice: String? = nil
    var nextActions: [CollaborationNextAction]? = nil
}

private struct CollaborationNextAction: Encodable {
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

private struct ContextOptions {
    let explicitRoot: String?
    let paths: [String]
    let limits: CollaborationContextLimits
}

private struct ResolvedSelection {
    let root: CollaborationRoot
    let paths: [String]?
}

private struct MutationSelection {
    let root: CollaborationRoot
    let path: String
}

private struct RequestIdentities {
    let requestID: String
    let stageID: String
}

private struct LoadedDocumentBase {
    let document: EmbeddedCommentDocument
    let cursor: CollaborationCursor
}

private struct LoadedDocumentBases {
    let documents: [String: EmbeddedCommentDocument]
    let cursor: CollaborationCursor
}

private struct ResolvedSuggestionSelector {
    let range: UnicodeScalarRange
    let expectedText: String
}

private enum SuggestionSelectorArguments {
    case quote(exact: String, prefix: String?, suffix: String?, occurrence: Int?, expected: String?)
    case range(UnicodeScalarRange, expected: String?)
    case coordinates(from: String, to: String, expected: String?)

    func resolve(in body: String) throws -> ResolvedSuggestionSelector {
        let projection = AnchorResolver.normalizedProjection(body)
        let input: CommentAnchorInput
        let suppliedExpected: String?
        switch self {
        case .quote(let exact, let prefix, let suffix, let occurrence, let expected):
            input = .quote(exact: exact, prefix: prefix, suffix: suffix, occurrence: occurrence)
            suppliedExpected = expected
        case .range(let range, let expected):
            input = .range(start: range.start, end: range.end, expectedExact: expected)
            suppliedExpected = expected
        case .coordinates(let from, let to, let expected):
            let startPoint = try TextSpan(parsing: "\(from)-\(from)").start
            let endPoint = try TextSpan(parsing: "\(to)-\(to)").start
            let startIndex = try TextCoordinates.index(for: startPoint, in: projection)
            let endIndex = try TextCoordinates.index(for: endPoint, in: projection)
            let start = TextCoordinates.unicodeScalarOffset(of: startIndex, in: projection)
            let end = TextCoordinates.unicodeScalarOffset(of: endIndex, in: projection)
            input = .range(start: start, end: end, expectedExact: expected)
            suppliedExpected = expected
        }
        let target = try AnchorResolver().target(
            for: input,
            documentID: "urn:margin:suggestion-selector",
            in: projection
        )
        guard case .selection(let selection) = target,
              let range = try AnchorResolver().resolve(selection, in: projection).range else {
            throw CLIError("SUGGESTION_NOT_ANCHORED", "The suggestion selector did not resolve to one passage.", exit: .data)
        }
        let scalars = Array(projection.unicodeScalars)
        guard range.start >= 0, range.end <= scalars.count, range.end > range.start else {
            throw CLIError("INVALID_SUGGESTION_RANGE", "The resolved suggestion range is outside the document.", exit: .data)
        }
        let exact = String(String.UnicodeScalarView(scalars[range.start..<range.end]))
        if let suppliedExpected,
           AnchorResolver.normalizedProjection(suppliedExpected) != exact {
            throw CLIError(
                "EXPECTED_TEXT_MISMATCH",
                "--expect does not match the uniquely resolved suggestion passage.",
                exit: .data
            )
        }
        return ResolvedSuggestionSelector(range: range, expectedText: exact)
    }
}

private struct ContextResult: Encodable {
    let invocationTarget: String
    let directFileTarget: String?
    let pathSemantics: String
    let cursor: String
    let files: [CollaborationContextFile]
    let fileActions: [ContextFileAction]
    let actors: [CollaborationActor]
    let activity: [CollaborationActorActivity]
    let truncation: CollaborationContextTruncation
    let availableActions: [CollaborationAvailableAction]
    let workflowGuidance: [ContextWorkflowHint]
}

private struct ContextBriefResult: Encodable {
    let invocationTarget: String
    let directFileTarget: String?
    let cursorOmitted = true
    let files: [ContextBriefFile]
    let work: [ContextBriefContribution]
    let truncation: ContextBriefTruncation
    let workflowGuidance: [ContextBriefWorkflowHint]
    let omittedWorkflowGuidanceCount: Int
}

private struct ContextBriefFile: Encodable {
    let path: String
    let actionPath: String
    let annotationRevision: Int
    let sourcePreview: String
    let sourcePreviewTruncated: Bool
    let outline: [MarkdownHeading]?
    let contributionCount: Int
    let omittedHeadingCount: Int?
    let omittedContributionCount: Int?

    init(file: CollaborationContextFile, root: CollaborationRoot) {
        let action = ContextFileAction(file: file, root: root)
        path = file.path
        actionPath = action.actionPath
        annotationRevision = action.annotationRevision
        sourcePreview = file.sourcePreview
        sourcePreviewTruncated = file.sourcePreviewTruncated
        outline = file.sourcePreviewTruncated ? file.outline : nil
        contributionCount = file.contributions.count
        omittedHeadingCount = file.omittedHeadingCount > 0 ? file.omittedHeadingCount : nil
        omittedContributionCount = file.omittedContributionCount > 0
            ? file.omittedContributionCount : nil
    }
}

private struct ContextBriefTruncation: Encodable {
    let isTruncated: Bool
    let omittedFileCount: Int?
    let omittedFileCountIsLowerBound: Bool?
    let omittedHeadingCount: Int?
    let omittedContributionCount: Int?
    let omittedActivityCount: Int?
    let hitFileLimit: Bool?
    let hitByteLimit: Bool?
    let hitDepthLimit: Bool?
    let hitOutputByteLimit: Bool?

    init(_ value: CollaborationContextTruncation) {
        isTruncated = value.isTruncated
        omittedFileCount = value.discovery.omittedFileCount > 0
            ? value.discovery.omittedFileCount : nil
        omittedFileCountIsLowerBound = value.discovery.omittedFileCountIsLowerBound == true
            ? true : nil
        omittedHeadingCount = value.omittedHeadingCount > 0
            ? value.omittedHeadingCount : nil
        omittedContributionCount = value.omittedContributionCount > 0
            ? value.omittedContributionCount : nil
        omittedActivityCount = value.omittedActivityCount > 0
            ? value.omittedActivityCount : nil
        hitFileLimit = value.discovery.hitFileLimit ? true : nil
        hitByteLimit = value.discovery.hitByteLimit ? true : nil
        hitDepthLimit = value.discovery.hitDepthLimit ? true : nil
        hitOutputByteLimit = value.hitOutputByteLimit ? true : nil
    }
}

private struct ContextBriefContribution: Encodable {
    let id: String
    let rootID: String
    let parentID: String?
    let path: String?
    let actionPath: String
    let kind: CollaborationContributionKind
    let actorID: String
    let bodyPreview: String
    let annotationRevision: Int
    let threadStatus: MarginCommentStatus
    let range: UnicodeScalarRange?
    let anchorState: AnchorResolutionState?
    let assigneeID: String?
    let priority: CollaborationPriority?

    init(
        contribution: CollaborationContextContribution,
        actionPath: String,
        annotationRevision: Int
    ) {
        id = contribution.id
        rootID = contribution.rootID
        parentID = contribution.parentID
        path = contribution.path == actionPath ? nil : contribution.path
        self.actionPath = actionPath
        kind = contribution.kind
        actorID = contribution.actorID
        bodyPreview = contribution.bodyPreview
        self.annotationRevision = annotationRevision
        threadStatus = contribution.threadStatus
        range = contribution.range
        anchorState = contribution.anchorState
        assigneeID = contribution.assigneeID
        priority = contribution.priority
    }
}

private struct ContextBriefWorkflowHint: Encodable {
    let purpose: String
    let argv: [String]?
    let argvTemplate: [String]?
    let requiredReplacements: [String]?

    init(_ hint: ContextWorkflowHint) {
        purpose = hint.purpose
        argv = hint.argv
        argvTemplate = hint.argvTemplate
        requiredReplacements = hint.requiredReplacements
    }
}

private struct ContextFileAction: Encodable {
    let path: String
    let actionPath: String
    let annotationRevision: Int
    let annotationRevisionSemantics = "observed-pre-write-value; copy exactly; zero is valid"
    let commentArgvTemplate: [String]
    let requiredReplacements = ["KIND", "TEXT", "UUID"]

    init(file: CollaborationContextFile, root: CollaborationRoot) {
        path = file.path
        let url: URL
        if root.kind == .document || file.path == "." {
            url = URL(fileURLWithPath: root.path, isDirectory: false)
        } else {
            url = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent(file.path, isDirectory: false)
        }
        actionPath = CollaborationCLI.pathRelativeToCurrentDirectoryIfPossible(url.path)
        annotationRevision = file.cursor.annotationRevision
        commentArgvTemplate = [
            "comments", "add", actionPath, "--document", "--kind", "KIND",
            "-m", "TEXT", "--contribution-id", "UUID", "--if-revision",
            String(annotationRevision),
        ]
    }
}

private struct ContextWorkflowHint: Encodable {
    let purpose: String
    let command: String
    let arguments: [String]
    let note: String
    let executable: Bool
    let argv: [String]?
    let argvTemplate: [String]?
    let requiredReplacements: [String]?

    init(purpose: String, command: String, arguments: [String], note: String) {
        self.purpose = purpose
        self.command = command
        self.arguments = arguments
        self.note = note
        let complete = command.split(separator: " ").map(String.init) + arguments
        var seen = Set<String>()
        let replacements = arguments.compactMap { argument -> String? in
            guard Self.isPlaceholder(argument), seen.insert(argument).inserted else { return nil }
            return argument
        }
        executable = replacements.isEmpty
        argv = replacements.isEmpty ? complete : nil
        argvTemplate = replacements.isEmpty ? nil : complete
        requiredReplacements = replacements.isEmpty ? nil : replacements
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.uppercaseLetters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || $0 == "_"
        }
    }

    private static func argument(_ placeholder: String, directTarget: String?) -> String {
        guard placeholder == "FILE" || placeholder == "TARGET" else { return placeholder }
        return directTarget ?? placeholder
    }

    static func defaults(directTarget: String?) -> [ContextWorkflowHint] {
        [ContextWorkflowHint(
            purpose: "answer an existing open thread",
            command: "comments reply",
            arguments: [
                argument("FILE", directTarget: directTarget), "ROOT_ID", "-m", "TEXT", "--id", "UUID",
                "--if-revision", "OBSERVED_ANNOTATION_REVISION",
            ],
            note: "Reply with the rootID directly; no source-range calculation is needed. Reuse invocationTarget instead of files[].path when a file was supplied. Add --resolve when this reply is also authorized to close the concern."
        ),
        ContextWorkflowHint(
            purpose: "answer and close an existing open thread atomically",
            command: "comments reply",
            arguments: [
                argument("FILE", directTarget: directTarget), "ROOT_ID", "-m", "TEXT", "--resolve",
                "--id", "UUID", "--if-revision", "OBSERVED_ANNOTATION_REVISION",
            ],
            note: "The reply and root resolution share one revision: both are saved or neither is. Use only when closure is authorized."
        ),
        ContextWorkflowHint(
            purpose: "close an addressed thread",
            command: "comments resolve",
            arguments: [argument("FILE", directTarget: directTarget), "ROOT_ID", "--if-revision", "REPLY_REVISION"],
            note: "Replying does not resolve the root. Resolve only when the task authorizes closure."
        ),
        ContextWorkflowHint(
            purpose: "verify a complete durable thread",
            command: "comments list",
            arguments: [argument("FILE", directTarget: directTarget), "--thread", "ROOT_ID", "--status", "all"],
            note: "Use --thread ROOT_ID and then validate the document."
        ),
        ContextWorkflowHint(
            purpose: "start typed document-level work",
            command: "comments add",
            arguments: [
                argument("FILE", directTarget: directTarget), "--document", "--kind", "KIND", "-m", "TEXT",
                "--contribution-id", "UUID", "--if-revision", "OBSERVED_ANNOTATION_REVISION",
            ],
            note: "Choose the requested kind explicitly: comment, question, issue, decision, task, or approval. Copy the observed annotation revision exactly; zero is valid and must not be incremented before the write."
        )]
    }

    static func forInboxItem(_ item: InboxItem) -> [ContextWorkflowHint] {
        if item.threadStatus == .resolved {
            return [
                ContextWorkflowHint(
                    purpose: "inspect the first matching resolved inbox thread",
                    command: "comments list",
                    arguments: [
                        item.actionPath, "--thread", item.rootID, "--status", "all",
                    ],
                    note: "Inspect the complete resolved thread before deciding whether more work is authorized."
                ),
                ContextWorkflowHint(
                    purpose: "reply and reopen the first matching resolved inbox thread atomically",
                    command: "comments reply",
                    arguments: [
                        item.actionPath, item.rootID, "-m", "TEXT", "--reopen",
                        "--id", "UUID", "--if-revision", String(item.annotationRevision),
                    ],
                    note: "Use only when continuing resolved work is authorized; reopen and reply are atomic."
                ),
            ]
        }
        return openThreadActions(
            actionPath: item.actionPath,
            rootID: item.rootID,
            annotationRevision: item.annotationRevision,
            description: "the first matching open inbox thread"
        )
    }

    private static func openThreadActions(
        actionPath: String,
        rootID: String,
        annotationRevision: Int,
        description: String
    ) -> [ContextWorkflowHint] {
        [ContextWorkflowHint(
            purpose: "reply to \(description)",
            command: "comments reply",
            arguments: [
                actionPath, rootID, "-m", "TEXT", "--id", "UUID",
                "--if-revision", String(annotationRevision),
            ],
            note: "Path, root ID, and revision are exact. Replace only TEXT and UUID; add --resolve only when closure is authorized."
        ),
        ContextWorkflowHint(
            purpose: "reply and close \(description) atomically",
            command: "comments reply",
            arguments: [
                actionPath, rootID, "-m", "TEXT", "--resolve", "--id", "UUID",
                "--if-revision", String(annotationRevision),
            ],
            note: "Use only when closure is authorized; reply and resolution are atomic."
        ),
        ContextWorkflowHint(
            purpose: "verify \(description)",
            command: "comments list",
            arguments: [actionPath, "--thread", rootID, "--status", "all"],
            note: "Inspect the complete thread, then validate the document."
        )]
    }

    static func forSnapshot(
        _ snapshot: CollaborationContextSnapshot,
        directTarget: String?,
        invocationTarget: String,
        invocationTargetIsDirectory: Bool
    ) -> [ContextWorkflowHint] {
        let contributions = snapshot.files.flatMap(\.contributions)
        let kinds = Set(contributions.map(\.kind))
        let sourceHints = sourceReadingHints(snapshot, directTarget: directTarget)
        if contributions.isEmpty {
            return sourceHints + startingWork(
                snapshot,
                directTarget: directTarget,
                invocationTarget: invocationTarget,
                invocationTargetIsDirectory: invocationTargetIsDirectory
            )
        }
        var relevant: [ContextWorkflowHint] = []
        let ordinaryOpen = contributions.first {
            $0.threadStatus == .open
                && $0.parentID == nil
                && $0.kind != .suggestion
                && $0.kind != .handoff
        }
        if let ordinaryOpen,
           let file = snapshot.files.first(where: { $0.path == ordinaryOpen.path }) {
            let action = ContextFileAction(file: file, root: snapshot.root)
            relevant += openThreadActions(
                actionPath: action.actionPath,
                rootID: ordinaryOpen.rootID,
                annotationRevision: action.annotationRevision,
                description: "the first open durable thread"
            )
            relevant += handoffActions(
                snapshot,
                directTarget: directTarget,
                invocationTarget: invocationTarget,
                invocationTargetIsDirectory: invocationTargetIsDirectory,
                preferredPath: ordinaryOpen.path
            )
        }
        if kinds.contains(.suggestion),
           let suggestion = contributions.first(where: {
               $0.kind == .suggestion && $0.threadStatus == .open
           }),
           let file = snapshot.files.first(where: { $0.path == suggestion.path }) {
            let action = ContextFileAction(file: file, root: snapshot.root)
            relevant += [
                ContextWorkflowHint(
                    purpose: "accept the first open suggestion when authorized",
                    command: "suggest accept",
                    arguments: [action.actionPath, suggestion.id],
                    note: "The target and suggestion ID are concrete. Acceptance edits Markdown; run it only after confirming the proposed change is authorized and the source preview is sufficient."
                ),
                ContextWorkflowHint(
                    purpose: "reject the first open suggestion without editing source",
                    command: "suggest reject",
                    arguments: [action.actionPath, suggestion.id],
                    note: "The target and suggestion ID are concrete. Rejection records the deciding actor and remains safe after source drift."
                ),
                ContextWorkflowHint(
                    purpose: "inspect all durable suggestions when more detail is needed",
                    command: "suggest list",
                    arguments: [directTarget ?? action.actionPath],
                    note: "Use this when another suggestion or a longer body must be reviewed; context already includes the first bounded work item."
                ),
            ]
        }
        if kinds.contains(.handoff),
           let handoff = contributions.first(where: {
               $0.kind == .handoff && $0.threadStatus == .open
           }),
           let file = snapshot.files.first(where: { $0.path == handoff.path }) {
            let action = ContextFileAction(file: file, root: snapshot.root)
            relevant += openThreadActions(
                actionPath: action.actionPath,
                rootID: handoff.rootID,
                annotationRevision: action.annotationRevision,
                description: "the first open durable handoff"
            )
        }
        return sourceHints + (relevant.isEmpty ? defaults(directTarget: directTarget) : relevant)
    }

    private static func sourceReadingHints(
        _ snapshot: CollaborationContextSnapshot,
        directTarget: String?
    ) -> [ContextWorkflowHint] {
        guard let file = snapshot.files.first(where: { $0.sourcePreviewTruncated }) else { return [] }
        let fileArgument: String
        if let directTarget, snapshot.files.count == 1 {
            fileArgument = directTarget
        } else if snapshot.root.kind == .document || file.path == "." {
            fileArgument = CollaborationCLI.pathRelativeToCurrentDirectoryIfPossible(snapshot.root.path)
        } else {
            let target = URL(fileURLWithPath: snapshot.root.path, isDirectory: true)
                .appendingPathComponent(file.path, isDirectory: false)
            fileArgument = CollaborationCLI.pathRelativeToCurrentDirectoryIfPossible(target.path)
        }
        return [ContextWorkflowHint(
            purpose: "read beyond the bounded Markdown source preview",
            command: "read",
            arguments: [fileArgument, "--json"],
            note: "sourcePreview is intentionally bounded. Use read for the complete logical Markdown before making a source-dependent decision."
        )]
    }

    private static func startingWork(
        _ snapshot: CollaborationContextSnapshot,
        directTarget: String?,
        invocationTarget: String,
        invocationTargetIsDirectory: Bool
    ) -> [ContextWorkflowHint] {
        let selectedFile = snapshot.files.count == 1 ? snapshot.files[0] : nil
        let selectedRevision = selectedFile.map { String($0.cursor.annotationRevision) }
            ?? "OBSERVED_ANNOTATION_REVISION"
        return handoffActions(
            snapshot,
            directTarget: directTarget,
            invocationTarget: invocationTarget,
            invocationTargetIsDirectory: invocationTargetIsDirectory,
            preferredPath: selectedFile?.path
        ) + [
            ContextWorkflowHint(
                purpose: "start typed document-level work",
                command: "comments add",
                arguments: [
                    directTarget ?? "FILE", "--document", "--kind", "KIND", "-m", "TEXT",
                    "--contribution-id", "UUID", "--if-revision", selectedRevision,
                ],
                note: "Choose the requested kind explicitly. For directory context, take the exact file and revision from fileActions instead of shortening files[].path or assuming revision zero."
            ),
        ]
    }

    private static func handoffActions(
        _ snapshot: CollaborationContextSnapshot,
        directTarget: String?,
        invocationTarget: String,
        invocationTargetIsDirectory: Bool,
        preferredPath: String?
    ) -> [ContextWorkflowHint] {
        let selectedPath = preferredPath
            ?? (snapshot.files.count == 1 ? snapshot.files[0].path : nil)
            ?? "RELATIVE_MARKDOWN_PATH"
        var handoffArguments: [String]
        var verificationArguments: [String]
        if invocationTargetIsDirectory {
            handoffArguments = [invocationTarget, "--path", selectedPath]
            verificationArguments = [invocationTarget, "--path", selectedPath]
        } else {
            handoffArguments = [directTarget ?? invocationTarget]
            verificationArguments = [directTarget ?? invocationTarget]
        }
        handoffArguments += [
            "-m", "TEXT", "--next-actor", "ACTOR_ID", "--contribution-id", "UUID",
            "--request-id", "UUID",
        ]
        return [
            ContextWorkflowHint(
                purpose: "start a durable handoff",
                command: "handoff add",
                arguments: handoffArguments,
                note: "For directories, keep TARGET and --path. The starting cursor is captured automatically."
            ),
            ContextWorkflowHint(
                purpose: "verify the new handoff",
                command: "handoff list",
                arguments: verificationArguments,
                note: "Inspect the returned id, actor, recipient, and body."
            ),
        ]
    }
}

private struct CollaboratorsResult: Encodable {
    let cursor: String
    let collaborators: [CollaborationActor]
    let activity: [CollaborationActorActivity]
    let truncation: CollaborationContextTruncation
}

private struct InboxFilter: Encodable {
    let status: String
    let kinds: [String]
    let actorID: String?
    let assigneeID: String?
}

private struct InboxResult: Encodable {
    let cursor: String
    let filter: InboxFilter
    let items: [InboxItem]
    let workflowGuidance: [ContextWorkflowHint]
    let truncation: ListTruncation
}

private struct InboxBriefResult: Encodable {
    let cursorOmitted: Bool
    let filter: InboxFilter
    let items: [InboxItem]
    let workflowGuidance: [ContextWorkflowHint]
    let truncation: ListTruncation
}

private struct InboxItem: Encodable {
    let reference: String
    let id: String
    let rootID: String
    let parentID: String?
    let path: String
    let actionPath: String
    let kind: CollaborationContributionKind
    let actorID: String
    let actorName: String
    let bodyPreview: String
    let created: String
    let modified: String
    let annotationRevision: Int
    let threadStatus: MarginCommentStatus
    let range: UnicodeScalarRange?
    let anchorState: AnchorResolutionState?
    let assigneeID: String?
    let priority: CollaborationPriority?
}

private struct StageSummary: Encodable {
    let stageID: String
    let changeSetID: String
    let requestID: String
    let actorID: String
    let created: String
    let operationCount: Int
    let pathCount: Int
    let paths: [String]
    let omittedPathCount: Int
    let baseCursorSha256: String
    let canonicalSha256: String
    let canonicalBytes: Int

    init(_ changeSet: CollaborationChangeSet) throws {
        let data = try CollaborationCanonicalJSON.encode(changeSet)
        stageID = changeSet.stageID
        changeSetID = changeSet.id
        requestID = changeSet.requestID
        actorID = changeSet.actor.id
        created = changeSet.created
        operationCount = changeSet.operations.count
        let allPaths = Array(Set(changeSet.operations.map(\.path))).sorted()
        pathCount = allPaths.count
        paths = Array(allPaths.prefix(64))
        omittedPathCount = max(0, allPaths.count - paths.count)
        baseCursorSha256 = try CollaborationCanonicalJSON.sha256(of: changeSet.baseCursor)
        canonicalSha256 = CollaborationCanonicalJSON.sha256(of: data)
        canonicalBytes = data.count
    }
}

private struct StageListResult: Encodable {
    let stages: [StageSummary]
    let omittedStageCount: Int
    let maximumAggregateBytes: Int
    let selectedCanonicalBytes: Int
    let omittedCanonicalBytes: Int
    let hitAggregateByteLimit: Bool
    let isTruncated: Bool
}

private struct StageDetail: Encodable {
    static let maximumEncodedBytes = 1_048_576

    let summary: StageSummary
    let actor: CollaborationActor
    let rootID: String
    let baseCursorFileCount: Int
    let baseCursorPaths: [String]
    let operations: [StageOperationSummary]
    let truncation: StageShowTruncation

    init(
        _ changeSet: CollaborationChangeSet,
        operations: [StageOperationSummary],
        baseCursorPaths: [String],
        maxPreviewBytes: Int,
        hitOutputByteLimit: Bool
    ) throws {
        summary = try StageSummary(changeSet)
        actor = changeSet.actor
        rootID = changeSet.root.id
        baseCursorFileCount = changeSet.baseCursor.files.count
        self.baseCursorPaths = baseCursorPaths
        self.operations = operations
        truncation = StageShowTruncation(
            maxPreviewBytes: maxPreviewBytes,
            maxEncodedBytes: Self.maximumEncodedBytes,
            includedOperationCount: operations.count,
            omittedOperationCount: max(0, changeSet.operations.count - operations.count),
            includedBaseCursorPathCount: baseCursorPaths.count,
            omittedBaseCursorPathCount: max(0, changeSet.baseCursor.files.count - baseCursorPaths.count),
            hitOutputByteLimit: hitOutputByteLimit
        )
    }
}

private struct StageShowTruncation: Encodable {
    let maxPreviewBytes: Int
    let maxEncodedBytes: Int
    let includedOperationCount: Int
    let omittedOperationCount: Int
    let includedBaseCursorPathCount: Int
    let omittedBaseCursorPathCount: Int
    let hitOutputByteLimit: Bool
    let isTruncated: Bool

    init(
        maxPreviewBytes: Int,
        maxEncodedBytes: Int,
        includedOperationCount: Int,
        omittedOperationCount: Int,
        includedBaseCursorPathCount: Int,
        omittedBaseCursorPathCount: Int,
        hitOutputByteLimit: Bool
    ) {
        self.maxPreviewBytes = maxPreviewBytes
        self.maxEncodedBytes = maxEncodedBytes
        self.includedOperationCount = includedOperationCount
        self.omittedOperationCount = omittedOperationCount
        self.includedBaseCursorPathCount = includedBaseCursorPathCount
        self.omittedBaseCursorPathCount = omittedBaseCursorPathCount
        self.hitOutputByteLimit = hitOutputByteLimit
        isTruncated = omittedOperationCount > 0 || omittedBaseCursorPathCount > 0
    }
}

private struct StageTextPreview: Encodable {
    let preview: String
    let sha256: String
    let bytes: Int
    let isTruncated: Bool

    init(_ value: String, maximumBytes: Int) {
        bytes = value.utf8.count
        sha256 = CollaborationCanonicalJSON.sha256(of: Data(value.utf8))
        isTruncated = bytes > maximumBytes
        guard isTruncated else {
            preview = value
            return
        }
        guard maximumBytes > 0 else {
            preview = ""
            return
        }
        var end = value.startIndex
        var count = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let nextBytes = value[end..<next].utf8.count
            if count + nextBytes > maximumBytes { break }
            count += nextBytes
            end = next
        }
        preview = String(value[..<end]) + "…"
    }
}

private struct StageIdentifierPreview: Encodable {
    let items: [String]
    let totalCount: Int
    let omittedCount: Int

    init(_ values: [String]) {
        items = Array(values.prefix(16))
        totalCount = values.count
        omittedCount = max(0, values.count - items.count)
    }
}

private struct StageTaskReview: Encodable {
    let state: CollaborationTaskState
    let assigneeID: String?
    let priority: CollaborationPriority
}

private struct StageSuggestionReview: Encodable {
    let status: CollaborationSuggestionStatus
    let baseContentSha256: String
    let expectedText: StageTextPreview
    let replacementText: StageTextPreview
}

private struct StageHandoffReview: Encodable {
    let startingCursorSha256: String
    let finishingCursorSha256: String?
    let touchedAnnotationIDs: StageIdentifierPreview
    let unresolvedIDs: StageIdentifierPreview
    let intendedNextActors: StageIdentifierPreview
}

private struct StageContributionReview: Encodable {
    let body: StageTextPreview
    let range: UnicodeScalarRange?
    let audience: StageIdentifierPreview
    let state: String?
    let parentID: String?
    let relatedContributionID: String?
    let rationale: StageTextPreview?
    let task: StageTaskReview?
    let suggestion: StageSuggestionReview?
    let handoff: StageHandoffReview?

    init(_ contribution: CollaborationContribution, maxPreviewBytes: Int) {
        body = StageTextPreview(contribution.body, maximumBytes: maxPreviewBytes)
        range = contribution.target.range
        audience = StageIdentifierPreview(contribution.audience)
        var state: String?
        var parentID: String?
        var relatedContributionID: String?
        var rationale: StageTextPreview?
        var task: StageTaskReview?
        var suggestion: StageSuggestionReview?
        var handoff: StageHandoffReview?
        switch contribution.details {
        case .comment(let value):
            parentID = value.parentID
        case .question(let value):
            relatedContributionID = value.answerContributionID
        case .issue(let value):
            state = value.state.rawValue
        case .decision(let value):
            state = value.status.rawValue
            rationale = value.rationale.map { StageTextPreview($0, maximumBytes: maxPreviewBytes) }
        case .task(let value):
            state = value.state.rawValue
            task = StageTaskReview(
                state: value.state,
                assigneeID: value.assignee,
                priority: value.priority
            )
        case .suggestion(let value):
            state = value.status.rawValue
            suggestion = StageSuggestionReview(
                status: value.status,
                baseContentSha256: value.baseContentSha256,
                expectedText: StageTextPreview(value.expectedText, maximumBytes: maxPreviewBytes),
                replacementText: StageTextPreview(value.replacementText, maximumBytes: maxPreviewBytes)
            )
        case .handoff(let value):
            handoff = StageHandoffReview(
                startingCursorSha256: CollaborationCanonicalJSON.sha256(of: Data(value.startingCursor.utf8)),
                finishingCursorSha256: value.finishingCursor.map {
                    CollaborationCanonicalJSON.sha256(of: Data($0.utf8))
                },
                touchedAnnotationIDs: StageIdentifierPreview(value.touchedAnnotationIDs),
                unresolvedIDs: StageIdentifierPreview(value.unresolvedIDs),
                intendedNextActors: StageIdentifierPreview(value.intendedNextActors)
            )
        case .approval(let value):
            state = value.state.rawValue
            relatedContributionID = value.subjectID
        }
        self.state = state
        self.parentID = parentID
        self.relatedContributionID = relatedContributionID
        self.rationale = rationale
        self.task = task
        self.suggestion = suggestion
        self.handoff = handoff
    }
}

private struct StageOperationSummary: Encodable {
    let id: String
    let kind: String
    let path: String
    let contributionID: String?
    let contributionKind: CollaborationContributionKind?
    let bodyBytes: Int?
    let annotationID: String?
    let disposition: CollaborationSuggestionDisposition?
    let resultKind: String?
    let resultBytes: Int?
    let resultSha256: String?
    let contributionReview: StageContributionReview?

    init(_ operation: CollaborationOperation, maxPreviewBytes: Int) {
        id = operation.id
        path = operation.path
        switch operation {
        case .contribution(_, let value):
            kind = "contribution"
            contributionID = value.contribution.id
            contributionKind = value.contribution.kind
            bodyBytes = value.contribution.body.utf8.count
            annotationID = nil
            disposition = nil
            resultKind = nil
            resultBytes = nil
            resultSha256 = nil
            contributionReview = StageContributionReview(
                value.contribution,
                maxPreviewBytes: maxPreviewBytes
            )
        case .status(_, let value):
            kind = "status"
            contributionID = nil
            contributionKind = nil
            bodyBytes = nil
            annotationID = value.annotationID
            disposition = nil
            resultKind = value.status.rawValue
            resultBytes = nil
            resultSha256 = nil
            contributionReview = nil
        case .acceptSuggestion(_, let value):
            kind = "accept-suggestion"
            contributionID = value.contributionID
            contributionKind = .suggestion
            bodyBytes = nil
            annotationID = nil
            disposition = .accept
            resultKind = nil
            resultBytes = nil
            resultSha256 = nil
            contributionReview = nil
        case .suggestionDisposition(_, let value):
            kind = "suggestion-disposition"
            contributionID = value.contributionID
            contributionKind = .suggestion
            bodyBytes = nil
            annotationID = nil
            disposition = value.disposition
            resultKind = nil
            resultBytes = nil
            resultSha256 = nil
            contributionReview = nil
        case .file(_, let value):
            kind = "file"
            contributionID = nil
            contributionKind = nil
            bodyBytes = nil
            annotationID = nil
            disposition = nil
            contributionReview = nil
            switch value.result {
            case .write(let data, _):
                resultKind = "write"
                resultBytes = data.count
                resultSha256 = CollaborationCanonicalJSON.sha256(of: data)
            case .remove:
                resultKind = "remove"
                resultBytes = 0
                resultSha256 = nil
            }
        }
    }
}

private struct StageDiscardResult: Encodable {
    let stageID: String
    let discarded: Bool
}

private struct StageSubmitResult: Encodable {
    let transaction: CollaborationTransactionReceipt
    let stageRemoved: Bool
    let cleanupWarning: String?
}

private struct StageRefreshSubmitResult: Encodable {
    let refresh: CollaborationStageRefreshReceipt
    let submission: StageSubmitResult
}

private struct ContributionMutationResult: Encodable {
    let contribution: CollaborationContribution
    let transaction: CollaborationTransactionReceipt
}

private struct SuggestionDispositionResult: Encodable {
    let contributionID: String
    let disposition: CollaborationSuggestionDisposition
    let transaction: CollaborationTransactionReceipt
}

private struct LoadedAnnotationFile {
    let path: String
    let annotationRevision: Int
    let comments: [ListedComment]
}

private struct LoadedAnnotations {
    let cursor: CollaborationCursor
    let files: [LoadedAnnotationFile]
    let truncation: ListTruncation
}

private struct ListTruncation: Encodable {
    let discovery: CollaborationDiscoveryResult
    let omittedContributionCount: Int
    let omittedMatchingContributionCount: Int
    let isTruncated: Bool

    init(discovery: CollaborationDiscoveryResult, omittedContributionCount: Int) {
        self.discovery = discovery
        self.omittedContributionCount = omittedContributionCount
        omittedMatchingContributionCount = omittedContributionCount
        isTruncated = discovery.isTruncated || omittedContributionCount > 0
    }
}

private struct SuggestionListItem: Encodable {
    let id: String
    let path: String
    let actorID: String
    let actorName: String
    let body: String
    let created: String
    let modified: String
    let range: UnicodeScalarRange?
    let anchorState: AnchorResolutionState?
    let threadStatus: MarginCommentStatus
    let status: String?
    let expectedText: String?
    let replacementText: String?
    let baseContentSha256: String?
}

private struct SuggestionListResult: Encodable {
    let cursor: String
    let suggestions: [SuggestionListItem]
    let truncation: ListTruncation
}

private struct HandoffListItem: Encodable {
    let id: String
    let path: String
    let actorID: String
    let actorName: String
    let body: String
    let created: String
    let startingCursor: String
    let finishingCursor: String?
    let touchedAnnotationIDs: [String]
    let unresolvedIDs: [String]
    let intendedNextActors: [String]
}

private struct HandoffListResult: Encodable {
    let cursor: String
    let handoffs: [HandoffListItem]
    let truncation: ListTruncation
}

private struct ReconcileResult: Encodable {
    let mode: String
    let analysis: ReconciliationAnalysis?
    let receipt: ReconciliationReceipt?
}

private struct MergeResult: Encodable {
    let clean: Bool
    let writtenTo: String?
    let documentID: String?
    let revision: Int
    let annotationCount: Int
    let contentSha256: String
    let conflicts: [SemanticMergeConflict]
    let anchorsNeedingAttention: [SemanticMergeAnchorAttention]
}

private struct StageIntentPlan: Decodable {
    let schema: String?
    let version: Int
    let operations: [StageIntentOperation]
}

private struct StageIntentOperation: Decodable {
    let kind: String
    let operationID: String?
    let path: String

    let contributionKind: String?
    let contributionID: String?
    let body: String?
    let range: UnicodeScalarRange?
    let quote: String?
    let prefix: String?
    let suffix: String?
    let occurrence: Int?
    let from: String?
    let to: String?
    let audience: [String]?
    let parentID: String?
    let answerContributionID: String?
    let issueState: String?
    let decisionStatus: String?
    let rationale: String?
    let taskState: String?
    let assignee: String?
    let priority: String?
    let approvalState: String?
    let subjectID: String?
    let expectedText: String?
    let replacementText: String?
    let startingCursor: String?
    let finishingCursor: String?
    let touchedAnnotationIDs: [String]?
    let unresolvedIDs: [String]?
    let intendedNextActors: [String]?

    let annotationID: String?
    let status: String?
    let disposition: String?

    let precondition: CollaborationFilePrecondition?
    let result: CollaborationFileResult?
}
