// swift-tools-version: 6.0
import PackageDescription

// HFHands: the agent's hands. The real pointer and keyboard (SystemHands), the
// quick voice tools built on them (QuickTools), and the permission check the
// first-run flow uses (Permissions). `hf-hands` runs one tool from the
// command line, for trying things on the real Mac without the voice agent.
let package = Package(
    name: "HFHands",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HFHands", targets: ["HFHands"]),
        .executable(name: "hf-hands", targets: ["hf-hands"]),
    ],
    dependencies: [.package(path: "../HFCore")],
    targets: [
        .target(
            name: "HFHands",
            dependencies: ["HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hf-hands",
            dependencies: ["HFHands", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HFHandsTests",
            dependencies: ["HFHands", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
