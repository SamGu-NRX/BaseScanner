import Foundation
@testable import HouseScanKit
import simd
import Testing

/// A walked step between poses in front of two pieces of a corner is clear only as far out as
/// the step itself stays in front of each piece (Codex finding 4114176102).
@Suite struct CornerWalkedPathTests {
    /// The standard wall turning away from the homeowner at s = 0.3048: past the corner the wall
    /// runs from (0.3048, 0) toward -z, facing +x.
    static let corner: Float = 0.3048

    static func camera(x: Float, z: Float) -> CameraFrame {
        portraitCamera(at: SIMD3(x, 1.4, z), forward: SIMD3(0, -0.3, -1))
    }

    /// A at (0.1048, 0.4) and B at (0.7048, -0.2), 1.8 s and 0.8485 m apart: each is 0.4 m in
    /// front of its own piece, but the step between them passes the corner's x at z = 0.2. The
    /// cell by the corner, [0.1524, 0.3048], reported 0.4 m less the error, 0.259792 m.
    static func record(_ map: inout CoverageMap) {
        map.observe(camera(x: 0.1048, z: 0.4), trackingNormal: true, time: 10)
        map.observe(camera(x: 0.7048, z: -0.2), trackingNormal: true, time: 11.8)
    }

    /// The step is 0.2 m in front of the meter's piece where it leaves that piece's stretch, and
    /// 0.2 m in front of the next piece where it enters its stretch.
    static let actualClear: Float = 0.2

    @Test func theCounterexampleWithTheCornerAlreadyMarked() throws {
        var wall = standardWall()
        wall.turn(.right, at: WallCorner(s: Self.corner, outward: SIMD3(1, 0, 0)))
        var map = CoverageMap(wall: wall)
        Self.record(&map)
        let clear = try #require(map.walkedClearance(at: 1))
        #expect(nearlyEqual(clear, Self.actualClear - map.positionError(atS: 0.3048)))
        #expect(map.facingSpans().allSatisfy { $0.out <= Self.actualClear })
    }

    /// The same poses kept before the corner is marked: walked steps are read against the wall
    /// as it is when exported, so marking the corner afterwards gives the same answer.
    @Test func aCrossingKeptBeforeTheCornerIsMarked() throws {
        var map = CoverageMap(wall: standardWall())
        Self.record(&map)
        // On the straight wall B is behind it: no step.
        #expect(map.walkedClearance(at: 1) == nil)
        try map.turnCorner(.right, meeting: SIMD3(Self.corner, 1, -1), outward: SIMD3(1, 0, 0), source: .tap)
        let clear = try #require(map.walkedClearance(at: 1))
        #expect(nearlyEqual(clear, Self.actualClear - map.positionError(atS: 0.3048)))
    }

    /// Straight steps on either piece keep their distance out; a step wholly in front of one
    /// piece is unchanged.
    @Test func stepsOnOnePieceAreUnchanged() throws {
        var wall = standardWall()
        wall.turn(.right, at: WallCorner(s: Self.corner, outward: SIMD3(1, 0, 0)))
        var map = CoverageMap(wall: wall)
        map.observe(Self.camera(x: -1, z: 0.5), trackingNormal: true, time: 0)
        map.observe(Self.camera(x: -0.5, z: 0.5), trackingNormal: true, time: 1)
        let clear = try #require(map.walkedClearance(at: -5))
        #expect(nearlyEqual(clear, 0.5 - map.positionError(atS: -0.7620)))
    }
}

/// An interruption can reach the map before a frame captured ahead of it (Codex 4114518313).
@Suite struct InterruptionOrderTests {
    /// B was captured before the interruption but delivered after it, so it gets the new segment;
    /// C comes after the resume. The break's time keeps B and C apart.
    @Test func aFrameDeliveredAfterTheInterruptionDoesntJoinAcrossIt() {
        var map = CoverageMap(wall: standardWall())
        map.observe(FacingTests.camera(s: 0, out: 2), trackingNormal: true, time: 10)
        map.breakWalkedPath(at: 10.5)
        map.observe(FacingTests.camera(s: 0.5, out: 2), trackingNormal: true, time: 10.5)
        map.observe(FacingTests.camera(s: 1.0, out: 2), trackingNormal: true, time: 11)
        // Cell 4 lies between B (0.5) and C (1.0) only.
        #expect(map.walkedClearance(at: 4) == nil)
        #expect(map.facingSpans().allSatisfy { $0.span.upperBound <= 0.5 + 1e-4 })
    }
}
