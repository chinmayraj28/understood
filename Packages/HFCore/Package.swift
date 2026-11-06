// swift-tools-version: 6.0
import PackageDescription

// HFCore: the shared vocabulary of the app. Types and protocols only, no behaviour
// that touches the network, the screen or the microphone. Every other package
// depends on this one and on nothing else of ours, so they can be built and
// tested on their own.
let package = Package(
    name: "HFCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HFCore", targets: ["HFCore"])],
    targets: [
        .target(name: "HFCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HFCoreTests",
            dependencies: ["HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
