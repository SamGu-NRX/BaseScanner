@testable import HouseScanKit
import simd
import Testing

/// `MeasuredWallChain.wallFrame` puts the wall on the fitted line, wherever the meter was tapped.
@Suite struct MeasuredWallFrameTests {
    /// The map frame is the world here: a straight measured wall along x at z = 0, facing +z.
    static let frame = MapFrame(poseInWorld: matrix_identity_float4x4, groundY: -1.2)
    static let chain = MeasuredWallChain(
        walls: [MeasuredWall(start: SIMD2(-3, 0), end: SIMD2(3, 0), outward: SIMD2(0, 1), source: .mesh, support: 60, plusMinus: 0.02)],
        meterIndex: 0)

    @Test func aMeterTappedOnABoxProudOfTheWallLeavesTheWallOnItsFittedLine() throws {
        // Tapped on the face of a meter box 0.25 m out from the wall, 0.5 m right of the origin.
        let meter = SIMD3<Float>(0.5, 0, 0.25)
        let wall = try #require(Self.chain.wallFrame(meter: meter, groundY: -1.2, frame: Self.frame))
        // The wall's line is the fit's, z = 0, so the box stands 0.25 m in front of it.
        #expect(abs(wall.meter.z) < 1e-5)
        #expect(abs(wall.wallPoint(meter).out - 0.25) < 1e-5)
        // s = 0 is the meter's foot on the fitted line, at the meter's height.
        #expect(simd_distance(wall.meter, SIMD3(0.5, 0, 0)) < 1e-5)
        #expect(wall.source == .mesh)
    }
}
