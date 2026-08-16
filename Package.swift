// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MarginCore", targets: ["MarginCore"]),
        .executable(name: "MarginAppBinary", targets: ["MarginApp"]),
        .executable(name: "margin-cli", targets: ["MarginCLI"])
    ],
    targets: [
        .target(
            name: "MarginCore",
            path: "Sources/MarginCore"
        ),
        .executableTarget(
            name: "MarginApp",
            dependencies: ["MarginCore"],
            path: "Sources/MarginApp"
        ),
        .executableTarget(
            name: "MarginCLI",
            dependencies: ["MarginCore"],
            path: "Sources/MarginCLI"
        ),
        .testTarget(
            name: "MarginCoreTests",
            dependencies: ["MarginCore"],
            path: "Tests/MarginCoreTests"
        ),
        .testTarget(
            name: "MarginAppTests",
            dependencies: ["MarginApp"],
            path: "Tests/MarginAppTests"
        ),
        .testTarget(
            name: "MarginCLITests",
            dependencies: ["MarginCLI"],
            path: "Tests/MarginCLITests"
        )
    ]
)
