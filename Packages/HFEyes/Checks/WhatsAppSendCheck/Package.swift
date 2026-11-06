// swift-tools-version: 6.0
import PackageDescription

// Throwaway check, kept apart from HFEyes so the real package never depends on HFHands.
// Types one harmless word into the TEST contact's WhatsApp chat with the real hands, reads
// the phrase the labels give the Send button that appears, then clears the text. It never
// presses Return and never clicks Send. Run: swift run whatsapp-send-check
let package = Package(
    name: "WhatsAppSendCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../HFCore"),
        .package(path: "../.."),  // HFEyes
        .package(path: "../../../HFHands"),
    ],
    targets: [
        .executableTarget(
            name: "whatsapp-send-check",
            dependencies: [
                .product(name: "HFCore", package: "HFCore"),
                .product(name: "HFEyes", package: "HFEyes"),
                .product(name: "HFHands", package: "HFHands"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
