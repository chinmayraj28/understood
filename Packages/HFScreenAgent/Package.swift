// swift-tools-version: 6.0
import PackageDescription

// HFScreenAgent: the Claude client (Messages API over URLSession) and the screen
// agent, which looks at a screenshot, lets Claude pick the next action, checks
// that action with the safety gate, and acts with the real pointer and keyboard.
// Everything it acts through arrives as an HFCore protocol (Hands, Eyes, Labels).
let package = Package(
    name: "HFScreenAgent",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HFScreenAgent", targets: ["HFScreenAgent"])],
    dependencies: [.package(path: "../HFCore")],
    targets: [
        .target(
            name: "HFScreenAgent",
            dependencies: [.product(name: "HFCore", package: "HFCore")],
            resources: [.copy("Resources/screen_agent.md")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HFScreenAgentTests",
            dependencies: ["HFScreenAgent", .product(name: "HFCore", package: "HFCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
