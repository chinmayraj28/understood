// swift-tools-version: 6.0
import PackageDescription

// HFVoice: the live ElevenLabs conversation. It registers every ToolSpec with the
// agent, hands each user sentence to listeners (the stop watcher is one), speaks
// task events, and defines the agent itself from code (AgentConfiguration).
// The only third-party dependency in the app is the ElevenLabs Swift SDK, here.
let package = Package(
    name: "HFVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HFVoice", targets: ["HFVoice"]),
        .executable(name: "hf-voice", targets: ["hf-voice"]),
    ],
    dependencies: [
        .package(path: "../HFCore"),
        .package(url: "https://github.com/elevenlabs/elevenlabs-swift-sdk.git", exact: "3.4.0"),
        // Already brought in by the ElevenLabs SDK; named here only to read its echo-cancellation state.
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "HFVoice",
            dependencies: [
                "HFCore",
                .product(name: "ElevenLabs", package: "elevenlabs-swift-sdk"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            resources: [.copy("Resources/voice_agent.md")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hf-voice",
            dependencies: ["HFVoice", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HFVoiceTests",
            dependencies: ["HFVoice", "HFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
