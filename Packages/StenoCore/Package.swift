// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StenoCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StenoCore", targets: ["StenoCore"])
    ],
    targets: [
        // Pure logic only: Foundation and nothing else. No AppKit, AVFoundation,
        // CoreAudio, or ScreenCaptureKit — everything here has to be testable
        // without a microphone, a display, or a permission prompt.
        .target(name: "StenoCore"),
        .testTarget(name: "StenoCoreTests", dependencies: ["StenoCore"])
    ]
)
