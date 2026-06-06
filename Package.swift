// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dusk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "dusk", targets: ["dusk"])
    ],
    targets: [
        // Core logic library: abstracts away system side effects so unit tests can run without a real second display.
        .target(
            name: "DuskKit",
            path: "Sources/DuskKit"
        ),
        // CLI entry point, kept as thin as possible.
        .executableTarget(
            name: "dusk",
            dependencies: ["DuskKit"],
            path: "Sources/dusk"
        ),
        .testTarget(
            name: "DuskKitTests",
            dependencies: ["DuskKit"],
            path: "Tests/DuskKitTests"
        )
    ]
)
