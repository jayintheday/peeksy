// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Peeksy",
    platforms: [.macOS(.v14)],
    targets: [
        // Foundation + Dispatch + os.Logger ONLY. No AppKit, no SwiftUI.
        // Everything testable lives here.
        .target(
            name: "PeeksyCore",
            path: "Sources/PeeksyCore"
        ),
        .executableTarget(
            name: "Peeksy",
            dependencies: ["PeeksyCore"],
            path: "Sources/Peeksy"
        ),
        .testTarget(
            name: "PeeksyCoreTests",
            dependencies: ["PeeksyCore"],
            path: "Tests/PeeksyCoreTests"
        ),
    ]
)
