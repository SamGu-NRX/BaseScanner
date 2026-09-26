// swift-tools-version: 6.2
// Runs the app's coverage code (HouseScanKit, a plain Swift package) on cameras given as JSON, for
// evals/coverage.py. HouseScanKit is used read-only from a checkout at a pinned commit; its path
// comes from HOUSESCANKIT_DIR, which `make coverage` sets.
import Foundation
import PackageDescription

guard let kit = ProcessInfo.processInfo.environment["HOUSESCANKIT_DIR"] else {
    fatalError("Set HOUSESCANKIT_DIR to ios/HouseScanKit in a checkout of the pinned commit (see evals/coverage.py)")
}

let package = Package(
    name: "CoverageDriver",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: kit)],
    targets: [
        .executableTarget(name: "coverage-driver", dependencies: [.product(name: "HouseScanKit", package: "HouseScanKit")]),
    ],
    swiftLanguageModes: [.v6]
)
