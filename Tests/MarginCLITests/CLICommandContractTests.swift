import Foundation
import MarginCore
import XCTest
import Darwin
@testable import MarginCLI

final class CLICommandContractTests: XCTestCase {
    func testCapabilitiesAreVersionedBoundedAndInternallyConsistent() throws {
        let capabilities = CLICommandCatalog.capabilities(cliVersion: MarginCommand.version)
        let compact = JSONEncoder()
        compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let compactData = try compact.encode(capabilities)
        let prettyData = try pretty.encode(capabilities)
        XCTAssertLessThanOrEqual(compactData.count + 1, capabilities.bounds.maxEncodedBytes)
        XCTAssertLessThanOrEqual(prettyData.count + 1, capabilities.bounds.maxEncodedBytes)
        XCTAssertLessThanOrEqual(capabilities.commands.count, capabilities.bounds.maxCommands)
        XCTAssertTrue(capabilities.commands.allSatisfy {
            $0.options.count <= capabilities.bounds.maxOptionsPerCommand &&
                $0.usage.count <= capabilities.bounds.maxUsageFormsPerCommand
        })

        let paths = capabilities.commands.map { $0.path.joined(separator: " ") }
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertEqual(capabilities.schema, "urn:margin:capabilities:v1")
        XCTAssertEqual(capabilities.contractVersion, 1)
        XCTAssertEqual(capabilities.cursor.tokenPrefix, "mcur1:")
        XCTAssertEqual(capabilities.cursor.availability, .available)
        XCTAssertEqual(capabilities.stageIntent.schema, "urn:margin:stage-intent:v1")
        XCTAssertEqual(capabilities.stageIntent.maxOperations, 4_096)
        XCTAssertFalse(capabilities.protocols.networkRequired)
    }

    func testCapabilityWorkflowProjectionsAreSmallDeterministicAndRelevant() throws {
        let compact = JSONEncoder()
        compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for workflow in CLICapabilityWorkflow.allCases {
            let projection = CLICommandCatalog.capabilitiesProjection(
                cliVersion: MarginCommand.version,
                workflow: workflow
            )
            let compactData = try compact.encode(projection)
            let repeatedData = try compact.encode(
                CLICommandCatalog.capabilitiesProjection(
                    cliVersion: MarginCommand.version,
                    workflow: workflow
                )
            )
            let prettyData = try pretty.encode(projection)
            XCTAssertEqual(compactData, repeatedData)
            XCTAssertLessThanOrEqual(compactData.count + 1, projection.bounds.maxEncodedBytes)
            XCTAssertLessThanOrEqual(prettyData.count + 1, projection.bounds.maxEncodedBytes)
            XCTAssertLessThanOrEqual(projection.commands.count, projection.bounds.maxCommands)
            XCTAssertEqual(projection.schema, "urn:margin:capabilities-projection:v1")
            XCTAssertEqual(projection.projection.workflow, workflow)
            XCTAssertEqual(projection.projection.parentSchema, "urn:margin:capabilities:v1")
            XCTAssertFalse(projection.projection.complete)
            XCTAssertTrue(projection.commands.allSatisfy { workflow.includes($0.path) })
            XCTAssertTrue(projection.commands.contains { $0.path == ["capabilities"] })
            XCTAssertEqual(projection.stageIntent != nil, workflow == .staging)
        }

        let suggestions = CLICommandCatalog.capabilitiesProjection(
            cliVersion: MarginCommand.version,
            workflow: .suggestions
        )
        XCTAssertTrue(suggestions.commands.contains { $0.path == ["suggest", "add"] })
        XCTAssertFalse(suggestions.commands.contains { $0.path == ["merge"] })

        let output = runCapturing(["capabilities", "--json", "--for", "suggestions"])
        XCTAssertEqual(output.exit, CLIExit.success.rawValue)
        let json = try jsonObject(output.output)
        XCTAssertEqual(json["schema"] as? String, "urn:margin:capabilities-projection:v1")
        let identity = try XCTUnwrap(json["projection"] as? [String: Any])
        XCTAssertEqual(identity["workflow"] as? String, "suggestions")
        XCTAssertEqual(
            runSilently(["capabilities", "--json", "--for", "unknown"]),
            CLIExit.usage.rawValue
        )
    }

    func testAliasesAndCommandLocalHelpComeFromTheSameCatalog() throws {
        XCTAssertEqual(CLICommandCatalog.canonicalTopLevel("comment"), "comments")
        XCTAssertEqual(CLICommandCatalog.canonicalTopLevel("-h"), "help")
        XCTAssertEqual(CLICommandCatalog.canonicalTopLevel("--version"), "version")
        XCTAssertEqual(
            CLICommandCatalog.command(path: ["comment", "add"])?.path,
            ["comments", "add"]
        )

        let slice = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["slice"]))
        XCTAssertTrue(slice.contains("margin slice FILE"))
        XCTAssertTrue(slice.contains("--heading NAME"))

        let add = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["comments", "add"]))
        XCTAssertTrue(add.contains("-m, --message, --body TEXT"))
        XCTAssertTrue(add.contains("--if-content-sha SHA"))

        let context = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["context"]))
        XCTAssertFalse(context.contains("Unsupported"))
        XCTAssertTrue(context.contains("margin context TARGET --json"))

        let stageCreate = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["stage", "create"]))
        XCTAssertTrue(stageCreate.contains("--operations-file PLAN_JSON_OR_-"))
        XCTAssertTrue(stageCreate.contains("--change-set-file CHANGESET_JSON_OR_-"))
        let stageShow = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["stage", "show"]))
        XCTAssertTrue(stageShow.contains("--max-preview-bytes N"))
        XCTAssertTrue(stageShow.contains("1 MiB"))
        let stageList = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["stage", "list"]))
        XCTAssertTrue(stageList.contains("--max-bytes N"))
        XCTAssertTrue(stageList.contains("Byte omissions are reported"))
        let stageRefresh = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["stage", "refresh"]))
        XCTAssertTrue(stageRefresh.contains("--id NEW_STAGE_ID"))
        XCTAssertTrue(stageRefresh.contains("preserving the prior stage"))

        let capabilities = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["capabilities"]))
        XCTAssertTrue(capabilities.contains("--for WORKFLOW"))
        XCTAssertTrue(capabilities.contains("review, staging, suggestions, handoff, or merge"))

        let manual = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["man"]))
        XCTAssertTrue(manual.contains("margin man [TOPIC]"))
        XCTAssertTrue(manual.contains("--list"))

        let agents = runCapturing(["help", "agents"])
        XCTAssertEqual(agents.exit, CLIExit.success.rawValue)
        let agentHelp = try XCTUnwrap(String(data: agents.output, encoding: .utf8))
        XCTAssertTrue(agentHelp.contains("MARGIN MANUAL"))
        XCTAssertTrue(agentHelp.contains("margin capabilities --json"))
        XCTAssertTrue(agentHelp.contains("margin context TARGET --json"))
        XCTAssertTrue(agentHelp.contains("margin inbox TARGET"))
        XCTAssertTrue(agentHelp.contains("margin man staging"))
        XCTAssertTrue(agentHelp.contains("not trusted"))

        for command in CLICommandCatalog.commands {
            XCTAssertNotNil(
                CLICommandCatalog.localHelp(path: command.path),
                "Missing local help for \(command.path.joined(separator: " "))"
            )
        }
    }

    func testProgressiveManualIsStaticDiscoverableAndFailClosed() throws {
        let globalHelp = runCapturing(["--help"])
        XCTAssertEqual(globalHelp.exit, CLIExit.success.rawValue)
        XCTAssertTrue(
            try XCTUnwrap(String(data: globalHelp.output, encoding: .utf8))
                .contains("margin man")
        )

        let overview = runCapturing(["man"])
        XCTAssertEqual(overview.exit, CLIExit.success.rawValue)
        let overviewText = try XCTUnwrap(String(data: overview.output, encoding: .utf8))
        XCTAssertTrue(overviewText.contains("MARGIN MANUAL"))
        XCTAssertTrue(overviewText.contains("margin capabilities --json --for review"))
        XCTAssertTrue(overviewText.contains("Never edit Margin's terminal metadata envelope directly"))
        XCTAssertTrue(overviewText.contains("not proof that someone is online"))

        let legacy = runCapturing(["help", "agents"])
        XCTAssertEqual(legacy.exit, CLIExit.success.rawValue)
        XCTAssertEqual(legacy.output, overview.output)

        let listed = runCapturing(["man", "--list"])
        XCTAssertEqual(listed.exit, CLIExit.success.rawValue)
        let listedText = try XCTUnwrap(String(data: listed.output, encoding: .utf8))
        for topic in MarginManual.canonicalTopics {
            XCTAssertTrue(listedText.contains(topic), "Missing manual topic \(topic)")
        }

        let expectedHeadings = [
            "review": "MARGIN MANUAL: REVIEW",
            "comments": "MARGIN MANUAL: COMMENTS",
            "suggestions": "MARGIN MANUAL: SUGGESTIONS",
            "staging": "MARGIN MANUAL: STAGING",
            "handoff": "MARGIN MANUAL: HANDOFF",
            "merge": "MARGIN MANUAL: MERGE",
            "safety": "MARGIN MANUAL: SAFETY",
        ]
        for topic in MarginManual.canonicalTopics {
            let result = runCapturing(["man", topic])
            XCTAssertEqual(result.exit, CLIExit.success.rawValue, topic)
            let text = try XCTUnwrap(String(data: result.output, encoding: .utf8))
            XCTAssertTrue(text.contains(try XCTUnwrap(expectedHeadings[topic])), topic)
            XCTAssertLessThan(result.output.count, 8_192, topic)
        }

        XCTAssertEqual(runSilently(["man", "comment"]), CLIExit.success.rawValue)
        XCTAssertEqual(runSilently(["man", "stage"]), CLIExit.success.rawValue)
        XCTAssertEqual(runSilently(["man", "security"]), CLIExit.success.rawValue)

        let unknown = runCapturingError(["man", "unknown"])
        XCTAssertEqual(unknown.exit, CLIExit.usage.rawValue)
        let errorText = try XCTUnwrap(String(data: unknown.output, encoding: .utf8))
        XCTAssertTrue(errorText.contains("Unknown manual topic 'unknown'"))
        XCTAssertTrue(errorText.contains("margin man --list"))
    }

    func testCollaborationCommandsAreAvailableWithSafeSideEffectContracts() {
        let expected = Set(CollaborationCLICommand.allCases.map(\.rawValue))
        let advertised = Set(
            CLICommandCatalog.commands
                .filter { $0.availability == .available }
                .compactMap(\.path.first)
        )
        XCTAssertTrue(expected.isSubset(of: advertised))
        XCTAssertTrue(CLICommandCatalog.commands.allSatisfy { $0.availability == .available })
        XCTAssertEqual(
            CLICommandCatalog.command(path: ["suggest", "reject"])?.sideEffects,
            "mutates-file-metadata"
        )
        XCTAssertEqual(
            CLICommandCatalog.command(path: ["suggest", "accept"])?.sideEffects,
            "mutates-logical-markdown-and-metadata"
        )
    }

    func testMutationOptionsCanSurroundPositionalsWithoutChangingTheirOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginCLIContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        let original = "# Review\n\nfirst target second.\n"
        try Data(original.utf8).write(to: file)

        let rootUUID = "00000000-0000-4000-8000-000000000801"
        let replyUUID = "00000000-0000-4000-8000-000000000802"
        let rootID = "urn:uuid:\(rootUUID)"
        let replyID = "urn:uuid:\(replyUUID)"

        XCTAssertEqual(
            runSilently([
                "comments", "add",
                "--quote", "target",
                "--actor-type", "agent",
                "-m", "Finding",
                "--if-revision", "0",
                file.path,
                "--id", rootUUID
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(
            runSilently([
                "comments", "reply",
                "--id", replyUUID,
                "--body", "Initial reply",
                file.path,
                rootID,
                "--actor-name", "CLI contract tests",
                "--if-revision", "1"
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(
            runSilently([
                "comments", "edit",
                "--message", "Edited reply",
                "--actor-type", "software",
                "--if-revision", "2",
                file.path,
                replyID
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(
            runSilently([
                "comments", "reanchor",
                "--quote", "first",
                "--if-revision", "3",
                file.path,
                rootID
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(
            runSilently([
                "comments", "resolve",
                "--actor-type", "agent",
                file.path,
                rootID,
                "--if-revision", "4"
            ]),
            CLIExit.success.rawValue
        )

        let snapshot = try CommentService().list(at: file)
        XCTAssertEqual(snapshot.revision, 5)
        XCTAssertEqual(snapshot.comments.count, 2)
        XCTAssertEqual(
            snapshot.comments.first { $0.annotation.id == replyID }?.annotation.body.value,
            "Edited reply"
        )
        XCTAssertTrue(snapshot.comments.allSatisfy { $0.threadStatus == .resolved })

        XCTAssertEqual(
            runSilently([
                "comments", "delete",
                "--if-revision", "5",
                "--subtree",
                file.path,
                rootID
            ]),
            CLIExit.success.rawValue
        )
        let deleted = try CommentService().list(at: file)
        XCTAssertEqual(deleted.revision, 0)
        XCTAssertTrue(deleted.comments.isEmpty)
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).body, original)
    }

    func testTypedContributionContextCollaboratorsAndInbox() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        let body = "# Review\n\nShip the draft.\n"
        try Data(body.utf8).write(to: file)

        XCTAssertEqual(
            runSilently(["workspace", "init", directory.path, "--id", "urn:test:workspace"]),
            CLIExit.success.rawValue
        )
        let workspaceRoot = try CollaborationRootResolver().directory(at: directory)
        let manifest = try XCTUnwrap(CollaborationRootResolver().manifest(for: workspaceRoot))
        XCTAssertEqual(manifest.include, CollaborationWorkspaceManifest.defaultInclude)
        XCTAssertEqual(manifest.exclude, CollaborationWorkspaceManifest.defaultExclude)
        XCTAssertTrue(manifest.exclude.contains("**/.build/**"))
        XCTAssertTrue(manifest.exclude.contains("**/.git/**"))
        XCTAssertTrue(manifest.exclude.contains("**/node_modules/**"))
        XCTAssertTrue(manifest.exclude.contains("**/vendor/**"))
        let typedID = "00000000-0000-4000-8000-000000000901"
        let typedArguments = [
                "comments", "add", file.path,
                "--document", "--kind", "task", "-m", "Verify the release",
                "--assignee", "urn:test:agent:owner", "--priority", "high",
                "--audience", "urn:test:agent:reviewer",
                "--actor-id", "urn:test:agent:author", "--actor-type", "software",
                "--actor-name", "Author", "--id", typedID
        ]
        XCTAssertEqual(runSilently(typedArguments), CLIExit.success.rawValue)
        XCTAssertEqual(runSilently(typedArguments), CLIExit.success.rawValue)

        let decoded = try EmbeddedCommentCodec().decode(Data(contentsOf: file))
        XCTAssertEqual(decoded.body, body)
        XCTAssertEqual(decoded.envelope?.revision, 1)
        let annotation = try XCTUnwrap(decoded.envelope?.items.first)
        XCTAssertEqual(string(in: annotation.extensions, key: "margin:kind"), "task")
        XCTAssertEqual(string(in: annotation.extensions, key: "margin:assignee"), "urn:test:agent:owner")
        XCTAssertEqual(string(in: annotation.extensions, key: "margin:priority"), "high")
        XCTAssertEqual(annotation.creator.id, "urn:test:agent:author")
        XCTAssertEqual(annotation.creator.type, .software)
        var changedTypedArguments = typedArguments
        let messageIndex = try XCTUnwrap(changedTypedArguments.firstIndex(of: "Verify the release"))
        changedTypedArguments[messageIndex] = "Different task payload"
        XCTAssertEqual(runSilently(changedTypedArguments), CLIExit.data.rawValue)

        let context = runCapturing(["context", file.path, "--json", "--max-files", "1"])
        XCTAssertEqual(context.exit, CLIExit.success.rawValue)
        let contextJSON = try jsonObject(context.output)
        let contextResult = try XCTUnwrap(contextJSON["result"] as? [String: Any])
        XCTAssertTrue((contextResult["cursor"] as? String)?.hasPrefix("mcur1:") == true)

        let collaborators = runCapturing(["collaborators", file.path])
        XCTAssertEqual(collaborators.exit, CLIExit.success.rawValue)
        let collaboratorResult = try XCTUnwrap(
            try jsonObject(collaborators.output)["result"] as? [String: Any]
        )
        XCTAssertEqual((collaboratorResult["collaborators"] as? [[String: Any]])?.count, 1)

        let inbox = runCapturing([
            "inbox", file.path, "--kind", "task", "--assignee", "urn:test:agent:owner"
        ])
        XCTAssertEqual(inbox.exit, CLIExit.success.rawValue)
        let inboxResult = try XCTUnwrap(try jsonObject(inbox.output)["result"] as? [String: Any])
        XCTAssertEqual((inboxResult["items"] as? [[String: Any]])?.count, 1)
    }

    func testSuggestionRejectPreservesBodyAndAcceptChangesOnlyTheSelection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        try Data("alpha beta\n".utf8).write(to: file)

        let rejectedUUID = "00000000-0000-4000-8000-000000000902"
        let rejectedAdd = [
                "suggest", "add", file.path,
                "--range", "6:10", "--expect", "beta", "--replacement", "gamma",
                "-m", "Prefer gamma", "--id", rejectedUUID,
                "--actor-id", "urn:test:agent:suggester", "--actor-type", "agent"
        ]
        XCTAssertEqual(runSilently(rejectedAdd), CLIExit.success.rawValue)
        XCTAssertEqual(runSilently(rejectedAdd), CLIExit.success.rawValue)
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).envelope?.revision, 1)
        var changedRejectedAdd = rejectedAdd
        let suggestionMessageIndex = try XCTUnwrap(changedRejectedAdd.firstIndex(of: "Prefer gamma"))
        changedRejectedAdd[suggestionMessageIndex] = "Different suggestion payload"
        XCTAssertEqual(runSilently(changedRejectedAdd), CLIExit.data.rawValue)
        let rejectedID = "urn:uuid:\(rejectedUUID)"
        let beforeReject = try EmbeddedCommentCodec().decode(Data(contentsOf: file)).bodyData
        XCTAssertEqual(
            runSilently([
                "suggest", "reject", file.path, rejectedID,
                "--request-id", "urn:test:request:reject-decision",
                "--actor-id", "urn:test:agent:reviewer", "--actor-type", "software"
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).bodyData, beforeReject)

        XCTAssertEqual(
            runSilently([
                "suggest", "add", file.path,
                "--quote", "alpha", "--replacement", "omega",
                "-m", "Prefer omega", "--request-id", "urn:test:request:accept",
                "--actor-id", "urn:test:agent:suggester", "--actor-type", "agent"
            ]),
            CLIExit.success.rawValue
        )
        let acceptedID = "urn:test:request:accept#contribution"
        XCTAssertEqual(
            runSilently([
                "suggest", "accept", file.path, acceptedID,
                "--request-id", "urn:test:request:accept-decision",
                "--actor-id", "urn:test:agent:reviewer", "--actor-type", "software"
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).body, "omega beta\n")

        let listed = runCapturing(["suggest", "list", file.path])
        XCTAssertEqual(listed.exit, CLIExit.success.rawValue)
        let result = try XCTUnwrap(try jsonObject(listed.output)["result"] as? [String: Any])
        let suggestions = try XCTUnwrap(result["suggestions"] as? [[String: Any]])
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(Set(suggestions.compactMap { $0["status"] as? String }), ["accepted", "rejected"])
    }

    func testSuggestionQuoteFailsAmbiguousWithoutWriting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        let original = Data("repeat and repeat\n".utf8)
        try original.write(to: file)
        XCTAssertEqual(
            runSilently([
                "suggest", "add", file.path,
                "--quote", "repeat", "--replacement", "unique", "-m", "Disambiguate"
            ]),
            CLIExit.data.rawValue
        )
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(
            runSilently([
                "suggest", "add", file.path,
                "--quote", "repeat", "--occurrence", "2", "--replacement", "unique",
                "--expect", "repeat", "-m", "Use the second occurrence"
            ]),
            CLIExit.success.rawValue
        )
    }

    func testHandoffRoundTripUsesCursorTokens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        let body = "# Handoff\n"
        try Data(body.utf8).write(to: file)

        let handoffUUID = "00000000-0000-4000-8000-000000000903"
        let handoffAdd = [
                "handoff", "add", file.path, "-m", "Continue with validation",
                "--next-actor", "urn:test:agent:next", "--unresolved", "urn:test:issue:1",
                "--id", handoffUUID,
                "--actor-id", "urn:test:agent:current", "--actor-type", "software"
        ]
        XCTAssertEqual(runSilently(handoffAdd), CLIExit.success.rawValue)
        XCTAssertEqual(runSilently(handoffAdd), CLIExit.success.rawValue)
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).envelope?.revision, 1)
        var changedHandoff = handoffAdd
        let handoffMessageIndex = try XCTUnwrap(changedHandoff.firstIndex(of: "Continue with validation"))
        changedHandoff[handoffMessageIndex] = "Different handoff payload"
        XCTAssertEqual(runSilently(changedHandoff), CLIExit.data.rawValue)
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).body, body)
        let listed = runCapturing(["handoff", "list", file.path])
        XCTAssertEqual(listed.exit, CLIExit.success.rawValue)
        let result = try XCTUnwrap(try jsonObject(listed.output)["result"] as? [String: Any])
        let handoffs = try XCTUnwrap(result["handoffs"] as? [[String: Any]])
        XCTAssertEqual(handoffs.count, 1)
        XCTAssertTrue((handoffs[0]["startingCursor"] as? String)?.hasPrefix("mcur1:") == true)
    }

    func testErgonomicStageShowIsImageFreeAndAlreadyAppliedSubmitCleansStage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        let planFile = directory.appendingPathComponent("plan.json")
        try Data("before\n".utf8).write(to: file)
        XCTAssertEqual(runSilently(["workspace", "init", directory.path]), CLIExit.success.rawValue)

        let replacement = Data("after\n".utf8)
        let plan: [String: Any] = [
            "schema": "urn:margin:stage-intent:v1",
            "version": 1,
            "operations": [[
                "kind": "file",
                "path": "review.md",
                "result": ["kind": "write", "data": replacement.base64EncodedString()]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys]).write(to: planFile)
        let stageID = "urn:test:stage:retry"
        XCTAssertEqual(
            runSilently([
                "stage", "create", directory.path, "--operations-file", planFile.path,
                "--request-id", "urn:test:request:stage", "--stage-id", stageID,
                "--actor-id", "urn:test:agent:stage", "--actor-type", "software"
            ]),
            CLIExit.success.rawValue
        )

        let shown = runCapturing(["stage", "show", directory.path, stageID])
        XCTAssertEqual(shown.exit, CLIExit.success.rawValue)
        let shownText = try XCTUnwrap(String(data: shown.output, encoding: .utf8))
        XCTAssertFalse(shownText.contains(replacement.base64EncodedString()))
        let shownResult = try XCTUnwrap(try jsonObject(shown.output)["result"] as? [String: Any])
        XCTAssertNotNil(shownResult["operations"])

        let root = try CollaborationRootResolver().directory(at: directory)
        let staged = try CollaborationStageStore().load(stageID: stageID, root: root)
        let firstReceipt = try CollaborationTransactionEngine().submit(staged)
        XCTAssertEqual(firstReceipt.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: file), replacement)

        let replay = runCapturing(["stage", "submit", directory.path, stageID])
        XCTAssertEqual(replay.exit, CLIExit.success.rawValue)
        let replayResult = try XCTUnwrap(try jsonObject(replay.output)["result"] as? [String: Any])
        XCTAssertEqual(replayResult["stageRemoved"] as? Bool, true)
        let replayTransaction = try XCTUnwrap(replayResult["transaction"] as? [String: Any])
        XCTAssertEqual(replayTransaction["disposition"] as? String, "already-applied")
        XCTAssertTrue(try CollaborationStageStore().list(root: root).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), replacement)
    }

    func testStageShowProvidesBoundedTypedReviewPreviews() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        let planFile = directory.appendingPathComponent("plan.json")
        try Data("alpha target omega\n".utf8).write(to: file)
        XCTAssertEqual(runSilently(["workspace", "init", directory.path]), CLIExit.success.rawValue)
        let plan: [String: Any] = [
            "version": 1,
            "operations": [
                [
                    "kind": "contribution", "path": "review.md",
                    "contributionKind": "task", "body": "Review the complete implementation",
                    "assignee": "urn:test:agent:owner", "priority": "high",
                    "audience": ["urn:test:agent:owner", "urn:test:agent:reviewer"],
                ],
                [
                    "kind": "contribution", "path": "review.md",
                    "contributionKind": "suggestion", "body": "Prefer a clearer term",
                    "quote": "target", "expectedText": "target",
                    "replacementText": "replacement-text",
                ],
                [
                    "kind": "contribution", "path": "review.md",
                    "contributionKind": "handoff", "body": "Continue with validation",
                    "touchedAnnotationIDs": ["urn:test:annotation:touched"],
                    "unresolvedIDs": ["urn:test:issue:open"],
                    "intendedNextActors": ["urn:test:agent:next"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys]).write(to: planFile)
        let stageID = "urn:test:stage:review-previews"
        XCTAssertEqual(
            runSilently([
                "stage", "create", directory.path, "--operations-file", planFile.path,
                "--stage-id", stageID, "--request-id", "urn:test:request:review-previews",
                "--actor-id", "urn:test:agent:planner", "--actor-type", "software",
            ]),
            CLIExit.success.rawValue
        )

        let shown = runCapturing([
            "stage", "show", directory.path, stageID, "--max-preview-bytes", "8"
        ])
        XCTAssertEqual(shown.exit, CLIExit.success.rawValue)
        XCTAssertLessThanOrEqual(shown.output.count, 1_048_576)
        let result = try XCTUnwrap(try jsonObject(shown.output)["result"] as? [String: Any])
        let operations = try XCTUnwrap(result["operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 3)

        let task = try XCTUnwrap(operations.first { $0["contributionKind"] as? String == "task" })
        let taskReview = try XCTUnwrap(task["contributionReview"] as? [String: Any])
        let taskBody = try XCTUnwrap(taskReview["body"] as? [String: Any])
        XCTAssertEqual(taskBody["isTruncated"] as? Bool, true)
        XCTAssertEqual((taskBody["sha256"] as? String)?.count, 64)
        XCTAssertLessThanOrEqual((taskBody["preview"] as? String)?.utf8.count ?? .max, 11)
        let taskDetails = try XCTUnwrap(taskReview["task"] as? [String: Any])
        XCTAssertEqual(taskDetails["assigneeID"] as? String, "urn:test:agent:owner")
        XCTAssertEqual(taskDetails["priority"] as? String, "high")
        let audience = try XCTUnwrap(taskReview["audience"] as? [String: Any])
        XCTAssertEqual(audience["totalCount"] as? Int, 2)

        let suggestion = try XCTUnwrap(
            operations.first { $0["contributionKind"] as? String == "suggestion" }
        )
        let suggestionReview = try XCTUnwrap(
            suggestion["contributionReview"] as? [String: Any]
        )
        let suggestionDetails = try XCTUnwrap(
            suggestionReview["suggestion"] as? [String: Any]
        )
        XCTAssertEqual(
            (suggestionDetails["expectedText"] as? [String: Any])?["preview"] as? String,
            "target"
        )
        XCTAssertEqual(
            (suggestionDetails["replacementText"] as? [String: Any])?["isTruncated"] as? Bool,
            true
        )

        let handoff = try XCTUnwrap(
            operations.first { $0["contributionKind"] as? String == "handoff" }
        )
        let handoffReview = try XCTUnwrap(handoff["contributionReview"] as? [String: Any])
        let handoffDetails = try XCTUnwrap(handoffReview["handoff"] as? [String: Any])
        XCTAssertEqual(
            (handoffDetails["touchedAnnotationIDs"] as? [String: Any])?["totalCount"] as? Int,
            1
        )
        XCTAssertEqual(
            (handoffDetails["intendedNextActors"] as? [String: Any])?["totalCount"] as? Int,
            1
        )
        XCTAssertFalse(try XCTUnwrap(String(data: shown.output, encoding: .utf8)).contains("mcur1:"))
        XCTAssertEqual(
            runSilently([
                "stage", "show", directory.path, stageID, "--max-preview-bytes", "4097"
            ]),
            CLIExit.usage.rawValue
        )
    }

    func testStageShowHardAggregateBudgetOmitsWholeOperations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        try Data("review\n".utf8).write(to: file)
        XCTAssertEqual(runSilently(["workspace", "init", directory.path]), CLIExit.success.rawValue)
        let root = try CollaborationRootResolver().directory(at: directory)
        let cursor = try CollaborationCursorService().capture(root: root, paths: ["review.md"])
        let actor = try CollaborationActor(
            id: "urn:test:agent:large-stage",
            type: .software,
            name: "Large stage"
        )
        let created = "2026-08-16T12:00:00Z"
        let operations = try (0..<300).map { index -> CollaborationOperation in
            let contribution = try CollaborationContribution(
                id: "urn:test:contribution:large:\(index)",
                actorID: actor.id,
                created: created,
                body: String(repeating: "x", count: 4_096) + "-\(index)",
                target: CollaborationTarget(path: "review.md"),
                details: .comment(CollaborationCommentDetails())
            )
            return .contribution(
                id: "urn:test:operation:large:\(index)",
                CollaborationContributionOperation(contribution: contribution)
            )
        }
        let stageID = "urn:test:stage:large-show"
        let changeSet = try CollaborationChangeSet(
            id: "urn:test:changeset:large-show",
            root: root,
            baseCursor: cursor,
            actor: actor,
            requestID: "urn:test:request:large-show",
            stageID: stageID,
            created: created,
            operations: operations
        )
        _ = try CollaborationStageStore().stage(changeSet)

        let shown = runCapturing([
            "stage", "show", directory.path, stageID,
            "--max-preview-bytes", "4096", "--pretty",
        ])
        XCTAssertEqual(shown.exit, CLIExit.success.rawValue)
        XCTAssertLessThanOrEqual(shown.output.count, 1_048_576)
        let result = try XCTUnwrap(try jsonObject(shown.output)["result"] as? [String: Any])
        let truncation = try XCTUnwrap(result["truncation"] as? [String: Any])
        XCTAssertEqual(truncation["hitOutputByteLimit"] as? Bool, true)
        XCTAssertEqual(truncation["isTruncated"] as? Bool, true)
        XCTAssertGreaterThan(truncation["omittedOperationCount"] as? Int ?? 0, 0)
        XCTAssertLessThan((result["operations"] as? [[String: Any]])?.count ?? .max, 300)

        let byteBoundedList = runCapturing([
            "stage", "list", directory.path, "--limit", "128", "--max-bytes", "0"
        ])
        XCTAssertEqual(byteBoundedList.exit, CLIExit.success.rawValue)
        let listResult = try XCTUnwrap(
            try jsonObject(byteBoundedList.output)["result"] as? [String: Any]
        )
        XCTAssertEqual((listResult["stages"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(listResult["selectedCanonicalBytes"] as? Int, 0)
        XCTAssertGreaterThan(listResult["omittedCanonicalBytes"] as? Int ?? 0, 0)
        XCTAssertEqual(listResult["hitAggregateByteLimit"] as? Bool, true)
        XCTAssertEqual(listResult["isTruncated"] as? Bool, true)
    }

    func testStageRefreshRetainsHistoryGuidesStaleSubmitAndConverges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        let planFile = directory.appendingPathComponent("plan.json")
        try Data("first\n".utf8).write(to: first)
        try Data("second\n".utf8).write(to: second)
        XCTAssertEqual(runSilently(["workspace", "init", directory.path]), CLIExit.success.rawValue)
        let plan: [String: Any] = [
            "version": 1,
            "operations": [
                [
                    "kind": "contribution", "path": "first.md",
                    "contributionKind": "task", "body": "Validate first",
                ],
                [
                    "kind": "contribution", "path": "second.md",
                    "contributionKind": "issue", "body": "Validate second",
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys]).write(to: planFile)
        let oldStageID = "urn:test:stage:refresh-old"
        XCTAssertEqual(
            runSilently([
                "stage", "create", directory.path, "--operations-file", planFile.path,
                "--stage-id", oldStageID, "--request-id", "urn:test:request:refresh",
                "--actor-id", "urn:test:agent:planner", "--actor-type", "software",
            ]),
            CLIExit.success.rawValue
        )
        _ = try CommentService().add(
            at: first,
            message: "Concurrent annotation-only drift",
            creator: MarginActor(id: "urn:test:agent:drift", type: .software, name: "Drift"),
            anchor: .document
        )

        let staleOld = runCapturingError(["stage", "submit", directory.path, oldStageID])
        XCTAssertEqual(staleOld.exit, CLIExit.temporaryFailure.rawValue)
        try assertStageRefreshGuidance(staleOld.output, stageID: oldStageID)

        let firstRefreshID = "urn:test:stage:refresh-one"
        let firstRefresh = runCapturing([
            "stage", "refresh", directory.path, oldStageID, "--id", firstRefreshID
        ])
        XCTAssertEqual(firstRefresh.exit, CLIExit.success.rawValue)
        let firstReceipt = try XCTUnwrap(
            try jsonObject(firstRefresh.output)["result"] as? [String: Any]
        )
        XCTAssertEqual(firstReceipt["priorStageID"] as? String, oldStageID)
        XCTAssertEqual(firstReceipt["refreshedStageID"] as? String, firstRefreshID)
        XCTAssertEqual(firstReceipt["priorStageWasStale"] as? Bool, true)
        XCTAssertEqual(firstReceipt["disposition"] as? String, "created")
        XCTAssertEqual(firstReceipt["evaluatedMutationCount"] as? Int, 2)
        let refreshReplay = runCapturing([
            "stage", "refresh", directory.path, oldStageID, "--id", firstRefreshID
        ])
        XCTAssertEqual(refreshReplay.exit, CLIExit.success.rawValue)
        let replayReceipt = try XCTUnwrap(
            try jsonObject(refreshReplay.output)["result"] as? [String: Any]
        )
        XCTAssertEqual(replayReceipt["disposition"] as? String, "already-present")
        XCTAssertEqual(replayReceipt["refreshedStageID"] as? String, firstRefreshID)

        let root = try CollaborationRootResolver().directory(at: directory)
        let store = CollaborationStageStore()
        let oldStage = try store.load(stageID: oldStageID, root: root)
        let refreshedStage = try store.load(stageID: firstRefreshID, root: root)
        XCTAssertEqual(refreshedStage.operations, oldStage.operations)
        XCTAssertEqual(refreshedStage.actor, oldStage.actor)
        XCTAssertEqual(refreshedStage.requestID, oldStage.requestID)
        XCTAssertEqual(refreshedStage.created, oldStage.created)
        XCTAssertNotEqual(refreshedStage.baseCursor, oldStage.baseCursor)
        XCTAssertNotNil(refreshedStage.extensions["margin:stageRefresh"])

        _ = try CommentService().add(
            at: second,
            message: "Further annotation-only drift",
            creator: MarginActor(id: "urn:test:agent:drift", type: .software, name: "Drift"),
            anchor: .document
        )
        let staleRefresh = runCapturingError([
            "stage", "submit", directory.path, firstRefreshID
        ])
        XCTAssertEqual(staleRefresh.exit, CLIExit.temporaryFailure.rawValue)
        try assertStageRefreshGuidance(staleRefresh.output, stageID: firstRefreshID)

        let finalStageID = "urn:test:stage:refresh-final"
        XCTAssertEqual(
            runSilently([
                "stage", "refresh", directory.path, firstRefreshID, "--id", finalStageID
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(
            runSilently(["stage", "submit", directory.path, finalStageID]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(
            try CommentService().list(at: first).comments.filter {
                string(in: $0.annotation.extensions, key: "margin:kind") == "task"
            }.count,
            1
        )
        XCTAssertEqual(
            try CommentService().list(at: second).comments.filter {
                string(in: $0.annotation.extensions, key: "margin:kind") == "issue"
            }.count,
            1
        )
        XCTAssertNoThrow(try store.load(stageID: oldStageID, root: root))
        XCTAssertNoThrow(try store.load(stageID: firstRefreshID, root: root))
        XCTAssertThrowsError(try store.load(stageID: finalStageID, root: root))
        XCTAssertNoThrow(try CollaborationTransactionEngine().recover(root: root))
    }

    func testStageIntentQuoteResolvesAgainstCapturedBase() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        let planFile = directory.appendingPathComponent("plan.json")
        try Data("before target after\n".utf8).write(to: file)
        XCTAssertEqual(runSilently(["workspace", "init", directory.path]), CLIExit.success.rawValue)
        let plan: [String: Any] = [
            "schema": "urn:margin:stage-intent:v1",
            "version": 1,
            "operations": [[
                "kind": "contribution",
                "path": "review.md",
                "contributionKind": "issue",
                "body": "Review this passage",
                "quote": "target",
                "expectedText": "target"
            ]]
        ]
        try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys]).write(to: planFile)
        let stageID = "urn:test:stage:quote"
        XCTAssertEqual(
            runSilently([
                "stage", "create", directory.path, "--operations-file", planFile.path,
                "--stage-id", stageID, "--request-id", "urn:test:request:quote",
                "--actor-id", "urn:test:agent:stage", "--actor-type", "software"
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(
            runSilently(["stage", "submit", directory.path, stageID]),
            CLIExit.success.rawValue
        )
        let comment = try XCTUnwrap(CommentService().list(at: file).comments.first)
        XCTAssertEqual(comment.anchor?.range, UnicodeScalarRange(start: 7, end: 13))
        XCTAssertEqual(string(in: comment.annotation.extensions, key: "margin:kind"), "issue")
    }

    func testReconcileRequiresExplicitApplyPolicy() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = directory.appendingPathComponent("previous.md")
        let current = directory.appendingPathComponent("current.md")
        try Data("before target after\n".utf8).write(to: previous)
        _ = try CommentService().add(
            at: previous,
            message: "Review target",
            creator: MarginActor(id: "urn:test:actor", type: .software, name: "Agent"),
            anchor: .quote(exact: "target")
        )
        let priorData = try Data(contentsOf: previous)
        let priorDocument = try EmbeddedCommentCodec().decode(priorData)
        let suffix = priorData.dropFirst(priorDocument.bodyData.count)
        var stale = Data("prefix before target after\n".utf8)
        stale.append(suffix)
        try stale.write(to: current)

        XCTAssertEqual(
            runSilently(["reconcile", current.path, "--from", previous.path]),
            CLIExit.success.rawValue
        )
        XCTAssertEqual(
            runSilently(["reconcile", current.path, "--from", previous.path, "--apply"]),
            CLIExit.usage.rawValue
        )
        XCTAssertEqual(
            runSilently([
                "reconcile", current.path, "--from", previous.path,
                "--apply", "--policy", "require-all"
            ]),
            CLIExit.success.rawValue
        )
        XCTAssertNoThrow(try EmbeddedCommentCodec().decode(Data(contentsOf: current)))
    }

    func testMergeCreatesNewOutputAndJSONOmitsDocumentBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent("base.md")
        let ours = directory.appendingPathComponent("ours.md")
        let theirs = directory.appendingPathComponent("theirs.md")
        let output = directory.appendingPathComponent("merged.md")
        try Data("base\n".utf8).write(to: base)
        try Data("base\n".utf8).write(to: ours)
        try Data("theirs\n".utf8).write(to: theirs)

        let merged = runCapturing([
            "merge", base.path, ours.path, theirs.path, "--output", output.path
        ])
        XCTAssertEqual(merged.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try Data(contentsOf: output), Data("theirs\n".utf8))
        let result = try XCTUnwrap(try jsonObject(merged.output)["result"] as? [String: Any])
        XCTAssertEqual(result["clean"] as? Bool, true)
        XCTAssertNil(result["data"])
        XCTAssertNil(try jsonObject(merged.output)["data"])

        XCTAssertEqual(
            runSilently(["merge", base.path, ours.path, theirs.path, "--output", output.path]),
            CLIExit.cannotCreate.rawValue
        )
        XCTAssertEqual(
            runSilently([
                "merge", base.path, ours.path, theirs.path,
                "--output", output.path, "--force"
            ]),
            CLIExit.success.rawValue
        )
    }

    func testFilteredListsMatchBeforeApplyingContributionLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        try Data("alpha target omega\n".utf8).write(to: file)

        let ordinaryActor = MarginActor(
            id: "urn:test:agent:ordinary",
            type: .software,
            name: "Ordinary commenter"
        )
        for index in 0..<70 {
            _ = try CommentService().add(
                at: file,
                message: "Ordinary comment \(index)",
                creator: ordinaryActor,
                anchor: .document
            )
        }

        for index in 0..<3 {
            XCTAssertEqual(
                runSilently([
                    "suggest", "add", file.path,
                    "--quote", "target", "--replacement", "replacement-\(index)",
                    "-m", "Suggestion \(index)",
                    "--id", String(format: "00000000-0000-4000-8000-%012d", 1_100 + index),
                    "--actor-id", "urn:test:agent:suggester", "--actor-type", "software"
                ]),
                CLIExit.success.rawValue
            )
            XCTAssertEqual(
                runSilently([
                    "handoff", "add", file.path, "-m", "Handoff \(index)",
                    "--id", String(format: "00000000-0000-4000-8000-%012d", 1_200 + index),
                    "--next-actor", "urn:test:agent:next",
                    "--actor-id", "urn:test:agent:handoff", "--actor-type", "software"
                ]),
                CLIExit.success.rawValue
            )
            XCTAssertEqual(
                runSilently([
                    "comments", "add", file.path, "--document", "--kind", "task",
                    "-m", "Task \(index)",
                    "--id", String(format: "00000000-0000-4000-8000-%012d", 1_300 + index),
                    "--assignee", "urn:test:agent:owner",
                    "--actor-id", "urn:test:agent:planner", "--actor-type", "software"
                ]),
                CLIExit.success.rawValue
            )
        }

        let suggestions = runCapturing([
            "suggest", "list", file.path, "--max-contributions", "2"
        ])
        XCTAssertEqual(suggestions.exit, CLIExit.success.rawValue)
        try assertFilteredList(
            suggestions.output,
            collection: "suggestions",
            expectedCount: 2,
            expectedOmitted: 1
        )

        let handoffs = runCapturing([
            "handoff", "list", file.path, "--max-contributions", "2"
        ])
        XCTAssertEqual(handoffs.exit, CLIExit.success.rawValue)
        try assertFilteredList(
            handoffs.output,
            collection: "handoffs",
            expectedCount: 2,
            expectedOmitted: 1
        )

        let inbox = runCapturing([
            "inbox", file.path,
            "--kind", "task", "--actor", "urn:test:agent:planner",
            "--assignee", "urn:test:agent:owner", "--max-contributions", "2"
        ])
        XCTAssertEqual(inbox.exit, CLIExit.success.rawValue)
        try assertFilteredList(
            inbox.output,
            collection: "items",
            expectedCount: 2,
            expectedOmitted: 1
        )
    }

    func testStaticLocalHelpLookupPerformance() {
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<1_000 {
                _ = CLICommandCatalog.localHelp(path: ["comments", "add"])
            }
        }
    }

    func testStaticManualLookupPerformance() {
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<1_000 {
                _ = MarginManual.page(for: "staging")
            }
        }
    }

    func testStaticCapabilitiesEncodingPerformance() {
        let capabilities = CLICommandCatalog.capabilities(cliVersion: MarginCommand.version)
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<25 {
                _ = try! JSONEncoder().encode(capabilities)
            }
        }
    }

    func testStaticCapabilityProjectionEncodingPerformance() {
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<100 {
                let projection = CLICommandCatalog.capabilitiesProjection(
                    cliVersion: MarginCommand.version,
                    workflow: .suggestions
                )
                _ = try! JSONEncoder().encode(projection)
            }
        }
    }

    private func runSilently(_ arguments: [String]) -> Int32 {
        let null = FileHandle(forWritingAtPath: "/dev/null")!
        let savedStandardOutput = dup(STDOUT_FILENO)
        precondition(savedStandardOutput >= 0)
        precondition(dup2(null.fileDescriptor, STDOUT_FILENO) >= 0)
        defer {
            _ = dup2(savedStandardOutput, STDOUT_FILENO)
            close(savedStandardOutput)
            try? null.close()
        }
        return MarginCommand.run(arguments: arguments)
    }

    private func runCapturing(_ arguments: [String]) -> (exit: Int32, output: Data) {
        runCapturing(arguments, fileDescriptor: STDOUT_FILENO)
    }

    private func runCapturingError(_ arguments: [String]) -> (exit: Int32, output: Data) {
        runCapturing(arguments, fileDescriptor: STDERR_FILENO)
    }

    private func runCapturing(
        _ arguments: [String],
        fileDescriptor: Int32
    ) -> (exit: Int32, output: Data) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginCLICapture-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = FileHandle(forWritingAtPath: outputURL.path)!
        let savedStandardOutput = dup(fileDescriptor)
        precondition(savedStandardOutput >= 0)
        precondition(dup2(handle.fileDescriptor, fileDescriptor) >= 0)
        let exit = MarginCommand.run(arguments: arguments)
        _ = fsync(handle.fileDescriptor)
        _ = dup2(savedStandardOutput, fileDescriptor)
        close(savedStandardOutput)
        try? handle.close()
        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        try? FileManager.default.removeItem(at: outputURL)
        return (exit, output)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginCLIContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func string(in values: [String: JSONValue], key: String) -> String? {
        guard case .string(let value)? = values[key] else { return nil }
        return value
    }

    private func assertFilteredList(
        _ data: Data,
        collection: String,
        expectedCount: Int,
        expectedOmitted: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try XCTUnwrap(
            try jsonObject(data)["result"] as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(
            (result[collection] as? [[String: Any]])?.count,
            expectedCount,
            file: file,
            line: line
        )
        let truncation = try XCTUnwrap(
            result["truncation"] as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(
            truncation["omittedMatchingContributionCount"] as? Int,
            expectedOmitted,
            file: file,
            line: line
        )
        XCTAssertEqual(
            truncation["omittedContributionCount"] as? Int,
            expectedOmitted,
            file: file,
            line: line
        )
        XCTAssertEqual(truncation["isTruncated"] as? Bool, true, file: file, line: line)
    }

    private func assertStageRefreshGuidance(
        _ data: Data,
        stageID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let payload = try jsonObject(data)
        let error = try XCTUnwrap(
            payload["error"] as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(
            error["code"] as? String,
            "COLLABORATION_PRECONDITION_FAILED",
            file: file,
            line: line
        )
        let details = try XCTUnwrap(
            error["details"] as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(details["stageID"] as? String, stageID, file: file, line: line)
        XCTAssertEqual(details["stageRetained"] as? String, "true", file: file, line: line)
        XCTAssertEqual(
            details["recoveryCommand"] as? String,
            "margin stage refresh ROOT STAGE_ID",
            file: file,
            line: line
        )
    }
}
