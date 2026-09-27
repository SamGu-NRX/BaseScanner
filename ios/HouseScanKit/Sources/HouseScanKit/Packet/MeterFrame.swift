import Foundation
import simd

/// The capture packet's frame (packet/README.md on t3/packet, "Units, frames and clocks"): origin
/// at the meter anchor, +y up (ARKit's gravity-aligned world +y), +z the wall's outward normal
/// made horizontal, and +x = y × z along the wall to the right as seen facing it, which is
/// scene.json's +s. Every pose and point in a packet is in this frame, in meters.
public struct MeterFrame: Sendable, Equatable {
    /// Meter frame to world: the manifest's `session.meter_anchor.pose_in_world`.
    public let meterInWorld: simd_float4x4
    /// World to meter frame, the rigid inverse of `meterInWorld`.
    private let worldToMeter: simd_float4x4

    /// Traps unless `meterInWorld` is a rotation plus a translation (to the packet validator's
    /// 1e-3): anything else is a bug in the code that built it.
    public init(meterInWorld: simd_float4x4) {
        precondition(PacketPose.isRigid(meterInWorld), "meterInWorld \(meterInWorld) is not a rotation plus a translation")
        self.meterInWorld = meterInWorld
        let c = meterInWorld.columns
        let rotation = simd_float3x3(SIMD3(c.0.x, c.0.y, c.0.z), SIMD3(c.1.x, c.1.y, c.1.z), SIMD3(c.2.x, c.2.y, c.2.z))
        let inverse = rotation.transpose
        let t = -(inverse * SIMD3(c.3.x, c.3.y, c.3.z))
        worldToMeter = simd_float4x4(
            SIMD4(inverse.columns.0, 0), SIMD4(inverse.columns.1, 0), SIMD4(inverse.columns.2, 0), SIMD4(t, 1))
    }

    /// The frame at `meter` (world meters, the tapped point on the meter) facing `outward`, the
    /// wall's normal toward the homeowner. Only the horizontal part of `outward` counts, so a
    /// slightly tilted wall normal still gives a gravity-aligned frame. Nil when `outward` has no
    /// horizontal part (a floor or ceiling normal).
    public init?(meter: SIMD3<Float>, outward: SIMD3<Float>) {
        let flat = SIMD3<Float>(outward.x, 0, outward.z)
        let length = simd_length(flat)
        guard length.isFinite, length > 1e-6, PacketNumber.isFinite(meter) else { return nil }
        let z = flat / length
        let y = SIMD3<Float>(0, 1, 0)
        let x = simd_cross(y, z)
        self.init(meterInWorld: simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(meter, 1)))
    }

    /// The frame of scene.json's wall: origin at `wall.meter`, +x its `along`, +z its `outward`.
    public init?(wall: SceneWall) {
        self.init(meter: wall.meter, outward: wall.outward)
    }

    /// A world pose (for example `ARFrame.camera.transform`) as a pose in the meter frame. The
    /// last row is set to exactly (0, 0, 0, 1), as the validator requires.
    public func pose(_ worldPose: simd_float4x4) -> simd_float4x4 {
        var m = worldToMeter * worldPose
        m.columns.0.w = 0
        m.columns.1.w = 0
        m.columns.2.w = 0
        m.columns.3.w = 1
        return m
    }

    /// A world point in the meter frame.
    public func point(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let p = worldToMeter * SIMD4(world, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// A meter-frame point in the world, the inverse of `point(_:)`.
    public func worldPoint(_ meter: SIMD3<Float>) -> SIMD3<Float> {
        let p = meterInWorld * SIMD4(meter, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// A world-frame mesh (ARKit's anchors merged, `TriangleMesh`) moved into the meter frame.
    public func mesh(_ world: TriangleMesh) -> TriangleMesh {
        TriangleMesh(vertices: world.vertices.map(point), indices: world.indices)
    }

    /// A point given in `wall`'s coordinates (s along the chain, height above the ground, out from
    /// the wall), in the meter frame. `wall` must be the one this frame was built from; round a
    /// corner the chain's own geometry places the point.
    public func point(on wall: SceneWall, s: Float, height: Float, out: Float) -> SIMD3<Float> {
        point(wall.world(s: s, height: height, out: out))
    }
}

/// Pose conversions the packet fixes: 16 numbers column by column, and the trajectory's unit
/// quaternion.
public enum PacketPose {
    /// The validator's tolerance on RᵀR = I (validate.py ROTATION_TOL).
    static let rotationTolerance: Float = 1e-3

    /// A rotation (orthonormal to 1e-3, determinant positive) plus a translation, last row
    /// (0, 0, 0, 1), all finite.
    public static func isRigid(_ m: simd_float4x4) -> Bool {
        let c = m.columns
        guard [c.0, c.1, c.2, c.3].allSatisfy({ PacketNumber.isFinite(SIMD3($0.x, $0.y, $0.z)) && $0.w.isFinite }) else { return false }
        guard c.0.w == 0, c.1.w == 0, c.2.w == 0, c.3.w == 1 else { return false }
        let r = rotation(m)
        let product = r.transpose * r
        let identity = matrix_identity_float3x3
        for column in 0..<3 {
            let error = simd_abs(product[column] - identity[column])
            if simd_reduce_max(error) > rotationTolerance { return false }
        }
        return simd_determinant(r) > 0
    }

    /// The upper-left 3 × 3.
    public static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        let c = m.columns
        return simd_float3x3(SIMD3(c.0.x, c.0.y, c.0.z), SIMD3(c.1.x, c.1.y, c.1.z), SIMD3(c.2.x, c.2.y, c.2.z))
    }

    public static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// The manifest's 16 numbers, column by column (simd layout). Each is the shortest decimal
    /// that reads back as the same Float, so 0.8660254 is written as that and not as the
    /// Double 0.866025388240814.
    public static func columnMajor(_ m: simd_float4x4) -> [Double] {
        let c = m.columns
        return [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }.map(PacketNumber.double)
    }

    /// Unit quaternion (x, y, z, w) of a rotation, w >= 0: a port of `quaternion_xyzw` in
    /// packet/write.py, the sign convention of the trajectory's qx qy qz qw columns. Computed in
    /// Double from the Float matrix.
    public static func quaternion(_ r: simd_float3x3) -> SIMD4<Double> {
        // m(row, column): simd matrices index columns first.
        func m(_ row: Int, _ column: Int) -> Double { Double(r[column][row]) }
        let trace: Double = m(0, 0) + m(1, 1) + m(2, 2)
        var q: SIMD4<Double>
        if trace > 0 {
            let s: Double = 2 * (trace + 1).squareRoot()
            q = SIMD4((m(2, 1) - m(1, 2)) / s, (m(0, 2) - m(2, 0)) / s, (m(1, 0) - m(0, 1)) / s, s / 4)
        } else if m(0, 0) > m(1, 1), m(0, 0) > m(2, 2) {
            let s: Double = 2 * (1 + m(0, 0) - m(1, 1) - m(2, 2)).squareRoot()
            q = SIMD4(s / 4, (m(0, 1) + m(1, 0)) / s, (m(0, 2) + m(2, 0)) / s, (m(2, 1) - m(1, 2)) / s)
        } else if m(1, 1) > m(2, 2) {
            let s: Double = 2 * (1 + m(1, 1) - m(0, 0) - m(2, 2)).squareRoot()
            q = SIMD4((m(0, 1) + m(1, 0)) / s, s / 4, (m(1, 2) + m(2, 1)) / s, (m(0, 2) - m(2, 0)) / s)
        } else {
            let s: Double = 2 * (1 + m(2, 2) - m(0, 0) - m(1, 1)).squareRoot()
            q = SIMD4((m(0, 2) + m(2, 0)) / s, (m(1, 2) + m(2, 1)) / s, s / 4, (m(1, 0) - m(0, 1)) / s)
        }
        q /= simd_length(q)
        return q.w >= 0 ? q : -q
    }

    /// Horizontal length of a path (meter frame x and z; y is up), summed in Double over the
    /// Float positions exactly as written: `horizontal_distance` in packet/validate.py, which
    /// checks `distance_walked_m` against the trajectory to 1%.
    public static func horizontalDistance(_ positions: [SIMD3<Float>]) -> Double {
        guard positions.count >= 2 else { return 0 }
        var total = 0.0
        for (a, b) in zip(positions, positions.dropFirst()) {
            let dx = Double(b.x) - Double(a.x)
            let dz = Double(b.z) - Double(a.z)
            total += (dx * dx + dz * dz).squareRoot()
        }
        return total
    }
}

/// How the packet writes numbers.
enum PacketNumber {
    /// The shortest decimal that reads back as `value`, as a Double, so JSON shows 0.1 for
    /// Float(0.1) rather than 0.10000000149011612.
    static func double(_ value: Float) -> Double {
        Double(value.description) ?? Double(value)
    }

    /// CSV text: the shortest round-trip decimal, which Python's float() reads back exactly.
    static func csv(_ value: Float) -> String { value.description }
    static func csv(_ value: Double) -> String { value.description }

    static func isFinite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
}
