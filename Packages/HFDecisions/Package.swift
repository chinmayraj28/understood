// swift-tools-version: 6.0
import PackageDescription

// HFDecisions: the fast decisions. The Jev client, the three classifiers with
// their keyword fallbacks, the safety gate and the stop watcher. Pure logic:
// no UI, no screen, no microphone. Depends only on HFCore.
let package = Package(
    name: "HFDecisions",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HFDecisions", targets: ["HFDecisions"]),
        // `swift run hf-eval-jev` runs the golden examples against the live API.
        .executable(name: "hf-eval-jev", targets: ["HFEvalJev"]),
    ],
    dependencies: [.package(path: "../HFCore")],
    targets: [
        .target(
            name: "HFDecisions",
            dependencies: ["HFCore"],
            // A copy of Fixtures/jev_golden.jsonl; a test fails if the two drift apart.
            resources: [.copy("Resources/jev_golden.jsonl")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HFEvalJev",
            dependencies: ["HFDecisions", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HFDecisionsTests",
            dependencies: ["HFDecisions", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
