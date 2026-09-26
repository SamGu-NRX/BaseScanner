// swift-tools-version: 6.2
// HouseScanKit: the capture logic of House Scan, free of ARKit and UIKit so it builds and tests on
// macOS and could ship as an SDK. The app adapts ARKit frames into these types.
import PackageDescription

let package = Package(
    name: "HouseScanKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HouseScanKit", targets: ["HouseScanKit"]),
    ],
    targets: [
        .target(name: "HouseScanKit"),
        .testTarget(name: "HouseScanKitTests", dependencies: ["HouseScanKit"]),
    ],
    swiftLanguageModes: [.v6]
)
