import Foundation
import HouseScanKit
import simd
import Testing

// A portrait camera 2 m out at height 1.4, pitched up by θ, facing the wall. Its image spans
// atan(300.8 / 500) = 31.03 degrees above the view axis (3 % margin), and pitch without roll leaves
// a wall point's height on screen independent of its s. So the view reaches the wall at
// h = 1.4 + 2 tan(θ + 31.03°) wherever it reaches the wall at all, unless 6 m of distance ends it
// first. Sideways, a wall point at depth d along the axis is in view when |s| <= 0.4512 d.
@Suite struct OverheadTests {
    static func tiltUp(s: Float = 0, pitch: Float) -> CameraFrame {
        let a = pitch * .pi / 180
        return portraitCamera(at: SIMD3(s, 1.4, 2), forward: SIMD3(0, sin(a), -cos(a)))
    }

    @Test func aTiltUpViewReachesTheTopOfTheImage() throws {
        let map = CoverageMap(wall: standardWall())
        // θ = 30: h = 1.4 + 2 tan(61.03°) = 5.0123. The foot of the reach, h = 1.9812, is at depth
        // 2 cos 30° + 0.5812 sin 30° = 2.0226, so |s| <= 0.9126: cells -6 to 5.
        let reach = map.overheadReach(from: Self.tiltUp(pitch: 30))
        #expect(reach.count == 1)
        let first = try #require(reach.first)
        #expect(nearlyEqual(first.span, -0.9144...0.9144))
        // Rounded down to 0.1 ft, never up.
        #expect(first.out <= 5.0123 && first.out > 5.0123 - 0.0305)
    }

    @Test func distanceEndsASteepView() throws {
        // θ = 45: the image would reach 1.4 + 2 tan(76.03°) = 9.44 m, but 6 m from the camera
        // ends it at h = 1.4 + sqrt(36 - 4) = 7.0569 over s = 0 (its bottom, 14 degrees up, still
        // shows the top of the wall band, 16.2 degrees up).
        let map = CoverageMap(wall: standardWall())
        let reach = map.overheadReach(from: Self.tiltUp(pitch: 45))
        let middle = try #require(reach.first { $0.span.contains(0.07) })
        #expect(middle.out <= 7.0569 && middle.out > 7.0569 - 0.0305)
    }

    @Test func aViewThatMissesTheTopOfTheWallBandShowsNothingOverhead() {
        let map = CoverageMap(wall: standardWall())
        // Pitched down 20: the top of the image meets the wall at 1.4 + 2 tan(11.03°) = 1.79 m.
        #expect(map.overheadReach(from: Self.tiltUp(pitch: -20)).isEmpty)
        // Behind the wall's plane nothing counts.
        #expect(map.overheadReach(from: portraitCamera(at: SIMD3(0, 1.4, -2), forward: SIMD3(0, 0.5, 1))).isEmpty)
    }

    @Test func onlyRecordedViewsWithNormalTrackingCount() {
        var map = CoverageMap(wall: standardWall())
        #expect(map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: false).isEmpty)
        #expect(map.overheadSpans().isEmpty)
        #expect(map.overheadHeight(at: 0) == nil)
        let revision = map.revision
        #expect(!map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true).isEmpty)
        #expect(map.revision == revision + 1)
        #expect(map.overheadHeight(at: 0).map { $0 > 4.98 } == true)
    }

    @Test func theHighestViewOfACellCountsAndEndsClip() throws {
        var map = CoverageMap(wall: standardWall())
        map.recordOverhead(Self.tiltUp(pitch: 0), trackingNormal: true)  // reaches 1.4 + 2 tan 31.03° = 2.6
        map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true)
        #expect(map.overheadHeight(at: 0).map { $0 > 4.98 } == true)
        map.setEnd(.left, at: -0.5)
        let spans = map.overheadSpans()
        #expect(spans.first.map { nearlyEqual($0.span.lowerBound, -0.5) } == true)
        #expect(spans.allSatisfy { $0.out > 2.5 })
    }

    @Test func exportSendsTheHeightSeen() throws {
        var map = CoverageMap(wall: standardWall())
        map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true)
        let wall = SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY)
        let data = try SceneExport.jsonData(SceneInput(
            wall: wall, baselineS: -2...2, coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: false)))
        #expect(try SceneSchemas.scene().validate(data) == [])
        let observed = try #require(JSONSchemaValidator.Value.parse(data)["coverage"]?["observed"]?.array)
        let overhead = observed.filter { $0["band"]?.string == "overhead" }
        #expect(overhead.count == 1)
        let feet = try #require(overhead.first?["out_ft"]?.number)
        // 5.0123 m is 16.44 ft; rounded down to 0.1 ft of a meter's worth, then to 4 decimals.
        #expect(feet <= 16.4447 && feet > 16.3)
    }
}
