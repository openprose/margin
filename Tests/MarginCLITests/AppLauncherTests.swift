import XCTest
@testable import MarginCLI

final class AppLauncherTests: XCTestCase {
    func testTopLevelEndOfOptionsMakesReservedAndOptionLikeNamesLiteralPaths() {
        XCTAssertEqual(
            MarginCommand.topLevelLiteralOpenPaths(["--", "compare", "--wait"]),
            ["compare", "--wait"]
        )
        XCTAssertEqual(MarginCommand.topLevelLiteralOpenPaths(["--"]), [])
        XCTAssertNil(MarginCommand.topLevelLiteralOpenPaths(["compare", "left", "right"]))

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginMissingParent-\(UUID().uuidString)")
            .appendingPathComponent("compare")
        XCTAssertEqual(
            MarginCommand.run(arguments: ["--", missing.path]),
            CLIExit.notFound.rawValue
        )
        XCTAssertEqual(MarginCommand.run(arguments: ["--"]), CLIExit.usage.rawValue)
    }

    func testLaunchArgumentsPassEveryDocumentInOneOpenEvent() {
        let app = URL(fileURLWithPath: "/Applications/Margin.app")
        let items = [
            URL(fileURLWithPath: "/tmp/brief.md"),
            URL(fileURLWithPath: "/tmp/architecture.md"),
        ]

        XCTAssertEqual(
            AppLauncher.launchArguments(app: app, items: items, wait: false),
            ["-a", app.path, items[0].path, items[1].path]
        )
    }

    func testWaitLaunchKeepsAllTabsInOneFreshApplicationInstance() {
        let app = URL(fileURLWithPath: "/Applications/Margin.app")
        let item = URL(fileURLWithPath: "/tmp/review.md")

        XCTAssertEqual(
            AppLauncher.launchArguments(app: app, items: [item], wait: true),
            ["-W", "-n", "-a", app.path, item.path]
        )
    }

    func testComparisonRequestIsOwnerOnlyAndContainsExactPayload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(#"{"private":"snapshot text","label":"Agent proposal"}"#.utf8)

        let request = try AppLauncher.writePrivateComparisonRequest(payload, in: directory)

        XCTAssertEqual(request.pathExtension, AppLauncher.comparisonRequestExtension)
        XCTAssertEqual(try Data(contentsOf: request), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: request.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    func testComparisonRequestNamesDoNotContainPayloadAndDoNotCollide() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "do-not-put-this-label-in-argv"

        let first = try AppLauncher.writePrivateComparisonRequest(Data(secret.utf8), in: directory)
        let second = try AppLauncher.writePrivateComparisonRequest(Data(secret.utf8), in: directory)

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.lastPathComponent.contains(secret))
        XCTAssertFalse(second.lastPathComponent.contains(secret))
        let arguments = AppLauncher.launchArguments(
            app: URL(fileURLWithPath: "/Applications/Margin.app"),
            items: [first],
            wait: false
        )
        XCTAssertEqual(arguments.last, first.path)
        XCTAssertFalse(arguments.joined(separator: " ").contains(secret))
    }

    func testFailedComparisonLaunchRemovesUnclaimedRequest() throws {
        var capturedURL: URL?
        XCTAssertThrowsError(
            try AppLauncher.openComparisonRequest(Data("private".utf8)) { items, _, _ in
                capturedURL = items.first
                throw CLIError("TEST_LAUNCH_FAILURE", "test", exit: .io)
            }
        )
        let request = try XCTUnwrap(capturedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))
    }

    func testSuccessfulComparisonLaunchLeavesRequestForAppToClaim() throws {
        var capturedURL: URL?
        try AppLauncher.openComparisonRequest(Data("private".utf8)) { items, _, _ in
            capturedURL = items.first
        }
        let request = try XCTUnwrap(capturedURL)
        defer { try? FileManager.default.removeItem(at: request) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.path))
        XCTAssertEqual(try Data(contentsOf: request), Data("private".utf8))
    }

    func testOversizedComparisonRequestIsRejectedBeforeCreatingAFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = Data(
            repeating: 0x61,
            count: AppLauncher.maximumComparisonRequestBytes + 1
        )

        XCTAssertThrowsError(
            try AppLauncher.writePrivateComparisonRequest(oversized, in: directory)
        ) { error in
            XCTAssertEqual((error as? CLIError)?.code, "COMPARISON_REQUEST_TOO_LARGE")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginAppLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
