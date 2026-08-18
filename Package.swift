// swift-tools-version: 5.10

import PackageDescription

var products: [Product] = [
    .library(name: "MarginCore", targets: ["MarginCore"]),
    .executable(name: "margin-cli", targets: ["MarginCLI"])
]

var targets: [Target] = [
    .target(
        name: "MarginCore",
        path: "Sources/MarginCore"
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
        name: "MarginCLITests",
        dependencies: ["MarginCLI"],
        path: "Tests/MarginCLITests"
    )
]

#if os(macOS)
products.append(.executable(name: "MarginAppBinary", targets: ["MarginApp"]))
targets.append(
    .executableTarget(
        name: "MarginApp",
        dependencies: ["MarginCore"],
        path: "Sources/MarginApp"
    )
)
targets.append(
    .testTarget(
        name: "MarginAppTests",
        dependencies: ["MarginApp"],
        path: "Tests/MarginAppTests"
    )
)
#endif

let package = Package(
    name: "Margin",
    platforms: [
        .macOS(.v13)
    ],
    products: products,
    targets: targets
)
