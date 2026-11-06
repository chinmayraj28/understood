// swift-tools-version: 6.0
import PackageDescription

// HFMemory: what the agent remembers about the user and how to use their Mac.
// A SQLite store, the hard rules (no secrets, nothing that skips a confirmation,
// no message wording), background learning through an injected language model,
// built-in recipes for the screen agent, and the memory voice tools.
// Pure logic: no UI, no network of its own, no screen.
//
// The JSON and Markdown under Sources/HFMemory/Resources are copies of the masters
// at the repo root (Fixtures/ and docs/prompts/). Run ./sync-resources.sh after
// editing a master; a test fails if a copy has drifted.
let package = Package(
    name: "HFMemory",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HFMemory", targets: ["HFMemory"])],
    dependencies: [.package(path: "../HFCore")],
    targets: [
        .target(
            name: "HFMemory",
            dependencies: [.product(name: "HFCore", package: "HFCore")],
            resources: [
                .copy("Resources/recipes.json"),
                .copy("Resources/memory_tools.json"),
                .copy("Resources/memory_learning.md"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "HFMemoryTests",
            dependencies: ["HFMemory", .product(name: "HFCore", package: "HFCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
