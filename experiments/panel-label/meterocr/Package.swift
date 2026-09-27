// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meterocr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "meterocr")
    ]
)
