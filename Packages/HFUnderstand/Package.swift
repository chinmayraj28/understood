// swift-tools-version: 6.0
import PackageDescription

// HFUnderstand: understanding impaired speech. One turn of speech is recorded on the Mac, heard
// by three recognisers, repaired with context by Claude, judged in code (act, or ask first), and
// learned from. `hf-understand` runs it on audio files, including the evaluation.
// See docs/SPEECH_PLAN.md.
let package = Package(
    name: "HFUnderstand",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HFUnderstand", targets: ["HFUnderstand"]),
        .executable(name: "hf-understand", targets: ["hf-understand"]),
    ],
    dependencies: [.package(path: "../HFCore")],
    targets: [
        .target(
            name: "HFUnderstand",
            dependencies: ["HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hf-understand",
            dependencies: ["HFUnderstand", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HFUnderstandTests",
            dependencies: ["HFUnderstand", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
