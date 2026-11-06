// swift-tools-version: 6.0
import PackageDescription

// HFWake: the wake phrase. While the app is asleep, WakeListener listens on the Mac itself
// (Apple's on-device speech recognition) for "Hey Handsfree"; WakePhraseMatcher decides whether
// a transcript contains the phrase; ListeningCycle owns the rule for when the app is asleep and
// when a conversation is open. `hf-wake` tries all of it from the command line.
let package = Package(
    name: "HFWake",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HFWake", targets: ["HFWake"]),
        .executable(name: "hf-wake", targets: ["hf-wake"]),
    ],
    dependencies: [.package(path: "../HFCore")],
    targets: [
        .target(
            name: "HFWake",
            dependencies: ["HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hf-wake",
            dependencies: ["HFWake", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HFWakeTests",
            dependencies: ["HFWake", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
