import ARKit
import MeasureGeometry

// ARKit hands out Float matrices; the geometry package works in Double.

extension SIMD3<Double> {
    init(_ v: SIMD3<Float>) {
        self.init(Double(v.x), Double(v.y), Double(v.z))
    }

    init(_ v: SIMD4<Float>) {
        self.init(Double(v.x), Double(v.y), Double(v.z))
    }
}

extension SIMD3<Float> {
    init(_ v: SIMD3<Double>) {
        self.init(Float(v.x), Float(v.y), Float(v.z))
    }
}

extension CameraPose {
    /// `ARCamera.transform`: camera-to-world, columns are the camera axes and position.
    init(_ m: simd_float4x4) {
        self.init(
            xAxis: SIMD3(m.columns.0),
            yAxis: SIMD3(m.columns.1),
            zAxis: SIMD3(m.columns.2),
            position: SIMD3(m.columns.3)
        )
    }
}

extension CameraIntrinsics {
    /// `ARCamera.intrinsics` is column-major: fx and fy on the diagonal, (cx, cy) in the third column.
    init(_ k: simd_float3x3) {
        self.init(
            fx: Double(k.columns.0.x),
            fy: Double(k.columns.1.y),
            cx: Double(k.columns.2.x),
            cy: Double(k.columns.2.y)
        )
    }
}
