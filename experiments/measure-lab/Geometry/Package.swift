// swift-tools-version: 6.0
// Measurement math for MeasureLab. Vectors are the standard library's SIMD3<Double> (no `simd`
// module, no ARKit), and trigonometry comes from Foundation, so the same code and tests run on
// macOS, iOS and Linux.
import PackageDescription

let package = Package(
    name: "MeasureGeometry",
    products: [
        .library(name: "MeasureGeometry", targets: ["MeasureGeometry"])
    ],
    targets: [
        .target(name: "MeasureGeometry"),
        .testTarget(name: "MeasureGeometryTests", dependencies: ["MeasureGeometry"]),
    ]
)
