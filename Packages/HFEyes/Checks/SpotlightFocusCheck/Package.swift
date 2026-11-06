// swift-tools-version: 6.0
import PackageDescription

// Throwaway check for the safety gate: what do the labels report as focused while Spotlight is
// open? Opens Spotlight, types "Notes", reads, presses Escape. Never presses Return.
// Posts its few key events with Quartz directly, so it does not depend on HFHands.
let package = Package(
    name: "SpotlightFocusCheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../HFCore"), .package(path: "../..")],
    targets: [
        .executableTarget(
            name: "spotlight-focus-check",
            dependencies: [.product(name: "HFCore", package: "HFCore"), .product(name: "HFEyes", package: "HFEyes")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
