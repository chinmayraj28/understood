// swift-tools-version: 6.0
import PackageDescription

// HFAgentCLI: `swift run hf-agent "<goal>"` runs the screen agent on this Mac
// from a terminal, with questions and confirmations asked on standard input.
// For trying the agent without voice. Kept in its own package so HFScreenAgent
// itself depends only on HFCore.
let package = Package(
    name: "HFAgentCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../HFCore"),
        .package(path: "../HFScreenAgent"),
        .package(path: "../HFHands"),
        .package(path: "../HFEyes"),
    ],
    targets: [
        .executableTarget(
            name: "hf-agent",
            dependencies: [
                .product(name: "HFCore", package: "HFCore"),
                .product(name: "HFScreenAgent", package: "HFScreenAgent"),
                .product(name: "HFHands", package: "HFHands"),
                .product(name: "HFEyes", package: "HFEyes"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
