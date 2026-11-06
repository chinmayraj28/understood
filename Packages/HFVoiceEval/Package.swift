// swift-tools-version: 6.0
import PackageDescription

// HFVoiceEval: measures how the voice agent behaves. It runs labelled conversations, in text
// mode, against a separate evaluation agent on ElevenLabs (never the user's), with the app's real
// tool definitions, the real voice session and the real task runner, and scores what the agent
// did and said. `swift run hf-voice-eval` (see Sources/hf-voice-eval/main.swift).
let package = Package(
    name: "HFVoiceEval",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../HFCore"),
        .package(path: "../HFVoice"),
        .package(path: "../HFTasks"),
        .package(path: "../HFMemory"),
        .package(path: "../HFHands"),
        .package(path: "../HFDecisions"),
    ],
    targets: [
        .executableTarget(
            name: "hf-voice-eval",
            dependencies: [
                .product(name: "HFCore", package: "HFCore"),
                .product(name: "HFVoice", package: "HFVoice"),
                .product(name: "HFTasks", package: "HFTasks"),
                .product(name: "HFMemory", package: "HFMemory"),
                .product(name: "HFHands", package: "HFHands"),
                .product(name: "HFDecisions", package: "HFDecisions"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
