import Foundation
import MarginCore
import XCTest
@testable import MarginCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

            let brief = CLICommandCatalog.capabilitiesBriefProjection(
                cliVersion: MarginCommand.version,
                workflow: workflow
            )
            let briefCompactData = try compact.encode(brief)
            let briefPrettyData = try pretty.encode(brief)
            XCTAssertLessThanOrEqual(briefCompactData.count + 1, brief.bounds.maxEncodedBytes)
            XCTAssertLessThanOrEqual(briefPrettyData.count + 1, brief.bounds.maxEncodedBytes)
            XCTAssertEqual(brief.schema, "urn:margin:capabilities-brief-projection:v1")
            XCTAssertEqual(brief.projection.workflow, workflow)
            XCTAssertEqual(brief.projection.parentSchema, projection.schema)
            XCTAssertEqual(brief.commands.map(\.path), projection.commands.map(\.path))
            XCTAssertTrue(brief.commands.allSatisfy { $0.helpArgv == $0.path + ["--help"] })
            XCTAssertEqual(brief.next.manualArgv, ["man", workflow.rawValue])
            XCTAssertEqual(
                brief.next.detailedCapabilitiesArgv,
                ["capabilities", "--json", "--for", workflow.rawValue]
            )
        }

        let suggestions = CLICommandCatalog.capabilitiesProjection(
            cliVersion: MarginCommand.version,
            workflow: .suggestions
        )
        let suggestionAdd = try XCTUnwrap(
            suggestions.commands.first { $0.path == ["suggest", "add"] }
        )
        let suggestionGuidance = try XCTUnwrap(suggestionAdd.guidance)
        XCTAssertEqual(suggestionGuidance.count, 5)
        XCTAssertTrue(suggestionGuidance[0].contains("margin suggest add FILE"))
        XCTAssertTrue(suggestionGuidance[0].contains("suggest batch is an exact alias"))
        XCTAssertTrue(suggestionGuidance[0].contains("standard input"))
        XCTAssertTrue(suggestionGuidance[0].contains("[{\"id\":\"UUID\""))
        XCTAssertTrue(suggestionGuidance[0].contains("\"exact\":\"old\""))
        XCTAssertTrue(suggestionGuidance[1].contains("add directly"))
        XCTAssertTrue(suggestionGuidance[1].contains("validate the source atomically"))
        XCTAssertTrue(suggestionGuidance[3].contains("suggest wait FILE ID..."))
        XCTAssertTrue(suggestionGuidance[3].contains("suggest list FILE once"))
        XCTAssertTrue(suggestionGuidance[3].contains("read FILE --json once"))
        let suggestionBatch = try XCTUnwrap(
            suggestions.commands.first { $0.path == ["suggest", "batch"] }
        )
        let batchGuidance = try XCTUnwrap(suggestionBatch.guidance)
        XCTAssertEqual(batchGuidance.count, 4)
        XCTAssertTrue(batchGuidance[0].contains("urn:margin:suggestion-batch:v1"))
        XCTAssertTrue(batchGuidance[0].contains("Default standard input"))
        XCTAssertTrue(batchGuidance[1].contains("rejects the whole batch"))
        let suggestionWait = try XCTUnwrap(
            suggestions.commands.first { $0.path == ["suggest", "wait"] }
        )
        XCTAssertTrue(suggestionWait.usage[0].contains("FILE ID..."))
        XCTAssertEqual(suggestionWait.sideEffects, "waits-for-named-file-state")
        XCTAssertFalse(suggestions.commands.contains { $0.path == ["inbox"] })
        XCTAssertFalse(suggestions.commands.contains { $0.path == ["merge"] })

        let staging = CLICommandCatalog.capabilitiesProjection(
            cliVersion: MarginCommand.version,
            workflow: .staging
        )
        XCTAssertTrue(staging.commands.contains { $0.path == ["stage", "refresh"] })
        XCTAssertFalse(staging.commands.contains { $0.path == ["transact"] })
        XCTAssertLessThanOrEqual(try compact.encode(staging).count + 1, 16 * 1_024)

        let output = runCapturing(["capabilities", "--json", "--for", "suggestions"])
        XCTAssertEqual(output.exit, CLIExit.success.rawValue)
        let json = try jsonObject(output.output)
        XCTAssertEqual(json["schema"] as? String, "urn:margin:capabilities-projection:v1")
        let identity = try XCTUnwrap(json["projection"] as? [String: Any])
        XCTAssertEqual(identity["workflow"] as? String, "suggestions")
        let briefOutput = runCapturing([
            "capabilities", "--json", "--for", "suggestions", "--brief",
        ])
        XCTAssertEqual(briefOutput.exit, CLIExit.success.rawValue)
        let briefJSON = try jsonObject(briefOutput.output)
        XCTAssertEqual(
            briefJSON["schema"] as? String,
            "urn:margin:capabilities-brief-projection:v1"
        )
        XCTAssertLessThanOrEqual(briefOutput.output.count, 8 * 1_024)
        let briefWithoutWorkflow = runCapturingError(["capabilities", "--json", "--brief"])
        XCTAssertEqual(briefWithoutWorkflow.exit, CLIExit.usage.rawValue)
        XCTAssertTrue(
            String(decoding: briefWithoutWorkflow.output, as: UTF8.self)
                .contains("--brief requires --for WORKFLOW")
        )
        XCTAssertEqual(
            runSilently(["capabilities", "--json", "--for", "unknown"]),
            CLIExit.usage.rawValue
        )
    }

    func testAliasesAndCommandLocalHelpComeFromTheSameCatalog() throws {
        XCTAssertEqual(CLICommandCatalog.canonicalTopLevel("comment"), "comments")
        XCTAssertEqual(CLICommandCatalog.canonicalTopLevel("show"), "read")
        XCTAssertEqual(CLICommandCatalog.canonicalTopLevel("cat"), "read")
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
        XCTAssertTrue(add.contains("--id, --contribution-id, --mutation-id UUID"))
        XCTAssertTrue(add.contains("--if-content-sha SHA"))
        XCTAssertTrue(add.lowercased().contains("zero is valid"))
        XCTAssertTrue(add.contains("observed current revision"))
        XCTAssertTrue(add.contains("--parent is reply shorthand"))
        XCTAssertTrue(add.contains("--parent PARENT"))
        XCTAssertTrue(add.contains("retry annotation-only races"))

        let reply = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["comments", "reply"]))
        XCTAssertTrue(reply.contains("(-m TEXT | --message-file PATH | --stdin)"))
        XCTAssertTrue(reply.contains("--resolve"))
        XCTAssertTrue(reply.contains("--id, --mutation-id UUID"))
        XCTAssertTrue(reply.contains("close the root thread atomically"))

        let show = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["show"]))
        XCTAssertTrue(show.contains("margin show FILE"))

        let context = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["context"]))
        XCTAssertFalse(context.contains("Unsupported"))
        XCTAssertTrue(context.contains("margin context TARGET [--json]"))
        XCTAssertTrue(context.contains("compact agent view"))
        XCTAssertTrue(context.contains("--max-source-bytes N"))
        XCTAssertTrue(context.contains("File cap: 128; brief 4"))
        XCTAssertTrue(context.contains("Work items/file: 64; brief 1"))

        let stageCreate = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["stage", "create"]))
        XCTAssertTrue(stageCreate.contains("--operations-file PLAN_JSON_OR_-"))
        XCTAssertTrue(stageCreate.contains("--change-set-file CHANGESET_JSON_OR_-"))
        XCTAssertTrue(stageCreate.contains("Do not pass JSON as a positional argument"))
        let stageCreateWithoutRoot = runCapturingError([
            "stage", "create", "--operations-file", "-"
        ])
        XCTAssertEqual(stageCreateWithoutRoot.exit, CLIExit.usage.rawValue)
        let stageCreateError = try XCTUnwrap(
            try jsonObject(stageCreateWithoutRoot.output)["error"] as? [String: Any]
        )
        XCTAssertTrue(
            (stageCreateError["message"] as? String)?.contains("stage create .") == true
        )
        let stageShow = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["stage", "show"]))
        XCTAssertTrue(stageShow.contains("--max-preview-bytes N"))
        XCTAssertTrue(stageShow.contains("1 MiB"))
        let stageList = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["stage", "list"]))
        XCTAssertTrue(stageList.contains("margin stage list [ROOT]"))
        XCTAssertTrue(stageList.contains("defaults to the current directory"))
        XCTAssertTrue(stageList.contains("--max-bytes N"))
        XCTAssertTrue(stageList.contains("Byte omissions are reported"))
        let stageRefresh = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["stage", "refresh"]))
        XCTAssertTrue(stageRefresh.contains("--id NEW_STAGE_ID"))
        XCTAssertTrue(stageRefresh.contains("--submit"))
        XCTAssertTrue(stageRefresh.contains("Safe to repeat"))
        XCTAssertTrue(stageRefresh.contains("preserving the prior stage"))

        let suggestionAdd = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["suggest", "add"]))
        XCTAssertTrue(suggestionAdd.contains("--id, --contribution-id ID"))
        let handoffAdd = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["handoff", "add"]))
        XCTAssertTrue(handoffAdd.contains("--id, --contribution-id ID"))
        XCTAssertTrue(handoffAdd.contains("writes nothing"))
        XCTAssertTrue(handoffAdd.contains("margin context TARGET --json"))
        XCTAssertTrue(handoffAdd.contains("never silently rebases"))
        let handoffManual = try XCTUnwrap(MarginManual.page(for: "handoff"))
        XCTAssertTrue(handoffManual.contains("COLLABORATION_PRECONDITION_FAILED"))
        XCTAssertTrue(handoffManual.contains("nothing was written"))
        XCTAssertTrue(handoffManual.contains("never place a stale handoff in an automatic retry loop"))

        let capabilities = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["capabilities"]))
        XCTAssertTrue(capabilities.contains("--for WORKFLOW"))
        XCTAssertTrue(capabilities.contains("--brief"))
        XCTAssertTrue(capabilities.contains("review, staging, suggestions, handoff, or merge"))

        let safetyManual = try XCTUnwrap(MarginManual.page(for: "safety"))
        XCTAssertTrue(safetyManual.contains("retry bounded"))
        XCTAssertTrue(safetyManual.contains("explicit revision"))

        XCTAssertEqual(CLICapabilityWorkflow.parse("comments"), .review)
        XCTAssertEqual(CLICapabilityWorkflow.parse("stage"), .staging)
        XCTAssertEqual(CLICapabilityWorkflow.parse("reconciliation"), .merge)
        let commentsProjection = runCapturing(["capabilities", "--json", "--for", "comments"])
        XCTAssertEqual(commentsProjection.exit, CLIExit.success.rawValue)
        XCTAssertEqual(
            (try jsonObject(commentsProjection.output)["projection"] as? [String: Any])?["workflow"] as? String,
            "review"
        )

        let manual = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["man"]))
        XCTAssertTrue(manual.contains("margin man [TOPIC]"))
        let commandManual = runCapturing(["man", "comments", "add"])
        XCTAssertEqual(commandManual.exit, CLIExit.success.rawValue)
        XCTAssertTrue(String(decoding: commandManual.output, as: UTF8.self).contains("margin comments add"))
        XCTAssertTrue(manual.contains("--list"))
        XCTAssertTrue(manual.contains("--json"))

        let commandManualJSON = runCapturing(["man", "comments", "add", "--json"])
        XCTAssertEqual(commandManualJSON.exit, CLIExit.success.rawValue)
        let manualObject = try jsonObject(commandManualJSON.output)
        XCTAssertEqual(manualObject["schema"] as? String, "urn:margin:manual:v1")
        XCTAssertEqual(manualObject["kind"] as? String, "command-help")
        XCTAssertEqual(manualObject["query"] as? [String], ["comments", "add"])
        XCTAssertTrue((manualObject["content"] as? String)?.contains("margin comments add") == true)
        let commandContracts = try XCTUnwrap(manualObject["contracts"] as? [[String: Any]])
        XCTAssertEqual(commandContracts.count, 1)
        XCTAssertEqual(commandContracts.first?["path"] as? [String], ["comments", "add"])
        XCTAssertEqual(manualObject["nextQueries"] as? [[String]], [])
        XCTAssertLessThan(commandManualJSON.output.count, MarginManualEnvelope.maximumEncodedBytes)

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
        let globalHelpText = try XCTUnwrap(String(data: globalHelp.output, encoding: .utf8))
        XCTAssertTrue(globalHelpText.contains("margin man"))
        XCTAssertTrue(globalHelpText.contains("start with context TARGET --json --brief"))
        XCTAssertTrue(globalHelpText.contains("Use margin man agents"))
        XCTAssertTrue(globalHelpText.contains("capabilities --json --for WORKFLOW"))
        XCTAssertTrue(globalHelpText.contains("--for WORKFLOW --brief"))
        XCTAssertTrue(globalHelpText.contains("unfiltered capabilities catalog is for integrations"))
        XCTAssertTrue(globalHelpText.contains("context --brief is the compact agent entry"))

        let capabilitiesHelp = runCapturing(["capabilities", "--help"])
        XCTAssertEqual(capabilitiesHelp.exit, CLIExit.success.rawValue)
        let capabilitiesHelpText = try XCTUnwrap(
            String(data: capabilitiesHelp.output, encoding: .utf8)
        )
        XCTAssertTrue(capabilitiesHelpText.contains("ordinary agent work"))
        XCTAssertTrue(capabilitiesHelpText.contains("Recommended for agent tasks"))
        XCTAssertTrue(capabilitiesHelpText.contains("compact command index"))
        XCTAssertTrue(capabilitiesHelpText.contains("full integration catalog"))

        let overview = runCapturing(["man"])
        XCTAssertEqual(overview.exit, CLIExit.success.rawValue)
        let overviewText = try XCTUnwrap(String(data: overview.output, encoding: .utf8))
        XCTAssertTrue(overviewText.contains("MARGIN MANUAL"))
        XCTAssertTrue(overviewText.contains("margin capabilities --json --for review --brief"))
        XCTAssertLessThan(
            try XCTUnwrap(overviewText.range(of: "margin context TARGET")).lowerBound,
            try XCTUnwrap(
                overviewText.range(of: "margin capabilities --json --for review --brief")
            ).lowerBound
        )
        XCTAssertTrue(overviewText.contains("Act from workflowGuidance"))
        XCTAssertTrue(overviewText.contains("margin context TARGET --json --brief"))
        XCTAssertTrue(overviewText.contains("margin inbox TARGET --status open --brief"))
        XCTAssertTrue(overviewText.contains("filtered queue across the target root"))
        XCTAssertTrue(overviewText.contains("does not inherit context's four-file cap"))
        XCTAssertFalse(overviewText.contains("--max-files 16"))
        XCTAssertFalse(overviewText.contains("--max-contributions 64"))
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
        let listedJSON = runCapturing(["man", "--json", "--list", "--pretty"])
        XCTAssertEqual(listedJSON.exit, CLIExit.success.rawValue)
        let listedObject = try jsonObject(listedJSON.output)
        XCTAssertEqual(listedObject["kind"] as? String, "topic-list")
        XCTAssertEqual(listedObject["query"] as? [String], [])
        XCTAssertEqual(listedObject["contentType"] as? String, "text/plain; charset=utf-8")
        XCTAssertTrue((listedObject["content"] as? String)?.contains("MARGIN MANUAL TOPICS") == true)
        XCTAssertEqual((listedObject["contracts"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(
            listedObject["nextQueries"] as? [[String]],
            MarginManual.canonicalTopics.map { [$0] }
        )

        let invalidPretty = runCapturingError(["man", "comments", "--pretty"])
        XCTAssertEqual(invalidPretty.exit, CLIExit.usage.rawValue)
        XCTAssertTrue(String(decoding: invalidPretty.output, as: UTF8.self).contains("--pretty requires --json"))
        XCTAssertEqual(MarginManual.page(for: "WORKFLOW"), MarginManual.overview)

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
        let canonicalReview = runCapturing(["man", "review"])
        XCTAssertEqual(canonicalReview.exit, CLIExit.success.rawValue)
        for naturalReviewTopic in ["directory", "folder", "workspace", "context", "inbox"] {
            let alias = runCapturing(["man", naturalReviewTopic])
            XCTAssertEqual(alias.exit, CLIExit.success.rawValue, naturalReviewTopic)
            XCTAssertEqual(alias.output, canonicalReview.output, naturalReviewTopic)
            XCTAssertEqual(
                MarginManual.contractPaths(for: naturalReviewTopic),
                MarginManual.contractPaths(for: "review"),
                naturalReviewTopic
            )
        }
        let marginAlias = runCapturing(["man", "margin"])
        XCTAssertEqual(marginAlias.exit, CLIExit.success.rawValue)
        XCTAssertEqual(marginAlias.output, overview.output)
        let markdownTarget = runCapturing(["man", "status.md"])
        XCTAssertEqual(markdownTarget.exit, CLIExit.success.rawValue)
        let markdownTargetText = try XCTUnwrap(String(data: markdownTarget.output, encoding: .utf8))
        XCTAssertTrue(markdownTargetText.contains("MARGIN MANUAL: MARKDOWN TARGET"))
        XCTAssertTrue(markdownTargetText.contains("margin context status.md --json --brief"))
        let nestedMarkdownTarget = runCapturing(["man", "notes/status.md", "--json"])
        XCTAssertEqual(nestedMarkdownTarget.exit, CLIExit.success.rawValue)
        let nestedTargetObject = try jsonObject(nestedMarkdownTarget.output)
        XCTAssertEqual(nestedTargetObject["query"] as? [String], ["notes/status.md"])
        let nestedTargetContracts = try XCTUnwrap(nestedTargetObject["contracts"] as? [[String: Any]])
        XCTAssertEqual(
            nestedTargetContracts.compactMap { $0["path"] as? [String] },
            [["context"], ["comments", "list"], ["handoff", "list"]]
        )
        XCTAssertEqual(runSilently(["man", "../status.md"]), CLIExit.usage.rawValue)
        let commentsManual = try XCTUnwrap(MarginManual.page(for: "comments"))
        XCTAssertTrue(commentsManual.contains("--document --kind issue"))
        let commentsJSON = runCapturing(["man", "comments", "--json"])
        XCTAssertEqual(commentsJSON.exit, CLIExit.success.rawValue)
        let commentsObject = try jsonObject(commentsJSON.output)
        let commentContracts = try XCTUnwrap(commentsObject["contracts"] as? [[String: Any]])
        XCTAssertEqual(
            commentContracts.compactMap { $0["path"] as? [String] },
            MarginManual.contractPaths(for: "comments")
        )
        XCTAssertEqual(
            commentsObject["nextQueries"] as? [[String]],
            MarginManual.contractPaths(for: "comments")
        )
        XCTAssertLessThan(commentsJSON.output.count, MarginManualEnvelope.maximumEncodedBytes)

        for topic in MarginManual.canonicalTopics {
            let topicJSON = runCapturing(["man", topic, "--json", "--pretty"])
            XCTAssertEqual(topicJSON.exit, CLIExit.success.rawValue, topic)
            XCTAssertLessThan(topicJSON.output.count, MarginManualEnvelope.maximumEncodedBytes, topic)
            let topicObject = try jsonObject(topicJSON.output)
            let topicContent = try XCTUnwrap(topicObject["content"] as? String)
            XCTAssertFalse(topicContent.contains("--max-files 16"), topic)
            XCTAssertFalse(topicContent.contains("--max-contributions 64"), topic)
        }

        let unknown = runCapturingError(["man", "unknown"])
        XCTAssertEqual(unknown.exit, CLIExit.usage.rawValue)
        let errorText = try XCTUnwrap(String(data: unknown.output, encoding: .utf8))
        XCTAssertTrue(errorText.contains("Unknown manual topic or command 'unknown'"))
        XCTAssertTrue(errorText.contains("margin man --list"))
    }

    func testFindingIsANaturalAliasForCanonicalIssueContribution() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("audit.md")
        let body = "# Audit\n\nReview this control.\n"
        try Data(body.utf8).write(to: file)

        let result = runCapturing([
            "comments", "add", file.path, "--document", "--kind", "finding",
            "-m", "The control needs evidence.",
            "--id", "00000000-0000-4000-8000-000000009901",
            "--actor-id", "urn:test:agent:auditor", "--actor-type", "software",
        ])
        XCTAssertEqual(result.exit, CLIExit.success.rawValue)
        XCTAssertTrue((try jsonObject(result.output)["notice"] as? String)?.contains("Typed issue saved") == true)

        let decoded = try EmbeddedCommentCodec().decode(Data(contentsOf: file))
        XCTAssertEqual(decoded.body, body)
        let annotation = try XCTUnwrap(decoded.envelope?.items.first)
        XCTAssertEqual(string(in: annotation.extensions, key: "margin:kind"), "issue")
        XCTAssertTrue(
            CLICommandCatalog.command(path: ["comments", "add"])?
                .options.first(where: { $0.names.contains("--kind") })?
                .choices?.contains("finding") == true
        )
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
        let reply = runCapturing([
            "comments", "reply",
            "--id", replyUUID,
            "--body", "Initial reply",
            file.path,
            rootID,
            "--actor-name", "CLI contract tests",
            "--if-revision", "1"
        ])
        XCTAssertEqual(reply.exit, CLIExit.success.rawValue)
        let replyJSON = try jsonObject(reply.output)
        let replyResult = try XCTUnwrap(replyJSON["result"] as? [String: Any])
        XCTAssertEqual(replyResult["threadStatus"] as? String, "open")
        let notice = try XCTUnwrap(replyJSON["notice"] as? String)
        XCTAssertTrue(notice.contains("remains open"))
        XCTAssertTrue(notice.contains("reply --resolve"))
        let nextActions = try XCTUnwrap(replyJSON["nextActions"] as? [[String: Any]])
        XCTAssertEqual(nextActions.first?["command"] as? String, "comments resolve")
        XCTAssertEqual(
            nextActions.first?["argv"] as? [String],
            ["comments", "resolve", file.path, rootID, "--if-revision", "2"]
        )
        XCTAssertTrue((nextActions.first?["condition"] as? String)?.contains("task asks") == true)
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

    func testReplyAndResolveIsOneIdempotentCLIRevision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginCLIContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("atomic-reply.md")
        let original = "# Review\n\nClose this thread safely.\n"
        try Data(original.utf8).write(to: file)

        let rootUUID = "00000000-0000-4000-8000-000000000811"
        let replyUUID = "00000000-0000-4000-8000-000000000812"
        let rootID = "urn:uuid:\(rootUUID)"
        XCTAssertEqual(
            runSilently([
                "comments", "add", file.path, "--quote", "Close this thread safely.",
                "-m", "Please verify and close.", "--id", rootUUID,
            ]),
            CLIExit.success.rawValue
        )

        let arguments = [
            "comments", "reply", file.path, rootID, "-m", "Verified and complete.",
            "--resolve", "--mutation-id", replyUUID, "--if-revision", "1",
            "--actor-id", "urn:test:resolver", "--actor-name", "Resolver",
            "--actor-type", "software",
        ]
        let reply = runCapturing(arguments)
        XCTAssertEqual(reply.exit, CLIExit.success.rawValue)
        let envelope = try jsonObject(reply.output)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["changed"] as? Bool, true)
        XCTAssertEqual(result["revision"] as? Int, 2)
        XCTAssertEqual(result["threadStatus"] as? String, "resolved")
        let annotation = try XCTUnwrap(result["annotation"] as? [String: Any])
        XCTAssertEqual(annotation["margin:resolveAfterReply"] as? Bool, true)
        XCTAssertTrue((envelope["notice"] as? String)?.contains("resolved atomically") == true)
        let nextActions = try XCTUnwrap(envelope["nextActions"] as? [[String: Any]])
        XCTAssertEqual(nextActions.map { $0["command"] as? String }, ["comments list"])

        let replay = runCapturing(arguments)
        XCTAssertEqual(replay.exit, CLIExit.success.rawValue)
        let replayResult = try XCTUnwrap(
            try jsonObject(replay.output)["result"] as? [String: Any]
        )
        XCTAssertEqual(replayResult["changed"] as? Bool, false)
        XCTAssertEqual(replayResult["revision"] as? Int, 2)

        var changedIntent = arguments
        changedIntent.remove(at: try XCTUnwrap(changedIntent.firstIndex(of: "--resolve")))
        XCTAssertEqual(runSilently(changedIntent), CLIExit.data.rawValue)
        XCTAssertEqual(
            runSilently([
                "comments", "reply", file.path, rootID, "-m", "Impossible",
                "--reopen", "--resolve",
            ]),
            CLIExit.usage.rawValue
        )

        let stalePhaseVocabulary = runCapturingError([
            "comments", "reply", file.path, rootID, "-m", "Still impossible",
            "--resolve", "--request-id", "urn:test:handoff-request",
        ])
        XCTAssertEqual(stalePhaseVocabulary.exit, CLIExit.usage.rawValue)
        let recoveryMessage = String(decoding: stalePhaseVocabulary.output, as: UTF8.self)
        XCTAssertTrue(recoveryMessage.contains("--request-id belongs to handoff"))
        XCTAssertTrue(recoveryMessage.contains("replace it with --id UUID"))

        let snapshot = try CommentService().list(at: file)
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.comments.count, 2)
        XCTAssertTrue(snapshot.comments.allSatisfy { $0.threadStatus == .resolved })
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).body, original)
    }

    func testReplyShorthandResolvesAtomicallyAndMisgroupedSuggestSelfCorrects() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reply-shorthand.md")
        try Data("# Review\n\nResolve this.\n".utf8).write(to: file)
        let rootUUID = "00000000-0000-4000-8000-000000000821"
        let rootID = "urn:uuid:\(rootUUID)"
        XCTAssertEqual(
            runSilently([
                "comments", "add", file.path, "--document", "-m", "Please resolve.",
                "--id", rootUUID,
            ]),
            CLIExit.success.rawValue
        )
        let reply = runCapturing([
            "comments", "add", file.path, "--parent", rootID,
            "-m", "Resolved via shorthand.", "--resolve",
            "--mutation-id", "00000000-0000-4000-8000-000000000822",
            "--if-revision", "1",
        ])
        XCTAssertEqual(reply.exit, CLIExit.success.rawValue)
        let result = try XCTUnwrap(try jsonObject(reply.output)["result"] as? [String: Any])
        XCTAssertEqual(result["threadStatus"] as? String, "resolved")
        XCTAssertEqual(result["revision"] as? Int, 2)
        XCTAssertTrue(try CommentService().list(at: file).comments.allSatisfy {
            $0.threadStatus == .resolved
        })

        let misplaced = runCapturingError(["comments", "suggest", "add", "--help"])
        XCTAssertEqual(misplaced.exit, CLIExit.usage.rawValue)
        let message = String(decoding: misplaced.output, as: UTF8.self)
        XCTAssertTrue(message.contains("top-level command"))
        XCTAssertTrue(message.contains("margin suggest add --help"))
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

        let emptyContext = runCapturing(["context", directory.path, "--max-files", "1"])
        XCTAssertEqual(emptyContext.exit, CLIExit.success.rawValue)
        let emptyContextJSON = try jsonObject(emptyContext.output)
        XCTAssertTrue(
            (emptyContextJSON["notice"] as? String)?.contains("Act from workflowGuidance") == true
        )
        XCTAssertTrue((emptyContextJSON["notice"] as? String)?.contains("before opening inbox") == true)
        let emptyResult = try XCTUnwrap(emptyContextJSON["result"] as? [String: Any])
        let emptyFileAction = try XCTUnwrap(
            (emptyResult["fileActions"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(emptyFileAction["path"] as? String, "review.md")
        XCTAssertEqual(emptyFileAction["actionPath"] as? String, file.path)
        XCTAssertEqual(emptyFileAction["annotationRevision"] as? Int, 0)
        XCTAssertEqual(
            emptyFileAction["commentArgvTemplate"] as? [String],
            [
                "comments", "add", file.path, "--document", "--kind", "KIND",
                "-m", "TEXT", "--contribution-id", "UUID", "--if-revision", "0",
            ]
        )
        let emptyGuidance = try XCTUnwrap(emptyResult["workflowGuidance"] as? [[String: Any]])
        XCTAssertEqual(emptyGuidance.first?["command"] as? String, "handoff add")
        XCTAssertEqual(
            emptyGuidance.first?["arguments"] as? [String],
            [
                directory.path, "--path", "review.md", "-m", "TEXT", "--next-actor", "ACTOR_ID",
                "--contribution-id", "UUID", "--request-id", "UUID",
            ]
        )
        XCTAssertEqual(
            emptyGuidance.first?["argvTemplate"] as? [String],
            [
                "handoff", "add", directory.path, "--path", "review.md", "-m", "TEXT",
                "--next-actor", "ACTOR_ID", "--contribution-id", "UUID", "--request-id", "UUID",
            ]
        )
        XCTAssertEqual(emptyGuidance.first?["executable"] as? Bool, false)
        XCTAssertNil(emptyGuidance.first?["argv"])
        XCTAssertEqual(
            emptyGuidance.first?["requiredReplacements"] as? [String],
            ["TEXT", "ACTOR_ID", "UUID"]
        )
        XCTAssertTrue(
            (emptyGuidance.first?["note"] as? String)?.contains("captured automatically") == true
        )

        let typedID = "00000000-0000-4000-8000-000000000901"
        let typedArguments = [
                "comments", "add", file.path,
                "--document", "--kind", "task", "-m", "Verify the release",
                "--assignee", "urn:test:agent:owner", "--priority", "high",
                "--audience", "urn:test:agent:reviewer",
                "--actor-id", "urn:test:agent:author", "--actor-type", "software",
                "--actor-name", "Author", "--contribution-id", typedID
        ]
        let typedCreate = runCapturing(typedArguments)
        XCTAssertEqual(typedCreate.exit, CLIExit.success.rawValue)
        let typedCreateJSON = try jsonObject(typedCreate.output)
        XCTAssertTrue((typedCreateJSON["notice"] as? String)?.contains("do not carry --document") == true)
        let typedNextActions = try XCTUnwrap(typedCreateJSON["nextActions"] as? [[String: Any]])
        XCTAssertEqual(typedNextActions.map { $0["command"] as? String }, ["comments get", "comments list"])
        XCTAssertEqual(
            typedNextActions.first?["argv"] as? [String],
            ["comments", "get", file.path, "urn:uuid:\(typedID)"]
        )
        XCTAssertEqual(
            typedNextActions.last?["arguments"] as? [String],
            [file.path, "--status", "all"]
        )
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
        XCTAssertEqual(contextResult["invocationTarget"] as? String, file.path)
        XCTAssertEqual(contextResult["directFileTarget"] as? String, file.path)
        XCTAssertTrue(
            (contextResult["pathSemantics"] as? String)?.contains("files[].path is relative") == true
        )
        XCTAssertTrue((contextResult["cursor"] as? String)?.hasPrefix("mcur1:") == true)
        let contextActions = try XCTUnwrap(contextResult["availableActions"] as? [String])
        XCTAssertTrue(contextActions.contains("read"))
        XCTAssertTrue(contextActions.contains("comments reply"))
        XCTAssertTrue(contextActions.contains("comments resolve"))
        let contextFiles = try XCTUnwrap(contextResult["files"] as? [[String: Any]])
        XCTAssertEqual(contextFiles.first?["sourcePreview"] as? String, body)
        XCTAssertEqual(contextFiles.first?["sourcePreviewTruncated"] as? Bool, false)
        let contextFileAction = try XCTUnwrap(
            (contextResult["fileActions"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(contextFileAction["actionPath"] as? String, file.path)
        XCTAssertEqual(contextFileAction["annotationRevision"] as? Int, 1)
        XCTAssertEqual(
            contextFileAction["annotationRevisionSemantics"] as? String,
            "observed-pre-write-value; copy exactly; zero is valid"
        )
        let guidance = try XCTUnwrap(contextResult["workflowGuidance"] as? [[String: Any]])
        XCTAssertEqual(guidance.first?["command"] as? String, "comments reply")
        XCTAssertEqual(
            guidance.first?["arguments"] as? [String],
            [
                file.path, "urn:uuid:\(typedID)", "-m", "TEXT", "--id", "UUID",
                "--if-revision", "1",
            ]
        )
        XCTAssertEqual(guidance.first?["executable"] as? Bool, false)
        XCTAssertNil(guidance.first?["argv"])
        XCTAssertEqual(
            guidance.first?["requiredReplacements"] as? [String],
            ["TEXT", "UUID"]
        )
        XCTAssertTrue((guidance.first?["note"] as? String)?.contains("root ID, and revision are exact") == true)
        let atomicReply = try XCTUnwrap(
            guidance.first {
                ($0["purpose"] as? String) == "reply and close the first open durable thread atomically"
            }
        )
        XCTAssertEqual(atomicReply["command"] as? String, "comments reply")
        XCTAssertEqual(
            atomicReply["argvTemplate"] as? [String],
            [
                "comments", "reply", file.path, "urn:uuid:\(typedID)", "-m", "TEXT",
                "--resolve", "--id", "UUID", "--if-revision", "1",
            ]
        )
        XCTAssertTrue((atomicReply["note"] as? String)?.contains("atomic") == true)
        XCTAssertNil(guidance.first { ($0["command"] as? String) == "comments add" })

        let followupHandoff = try XCTUnwrap(
            guidance.first { ($0["purpose"] as? String) == "start a durable handoff" }
        )
        XCTAssertEqual(
            followupHandoff["argvTemplate"] as? [String],
            [
                "handoff", "add", file.path, "-m", "TEXT", "--next-actor", "ACTOR_ID",
                "--contribution-id", "UUID", "--request-id", "UUID",
            ]
        )
        let verifyHandoff = try XCTUnwrap(
            guidance.first { ($0["purpose"] as? String) == "verify the new handoff" }
        )
        XCTAssertEqual(
            verifyHandoff["argv"] as? [String],
            ["handoff", "list", file.path]
        )

        let briefContext = runCapturing([
            "context", file.path, "--json", "--brief", "--max-files", "1",
        ])
        XCTAssertEqual(briefContext.exit, CLIExit.success.rawValue)
        XCTAssertLessThan(briefContext.output.count, context.output.count)
        let briefJSON = try jsonObject(briefContext.output)
        XCTAssertTrue((briefJSON["notice"] as? String)?.lowercased().contains("brief context") == true)
        XCTAssertLessThanOrEqual(briefContext.output.count, 4 * 1_024)
        let briefResult = try XCTUnwrap(briefJSON["result"] as? [String: Any])
        XCTAssertNil(briefResult["actors"])
        XCTAssertNil(briefResult["activity"])
        XCTAssertNil(briefResult["availableActions"])
        XCTAssertNil(briefResult["fileActions"])
        XCTAssertNil(briefResult["cursor"])
        XCTAssertNil(briefResult["pathSemantics"])
        XCTAssertEqual(briefResult["cursorOmitted"] as? Bool, true)
        let briefFiles = try XCTUnwrap(briefResult["files"] as? [[String: Any]])
        XCTAssertEqual(briefFiles.first?["actionPath"] as? String, file.path)
        XCTAssertEqual(briefFiles.first?["annotationRevision"] as? Int, 1)
        XCTAssertEqual(briefFiles.first?["contributionCount"] as? Int, 1)
        let briefWork = try XCTUnwrap(briefResult["work"] as? [[String: Any]])
        XCTAssertEqual(briefWork.first?["kind"] as? String, "task")
        XCTAssertEqual(briefWork.first?["actionPath"] as? String, file.path)
        XCTAssertEqual(briefWork.first?["annotationRevision"] as? Int, 1)
        let briefGuidance = try XCTUnwrap(
            briefResult["workflowGuidance"] as? [[String: Any]]
        )
        XCTAssertLessThanOrEqual(briefGuidance.count, 5)
        XCTAssertEqual(briefGuidance.count, 5)
        XCTAssertNil(briefGuidance.first?["command"])
        XCTAssertNil(briefGuidance.first?["arguments"])
        XCTAssertNil(briefGuidance.first?["executable"])
        XCTAssertNil(briefGuidance.first?["note"])
        XCTAssertNotNil(briefGuidance.first?["argvTemplate"])
        XCTAssertTrue(
            briefGuidance.contains {
                ($0["purpose"] as? String) == "start a durable handoff"
                    && ($0["argvTemplate"] as? [String])?.first == "handoff"
            }
        )
        XCTAssertTrue(
            briefGuidance.contains {
                ($0["purpose"] as? String) == "verify the new handoff"
                    && ($0["argv"] as? [String]) == ["handoff", "list", file.path]
            }
        )

        let contextWithoutJSONFlag = runCapturing(["context", file.path, "--max-files", "1"])
        XCTAssertEqual(contextWithoutJSONFlag.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(contextWithoutJSONFlag.output)["command"] as? String, "context")

        let truncatedContext = runCapturing([
            "context", file.path, "--max-files", "1", "--max-source-bytes", "8",
        ])
        XCTAssertEqual(truncatedContext.exit, CLIExit.success.rawValue)
        let truncatedResult = try XCTUnwrap(
            try jsonObject(truncatedContext.output)["result"] as? [String: Any]
        )
        let truncatedFiles = try XCTUnwrap(truncatedResult["files"] as? [[String: Any]])
        XCTAssertEqual(truncatedFiles.first?["sourcePreviewTruncated"] as? Bool, true)
        XCTAssertFalse(
            (truncatedFiles.first?["sourcePreview"] as? String)?.contains("margin:comments") == true
        )
        let truncatedGuidance = try XCTUnwrap(
            truncatedResult["workflowGuidance"] as? [[String: Any]]
        )
        XCTAssertEqual(truncatedGuidance.first?["command"] as? String, "read")
        XCTAssertEqual(truncatedGuidance.first?["arguments"] as? [String], [file.path, "--json"])
        XCTAssertEqual(truncatedGuidance.first?["executable"] as? Bool, true)
        XCTAssertEqual(
            truncatedGuidance.first?["argv"] as? [String],
            ["read", file.path, "--json"]
        )
        XCTAssertNil(truncatedGuidance.first?["argvTemplate"])

        let directoryContext = runCapturing(["context", directory.path, "--max-files", "1"])
        XCTAssertEqual(directoryContext.exit, CLIExit.success.rawValue)
        let directoryContextResult = try XCTUnwrap(
            try jsonObject(directoryContext.output)["result"] as? [String: Any]
        )
        XCTAssertEqual(directoryContextResult["invocationTarget"] as? String, directory.path)
        XCTAssertEqual(directoryContextResult["directFileTarget"] as? String, file.path)
        XCTAssertTrue(
            (directoryContextResult["pathSemantics"] as? String)?
                .contains("not valid for file-only comment commands") == true
        )
        let directoryGuidance = try XCTUnwrap(
            directoryContextResult["workflowGuidance"] as? [[String: Any]]
        )
        XCTAssertEqual(
            directoryGuidance.first?["arguments"] as? [String],
            [
                file.path, "urn:uuid:\(typedID)", "-m", "TEXT", "--id", "UUID",
                "--if-revision", "1",
            ]
        )
        let directoryHandoff = try XCTUnwrap(
            directoryGuidance.first { ($0["purpose"] as? String) == "start a durable handoff" }
        )
        XCTAssertEqual(
            directoryHandoff["argvTemplate"] as? [String],
            [
                "handoff", "add", directory.path, "--path", "review.md", "-m", "TEXT",
                "--next-actor", "ACTOR_ID", "--contribution-id", "UUID", "--request-id", "UUID",
            ]
        )
        let directoryHandoffVerification = try XCTUnwrap(
            directoryGuidance.first { ($0["purpose"] as? String) == "verify the new handoff" }
        )
        XCTAssertEqual(
            directoryHandoffVerification["argv"] as? [String],
            ["handoff", "list", directory.path, "--path", "review.md"]
        )

        XCTAssertEqual(
            CollaborationCLI.pathRelativeToCurrentDirectoryIfPossible(
                "/workspace/notes/review.md",
                currentDirectoryPath: "/workspace"
            ),
            "notes/review.md"
        )
        XCTAssertEqual(
            CollaborationCLI.pathRelativeToCurrentDirectoryIfPossible(
                "/outside/review.md",
                currentDirectoryPath: "/workspace"
            ),
            "/outside/review.md"
        )

        let reviewWithoutJSONFlag = runCapturing(["review", file.path])
        XCTAssertEqual(reviewWithoutJSONFlag.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(reviewWithoutJSONFlag.output)["command"] as? String, "review")

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
        let inboxItems = try XCTUnwrap(inboxResult["items"] as? [[String: Any]])
        XCTAssertEqual(inboxItems.count, 1)
        XCTAssertEqual(inboxItems.first?["path"] as? String, "review.md")
        XCTAssertEqual(inboxItems.first?["actionPath"] as? String, file.path)
        XCTAssertEqual(inboxItems.first?["annotationRevision"] as? Int, 1)
        let inboxGuidance = try XCTUnwrap(
            inboxResult["workflowGuidance"] as? [[String: Any]]
        )
        XCTAssertEqual(inboxGuidance.count, 3)
        XCTAssertEqual(
            inboxGuidance[1]["argvTemplate"] as? [String],
            [
                "comments", "reply", file.path, "urn:uuid:\(typedID)", "-m", "TEXT",
                "--resolve", "--id", "UUID", "--if-revision", "1",
            ]
        )
        XCTAssertEqual(
            inboxGuidance[2]["argv"] as? [String],
            [
                "comments", "list", file.path, "--thread", "urn:uuid:\(typedID)",
                "--status", "all",
            ]
        )

        XCTAssertEqual(
            runSilently(["comments", "resolve", file.path, typedID]),
            CLIExit.success.rawValue
        )
        let resolvedInbox = runCapturing([
            "inbox", file.path, "--kind", "task", "--status", "resolved",
        ])
        XCTAssertEqual(resolvedInbox.exit, CLIExit.success.rawValue)
        let resolvedResult = try XCTUnwrap(
            try jsonObject(resolvedInbox.output)["result"] as? [String: Any]
        )
        let resolvedGuidance = try XCTUnwrap(
            resolvedResult["workflowGuidance"] as? [[String: Any]]
        )
        XCTAssertEqual(resolvedGuidance.count, 2)
        XCTAssertEqual(
            resolvedGuidance[0]["argv"] as? [String],
            [
                "comments", "list", file.path, "--thread", "urn:uuid:\(typedID)",
                "--status", "all",
            ]
        )
        XCTAssertEqual(
            resolvedGuidance[1]["argvTemplate"] as? [String],
            [
                "comments", "reply", file.path, "urn:uuid:\(typedID)", "-m", "TEXT",
                "--reopen", "--id", "UUID", "--if-revision", "2",
            ]
        )
    }

    func testConcurrentTypedContributionsConvergeWithoutAgentVisibleRetries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        let source = "# Concurrent review\n\nShared source remains stable.\n"
        try Data(source.utf8).write(to: file)
        let expectedContentSha256 = DocumentRevision(data: Data(source.utf8)).sha256

        let null = try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        let savedStandardOutput = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(savedStandardOutput, 0)
        XCTAssertGreaterThanOrEqual(dup2(null.fileDescriptor, STDOUT_FILENO), 0)
        defer {
            _ = dup2(savedStandardOutput, STDOUT_FILENO)
            close(savedStandardOutput)
            try? null.close()
        }

        let failures = NSLock()
        var capturedErrors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                try CollaborationCLI.addTypedContribution(
                    file: file,
                    fileArgument: file.path,
                    message: "Independent issue \(index)",
                    creator: MarginActor(
                        id: "urn:test:agent:concurrent-\(index)",
                        type: .software,
                        name: "Concurrent Agent \(index)"
                    ),
                    kind: .issue,
                    range: nil,
                    assignee: nil,
                    priority: .normal,
                    audience: [],
                    annotationID: String(
                        format: "00000000-0000-4000-8000-%012d",
                        80_000 + index
                    ),
                    requestID: nil,
                    stageID: nil,
                    expectedBaseContentSha256: expectedContentSha256,
                    preconditions: CommentMutationPreconditions(),
                    pretty: false
                )
            } catch {
                failures.lock()
                capturedErrors.append(error.localizedDescription)
                failures.unlock()
            }
        }

        XCTAssertTrue(capturedErrors.isEmpty, capturedErrors.joined(separator: "\n"))
        let snapshot = try CommentService().list(at: file)
        XCTAssertEqual(snapshot.comments.count, 8)
        XCTAssertEqual(Set(snapshot.comments.map(\.annotation.creator.id)).count, 8)
        XCTAssertTrue(snapshot.comments.allSatisfy {
            string(in: $0.annotation.extensions, key: "margin:kind") == "issue"
        })
        XCTAssertThrowsError(
            try CollaborationCLI.addTypedContribution(
                file: file,
                fileArgument: file.path,
                message: "Must not bypass an explicit stale revision",
                creator: MarginActor(
                    id: "urn:test:agent:guarded",
                    type: .software,
                    name: "Guarded Agent"
                ),
                kind: .issue,
                range: nil,
                assignee: nil,
                priority: .normal,
                audience: [],
                annotationID: "00000000-0000-4000-8000-000000089999",
                requestID: nil,
                stageID: nil,
                expectedBaseContentSha256: expectedContentSha256,
                preconditions: CommentMutationPreconditions(revision: 0),
                pretty: false
            )
        ) { error in
            XCTAssertEqual((error as? CollaborationError)?.code, "COLLABORATION_PRECONDITION_FAILED")
        }
        XCTAssertEqual(try CommentService().list(at: file).comments.count, 8)
        let decoded = try EmbeddedCommentCodec().decode(Data(contentsOf: file))
        XCTAssertEqual(String(data: decoded.bodyData, encoding: .utf8), source)
    }

    func testConcurrentSuggestionAddsAndIndependentRejectionsConvergeInternally() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("suggestions.md")
        let source = (0..<16).map {
            "Anchor \(String(format: "%02d", $0)) retains original value \(String(format: "%02d", $0))."
        }.joined(separator: "\n\n") + "\n"
        try Data(source.utf8).write(to: file)

        let null = try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        let savedStandardOutput = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(savedStandardOutput, 0)
        XCTAssertGreaterThanOrEqual(dup2(null.fileDescriptor, STDOUT_FILENO), 0)
        defer {
            _ = dup2(savedStandardOutput, STDOUT_FILENO)
            close(savedStandardOutput)
            try? null.close()
        }

        let failures = NSLock()
        var capturedErrors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                let identifier = String(
                    format: "00000000-0000-4000-8000-%012d",
                    90_000 + index
                )
                let anchor = "Anchor \(String(format: "%02d", index)) retains original value \(String(format: "%02d", index))."
                var cursor = ArgumentCursor([
                    "add", file.path, "--quote", anchor, "--expect", anchor,
                    "--replacement", "Accepted value \(index)",
                    "-m", "Independent suggestion \(index)",
                    "--id", identifier,
                    "--request-id", "urn:test:request:suggestion-add:\(index)",
                    "--actor-id", "urn:test:agent:suggestion:\(index)",
                    "--actor-type", "software",
                ])
                try CollaborationCLI.run(command: "suggest", cursor: &cursor)
            } catch {
                failures.lock()
                capturedErrors.append("add \(index): \(error.localizedDescription)")
                failures.unlock()
            }
        }
        XCTAssertTrue(capturedErrors.isEmpty, capturedErrors.joined(separator: "\n"))
        XCTAssertEqual(try CommentService().list(at: file).comments.count, 16)

        capturedErrors = []
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                let identifier = String(
                    format: "00000000-0000-4000-8000-%012d",
                    90_000 + index
                )
                var cursor = ArgumentCursor([
                    "reject", file.path, identifier,
                    "--request-id", "urn:test:request:suggestion-reject:\(index)",
                    "--actor-id", "urn:test:agent:reviewer:\(index)",
                    "--actor-type", "software",
                ])
                try CollaborationCLI.run(command: "suggest", cursor: &cursor)
            } catch {
                failures.lock()
                capturedErrors.append("reject \(index): \(error.localizedDescription)")
                failures.unlock()
            }
        }

        XCTAssertTrue(capturedErrors.isEmpty, capturedErrors.joined(separator: "\n"))
        let snapshot = try CommentService().list(at: file)
        XCTAssertEqual(snapshot.comments.count, 16)
        XCTAssertTrue(snapshot.comments.allSatisfy { listed in
            guard case .object(let details)? =
                    listed.annotation.extensions["margin:suggestion"],
                  case .string("rejected")? = details["status"] else {
                return false
            }
            return true
        })
        let decoded = try EmbeddedCommentCodec().decode(Data(contentsOf: file))
        XCTAssertEqual(String(data: decoded.bodyData, encoding: .utf8), source)
    }

    func testSuggestionBatchIsAtomicReplaySafeAndSourcePreserving() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingTarget = runCapturing(
            ["suggest", "add"],
            standardInput: Data()
        )
        XCTAssertEqual(missingTarget.exit, CLIExit.usage.rawValue)

        let file = directory.appendingPathComponent("batch.md")
        let source = "Alpha remains.\n\nBeta remains.\n\nGamma remains.\n"
        try Data(source.utf8).write(to: file)

        func writePlan(_ name: String, items: [[String: Any]]) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": "urn:margin:suggestion-batch:v1",
                "version": 1,
                "items": items,
            ], options: [.sortedKeys])
            try data.write(to: url)
            return url
        }

        let invalid = try writePlan("invalid.json", items: [
            [
                "id": "00000000-0000-4000-8000-000000095001",
                "exact": "Alpha remains.",
                "replacement": "Alpha improves.",
                "body": "Valid first item must not leak from a rejected batch.",
            ],
            [
                "id": "00000000-0000-4000-8000-000000095002",
                "exact": "Missing passage.",
                "replacement": "No replacement.",
                "body": "Invalid second item rejects everything.",
            ],
        ])
        let pristine = try Data(contentsOf: file)
        XCTAssertEqual(
            runSilently([
                "suggest", "batch", file.path, "--items-file", invalid.path,
                "--actor-id", "urn:test:agent:batch", "--actor-type", "software",
            ]),
            CLIExit.data.rawValue
        )
        XCTAssertEqual(try Data(contentsOf: file), pristine)

        let standardInputFile = directory.appendingPathComponent("standard-input.md")
        let standardInputSource = "One stays.\n\nTwo stays.\n"
        try Data(standardInputSource.utf8).write(to: standardInputFile)
        let standardInputItems: [[String: Any]] = [
            [
                "id": "00000000-0000-4000-8000-000000095021",
                "exact": "One stays.",
                "replacement": "One improves.",
                "body": "Improve one.",
            ],
            [
                "id": "00000000-0000-4000-8000-000000095022",
                "exact": "Two stays.",
                "replacement": "Two improves.",
                "body": "Improve two.",
            ],
        ]
        let standardInput = try JSONSerialization.data(
            withJSONObject: standardInputItems,
            options: [.sortedKeys]
        )
        let standardInputResult = runCapturing(
            [
                "suggest", "add", standardInputFile.path,
                "--actor-id", "urn:test:agent:standard-input",
                "--actor-type", "software",
            ],
            standardInput: standardInput
        )
        XCTAssertEqual(standardInputResult.exit, CLIExit.success.rawValue)
        let standardInputSnapshot = try CommentService().list(at: standardInputFile)
        XCTAssertEqual(standardInputSnapshot.comments.count, 2)
        let standardInputDecoded = try EmbeddedCommentCodec().decode(
            Data(contentsOf: standardInputFile)
        )
        XCTAssertEqual(
            String(data: standardInputDecoded.bodyData, encoding: .utf8),
            standardInputSource
        )

        let items: [[String: Any]] = [
            [
                "id": "00000000-0000-4000-8000-000000095011",
                "exact": "Alpha remains.",
                "replacement": "Alpha improves.",
                "body": "Improve Alpha.",
            ],
            [
                "id": "00000000-0000-4000-8000-000000095012",
                "exact": "Beta remains.",
                "replacement": "Beta improves.",
                "body": "Improve Beta.",
            ],
            [
                "id": "00000000-0000-4000-8000-000000095013",
                "exact": "Gamma remains.",
                "replacement": "Gamma improves.",
                "body": "Improve Gamma.",
            ],
        ]
        let plan = try writePlan("batch.json", items: items)
        let arguments = [
            "suggest", "add", file.path, "--items-file", plan.path,
            "--batch-id", "00000000-0000-4000-8000-000000095099",
            "--actor-id", "urn:test:agent:batch", "--actor-type", "software",
        ]
        let first = runCapturing(arguments)
        XCTAssertEqual(first.exit, CLIExit.success.rawValue)
        let firstResult = try XCTUnwrap(try jsonObject(first.output)["result"] as? [String: Any])
        XCTAssertEqual(
            firstResult["batchID"] as? String,
            "urn:uuid:00000000-0000-4000-8000-000000095099"
        )
        XCTAssertEqual(firstResult["contributionCount"] as? Int, 3)
        let firstTransaction = try XCTUnwrap(firstResult["transaction"] as? [String: Any])
        XCTAssertEqual(firstTransaction["disposition"] as? String, "applied")

        let stored = try Data(contentsOf: file)
        let decoded = try EmbeddedCommentCodec().decode(stored)
        XCTAssertEqual(String(data: decoded.bodyData, encoding: .utf8), source)
        XCTAssertEqual(decoded.envelope?.revision, 1)
        let snapshot = try CommentService().list(at: file)
        XCTAssertEqual(snapshot.comments.count, 3)
        XCTAssertEqual(
            Set(snapshot.comments.map(\.annotation.id)),
            Set(items.compactMap { $0["id"] as? String }.map(MarginID.annotation))
        )

        var legacyArguments = arguments
        legacyArguments[1] = "batch"
        let replay = runCapturing(legacyArguments)
        XCTAssertEqual(replay.exit, CLIExit.success.rawValue)
        let replayResult = try XCTUnwrap(try jsonObject(replay.output)["result"] as? [String: Any])
        let replayTransaction = try XCTUnwrap(replayResult["transaction"] as? [String: Any])
        XCTAssertEqual(replayTransaction["disposition"] as? String, "already-applied")
        XCTAssertEqual(try Data(contentsOf: file), stored)

        XCTAssertEqual(
            runSilently(arguments + ["--request-id", "urn:test:request:conflict"]),
            CLIExit.usage.rawValue
        )
        XCTAssertEqual(try Data(contentsOf: file), stored)

        var changedItems = items
        changedItems[0]["replacement"] = "Conflicting Alpha."
        let changed = try writePlan("changed.json", items: changedItems)
        var changedArguments = arguments
        changedArguments[changedArguments.firstIndex(of: plan.path)!] = changed.path
        XCTAssertEqual(runSilently(changedArguments), CLIExit.data.rawValue)
        XCTAssertEqual(try Data(contentsOf: file), stored)
    }

    func testConcurrentSuggestionBatchesConvergeAsWholeMetadataTransactions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("concurrent-batches.md")
        let source = (0..<8).map { "Lane \($0) stays literal." }.joined(separator: "\n\n") + "\n"
        try Data(source.utf8).write(to: file)

        var planURLs: [URL] = []
        for batch in 0..<2 {
            let items = (0..<4).map { offset -> [String: Any] in
                let index = batch * 4 + offset
                return [
                    "id": String(format: "00000000-0000-4000-8000-%012d", 96_000 + index),
                    "exact": "Lane \(index) stays literal.",
                    "replacement": "Lane \(index) becomes proposed.",
                    "body": "Concurrent batch suggestion \(index).",
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": "urn:margin:suggestion-batch:v1",
                "version": 1,
                "items": items,
            ], options: [.sortedKeys])
            let plan = directory.appendingPathComponent("batch-\(batch).json")
            try data.write(to: plan)
            planURLs.append(plan)
        }

        let null = try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        let savedStandardOutput = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(savedStandardOutput, 0)
        XCTAssertGreaterThanOrEqual(dup2(null.fileDescriptor, STDOUT_FILENO), 0)
        defer {
            _ = dup2(savedStandardOutput, STDOUT_FILENO)
            close(savedStandardOutput)
            try? null.close()
        }

        let failures = NSLock()
        var capturedErrors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 4) { iteration in
            do {
                let batch = iteration % 2
                var cursor = ArgumentCursor([
                    "batch", file.path, "--items-file", planURLs[batch].path,
                    "--batch-id", "urn:test:suggestion-batch:\(batch)",
                    "--actor-id", "urn:test:agent:batch:\(batch)",
                    "--actor-type", "software",
                ])
                try CollaborationCLI.run(command: "suggest", cursor: &cursor)
            } catch {
                failures.lock()
                capturedErrors.append(error.localizedDescription)
                failures.unlock()
            }
        }

        XCTAssertTrue(capturedErrors.isEmpty, capturedErrors.joined(separator: "\n"))
        let decoded = try EmbeddedCommentCodec().decode(Data(contentsOf: file))
        XCTAssertEqual(String(data: decoded.bodyData, encoding: .utf8), source)
        XCTAssertEqual(decoded.envelope?.revision, 2)
        let snapshot = try CommentService().list(at: file)
        XCTAssertEqual(snapshot.comments.count, 8)
        XCTAssertEqual(Set(snapshot.comments.map(\.annotation.creator.id)).count, 2)
        XCTAssertTrue(snapshot.comments.allSatisfy {
            string(in: $0.annotation.extensions, key: "margin:kind") == "suggestion"
        })
    }

    func testSuggestionAndHandoffHelpExplainContentionSafety() throws {
        let parent = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["suggest"]))
        XCTAssertTrue(parent.contains("Several exact assignments"))
        XCTAssertTrue(parent.contains("margin suggest add FILE"))
        XCTAssertTrue(parent.contains("suggest batch is an exact alias"))
        XCTAssertTrue(parent.contains("standard input"))
        XCTAssertTrue(parent.contains("margin suggest wait FILE ID... --timeout 20"))

        let add = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["suggest", "add"]))
        XCTAssertTrue(add.contains("Metadata races retry internally"))
        XCTAssertTrue(add.contains("source drift fails closed"))
        XCTAssertTrue(add.contains("already-applied receipt is conclusive"))
        XCTAssertTrue(add.contains("--quote \"current text\" --expect \"current text\""))
        XCTAssertTrue(add.contains("EXACT-ASSIGNMENT FAST PATH"))
        let batchUsage = try XCTUnwrap(add.range(of: "margin suggest add FILE [--batch-id ID]"))
        let singleUsage = try XCTUnwrap(add.range(of: "margin suggest add TARGET (--quote"))
        XCTAssertLessThan(batchUsage.lowerBound, singleUsage.lowerBound)
        XCTAssertTrue(add.contains("suggest batch is an exact alias"))
        XCTAssertTrue(add.contains("standard input"))
        XCTAssertTrue(add.contains("\"replacement\":\"new\""))
        XCTAssertTrue(add.contains("add directly"))
        XCTAssertTrue(add.contains("validate the source atomically"))
        XCTAssertTrue(add.contains("suggest wait FILE ID... --timeout 20"))
        XCTAssertTrue(add.contains("suggest list FILE once"))
        XCTAssertTrue(add.contains("Skip preliminary context, inspect, review, list, and read"))
        XCTAssertFalse(add.contains("read FILE --json once and confirm every quoted passage"))

        let batch = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["suggest", "batch"]))
        XCTAssertTrue(batch.contains("margin suggest batch FILE [--batch-id ID]"))
        XCTAssertTrue(batch.contains("omit to read standard input"))
        XCTAssertTrue(batch.contains("Bare array or v1 envelope"))
        XCTAssertTrue(batch.contains("urn:margin:suggestion-batch:v1"))
        XCTAssertTrue(batch.contains("rejects the whole batch"))
        XCTAssertTrue(batch.contains("source drift fails closed"))

        let wait = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["suggest", "wait"]))
        XCTAssertTrue(wait.contains("margin suggest wait FILE ID..."))
        XCTAssertTrue(wait.contains("1 to 256"))
        XCTAssertTrue(wait.contains("Exit 0 is conclusive"))
        XCTAssertTrue(wait.contains("do not list or wait again"))
        XCTAssertTrue(wait.contains("not presence or unrelated completion"))
        XCTAssertTrue(wait.contains("no daemon"))

        let accept = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["suggest", "accept"]))
        XCTAssertTrue(accept.contains("never silently rebased"))

        let reject = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["suggest", "reject"]))
        XCTAssertTrue(reject.contains("metadata races retry internally"))
        XCTAssertTrue(reject.contains("target drift fails closed"))

        let handoff = try XCTUnwrap(CLICommandCatalog.localHelp(path: ["handoff", "add"]))
        XCTAssertTrue(handoff.contains("provenance is never silently rewritten"))
    }

    func testSuccessfulSuggestionWaitReceiptEndsImmediateReverification() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wait-receipt.md")
        try Data("# Review\n\nLiteral source remains.\n".utf8).write(to: file)
        let id = "00000000-0000-4000-8000-000000099001"

        XCTAssertEqual(
            runSilently([
                "suggest", "add", file.path,
                "--quote", "Literal source remains.",
                "--expect", "Literal source remains.",
                "--replacement", "Literal source improves.",
                "-m", "Make the intent exact.",
                "--id", id,
                "--actor-id", "urn:test:agent:wait-receipt",
                "--actor-type", "software",
            ]),
            CLIExit.success.rawValue
        )

        let waited = runCapturing([
            "suggest", "wait", file.path, id, "--timeout", "0",
        ])
        XCTAssertEqual(waited.exit, CLIExit.success.rawValue)
        let envelope = try jsonObject(waited.output)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["complete"] as? Bool, true)
        XCTAssertEqual(result["receiptConclusiveForNamedIDs"] as? Bool, true)
        XCTAssertEqual(result["immediateRecheckRequired"] as? Bool, false)
        let notice = try XCTUnwrap(envelope["notice"] as? String)
        XCTAssertTrue(notice.contains("Conclusive for these ids at the reported revision"))
        XCTAssertTrue(notice.contains("Do not run suggest list or suggest wait again"))
        XCTAssertTrue(notice.contains("not collaborator presence"))
        let nextActions = try XCTUnwrap(envelope["nextActions"] as? [[String: Any]])
        XCTAssertEqual(nextActions.count, 1)
        XCTAssertEqual(nextActions.first?["command"] as? String, "read")
        XCTAssertTrue(
            (nextActions.first?["condition"] as? String)?.contains(
                "does not recheck the named suggestion ids"
            ) == true
        )
    }

    func testSuggestionManualSeparatesExactAssignmentsFromDiscovery() throws {
        let manual = try XCTUnwrap(MarginManual.page(for: "suggestions"))
        let exactPath = try XCTUnwrap(manual.range(of: "EXACT ASSIGNMENTS — SHORTEST SAFE PATH"))
        let discoveryPath = try XCTUnwrap(manual.range(of: "DISCOVER OR DECIDE WORK"))

        XCTAssertLessThan(exactPath.lowerBound, discoveryPath.lowerBound)
        XCTAssertTrue(manual.contains("For one suggestion, add it directly"))
        XCTAssertTrue(manual.contains("submit one atomic batch"))
        XCTAssertTrue(manual.contains("margin suggest batch FILE"))
        XCTAssertTrue(manual.contains("bounded array through standard input"))
        XCTAssertTrue(manual.contains("One bad item rejects"))
        XCTAssertTrue(manual.contains("--expect \"current text\""))
        XCTAssertTrue(manual.contains("validate the source in the same operation"))
        XCTAssertTrue(manual.contains("successful or already-applied matching receipt is conclusive"))
        XCTAssertTrue(manual.contains("wait once for"))
        XCTAssertTrue(manual.contains("margin suggest wait FILE ID... --timeout 20"))
        XCTAssertTrue(manual.contains("Exit 0 is conclusive"))
        XCTAssertTrue(manual.contains("list or wait again"))
        XCTAssertTrue(manual.contains("not confirm collaborator presence"))
        XCTAssertTrue(manual.contains("complete id set, list once"))
        XCTAssertTrue(manual.contains("read once after the"))
        XCTAssertTrue(manual.contains("Skip preliminary context, inspect, review, list, and read calls"))
        XCTAssertTrue(manual.contains("margin context TARGET --json --brief"))
    }

    func testDirectoryContextReturnsReusablePerFilePathsAndNeverInventsRevisionZero() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstDirectory = directory.appendingPathComponent("one", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("note.md")
        let second = secondDirectory.appendingPathComponent("note.md")
        try Data("# One\n".utf8).write(to: first)
        try Data("# Two\n".utf8).write(to: second)

        let context = runCapturing([
            "context", directory.path,
            "--path", "one/note.md", "--path", "two/note.md", "--max-files", "2",
        ])
        XCTAssertEqual(context.exit, CLIExit.success.rawValue)
        let result = try XCTUnwrap(try jsonObject(context.output)["result"] as? [String: Any])
        XCTAssertNil(result["directFileTarget"] as? String)
        let actions = try XCTUnwrap(result["fileActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 2)
        let actionPairs: [(String, [String: Any])] = actions.compactMap { action in
            guard let path = action["path"] as? String else { return nil }
            return (path, action)
        }
        let byPath: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: actionPairs)
        XCTAssertTrue((byPath["one/note.md"]?["actionPath"] as? String)?.hasSuffix("/one/note.md") == true)
        XCTAssertTrue((byPath["two/note.md"]?["actionPath"] as? String)?.hasSuffix("/two/note.md") == true)
        XCTAssertEqual(byPath["one/note.md"]?["annotationRevision"] as? Int, 0)

        let guidance = try XCTUnwrap(result["workflowGuidance"] as? [[String: Any]])
        let add = try XCTUnwrap(guidance.first { ($0["command"] as? String) == "comments add" })
        XCTAssertEqual(
            add["arguments"] as? [String],
            [
                "FILE", "--document", "--kind", "KIND", "-m", "TEXT",
                "--contribution-id", "UUID", "--if-revision", "OBSERVED_ANNOTATION_REVISION",
            ]
        )
        XCTAssertTrue((add["note"] as? String)?.contains("fileActions") == true)
    }

    func testBriefContextKeepsSmallMultiFileWorkBelowTheFourKilobyteAgentBucket() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["architecture.md", "review.md", "handoff.md"].map {
            directory.appendingPathComponent($0)
        }
        let headingCounts = [4, 3, 3]
        for (file, count) in zip(files, headingCounts) {
            let markdown = (1...count).map { "## Section \($0)\n\nConcise evidence \($0)." }
                .joined(separator: "\n\n") + "\n"
            try Data(markdown.utf8).write(to: file)
        }
        for (index, file) in files.enumerated() {
            XCTAssertEqual(
                runSilently([
                    "comments", "add", file.path, "--document", "--kind", "task",
                    "-m", "Review item \(index + 1)",
                    "--id", String(format: "00000000-0000-4000-8000-%012d", 930 + index),
                    "--actor-id", "urn:test:agent:author", "--actor-type", "software",
                ]),
                CLIExit.success.rawValue
            )
        }

        let previousDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(previousDirectory)) }
        let context = runCapturing([
            "context", ".", "--json", "--brief", "--max-files", "3",
        ])
        XCTAssertEqual(context.exit, CLIExit.success.rawValue)
        XCTAssertLessThanOrEqual(context.output.count, 4 * 1_024)
        let result = try XCTUnwrap(try jsonObject(context.output)["result"] as? [String: Any])
        XCTAssertNil(result["outlinePolicy"])
        let contextFiles = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(contextFiles.count, 3)
        XCTAssertTrue(contextFiles.allSatisfy { $0["outline"] == nil })
        let work = try XCTUnwrap(result["work"] as? [[String: Any]])
        XCTAssertEqual(work.count, 3)
        XCTAssertTrue(work.allSatisfy { $0["path"] == nil })
    }

    func testBriefContextKeepsLongSourceAndOpenWorkBelowFourKilobytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("status.md")
        let markdown = "# Status\n\n" + String(repeating: "A precise technical note. ", count: 180)
        try Data(markdown.utf8).write(to: file)
        XCTAssertEqual(
            runSilently([
                "comments", "add", file.path, "--document", "--kind", "task",
                "-m", "Reply, resolve, and hand off the verified result.",
                "--id", "00000000-0000-4000-8000-000000000940",
                "--actor-id", "urn:test:agent:author", "--actor-type", "software",
            ]),
            CLIExit.success.rawValue
        )

        let context = runCapturing([
            "context", directory.path, "--json", "--brief", "--max-files", "1",
        ])
        XCTAssertEqual(context.exit, CLIExit.success.rawValue)
        XCTAssertLessThanOrEqual(context.output.count, 4 * 1_024)
        let result = try XCTUnwrap(try jsonObject(context.output)["result"] as? [String: Any])
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["sourcePreviewTruncated"] as? Bool, true)
        let guidance = try XCTUnwrap(result["workflowGuidance"] as? [[String: Any]])
        XCTAssertEqual(guidance.count, 5)
        XCTAssertEqual(guidance.first?["argv"] as? [String], ["read", file.path, "--json"])
        XCTAssertTrue(guidance.allSatisfy { $0["note"] == nil })
        XCTAssertTrue(
            guidance.contains {
                ($0["purpose"] as? String) == "start a durable handoff"
                    && ($0["argvTemplate"] as? [String])?.first == "handoff"
            }
        )
    }

    func testBriefContextDefaultsKeepWideWorkspaceOrientationBounded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CommentService()
        let actor = MarginActor(
            id: "urn:test:agent:wide-context",
            type: .software,
            name: "Wide Context Agent"
        )
        for fileIndex in 1...8 {
            let file = directory.appendingPathComponent("note-\(fileIndex).md")
            let markdown = "# Note \(fileIndex)\n\n" + String(repeating: "Bounded context. ", count: 50)
            try Data(markdown.utf8).write(to: file)
            for commentIndex in 1...3 {
                _ = try service.add(
                    at: file,
                    message: "Open item \(fileIndex).\(commentIndex)",
                    creator: actor,
                    anchor: .document,
                    annotationID: String(
                        format: "00000000-0000-4000-8000-%012d",
                        10_000 + fileIndex * 10 + commentIndex
                    )
                )
            }
        }
        let questionID = "00000000-0000-4000-8000-000000019999"
        XCTAssertEqual(
            runSilently([
                "comments", "add", directory.appendingPathComponent("note-8.md").path,
                "--document", "--kind", "question",
                "-m", "Which bounded queue should the reviewer use?",
                "--id", questionID,
                "--actor-id", "urn:test:agent:wide-context", "--actor-type", "software",
            ]),
            CLIExit.success.rawValue
        )

        let context = runCapturing(["context", directory.path, "--json", "--brief"])
        XCTAssertEqual(context.exit, CLIExit.success.rawValue)
        XCTAssertLessThanOrEqual(context.output.count, 12 * 1_024)
        let result = try XCTUnwrap(try jsonObject(context.output)["result"] as? [String: Any])
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        let work = try XCTUnwrap(result["work"] as? [[String: Any]])
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(work.count, 4)
        let truncation = try XCTUnwrap(result["truncation"] as? [String: Any])
        XCTAssertEqual(truncation["isTruncated"] as? Bool, true)
        XCTAssertEqual(truncation["hitFileLimit"] as? Bool, true)
        XCTAssertEqual(truncation["omittedFileCountIsLowerBound"] as? Bool, true)
        XCTAssertGreaterThan(truncation["omittedContributionCount"] as? Int ?? 0, 0)
        XCTAssertTrue((try jsonObject(context.output)["notice"] as? String)?.contains(
            "omittedFileCount is a lower bound"
        ) == true)
        XCTAssertEqual((result["workflowGuidance"] as? [[String: Any]])?.count, 5)

        let fullInbox = runCapturing([
            "inbox", directory.path, "--kind", "question", "--status", "open", "--json",
        ])
        XCTAssertEqual(fullInbox.exit, CLIExit.success.rawValue)
        let fullResult = try XCTUnwrap(
            try jsonObject(fullInbox.output)["result"] as? [String: Any]
        )
        XCTAssertNotNil(fullResult["cursor"] as? String)

        let briefInbox = runCapturing([
            "inbox", directory.path, "--kind", "question", "--status", "open", "--json",
            "--brief",
        ])
        XCTAssertEqual(briefInbox.exit, CLIExit.success.rawValue)
        XCTAssertLessThanOrEqual(briefInbox.output.count, 4 * 1_024)
        let briefResult = try XCTUnwrap(
            try jsonObject(briefInbox.output)["result"] as? [String: Any]
        )
        XCTAssertNil(briefResult["cursor"])
        XCTAssertEqual(briefResult["cursorOmitted"] as? Bool, true)
        let items = try XCTUnwrap(briefResult["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["id"] as? String, "urn:uuid:\(questionID)")
        XCTAssertEqual(items.first?["actionPath"] as? String, directory
            .appendingPathComponent("note-8.md").path)
        XCTAssertGreaterThan(items.first?["annotationRevision"] as? Int ?? 0, 0)
        XCTAssertTrue((try jsonObject(briefInbox.output)["notice"] as? String)?.contains(
            "omits the workspace cursor"
        ) == true)
    }

    func testCommentsAddParentIsCanonicalReplyShorthand() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        try Data("# Review\n".utf8).write(to: file)

        let rootID = "00000000-0000-4000-8000-000000000910"
        let replyID = "00000000-0000-4000-8000-000000000911"
        XCTAssertEqual(
            runSilently([
                "comments", "add", file.path, "-m", "Root", "--document", "--id", rootID,
            ]),
            CLIExit.success.rawValue
        )
        let reply = runCapturing([
            "comments", "add", file.path, "--body", "Reply",
            "--parent", rootID, "--contribution-id", replyID,
        ])
        XCTAssertEqual(reply.exit, CLIExit.success.rawValue)
        let envelope = try jsonObject(reply.output)
        XCTAssertEqual(envelope["command"] as? String, "comments.reply")
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["rootID"] as? String, "urn:uuid:\(rootID)")
        XCTAssertEqual(result["revision"] as? Int, 2)
        let nextActions = try XCTUnwrap(envelope["nextActions"] as? [[String: Any]])
        XCTAssertEqual(
            nextActions.first?["arguments"] as? [String],
            [file.path, "urn:uuid:\(rootID)", "--if-revision", "2"]
        )
        XCTAssertEqual(
            nextActions.last?["arguments"] as? [String],
            [file.path, "--thread", "urn:uuid:\(rootID)", "--status", "all"]
        )

        let verifiedOpen = runCapturing([
            "comments", "list", file.path, "--thread", rootID, "--status", "all",
        ])
        XCTAssertEqual(verifiedOpen.exit, CLIExit.success.rawValue)
        let verifiedEnvelope = try jsonObject(verifiedOpen.output)
        XCTAssertTrue((verifiedEnvelope["notice"] as? String)?.contains("still open") == true)
        let verifiedActions = try XCTUnwrap(
            verifiedEnvelope["nextActions"] as? [[String: Any]]
        )
        XCTAssertEqual(
            verifiedActions.first?["arguments"] as? [String],
            [file.path, "urn:uuid:\(rootID)", "--if-revision", "2"]
        )

        XCTAssertEqual(
            runSilently([
                "comments", "add", file.path, "-m", "Invalid", "--parent", rootID,
                "--document", "--id", "00000000-0000-4000-8000-000000000912",
            ]),
            CLIExit.usage.rawValue
        )
        XCTAssertEqual(try CommentService().list(at: file).revision, 2)
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
                "-m", "Prefer gamma", "--contribution-id", rejectedUUID,
                "--actor-id", "urn:test:agent:suggester", "--actor-type", "agent"
        ]
        let rejectedCreate = runCapturing(rejectedAdd)
        XCTAssertEqual(rejectedCreate.exit, CLIExit.success.rawValue)
        let rejectedCreateJSON = try jsonObject(rejectedCreate.output)
        let suggestionActions = try XCTUnwrap(
            rejectedCreateJSON["nextActions"] as? [[String: Any]]
        )
        XCTAssertEqual(
            suggestionActions.compactMap { $0["command"] as? String },
            ["suggest list", "comments get"]
        )
        XCTAssertEqual(
            suggestionActions.first?["arguments"] as? [String],
            [file.path]
        )
        XCTAssertEqual(runSilently(rejectedAdd), CLIExit.success.rawValue)
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).envelope?.revision, 1)
        let suggestionContext = runCapturing(["context", file.path])
        XCTAssertEqual(suggestionContext.exit, CLIExit.success.rawValue)
        let suggestionContextResult = try XCTUnwrap(
            try jsonObject(suggestionContext.output)["result"] as? [String: Any]
        )
        let suggestionGuidance = try XCTUnwrap(
            suggestionContextResult["workflowGuidance"] as? [[String: Any]]
        )
        XCTAssertEqual(
            Array(suggestionGuidance.prefix(3)).compactMap { $0["command"] as? String },
            ["suggest accept", "suggest reject", "suggest list"]
        )
        XCTAssertEqual(suggestionGuidance[0]["executable"] as? Bool, true)
        XCTAssertNotNil(suggestionGuidance[0]["argv"])
        XCTAssertEqual(suggestionGuidance[1]["executable"] as? Bool, true)
        XCTAssertEqual(
            suggestionGuidance[0]["arguments"] as? [String],
            [file.path, "urn:uuid:\(rejectedUUID)"]
        )
        var changedRejectedAdd = rejectedAdd
        let suggestionMessageIndex = try XCTUnwrap(changedRejectedAdd.firstIndex(of: "Prefer gamma"))
        changedRejectedAdd[suggestionMessageIndex] = "Different suggestion payload"
        XCTAssertEqual(runSilently(changedRejectedAdd), CLIExit.data.rawValue)
        let rejectedID = "urn:uuid:\(rejectedUUID)"
        let beforeReject = try EmbeddedCommentCodec().decode(Data(contentsOf: file)).bodyData
        let rejectedDisposition = runCapturing([
                "suggest", "reject", file.path, rejectedID,
                "--request-id", "urn:test:request:reject-decision",
                "--actor-id", "urn:test:agent:reviewer", "--actor-type", "software"
            ])
        XCTAssertEqual(rejectedDisposition.exit, CLIExit.success.rawValue)
        let rejectedDispositionJSON = try jsonObject(rejectedDisposition.output)
        XCTAssertEqual(
            (rejectedDispositionJSON["nextActions"] as? [[String: Any]])?
                .compactMap { $0["command"] as? String },
            ["read", "comments validate"]
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
                "--contribution-id", handoffUUID,
                "--actor-id", "urn:test:agent:current", "--actor-type", "software"
        ]
        let compatibleContributionVocabulary = handoffAdd + [
            "--document", "--kind", "handoff", "--if-revision", "0",
        ]
        let handoffCreate = runCapturing(compatibleContributionVocabulary)
        XCTAssertEqual(handoffCreate.exit, CLIExit.success.rawValue)
        let handoffCreateJSON = try jsonObject(handoffCreate.output)
        let handoffActions = try XCTUnwrap(
            handoffCreateJSON["nextActions"] as? [[String: Any]]
        )
        XCTAssertEqual(
            handoffActions.compactMap { $0["command"] as? String },
            ["handoff list", "comments get"]
        )
        XCTAssertEqual(handoffActions.first?["arguments"] as? [String], [file.path])
        XCTAssertEqual(runSilently(handoffAdd), CLIExit.success.rawValue)
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).envelope?.revision, 1)
        var conciseAlias = handoffAdd
        conciseAlias[try XCTUnwrap(conciseAlias.firstIndex(of: "--next-actor"))] = "--to"
        XCTAssertEqual(runSilently(conciseAlias), CLIExit.success.rawValue)
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).envelope?.revision, 1)
        let staleGuard = runCapturingError([
            "handoff", "add", file.path, "-m", "A distinct stale handoff",
            "--contribution-id", "00000000-0000-4000-8000-000000000904",
            "--if-revision", "0",
        ])
        XCTAssertEqual(staleGuard.exit, CLIExit.temporaryFailure.rawValue)
        let stalePayload = try jsonObject(staleGuard.output)
        let staleError = try XCTUnwrap(stalePayload["error"] as? [String: Any])
        XCTAssertTrue((staleError["message"] as? String)?.contains("Expected annotation revision 0") == true)
        XCTAssertTrue((staleError["message"] as? String)?.contains("Nothing was written") == true)
        let staleDetails = try XCTUnwrap(staleError["details"] as? [String: Any])
        XCTAssertEqual(staleDetails["operation"] as? String, "handoff.add")
        XCTAssertEqual(staleDetails["handoffWritten"] as? String, "false")
        XCTAssertEqual(staleDetails["automaticRetrySafe"] as? String, "false")
        XCTAssertEqual(
            staleDetails["recoveryCommand"] as? String,
            "margin context TARGET --json"
        )
        XCTAssertEqual(
            staleDetails["reviewCommand"] as? String,
            "margin handoff list TARGET"
        )
        XCTAssertEqual(staleDetails["recoveryTarget"] as? String, file.path)
        XCTAssertEqual(staleDetails["provenancePolicy"] as? String, "never-silently-rebase")
        XCTAssertEqual(try EmbeddedCommentCodec().decode(Data(contentsOf: file)).envelope?.revision, 1)
        XCTAssertEqual(
            runSilently(handoffAdd + ["--kind", "comment"]),
            CLIExit.usage.rawValue
        )
        let handoffContract = try XCTUnwrap(
            CLICommandCatalog.commands.first { $0.path == ["handoff", "add"] }
        )
        XCTAssertTrue(handoffContract.options.contains { $0.names == ["--next-actor", "--to"] })
        XCTAssertTrue(handoffContract.options.contains { $0.names == ["--if-revision"] })
        XCTAssertTrue(handoffContract.options.contains { $0.names == ["--document"] })
        XCTAssertTrue(handoffContract.options.contains { $0.names == ["--kind"] })
        XCTAssertEqual(
            runSilently(handoffAdd + ["--id", handoffUUID]),
            CLIExit.usage.rawValue
        )
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
        let created = runCapturing([
            "stage", "create", directory.path, "--operations-file", planFile.path,
            "--request-id", "urn:test:request:stage", "--stage-id", stageID,
            "--actor-id", "urn:test:agent:stage", "--actor-type", "software"
        ])
        XCTAssertEqual(created.exit, CLIExit.success.rawValue)
        let createActions = try XCTUnwrap(
            try jsonObject(created.output)["nextActions"] as? [[String: Any]]
        )
        XCTAssertEqual(
            createActions.compactMap { $0["command"] as? String },
            ["stage show", "stage submit", "stage refresh"]
        )
        XCTAssertEqual(createActions[0]["argv"] as? [String], [
            "stage", "show", directory.path, stageID,
        ])

        let listed = runCapturing(["stage", "list", directory.path])
        XCTAssertEqual(listed.exit, CLIExit.success.rawValue)
        let listActions = try XCTUnwrap(
            try jsonObject(listed.output)["nextActions"] as? [[String: Any]]
        )
        XCTAssertEqual(listActions[1]["argv"] as? [String], [
            "stage", "submit", directory.path, stageID,
        ])

        let shown = runCapturing(["stage", "show", directory.path, stageID])
        XCTAssertEqual(shown.exit, CLIExit.success.rawValue)
        let shownText = try XCTUnwrap(String(data: shown.output, encoding: .utf8))
        XCTAssertFalse(shownText.contains(replacement.base64EncodedString()))
        let shownResult = try XCTUnwrap(try jsonObject(shown.output)["result"] as? [String: Any])
        XCTAssertNotNil(shownResult["operations"])
        let showActions = try XCTUnwrap(
            try jsonObject(shown.output)["nextActions"] as? [[String: Any]]
        )
        XCTAssertEqual(showActions[2]["argv"] as? [String], [
            "stage", "refresh", directory.path, stageID, "--submit",
        ])

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

    func testStageListDefaultsToCurrentWorkspace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(runSilently(["workspace", "init", directory.path]), CLIExit.success.rawValue)

        let previousDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(nested.path))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(previousDirectory)) }

        let listed = runCapturing(["stage", "list"])
        XCTAssertEqual(listed.exit, CLIExit.success.rawValue)
        let envelope = try jsonObject(listed.output)
        XCTAssertEqual(envelope["command"] as? String, "stage.list")
        let root = try XCTUnwrap(envelope["root"] as? [String: Any])
        XCTAssertEqual(root["path"] as? String, directory.path)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual((result["stages"] as? [[String: Any]])?.count, 0)

        let mistakenStageID = runCapturingError([
            "stage", "list", "urn:test:stage:not-a-root"
        ])
        XCTAssertEqual(mistakenStageID.exit, CLIExit.usage.rawValue)
        let error = try XCTUnwrap(
            try jsonObject(mistakenStageID.output)["error"] as? [String: Any]
        )
        XCTAssertEqual(error["code"] as? String, "USAGE")
        XCTAssertTrue(
            (error["message"] as? String)?.contains("not a stage id") == true
        )
        XCTAssertTrue(
            (error["message"] as? String)?.contains("stage show ROOT STAGE_ID") == true
        )

        let missingStage = runCapturingError([
            "stage", "show", directory.path, "urn:test:stage:missing"
        ])
        XCTAssertEqual(missingStage.exit, CLIExit.notFound.rawValue)
        let missingError = try XCTUnwrap(
            try jsonObject(missingStage.output)["error"] as? [String: Any]
        )
        XCTAssertEqual(missingError["code"] as? String, "STAGE_NOT_FOUND")
        XCTAssertTrue(
            (missingError["message"] as? String)?.contains("stage list ROOT") == true
        )
        let missingDetails = try XCTUnwrap(
            missingError["details"] as? [String: Any]
        )
        XCTAssertEqual(missingDetails["requestedStageID"] as? String, "urn:test:stage:missing")
        XCTAssertEqual(missingDetails["recoveryCommand"] as? String, "margin stage list ROOT")
        XCTAssertEqual(missingDetails["recoveryRoot"] as? String, directory.path)
        XCTAssertFalse(
            (missingError["message"] as? String)?.contains("determine the size") == true
        )
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
        let refreshActions = try XCTUnwrap(
            try jsonObject(firstRefresh.output)["nextActions"] as? [[String: Any]]
        )
        XCTAssertEqual(refreshActions[0]["argv"] as? [String], [
            "stage", "show", directory.path, firstRefreshID,
        ])
        XCTAssertEqual(refreshActions[1]["argv"] as? [String], [
            "stage", "submit", directory.path, firstRefreshID,
        ])
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
        let refreshAndSubmitArguments = [
            "stage", "refresh", directory.path, firstRefreshID,
            "--id", finalStageID, "--submit",
        ]
        let finalSubmission = runCapturing(refreshAndSubmitArguments)
        XCTAssertEqual(finalSubmission.exit, CLIExit.success.rawValue)
        let finalEnvelope = try jsonObject(finalSubmission.output)
        XCTAssertEqual(finalEnvelope["command"] as? String, "stage.refresh-submit")
        let finalResult = try XCTUnwrap(finalEnvelope["result"] as? [String: Any])
        let finalRefresh = try XCTUnwrap(finalResult["refresh"] as? [String: Any])
        XCTAssertEqual(finalRefresh["priorStageID"] as? String, firstRefreshID)
        XCTAssertEqual(finalRefresh["refreshedStageID"] as? String, finalStageID)
        let finalSubmit = try XCTUnwrap(finalResult["submission"] as? [String: Any])
        XCTAssertEqual(finalSubmit["stageRemoved"] as? Bool, true)
        XCTAssertEqual(
            (finalSubmit["transaction"] as? [String: Any])?["disposition"] as? String,
            "applied"
        )

        let exactRetry = runCapturing(refreshAndSubmitArguments)
        XCTAssertEqual(exactRetry.exit, CLIExit.success.rawValue)
        let retryResult = try XCTUnwrap(
            try jsonObject(exactRetry.output)["result"] as? [String: Any]
        )
        let retrySubmit = try XCTUnwrap(retryResult["submission"] as? [String: Any])
        XCTAssertEqual(retrySubmit["stageRemoved"] as? Bool, true)
        XCTAssertEqual(
            (retrySubmit["transaction"] as? [String: Any])?["disposition"] as? String,
            "already-applied"
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

#if canImport(Darwin)
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

    func testStaticBriefCapabilityProjectionEncodingPerformance() {
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<100 {
                let projection = CLICommandCatalog.capabilitiesBriefProjection(
                    cliVersion: MarginCommand.version,
                    workflow: .suggestions
                )
                _ = try! JSONEncoder().encode(projection)
            }
        }
    }
#endif

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

    private func runCapturing(
        _ arguments: [String],
        standardInput: Data
    ) -> (exit: Int32, output: Data) {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginCLIInput-\(UUID().uuidString)")
        try! standardInput.write(to: inputURL)
        let handle = FileHandle(forReadingAtPath: inputURL.path)!
        let savedStandardInput = dup(STDIN_FILENO)
        precondition(savedStandardInput >= 0)
        precondition(dup2(handle.fileDescriptor, STDIN_FILENO) >= 0)
        defer {
            _ = dup2(savedStandardInput, STDIN_FILENO)
            close(savedStandardInput)
            try? handle.close()
            try? FileManager.default.removeItem(at: inputURL)
        }
        return runCapturing(arguments)
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
        // The command writes directly to this descriptor. Durability is not
        // part of capture semantics, and fsync can stall for minutes on a
        // Docker Desktop bind-backed /tmp even after the bytes are readable.
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
            "margin stage refresh ROOT STAGE_ID --submit",
            file: file,
            line: line
        )
        XCTAssertEqual(
            details["recoveryStageID"] as? String,
            stageID,
            file: file,
            line: line
        )
    }
}
