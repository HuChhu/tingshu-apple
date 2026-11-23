// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlaybackCore",
    products: [.library(name: "PlaybackCore", targets: ["PlaybackCore"])],
    targets: [
        .target(name: "PlaybackCore", path: "Sources/PlaybackCore"),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"],
                    path: "Tests/PlaybackCoreTests"),
    ]
)
