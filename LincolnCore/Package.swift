// swift-tools-version: 5.9
import PackageDescription

// Platform-independent logic shared by the Lincoln macOS app: the tunnel
// model and JSON store, the read-only ssh_config parser, the ssh command
// builder, the connection state machine, reconnect policy and console
// prompt detection. Must stay free of AppKit/SwiftUI so the test suite runs
// on Linux (see ../Dockerfile).
let package = Package(
    name: "LincolnCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LincolnCore", targets: ["LincolnCore"])
    ],
    targets: [
        .target(
            name: "LincolnCore"
        ),
        .testTarget(
            name: "LincolnCoreTests",
            dependencies: ["LincolnCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
