// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionPrep",
    platforms: [
        .macOS(.v13) // Table view (used in ContentView) requires macOS 13+
    ],
    targets: [
        .executableTarget(
            name: "SessionPrep",
            path: "Sources/SessionPrep"
        )
    ]
)
