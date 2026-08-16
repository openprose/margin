import XCTest
@testable import MarginCLI

final class AppLauncherTests: XCTestCase {
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
}
