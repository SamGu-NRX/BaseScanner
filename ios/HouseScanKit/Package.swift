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
        // Schemas/ holds vendored copies of the server's scene and result contracts.
        .testTarget(name: "HouseScanKitTests", dependencies: ["HouseScanKit"], resources: [.copy("Schemas")]),
    ],
    swiftLanguageModes: [.v6]
)
