// swift-tools-version: 6.0
import PackageDescription

// HFIntegration: tests that prove the packages work together. Real
// implementations wherever they exist, fakes only where they do not yet.
// A test target only; it ships nothing. Live tests run only with HF_LIVE=1.
let package = Package(
    name: "HFIntegration",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../HFCore"),
        .package(path: "../HFTasks"),
        .package(path: "../HFDecisions"),
        .package(path: "../HFMemory"),
        .package(path: "../HFEyes"),
        .package(path: "../HFHands"),
        .package(path: "../HFScreenAgent"),
        .package(path: "../HFVoice"),
    ],
    targets: [
        .testTarget(
            name: "HFIntegrationTests",
            dependencies: [
                .product(name: "HFCore", package: "HFCore"),
                .product(name: "HFTasks", package: "HFTasks"),
                .product(name: "HFDecisions", package: "HFDecisions"),
                .product(name: "HFMemory", package: "HFMemory"),
                .product(name: "HFEyes", package: "HFEyes"),
                .product(name: "HFHands", package: "HFHands"),
                .product(name: "HFScreenAgent", package: "HFScreenAgent"),
                .product(name: "HFVoice", package: "HFVoice"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
