// swift-tools-version: 6.0
import PackageDescription

// HFTasks: the Tier 3 task runner (one spoken goal at a time, in the background
// of the conversation) and its four voice tools. Pure logic: no UI, no network,
// no screen. Everything it talks to arrives through HFCore protocols.
let package = Package(
    name: "HFTasks",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HFTasks", targets: ["HFTasks"])],
    dependencies: [.package(path: "../HFCore")],
    targets: [
        .target(
            name: "HFTasks",
            dependencies: [.product(name: "HFCore", package: "HFCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HFTasksTests",
            dependencies: ["HFTasks", .product(name: "HFCore", package: "HFCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
