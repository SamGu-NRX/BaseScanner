// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "autodetect-vision",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "rects"),
        .executableTarget(name: "trainod"),
        .executableTarget(name: "coremldet"),
    ]
)
