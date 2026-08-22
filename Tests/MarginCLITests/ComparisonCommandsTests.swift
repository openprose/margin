import Foundation
import MarginCore
import XCTest
@testable import MarginCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ComparisonCommandsTests: XCTestCase {
    func testParserSupportsExactSourcesLabelsBoundsAndAppOptions() throws {
        let parsed = try ComparisonCommands.parse([
            "left.md", "-", "--label-left", "Before", "--label-right", "Agent draft",
            "--save-review", "review.margin-review.json", "--max-blocks", "999",
            "--max-preview-bytes", "99999", "--after-block", "urn:block:one",
            "--json", "--pretty",
        ])

        XCTAssertEqual(parsed.left, "left.md")
        XCTAssertEqual(parsed.right, "-")
        XCTAssertEqual(parsed.labelLeft, "Before")
        XCTAssertEqual(parsed.labelRight, "Agent draft")
        XCTAssertEqual(parsed.saveReview, "review.margin-review.json")
        XCTAssertEqual(parsed.maximumBlocks, ComparisonCommands.maximumBlocks)
        XCTAssertEqual(parsed.maximumPreviewBytes, ComparisonCommands.maximumPreviewBytes)
        XCTAssertEqual(parsed.afterBlock, "urn:block:one")
        XCTAssertTrue(parsed.json)
        XCTAssertTrue(parsed.pretty)

        let app = try ComparisonCommands.parse([
            "left.md", "right.md", "--wait", "--app", "/Applications/Margin.app",
        ])
        XCTAssertTrue(app.wait)
        XCTAssertEqual(app.appOverride, "/Applications/Margin.app")

        let dashPath = try ComparisonCommands.parse([
            "--json", "--", "-left.md", "right.md",
        ])
        XCTAssertEqual(dashPath.left, "-left.md")
        XCTAssertEqual(dashPath.right, "right.md")
    }

    func testParserRejectsAmbiguousOrMalformedGrammar() {
        assertUsage([])
        assertUsage(["only-one.md"])
        assertUsage(["a.md", "b.md", "c.md"])
        assertUsage(["a.md", "b.md", "--unknown"])
        assertUsage(["a.md", "b.md", "--json", "--json"])
        assertUsage(["a.md", "b.md", "--label-left"])
        assertUsage(["a.md", "b.md", "--max-blocks", "0"])
        assertUsage(["a.md", "b.md", "--max-preview-bytes", "-1"])
        assertUsage(["a.md", "b.md", "--after-block", ""])
    }

    func testJSONComparisonEmitsChangedBlocksWithoutFullSnapshots() throws {
        let fixture = try fixture(
            left: "# Architecture\n\nStable context.\n\nOld choice.\n",
            right: "# Architecture\n\nStable context.\n\nNew choice.\n"
        )
        defer { fixture.remove() }

        let output = runCapturing([
            "compare", fixture.left.path, fixture.right.path,
            "--label-left", "Current", "--label-right", "Proposal", "--json",
        ])
        XCTAssertEqual(output.exit, CLIExit.success.rawValue)
        let object = try jsonObject(output.output)
        XCTAssertEqual(object["schema"] as? String, "urn:margin:comparison-result:v1")
        XCTAssertEqual(object["command"] as? String, "compare")
        XCTAssertEqual(object["total"] as? Int, 1)
        XCTAssertEqual(object["included"] as? Int, 1)
        XCTAssertEqual(object["omitted"] as? Int, 0)
        XCTAssertEqual(object["truncated"] as? Bool, false)
        let pair = try XCTUnwrap(object["pair"] as? [String: Any])
        let left = try XCTUnwrap(pair["left"] as? [String: Any])
        let right = try XCTUnwrap(pair["right"] as? [String: Any])
        XCTAssertEqual(left["label"] as? String, "Current")
        XCTAssertEqual(right["label"] as? String, "Proposal")
        XCTAssertEqual(left["pathHint"] as? String, fixture.left.lastPathComponent)
        XCTAssertFalse(output.output.contains(Data(fixture.left.path.utf8)))
        XCTAssertNil(left["content"])
        XCTAssertNil(right["content"])

        let blocks = try XCTUnwrap(object["blocks"] as? [[String: Any]])
        let block = try XCTUnwrap(blocks.first)
        XCTAssertNotNil(block["id"] as? String)
        XCTAssertEqual(block["kind"] as? String, "replacement")
        XCTAssertEqual(block["leftPreview"] as? String, "Old choice.\n")
        XCTAssertEqual(block["rightPreview"] as? String, "New choice.\n")
        XCTAssertNotNil(block["leftRange"] as? [String: Any])
        XCTAssertNotNil(block["rightRange"] as? [String: Any])
    }

    func testIdenticalJSONComparisonHasAnEmptyBoundedPage() throws {
        let fixture = try fixture(left: "Same.\n", right: "Same.\n")
        defer { fixture.remove() }

        let output = runCapturing(["compare", fixture.left.path, fixture.right.path, "--json"])
        let object = try jsonObject(output.output)

        XCTAssertEqual(output.exit, CLIExit.success.rawValue)
        XCTAssertEqual(object["total"] as? Int, 0)
        XCTAssertEqual(object["included"] as? Int, 0)
        XCTAssertEqual((object["blocks"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(object["nextArgv"])
    }

    func testJSONComparisonLineOffsetsAreExplicitlyZeroBased() throws {
        let fixture = try fixture(left: "Old first line.\n", right: "New first line.\n")
        defer { fixture.remove() }

        let output = runCapturing([
            "compare", fixture.left.path, fixture.right.path, "--json",
        ])
        let block = try XCTUnwrap(
            (try jsonObject(output.output)["blocks"] as? [[String: Any]])?.first
        )
        let leftRange = try XCTUnwrap(block["leftRange"] as? [String: Any])
        let rightRange = try XCTUnwrap(block["rightRange"] as? [String: Any])

        XCTAssertEqual(leftRange["lineStart"] as? Int, 0)
        XCTAssertEqual(rightRange["lineStart"] as? Int, 0)
    }

    func testStandardInputIsReadOnceAndMayAppearOnEitherSide() throws {
        let fixture = try fixture(left: "From file.\n", right: "Unused.\n")
        defer { fixture.remove() }

        let output = runCapturing(
            [
                "compare", fixture.left.path, "-", "--label-right", "Piped proposal",
                "--json",
            ],
            standardInput: Data("From pipe.\n".utf8)
        )
        XCTAssertEqual(output.exit, CLIExit.success.rawValue)
        let pair = try XCTUnwrap(try jsonObject(output.output)["pair"] as? [String: Any])
        let right = try XCTUnwrap(pair["right"] as? [String: Any])
        XCTAssertEqual(right["label"] as? String, "Piped proposal")
        XCTAssertNil(right["pathHint"])

        var reads = 0
        var cursor = ArgumentCursor(["-", "-"])
        XCTAssertThrowsError(
            try ComparisonCommands.run(
                &cursor,
                standardInput: {
                    reads += 1
                    return Data("Never read".utf8)
                }
            )
        ) { error in
            XCTAssertEqual((error as? CLIError)?.code, "USAGE")
        }
        XCTAssertEqual(reads, 0)
    }

    func testJSONNeverInvokesEitherApplicationLauncher() throws {
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        var requestLaunches = 0
        var itemLaunches = 0
        var cursor = ArgumentCursor([fixture.left.path, fixture.right.path, "--json"])

        _ = try captureStandardOutput {
            try ComparisonCommands.run(
                &cursor,
                launchRequest: { _, _, _ in requestLaunches += 1 },
                launchItem: { _, _, _ in itemLaunches += 1 }
            )
        }

        XCTAssertEqual(requestLaunches, 0)
        XCTAssertEqual(itemLaunches, 0)
    }

    func testUnsavedHumanComparisonUsesPrivateRequestAndPropagatesAppOptions() throws {
#if os(macOS)
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        var requestData: Data?
        var observedWait = false
        var observedApp: String?
        var itemLaunches = 0
        var cursor = ArgumentCursor([
            fixture.left.path, fixture.right.path,
            "--label-left", "Before", "--label-right", "After",
            "--wait", "--app", "/tmp/Test Margin.app",
        ])

        try ComparisonCommands.run(
            &cursor,
            launchRequest: { data, wait, app in
                requestData = data
                observedWait = wait
                observedApp = app
            },
            launchItem: { _, _, _ in itemLaunches += 1 }
        )

        let request = try ComparisonOpenRequestCodec.decode(try XCTUnwrap(requestData))
        XCTAssertEqual(request.left.content, "Before.\n")
        XCTAssertEqual(request.right.content, "After.\n")
        XCTAssertEqual(request.left.label, "Before")
        XCTAssertEqual(request.right.label, "After")
        XCTAssertTrue(observedWait)
        XCTAssertEqual(observedApp, "/tmp/Test Margin.app")
        XCTAssertEqual(itemLaunches, 0)
        XCTAssertFalse(try XCTUnwrap(requestData).contains(Data(fixture.left.path.utf8)))
#endif
    }

    func testSaveReviewCreatesOwnerOnlyArtifactAndJSONStillDoesNotLaunch() throws {
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        let reviewURL = fixture.directory.appendingPathComponent("saved.margin-review.json")
        var cursor = ArgumentCursor([
            fixture.left.path, fixture.right.path, "--save-review", reviewURL.path, "--json",
        ])
        var launches = 0

        let data = try captureStandardOutput {
            try ComparisonCommands.run(
                &cursor,
                launchRequest: { _, _, _ in launches += 1 },
                launchItem: { _, _, _ in launches += 1 }
            )
        }

        XCTAssertEqual(launches, 0)
        XCTAssertEqual(try jsonObject(data)["savedReview"] as? String, reviewURL.path)
        let review = try ComparisonReviewStore().load(at: reviewURL)
        XCTAssertEqual(review.snapshots.left.content, "Before.\n")
        XCTAssertEqual(review.snapshots.right.content, "After.\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: reviewURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    func testSavedHumanComparisonOpensReviewItselfRatherThanRequest() throws {
#if os(macOS)
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        let reviewURL = fixture.directory.appendingPathComponent("saved.margin-review.json")
        var requestLaunches = 0
        var openedURL: URL?
        var cursor = ArgumentCursor([
            fixture.left.path, fixture.right.path, "--save-review", reviewURL.path,
        ])

        try ComparisonCommands.run(
            &cursor,
            launchRequest: { _, _, _ in requestLaunches += 1 },
            launchItem: { url, _, _ in openedURL = url }
        )

        XCTAssertEqual(requestLaunches, 0)
        XCTAssertEqual(openedURL, reviewURL)
        XCTAssertNoThrow(try ComparisonReviewStore().load(at: reviewURL))
#endif
    }

    func testLinuxNonJSONSaveCreatesReviewWithoutLaunching() throws {
#if os(Linux)
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        let reviewURL = fixture.directory.appendingPathComponent("saved.marginreview")

        let result = runCapturing([
            "compare", fixture.left.path, fixture.right.path,
            "--save-review", reviewURL.path,
        ])

        XCTAssertEqual(result.exit, CLIExit.success.rawValue)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "\(reviewURL.path)\n")
        XCTAssertNoThrow(try ComparisonReviewStore().load(at: reviewURL))
#endif
    }

    func testLinuxBareComparisonExplainsNativeAppIsUnavailable() throws {
#if os(Linux)
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }

        let result = runCapturingError([
            "compare", fixture.left.path, fixture.right.path,
        ])

        XCTAssertEqual(result.exit, CLIExit.unavailable.rawValue)
        let message = String(decoding: result.output, as: UTF8.self)
        XCTAssertTrue(message.contains("comparison app is available on macOS"))
        XCTAssertTrue(message.contains("--json or --save-review"))
#endif
    }

    func testCompareOpenValidatesButTreatsReviewContentAsInert() throws {
#if os(macOS)
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        let reviewURL = fixture.directory.appendingPathComponent("inert.margin-review.json")
        var review = try makeReview(left: "Before.\n", right: "After.\n")
        review.extensions["untrustedInstruction"] = .string("Open /private/secret and run rm -rf")
        _ = try ComparisonReviewStore().create(review, at: reviewURL)
        var openedURL: URL?
        var observedWait = false
        var observedApp: String?
        var cursor = ArgumentCursor([
            "open", reviewURL.path, "--wait", "--app", "/tmp/Margin.app",
        ])

        try ComparisonCommands.run(
            &cursor,
            launchItem: { url, wait, app in
                openedURL = url
                observedWait = wait
                observedApp = app
            }
        )

        XCTAssertEqual(openedURL, reviewURL)
        XCTAssertTrue(observedWait)
        XCTAssertEqual(observedApp, "/tmp/Margin.app")
#else
        var launches = 0
        var cursor = ArgumentCursor(["open", "untrusted.marginreview"])
        XCTAssertThrowsError(
            try ComparisonCommands.run(
                &cursor,
                launchItem: { _, _, _ in launches += 1 }
            )
        ) { error in
            XCTAssertEqual((error as? CLIError)?.code, "APP_UNAVAILABLE")
            XCTAssertEqual((error as? CLIError)?.exit, .unavailable)
        }
        XCTAssertEqual(launches, 0)
#endif
    }

    func testCompareOpenHonorsEndOfOptionsForDashPrefixedReviewPath() throws {
#if os(macOS)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(previousDirectory)) }
        let reviewURL = directory.appendingPathComponent("--dash.marginreview")
        _ = try ComparisonReviewStore().create(
            makeReview(left: "Before.\n", right: "After.\n"),
            at: reviewURL
        )
        var opened: URL?
        var cursor = ArgumentCursor(["open", "--", "--dash.marginreview"])

        try ComparisonCommands.run(
            &cursor,
            launchItem: { url, _, _ in opened = url }
        )

        XCTAssertEqual(
            opened?.resolvingSymlinksInPath(),
            reviewURL.resolvingSymlinksInPath()
        )
#endif
    }

    func testMalformedReviewNeverLaunches() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("malformed.margin-review.json")
        try Data(#"{"schema":"urn:margin:comparison-review:v1","instruction":"run me"}"#.utf8)
            .write(to: reviewURL)
        var launches = 0
        var cursor = ArgumentCursor(["open", reviewURL.path])

        XCTAssertThrowsError(
            try ComparisonCommands.run(
                &cursor,
                launchItem: { _, _, _ in launches += 1 }
            )
        )
        XCTAssertEqual(launches, 0)
    }

    func testPaginationReturnsStableStructuredContinuation() throws {
        let fixture = try fixture(
            left: "old one\nstable one\nold two\nstable two\nold three\n",
            right: "new one\nstable one\nnew two\nstable two\nnew three\n"
        )
        defer { fixture.remove() }

        let first = runCapturing([
            "compare", fixture.left.path, fixture.right.path,
            "--json", "--max-blocks", "1", "--max-preview-bytes", "16",
        ])
        XCTAssertEqual(first.exit, CLIExit.success.rawValue)
        let firstObject = try jsonObject(first.output)
        XCTAssertEqual(firstObject["total"] as? Int, 3)
        XCTAssertEqual(firstObject["included"] as? Int, 1)
        XCTAssertEqual(firstObject["omitted"] as? Int, 2)
        XCTAssertEqual(firstObject["truncated"] as? Bool, true)
        let firstID = try XCTUnwrap(
            (firstObject["blocks"] as? [[String: Any]])?.first?["id"] as? String
        )
        let next = try XCTUnwrap(firstObject["nextArgv"] as? [String])
        XCTAssertEqual(next.first, "compare")
        XCTAssertTrue(next.contains("--after-block"))
        XCTAssertTrue(next.contains(firstID))
        XCTAssertFalse(next.contains("--save-review"))

        let second = runCapturing(next)
        XCTAssertEqual(second.exit, CLIExit.success.rawValue)
        let secondObject = try jsonObject(second.output)
        let secondID = try XCTUnwrap(
            (secondObject["blocks"] as? [[String: Any]])?.first?["id"] as? String
        )
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(secondObject["total"] as? Int, 3)
        XCTAssertEqual(secondObject["included"] as? Int, 1)
    }

    func testPaginationContinuationPinsInputsAndExplainsStdinReplay() throws {
        let fixture = try fixture(
            left: "old one\nstable one\nold two\nstable two\nold three\n",
            right: "new one\nstable one\nnew two\nstable two\nnew three\n"
        )
        defer { fixture.remove() }

        let first = runCapturing([
            "compare", fixture.left.path, fixture.right.path,
            "--json", "--max-blocks", "1",
        ])
        let firstObject = try jsonObject(first.output)
        let next = try XCTUnwrap(firstObject["nextArgv"] as? [String])
        XCTAssertTrue(next.contains("--if-left-sha"))
        XCTAssertTrue(next.contains("--if-right-sha"))
        XCTAssertEqual(firstObject["nextRequiresSameStandardInput"] as? Bool, false)

        try Data("Changed after page one.\n".utf8).write(to: fixture.right)
        let changed = runCapturingError(next)
        XCTAssertEqual(changed.exit, CLIExit.temporaryFailure.rawValue)
        XCTAssertEqual(try errorCode(changed.output), "INPUT_CHANGED")

        let stdinBody = Data(
            "new one\nstable one\nnew two\nstable two\nnew three\n".utf8
        )
        let stdinFirst = runCapturing(
            ["compare", fixture.left.path, "-", "--json", "--max-blocks", "1"],
            standardInput: stdinBody
        )
        let stdinObject = try jsonObject(stdinFirst.output)
        XCTAssertEqual(stdinObject["nextRequiresSameStandardInput"] as? Bool, true)
        let stdinNext = try XCTUnwrap(stdinObject["nextArgv"] as? [String])
        let changedStdin = runCapturingError(
            stdinNext,
            standardInput: Data("Different replay input.\n".utf8)
        )
        XCTAssertEqual(changedStdin.exit, CLIExit.temporaryFailure.rawValue)
        XCTAssertEqual(try errorCode(changedStdin.output), "INPUT_CHANGED")
    }

    func testDashPrefixedSourcesAndTheirContinuationReplayAfterEndOfOptions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(previousDirectory)) }
        try Data("old one\nstable\nold two\n".utf8)
            .write(to: directory.appendingPathComponent("-left.md"))
        try Data("new one\nstable\nnew two\n".utf8)
            .write(to: directory.appendingPathComponent("-right.md"))

        let first = runCapturing([
            "compare", "--json", "--max-blocks", "1", "--",
            "-left.md", "-right.md",
        ])
        XCTAssertEqual(first.exit, CLIExit.success.rawValue)
        let next = try XCTUnwrap(try jsonObject(first.output)["nextArgv"] as? [String])
        let separator = try XCTUnwrap(next.firstIndex(of: "--"))
        XCTAssertEqual(Array(next.suffix(from: separator)), ["--", "-left.md", "-right.md"])
        XCTAssertEqual(runCapturing(next).exit, CLIExit.success.rawValue)
    }

    func testPreviewTruncationPreservesUTF8ScalarBoundaries() throws {
        let fixture = try fixture(left: "éééé\n", right: "üüüü\n")
        defer { fixture.remove() }

        let output = runCapturing([
            "compare", fixture.left.path, fixture.right.path,
            "--json", "--max-preview-bytes", "3",
        ])
        let blocks = try XCTUnwrap(
            try jsonObject(output.output)["blocks"] as? [[String: Any]]
        )
        let block = try XCTUnwrap(blocks.first)

        XCTAssertEqual(block["leftPreview"] as? String, "é")
        XCTAssertEqual(block["rightPreview"] as? String, "ü")
        XCTAssertEqual(block["leftPreviewTruncated"] as? Bool, true)
        XCTAssertEqual(block["rightPreviewTruncated"] as? Bool, true)
        XCTAssertNotNil(String(data: output.output, encoding: .utf8))
    }

    func testInvalidSourcesAndContinuationFailWithStableJSONErrors() throws {
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        let missing = fixture.directory.appendingPathComponent("missing.md")
        let missingResult = runCapturingError([
            "compare", missing.path, fixture.right.path, "--json",
        ])
        XCTAssertEqual(missingResult.exit, CLIExit.notFound.rawValue)
        XCTAssertEqual(try errorCode(missingResult.output), "INPUT_NOT_FOUND")

        let directoryResult = runCapturingError([
            "compare", fixture.directory.path, fixture.right.path, "--json",
        ])
        XCTAssertEqual(directoryResult.exit, CLIExit.data.rawValue)
        XCTAssertEqual(try errorCode(directoryResult.output), "NOT_REGULAR_FILE")

        let symlink = fixture.directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.left)
        let symlinkResult = runCapturingError([
            "compare", symlink.path, fixture.right.path, "--json",
        ])
        XCTAssertEqual(symlinkResult.exit, CLIExit.permission.rawValue)
        XCTAssertEqual(try errorCode(symlinkResult.output), "SYMBOLIC_LINK")

        let invalid = fixture.directory.appendingPathComponent("invalid.md")
        try Data([0xff, 0xfe]).write(to: invalid)
        let invalidResult = runCapturingError([
            "compare", invalid.path, fixture.right.path, "--json",
        ])
        XCTAssertEqual(invalidResult.exit, CLIExit.data.rawValue)
        XCTAssertEqual(try errorCode(invalidResult.output), "INVALID_UTF8")

        let blockResult = runCapturingError([
            "compare", fixture.left.path, fixture.right.path,
            "--json", "--after-block", "urn:missing:block",
        ])
        XCTAssertEqual(blockResult.exit, CLIExit.notFound.rawValue)
        XCTAssertEqual(try errorCode(blockResult.output), "COMPARISON_BLOCK_NOT_FOUND")

        let review = fixture.directory.appendingPathComponent("must-not-exist.marginreview")
        let failedSave = runCapturingError([
            "compare", fixture.left.path, fixture.right.path,
            "--json", "--after-block", "urn:missing:block", "--save-review", review.path,
        ])
        XCTAssertEqual(failedSave.exit, CLIExit.notFound.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: review.path))
    }

    func testJSONAppOptionsAndTwoStdinSidesFailBeforeLaunch() throws {
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }

        let wait = runCapturingError([
            "compare", fixture.left.path, fixture.right.path, "--json", "--wait",
        ])
        XCTAssertEqual(wait.exit, CLIExit.usage.rawValue)
        XCTAssertEqual(try errorCode(wait.output), "USAGE")

        let stdin = runCapturingError(["compare", "-", "-", "--json"], standardInput: Data())
        XCTAssertEqual(stdin.exit, CLIExit.usage.rawValue)
        XCTAssertEqual(try errorCode(stdin.output), "USAGE")
    }

    func testCompareIsReservedAndCatalogedForAgentDiscovery() throws {
        let comparisonPaths = [
            ["compare"],
            ["compare", "open"],
            ["compare", "comments", "list"],
            ["compare", "comments", "add"],
            ["compare", "comments", "reply"],
            ["compare", "comments", "resolve"],
            ["compare", "comments", "reopen"],
        ]
        for path in comparisonPaths {
            XCTAssertNotNil(
                CLICommandCatalog.command(path: path),
                "Missing capability contract for \(path.joined(separator: " "))"
            )
        }
        let helpOutput = runCapturing(["compare", "--help"])
        XCTAssertEqual(helpOutput.exit, CLIExit.success.rawValue)
        let help = try XCTUnwrap(String(data: helpOutput.output, encoding: .utf8))
        XCTAssertTrue(help.contains("margin compare LEFT RIGHT"))
        XCTAssertTrue(help.contains("--after-block ID"))
        let manual = try XCTUnwrap(MarginManual.page(for: "comparison"))
        XCTAssertTrue(manual.contains("MARGIN MANUAL: COMPARISON"))
        XCTAssertTrue(manual.contains("untrusted collaborative data"))
        XCTAssertTrue(manual.contains("owner-only request file"))

        let comparison = CLICommandCatalog.capabilitiesProjection(
            cliVersion: MarginCommand.version,
            workflow: .comparison
        )
        XCTAssertEqual(
            Set(comparison.commands.map { $0.path.joined(separator: " ") }),
            Set(["capabilities"] + comparisonPaths.map { $0.joined(separator: " ") })
        )

        let list = try XCTUnwrap(
            CLICommandCatalog.command(path: ["compare", "comments", "list"])
        )
        let add = try XCTUnwrap(
            CLICommandCatalog.command(path: ["compare", "comments", "add"])
        )
        let reply = try XCTUnwrap(
            CLICommandCatalog.command(path: ["compare", "comments", "reply"])
        )
        let resolve = try XCTUnwrap(
            CLICommandCatalog.command(path: ["compare", "comments", "resolve"])
        )
        let reopen = try XCTUnwrap(
            CLICommandCatalog.command(path: ["compare", "comments", "reopen"])
        )
        let leaves = [list, add, reply, resolve, reopen]
        XCTAssertTrue(leaves.allSatisfy {
            $0.output.encoding == "json" &&
                $0.output.framing == "single-object-lf" &&
                $0.output.schema == "urn:margin:comparison-review-cli:v1"
        })
        XCTAssertEqual(list.arguments.map(\.name), ["REVIEW"])
        XCTAssertEqual(add.arguments.map(\.name), ["REVIEW"])
        XCTAssertEqual(reply.arguments.map(\.name), ["REVIEW", "PARENT"])
        XCTAssertEqual(resolve.arguments.map(\.name), ["REVIEW", "THREAD"])
        XCTAssertEqual(reopen.arguments.map(\.name), ["REVIEW", "THREAD"])
        XCTAssertEqual(list.sideEffects, "reads-comparison-review")
        XCTAssertTrue([add, reply, resolve, reopen].allSatisfy {
            $0.sideEffects == "atomically-mutates-comparison-review"
        })

        func optionNames(_ command: CLICommandContract) -> Set<String> {
            Set(command.options.flatMap(\.names))
        }
        XCTAssertEqual(optionNames(list), Set([
            "--status", "--max-threads", "--max-body-bytes", "--after-thread",
            "--if-revision", "--json", "--pretty",
        ]))
        XCTAssertEqual(optionNames(add), Set([
            "--side", "--block", "--id", "--comment-id", "--request-id",
            "--quote", "--prefix", "--suffix", "--occurrence", "--range",
            "--from", "--to", "--expect", "-m", "--message", "--body",
            "--message-file", "--stdin", "--actor-name", "--actor-id",
            "--actor-type", "--if-revision", "--json", "--pretty",
        ]))
        XCTAssertEqual(optionNames(reply), Set([
            "--id", "--comment-id", "--request-id", "-m", "--message", "--body",
            "--message-file", "--stdin", "--actor-name", "--actor-id",
            "--actor-type", "--if-revision", "--json", "--pretty",
        ]))
        let statusOptions: Set<String> = [
            "--actor-name", "--actor-id", "--actor-type", "--if-revision",
            "--json", "--pretty",
        ]
        XCTAssertEqual(optionNames(resolve), statusOptions)
        XCTAssertEqual(optionNames(reopen), statusOptions)
        let side = try XCTUnwrap(add.options.first { $0.names == ["--side"] })
        XCTAssertTrue(side.required)
        XCTAssertEqual(side.choices, ["left", "right"])
        XCTAssertTrue(leaves.allSatisfy { command in
            command.usage.contains { $0.contains("-- REVIEW") }
        })

        let reserved = runCapturingError(["compare"])
        XCTAssertEqual(reserved.exit, CLIExit.usage.rawValue)
        XCTAssertTrue(String(decoding: reserved.output, as: UTF8.self).contains("requires LEFT and RIGHT"))
    }

    func testComparisonHelpRoutesToExactLocalGrammarInsteadOfTheOverview() throws {
        let direct = runCapturing(["compare", "--help"])
        let global = runCapturing(["help", "compare"])
        XCTAssertEqual(direct.exit, CLIExit.success.rawValue)
        XCTAssertEqual(global.exit, CLIExit.success.rawValue)
        XCTAssertEqual(direct.output, global.output)
        let top = String(decoding: direct.output, as: UTF8.self)
        XCTAssertTrue(top.contains("MARGIN COMPARE\n"))
        XCTAssertTrue(top.contains("margin compare [OPTIONS] -- LEFT RIGHT"))
        XCTAssertTrue(top.contains("--if-left-sha SHA256"))
        XCTAssertFalse(top.contains("MARGIN MANUAL: COMPARISON"))

        let comments = runCapturing(["compare", "comments", "--help"])
        let commentsText = String(decoding: comments.output, as: UTF8.self)
        XCTAssertTrue(commentsText.contains("MARGIN COMPARE COMMENTS\n"))
        XCTAssertTrue(commentsText.contains("comments add REVIEW ANCHOR"))
        XCTAssertFalse(commentsText.contains("MARGIN MANUAL: COMPARISON"))

        let addDirect = runCapturing(["compare", "comments", "add", "--help"])
        let addGlobal = runCapturing(["help", "compare", "comments", "add"])
        XCTAssertEqual(addDirect.output, addGlobal.output)
        let add = String(decoding: addDirect.output, as: UTF8.self)
        XCTAssertTrue(add.contains("MARGIN COMPARE COMMENTS ADD"))
        XCTAssertTrue(add.contains("--message-file PATH"))
        XCTAssertTrue(add.contains("--actor-type person|software|organization"))

        let overview = try XCTUnwrap(MarginManual.page(for: "comparison"))
        XCTAssertTrue(overview.contains("MARGIN MANUAL: COMPARISON"))
        XCTAssertNotEqual(Data(overview.utf8), direct.output)
    }

    func testExistingReviewIsNeverSilentlyOverwritten() throws {
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        let review = fixture.directory.appendingPathComponent("existing.margin-review.json")
        let arguments = [
            "compare", fixture.left.path, fixture.right.path,
            "--save-review", review.path, "--json",
        ]
        XCTAssertEqual(runCapturing(arguments).exit, CLIExit.success.rawValue)

        let repeated = runCapturingError(arguments)
        XCTAssertEqual(repeated.exit, CLIExit.cannotCreate.rawValue)
        XCTAssertEqual(try errorCode(repeated.output), "REVIEW_ALREADY_EXISTS")
        XCTAssertNoThrow(try ComparisonReviewStore().load(at: review))
    }

    func testReviewOutputRequiresAnAppRecognizableExtension() throws {
        let fixture = try fixture(left: "Before.\n", right: "After.\n")
        defer { fixture.remove() }
        let arbitrary = fixture.directory.appendingPathComponent("review.json")

        let output = runCapturingError([
            "compare", fixture.left.path, fixture.right.path,
            "--save-review", arbitrary.path, "--json",
        ])

        XCTAssertEqual(output.exit, CLIExit.usage.rawValue)
        XCTAssertEqual(try errorCode(output.output), "USAGE")
        XCTAssertFalse(FileManager.default.fileExists(atPath: arbitrary.path))
    }

    func testReviewCommentsRoundTripWithIDsActorsRevisionsAndStatus() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("discussion.marginreview")
        _ = try ComparisonReviewStore().create(
            makeReview(left: "Before text.\n", right: "After text.\n"),
            at: reviewURL
        )
        let rootUUID = "00000000-0000-4000-8000-000000000101"
        let replyUUID = "00000000-0000-4000-8000-000000000102"
        let rootID = "urn:uuid:\(rootUUID)"
        let replyID = "urn:uuid:\(replyUUID)"

        let added = runCapturing([
            "compare", "comments", "add", reviewURL.path,
            "--side", "left", "--quote", "Before text.",
            "-m", "Please explain the transition.",
            "--id", rootUUID, "--if-revision", "0",
            "--actor-id", "urn:test:agent:reviewer",
            "--actor-name", "Review agent", "--actor-type", "software",
        ])
        XCTAssertEqual(added.exit, CLIExit.success.rawValue)
        let addedObject = try jsonObject(added.output)
        XCTAssertEqual(addedObject["command"] as? String, "compare.comments.add")
        XCTAssertEqual(addedObject["previousRevision"] as? Int, 0)
        XCTAssertEqual(addedObject["revision"] as? Int, 1)
        XCTAssertEqual(addedObject["changed"] as? Bool, true)
        let mutationNext = try XCTUnwrap(addedObject["nextArgv"] as? [String])
        XCTAssertEqual(Array(mutationNext.suffix(2)), ["--if-revision", "1"])
        XCTAssertEqual(runCapturing(mutationNext).exit, CLIExit.success.rawValue)
        let addedThread = try XCTUnwrap(addedObject["thread"] as? [String: Any])
        XCTAssertEqual(addedThread["id"] as? String, rootID)
        XCTAssertEqual(addedThread["side"] as? String, "left")
        XCTAssertEqual(addedThread["status"] as? String, "open")

        let listed = runCapturing([
            "compare", "comments", "list", reviewURL.path, "--status", "all",
        ])
        XCTAssertEqual(listed.exit, CLIExit.success.rawValue)
        let listedObject = try jsonObject(listed.output)
        XCTAssertEqual(listedObject["schema"] as? String, "urn:margin:comparison-review-cli:v1")
        XCTAssertEqual(listedObject["total"] as? Int, 1)
        let threads = try XCTUnwrap(listedObject["threads"] as? [[String: Any]])
        let comments = try XCTUnwrap(threads.first?["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.first?["bodyPreview"] as? String, "Please explain the transition.")
        XCTAssertEqual(
            (comments.first?["creator"] as? [String: Any])?["id"] as? String,
            "urn:test:agent:reviewer"
        )

        let replied = runCapturing([
            "compare", "comments", "reply", reviewURL.path, rootUUID,
            "--stdin", "--id", replyUUID, "--if-revision", "1",
            "--actor-id", "urn:test:person:architect",
            "--actor-name", "Architect", "--actor-type", "person",
        ], standardInput: Data("The new wording narrows the claim.\n".utf8))
        XCTAssertEqual(replied.exit, CLIExit.success.rawValue)
        let repliedObject = try jsonObject(replied.output)
        XCTAssertEqual(repliedObject["revision"] as? Int, 2)
        let repliedThread = try XCTUnwrap(repliedObject["thread"] as? [String: Any])
        let replies = try XCTUnwrap(repliedThread["comments"] as? [[String: Any]])
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[1]["id"] as? String, replyID)
        XCTAssertEqual(replies[1]["parentID"] as? String, rootID)

        let resolved = runCapturing([
            "compare", "comments", "resolve", reviewURL.path, rootUUID,
            "--if-revision", "2", "--actor-id", "urn:test:person:architect",
            "--actor-name", "Architect",
        ])
        XCTAssertEqual(resolved.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(resolved.output)["revision"] as? Int, 3)
        XCTAssertEqual(
            (try jsonObject(resolved.output)["thread"] as? [String: Any])?["status"] as? String,
            "resolved"
        )

        let openList = runCapturing(["compare", "comments", "list", reviewURL.path])
        XCTAssertEqual(try jsonObject(openList.output)["total"] as? Int, 0)
        let allList = runCapturing([
            "compare", "comments", "list", reviewURL.path, "--status", "all",
        ])
        XCTAssertEqual(try jsonObject(allList.output)["total"] as? Int, 1)

        let reopened = runCapturing([
            "compare", "comments", "reopen", reviewURL.path, rootID,
            "--if-revision", "3", "--actor-id", "urn:test:person:architect",
            "--actor-name", "Architect",
        ])
        XCTAssertEqual(reopened.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(reopened.output)["revision"] as? Int, 4)
        XCTAssertEqual(
            (try jsonObject(reopened.output)["thread"] as? [String: Any])?["status"] as? String,
            "open"
        )

        let persisted = try ComparisonReviewStore().load(at: reviewURL)
        XCTAssertEqual(persisted.revision, 4)
        XCTAssertEqual(persisted.threads.first?.comments.map(\.id), [rootID, replyID])
    }

    func testReviewCommentMutationsRejectStaleRevisionAndUnknownTargets() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("stale.marginreview")
        _ = try ComparisonReviewStore().create(
            makeReview(left: "Before.\n", right: "After.\n"),
            at: reviewURL
        )
        let first = runCapturing([
            "compare", "comments", "add", reviewURL.path,
            "--side", "right", "--quote", "After.", "-m", "First",
            "--id", "00000000-0000-4000-8000-000000000201",
            "--if-revision", "0",
        ])
        XCTAssertEqual(first.exit, CLIExit.success.rawValue)

        let stale = runCapturingError([
            "compare", "comments", "add", reviewURL.path,
            "--side", "right", "--quote", "After.", "-m", "Stale",
            "--id", "00000000-0000-4000-8000-000000000202",
            "--if-revision", "0",
        ])
        XCTAssertEqual(stale.exit, CLIExit.temporaryFailure.rawValue)
        XCTAssertEqual(try errorCode(stale.output), "REVISION_CONFLICT")

        let missing = runCapturingError([
            "compare", "comments", "reply", reviewURL.path, "urn:missing:parent",
            "-m", "No parent", "--id", "00000000-0000-4000-8000-000000000203",
        ])
        XCTAssertEqual(missing.exit, CLIExit.notFound.rawValue)
        XCTAssertEqual(try errorCode(missing.output), "COMPARISON_COMMENT_NOT_FOUND")

        let unknownBlock = runCapturingError([
            "compare", "comments", "add", reviewURL.path,
            "--side", "left", "--quote", "Before.", "-m", "Block",
            "--block", "urn:margin:comparison-block:missing",
        ])
        XCTAssertEqual(unknownBlock.exit, CLIExit.notFound.rawValue)
        XCTAssertEqual(try errorCode(unknownBlock.output), "COMPARISON_BLOCK_NOT_FOUND")
    }

    func testStableCommentIDsRemainIdempotentAfterRepliesAndStatusChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("idempotent.marginreview")
        _ = try ComparisonReviewStore().create(
            makeReview(left: "Before.\n", right: "After.\n"),
            at: reviewURL
        )
        let rootID = "00000000-0000-4000-8000-000000000401"
        let replyID = "00000000-0000-4000-8000-000000000402"
        let addArguments = [
            "compare", "comments", "add", reviewURL.path,
            "--side", "left", "--quote", "Before.", "-m", "Stable request",
            "--id", rootID, "--actor-id", "urn:test:agent:one",
            "--actor-name", "Agent One", "--actor-type", "software",
        ]
        XCTAssertEqual(runCapturing(addArguments).exit, CLIExit.success.rawValue)
        let replyArguments = [
            "compare", "comments", "reply", reviewURL.path, rootID,
            "-m", "Later reply", "--id", replyID,
        ]
        XCTAssertEqual(runCapturing(replyArguments).exit, CLIExit.success.rawValue)
        XCTAssertEqual(runCapturing([
            "compare", "comments", "resolve", reviewURL.path, rootID,
        ]).exit, CLIExit.success.rawValue)

        let statusRetry = runCapturing([
            "compare", "comments", "resolve", reviewURL.path, rootID,
            "--if-revision", "2",
        ])
        XCTAssertEqual(statusRetry.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(statusRetry.output)["changed"] as? Bool, false)
        XCTAssertEqual(try jsonObject(statusRetry.output)["revision"] as? Int, 3)

        let retry = runCapturing(addArguments)
        XCTAssertEqual(retry.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(retry.output)["changed"] as? Bool, false)
        XCTAssertEqual(try jsonObject(retry.output)["revision"] as? Int, 3)
        let persisted = try ComparisonReviewStore().load(at: reviewURL)
        XCTAssertEqual(persisted.threads.first?.status, .resolved)
        XCTAssertEqual(persisted.threads.first?.comments.count, 2)

        var conflictArguments = addArguments
        let messageIndex = try XCTUnwrap(conflictArguments.firstIndex(of: "Stable request"))
        conflictArguments[messageIndex] = "Different content"
        let conflict = runCapturingError(conflictArguments + ["--if-revision", "0"])
        XCTAssertEqual(conflict.exit, CLIExit.data.rawValue)
        XCTAssertEqual(try errorCode(conflict.output), "ID_CONFLICT")

        let staleRetry = runCapturing(addArguments + ["--if-revision", "0"])
        XCTAssertEqual(staleRetry.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(staleRetry.output)["changed"] as? Bool, false)
        XCTAssertEqual(try jsonObject(staleRetry.output)["revision"] as? Int, 3)

        let staleReplyRetry = runCapturing(replyArguments + ["--if-revision", "1"])
        XCTAssertEqual(staleReplyRetry.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(staleReplyRetry.output)["changed"] as? Bool, false)
        XCTAssertEqual(try jsonObject(staleReplyRetry.output)["revision"] as? Int, 3)
    }

    func testMaximumActorNameProducesABoundedDefaultID() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("actor.marginreview")
        _ = try ComparisonReviewStore().create(
            makeReview(left: "Before.\n", right: "After.\n"),
            at: reviewURL
        )
        let maximumName = String(
            repeating: "a",
            count: ComparisonHardLimits.actorNameUTF8Bytes
        )

        let added = runCapturing([
            "compare", "comments", "add", reviewURL.path,
            "--side", "left", "--quote", "Before.", "-m", "Bounded actor",
            "--id", "urn:test:bounded-actor", "--actor-name", maximumName,
        ])
        XCTAssertEqual(added.exit, CLIExit.success.rawValue)
        let thread = try XCTUnwrap(try jsonObject(added.output)["thread"] as? [String: Any])
        let comments = try XCTUnwrap(thread["comments"] as? [[String: Any]])
        let creator = try XCTUnwrap(comments.first?["creator"] as? [String: Any])
        XCTAssertEqual(creator["name"] as? String, maximumName)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(creator["id"] as? String).utf8.count,
            ComparisonHardLimits.identifierUTF8Bytes
        )

        let invalid = runCapturingError([
            "compare", "comments", "reply", reviewURL.path, "urn:test:bounded-actor",
            "-m", "Invalid actor", "--id", "urn:test:invalid-actor",
            "--actor-name", maximumName + "a",
        ])
        XCTAssertEqual(invalid.exit, CLIExit.configuration.rawValue)
        XCTAssertEqual(try errorCode(invalid.output), "INVALID_ACTOR")
        XCTAssertEqual(
            try ComparisonReviewStore().load(at: reviewURL).threads.first?.comments.count,
            1
        )
    }

    func testMessageFilesRejectSymlinksNonRegularInputsAndOversizeBeforeMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("messages.marginreview")
        _ = try ComparisonReviewStore().create(
            makeReview(left: "Anchor.\n", right: "Other.\n"),
            at: reviewURL
        )
        let message = directory.appendingPathComponent("message.txt")
        try Data("A regular message.\n".utf8).write(to: message)
        let common = [
            "compare", "comments", "add", reviewURL.path,
            "--side", "left", "--quote", "Anchor.",
        ]
        XCTAssertEqual(runCapturing(
            common + ["--message-file", message.path, "--id", "urn:test:regular"]
        ).exit, CLIExit.success.rawValue)

        let link = directory.appendingPathComponent("message-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: message)
        let symlink = runCapturingError(
            common + ["--message-file", link.path, "--id", "urn:test:link"]
        )
        XCTAssertEqual(symlink.exit, CLIExit.permission.rawValue)
        XCTAssertEqual(try errorCode(symlink.output), "SYMBOLIC_LINK")

        let nonRegular = runCapturingError(
            common + ["--message-file", directory.path, "--id", "urn:test:directory"]
        )
        XCTAssertEqual(nonRegular.exit, CLIExit.data.rawValue)
        XCTAssertEqual(try errorCode(nonRegular.output), "NOT_REGULAR_FILE")

        let fifo = directory.appendingPathComponent("message.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let fifoResult = runCapturingError(
            common + ["--message-file", fifo.path, "--id", "urn:test:fifo"]
        )
        XCTAssertEqual(fifoResult.exit, CLIExit.data.rawValue)
        XCTAssertEqual(try errorCode(fifoResult.output), "NOT_REGULAR_FILE")

        let oversized = directory.appendingPathComponent("oversized.txt")
        try Data(
            repeating: 0x61,
            count: ComparisonHardLimits.commentBodyUTF8Bytes + 1
        ).write(to: oversized)
        let tooLarge = runCapturingError(
            common + ["--message-file", oversized.path, "--id", "urn:test:oversized"]
        )
        XCTAssertEqual(tooLarge.exit, CLIExit.data.rawValue)
        XCTAssertEqual(try errorCode(tooLarge.output), "INVALID_COMMENT_BODY")
        XCTAssertEqual(try ComparisonReviewStore().load(at: reviewURL).threads.count, 1)
    }

    func testReviewCommandsHonorEndOfOptionsWithoutStealingOptionLikeValues() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(previousDirectory)) }
        let reviewURL = directory.appendingPathComponent("--status")
        _ = try ComparisonReviewStore().create(
            makeReview(left: "Before.\n", right: "After.\n"),
            at: reviewURL
        )

        let listed = runCapturing(["compare", "comments", "list", "--", "--status"])
        XCTAssertEqual(listed.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(listed.output)["total"] as? Int, 0)

        let added = runCapturing([
            "compare", "comments", "add",
            "--side", "left", "--quote", "Before.", "-m", "--",
            "--", "--status",
        ])
        XCTAssertEqual(added.exit, CLIExit.success.rawValue)
        let thread = try XCTUnwrap(try jsonObject(added.output)["thread"] as? [String: Any])
        let threadID = try XCTUnwrap(thread["id"] as? String)
        let comments = try XCTUnwrap(thread["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.first?["bodyPreview"] as? String, "--")

        let replied = runCapturing([
            "compare", "comments", "reply", "-m", "Reply", "--",
            "--status", threadID,
        ])
        XCTAssertEqual(replied.exit, CLIExit.success.rawValue)
        let resolved = runCapturing([
            "compare", "comments", "resolve", "--", "--status", threadID,
        ])
        XCTAssertEqual(resolved.exit, CLIExit.success.rawValue)
        let reopened = runCapturing([
            "compare", "comments", "reopen", "--", "--status", threadID,
        ])
        XCTAssertEqual(reopened.exit, CLIExit.success.rawValue)
    }

    func testReviewThreadListIsPreviewBoundedAndDirectlyPageable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("paged.marginreview")
        _ = try ComparisonReviewStore().create(
            makeReview(left: "Anchor.\n", right: "Other.\n"),
            at: reviewURL
        )
        for index in 0..<3 {
            let result = runCapturing([
                "compare", "comments", "add", reviewURL.path,
                "--side", "left", "--quote", "Anchor.",
                "-m", String(repeating: "é", count: 400) + " \(index)",
                "--id", String(format: "00000000-0000-4000-8000-%012d", 300 + index),
            ])
            XCTAssertEqual(result.exit, CLIExit.success.rawValue, "\(index)")
        }

        let first = runCapturing([
            "compare", "comments", "list", reviewURL.path, "--status", "all",
            "--max-threads", "1", "--max-body-bytes", "3",
        ])
        let firstObject = try jsonObject(first.output)
        XCTAssertEqual(firstObject["total"] as? Int, 3)
        XCTAssertEqual(firstObject["included"] as? Int, 1)
        XCTAssertEqual(firstObject["omitted"] as? Int, 2)
        let thread = try XCTUnwrap((firstObject["threads"] as? [[String: Any]])?.first)
        let comment = try XCTUnwrap((thread["comments"] as? [[String: Any]])?.first)
        XCTAssertEqual(comment["bodyPreview"] as? String, "é")
        XCTAssertEqual(comment["bodyPreviewTruncated"] as? Bool, true)

        let next = try XCTUnwrap(firstObject["nextArgv"] as? [String])
        XCTAssertTrue(next.contains("--if-revision"))
        let second = runCapturing(next)
        XCTAssertEqual(second.exit, CLIExit.success.rawValue)
        XCTAssertEqual(try jsonObject(second.output)["included"] as? Int, 1)

        XCTAssertEqual(runCapturing([
            "compare", "comments", "add", reviewURL.path,
            "--side", "left", "--quote", "Anchor.", "-m", "Concurrent",
            "--id", "00000000-0000-4000-8000-000000000399",
        ]).exit, CLIExit.success.rawValue)
        let stalePage = runCapturingError(next)
        XCTAssertEqual(stalePage.exit, CLIExit.temporaryFailure.rawValue)
        XCTAssertEqual(try errorCode(stalePage.output), "REVISION_CONFLICT")
    }

    private func assertUsage(
        _ arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ComparisonCommands.parse(arguments), file: file, line: line) {
            XCTAssertEqual(($0 as? CLIError)?.code, "USAGE", file: file, line: line)
        }
    }

    private func makeReview(left: String, right: String) throws -> ComparisonReview {
        let pair = try ComparisonSnapshotPair(
            left: ComparisonSnapshot(markdownBody: left, label: "Left"),
            right: ComparisonSnapshot(markdownBody: right, label: "Right")
        )
        return try ComparisonReview(
            id: "urn:uuid:\(UUID().uuidString.lowercased())",
            created: "2026-08-21T12:00:00Z",
            modified: "2026-08-21T12:00:00Z",
            snapshots: pair
        )
    }

    private func fixture(left: String, right: String) throws -> Fixture {
        let directory = try temporaryDirectory()
        let leftURL = directory.appendingPathComponent("left.md")
        let rightURL = directory.appendingPathComponent("right.md")
        try Data(left.utf8).write(to: leftURL)
        try Data(right.utf8).write(to: rightURL)
        return Fixture(directory: directory, left: leftURL, right: rightURL)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginComparisonCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func runCapturing(_ arguments: [String]) -> (exit: Int32, output: Data) {
        runCapturing(arguments, fileDescriptor: STDOUT_FILENO)
    }

    private func runCapturing(
        _ arguments: [String],
        standardInput: Data
    ) -> (exit: Int32, output: Data) {
        withStandardInput(standardInput) { runCapturing(arguments) }
    }

    private func runCapturingError(_ arguments: [String]) -> (exit: Int32, output: Data) {
        runCapturing(arguments, fileDescriptor: STDERR_FILENO)
    }

    private func runCapturingError(
        _ arguments: [String],
        standardInput: Data
    ) -> (exit: Int32, output: Data) {
        withStandardInput(standardInput) { runCapturingError(arguments) }
    }

    private func runCapturing(
        _ arguments: [String],
        fileDescriptor: Int32
    ) -> (exit: Int32, output: Data) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginComparisonCapture-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = FileHandle(forWritingAtPath: outputURL.path)!
        let saved = dup(fileDescriptor)
        precondition(saved >= 0)
        precondition(dup2(handle.fileDescriptor, fileDescriptor) >= 0)
        let exit = MarginCommand.run(arguments: arguments)
        _ = dup2(saved, fileDescriptor)
        close(saved)
        try? handle.close()
        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        try? FileManager.default.removeItem(at: outputURL)
        return (exit, output)
    }

    private func captureStandardOutput(_ operation: () throws -> Void) throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginComparisonDirectCapture-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = FileHandle(forWritingAtPath: outputURL.path)!
        let saved = dup(STDOUT_FILENO)
        precondition(saved >= 0)
        precondition(dup2(handle.fileDescriptor, STDOUT_FILENO) >= 0)
        do {
            try operation()
        } catch {
            _ = dup2(saved, STDOUT_FILENO)
            close(saved)
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        _ = dup2(saved, STDOUT_FILENO)
        close(saved)
        try? handle.close()
        let output = try Data(contentsOf: outputURL)
        try? FileManager.default.removeItem(at: outputURL)
        return output
    }

    private func withStandardInput<T>(_ data: Data, _ operation: () -> T) -> T {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginComparisonInput-\(UUID().uuidString)")
        try! data.write(to: inputURL)
        let handle = FileHandle(forReadingAtPath: inputURL.path)!
        let saved = dup(STDIN_FILENO)
        precondition(saved >= 0)
        precondition(dup2(handle.fileDescriptor, STDIN_FILENO) >= 0)
        defer {
            _ = dup2(saved, STDIN_FILENO)
            close(saved)
            try? handle.close()
            try? FileManager.default.removeItem(at: inputURL)
        }
        return operation()
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func errorCode(_ data: Data) throws -> String {
        let error = try XCTUnwrap(try jsonObject(data)["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? String)
    }
}

private struct Fixture {
    let directory: URL
    let left: URL
    let right: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
