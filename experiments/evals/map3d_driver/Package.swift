// swift-tools-version: 6.2
// Runs the app's 3D map (HouseScanKit's Map3D) on depth frames given as JSON, for
// evals/map3d.py. HouseScanKit is used read-only from a checkout at a pinned commit; its path
// comes from HOUSESCANKIT_DIR, which `make map3d` sets.
import Foundation
import PackageDescription

guard let kit = ProcessInfo.processInfo.environment["HOUSESCANKIT_DIR"] else {
    fatalError("Set HOUSESCANKIT_DIR to ios/HouseScanKit in a checkout of the pinned commit (see evals/coverage.py)")
}

let package = Package(
    name: "Map3DDriver",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: kit)],
    targets: [
        .executableTarget(name: "map3d-driver", dependencies: [.product(name: "HouseScanKit", package: "HouseScanKit")]),
    ],
    swiftLanguageModes: [.v6]
)
