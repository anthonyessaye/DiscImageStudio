// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiscImageStudioMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiscImageStudioMac", targets: ["DiscImageStudioMac"]),
    ],
    targets: [
        // UI-free logic (project files, running the CLI) so it can be unit tested.
        .target(
            name: "DiscImageStudioKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DiscImageStudioMac",
            dependencies: ["DiscImageStudioKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DiscImageStudioKitTests",
            dependencies: ["DiscImageStudioKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DiscImageStudioMacTests",
            dependencies: ["DiscImageStudioMac", "DiscImageStudioKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
