import Foundation
@testable import MeasureGeometry

/// Default tolerance for hand-computed answers. Expected values are exact or written to at least
/// 12 significant digits, so 1e-9 only absorbs floating-point rounding.
let tolerance = 1e-9

func isClose(_ a: Double, _ b: Double, within limit: Double = tolerance) -> Bool {
    abs(a - b) <= limit
}

func isClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, within limit: Double = tolerance) -> Bool {
    isClose(a.x, b.x, within: limit) && isClose(a.y, b.y, within: limit) && isClose(a.z, b.z, within: limit)
}

/// A camera turned `degrees` about world up (y), standing at `position`. At 0° it looks along −z.
func poseTurned(_ degrees: Double, at position: SIMD3<Double> = .zero) -> CameraPose {
    let r = degrees * .pi / 180
    return CameraPose(
        xAxis: SIMD3(cos(r), 0, -sin(r)),
        yAxis: SIMD3(0, 1, 0),
        zAxis: SIMD3(sin(r), 0, cos(r)),
        position: position
    )
}

let identityPose = poseTurned(0)
