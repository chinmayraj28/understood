// swift-tools-version: 6.0
import PackageDescription

// HFEyes: the agent's eyes and labels.
// - ScreenEyes takes screenshots of the main display for the model (ScreenCaptureKit).
// - AccessibilityLabels names the control under a point or with keyboard focus,
//   read-only, through the macOS accessibility API. Its phrases feed the safety gate.
// `swift run hf-eyes` is a small command-line tool for checking both by hand.
let package = Package(
    name: "HFEyes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HFEyes", targets: ["HFEyes"]),
        .executable(name: "hf-eyes", targets: ["HFEyesTool"]),
    ],
    dependencies: [.package(path: "../HFCore")],
    targets: [
        .target(
            name: "HFEyes",
            dependencies: [.product(name: "HFCore", package: "HFCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HFEyesTool",
            dependencies: ["HFEyes", .product(name: "HFCore", package: "HFCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HFEyesTests",
            dependencies: ["HFEyes", .product(name: "HFCore", package: "HFCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
