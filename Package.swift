// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentNotch",
    platforms: [.macOS(.v14)],
    targets: [
        // Foundation + Dispatch + os.Logger ONLY. No AppKit, no SwiftUI.
        // Everything testable lives here.
        .target(
            name: "AgentNotchCore",
            path: "Sources/AgentNotchCore"
        ),
        .executableTarget(
            name: "AgentNotch",
            dependencies: ["AgentNotchCore"],
            path: "Sources/AgentNotch"
        ),
        .testTarget(
            name: "AgentNotchCoreTests",
            dependencies: ["AgentNotchCore"],
            path: "Tests/AgentNotchCoreTests"
        ),
    ]
)
