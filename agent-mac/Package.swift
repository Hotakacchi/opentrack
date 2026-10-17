// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenTrack",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "OpenTrack", path: "Sources/OpenTrack")
    ]
)
