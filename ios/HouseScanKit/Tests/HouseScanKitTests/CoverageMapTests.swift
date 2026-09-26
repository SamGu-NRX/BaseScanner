import HouseScanKit
import simd
import Testing

// Cells are 0.1524 m wide: cell -1 is [-0.1524, 0], cell 0 is [0, 0.1524]. Wall samples sit at
// heights 0.4, 1.2 and 2.0; ground samples 0.2, 0.6 and 1.0 out; a cell counts as seen at 4 of 6.
//
// The front camera stands 2.6 m out at height 1.4, pitched down 20 degrees. With the 3 % margin the
// image spans atan(300.8 / 500) = 31.03 degrees above and below the view axis. Looking at s = 0:
//   wall h 0.4: atan(-1.0 / 2.6) = -21.0, so 1.0 below the axis    -> in
//   wall h 1.2: atan(-0.2 / 2.6) = -4.4, so 15.6 above              -> in
//   wall h 2.0: atan(0.6 / 2.6) = 13.0, so 33.0 above               -> out
//   ground out 0.2 / 0.6 / 1.0: -30.3 / -35.0 / -41.2, so 10.3 / 15.0 / 21.2 below -> in
// The shallowest ground view (out 0.2) is acos(1.4 / 2.78) = 59.7 degrees from the normal, under 65.
// So cells -1 and 0 are seen in both bands: 4/6 on the wall, 6/6 on the ground.
@Suite struct CoverageMapTests {
    static let front = SIMD3<Float>(0, 1.4, 2.6)
    static func frontCamera(x: Float = 0) -> CameraFrame {
        portraitCamera(at: front + SIMD3(x, 0, 0), forward: forwardFacingWall(pitchedDown: 20))
    }

    @Test func frontCameraSeesBothBandsAroundTheMeter() {
        var map = CoverageMap(wall: standardWall())
        let delta = map.observe(Self.frontCamera(), trackingNormal: true)
        #expect(delta.newlySeen > 0)
        #expect(delta.newlyCovered == 0)
        #expect(map.revision == 1)
        for band in SurfaceBand.allCases {
            for index in [-1, 0] {
                #expect(map.level(band, index) == .seen, "\(band) \(index)")
            }
        }
        #expect(map.coveredCount == 0)
        // 6 m away from the meter is far outside a 2.6 m view.
        #expect(map.level(.wall, 40) == .unseen)
    }

    @Test func repeatedAndNearbyFramesNeverCover() {
        var map = CoverageMap(wall: standardWall())
        map.observe(Self.frontCamera(), trackingNormal: true)
        // Same position: every visible cell already holds it.
        let again = map.observe(Self.frontCamera(), trackingNormal: true)
        #expect(!again.changed)
        #expect(map.revision == 1)
        // 0.1 m away is under the 0.25 m covering baseline, so it never counts as a second view.
        let nearby = map.observe(Self.frontCamera(x: 0.1), trackingNormal: true)
        #expect(nearby.newlyCovered == 0)
        #expect(map.coveredCount == 0)
        #expect(map.level(.wall, 0) == .seen)
        #expect(map.level(.ground, -1) == .seen)
    }

    @Test func secondPositionCoversTheOverlap() {
        var map = CoverageMap(wall: standardWall())
        map.observe(Self.frontCamera(), trackingNormal: true)
        // 0.3 m to the side: cells -1 and 0 are at most 0.41 m sideways, about 9 degrees off axis.
        let delta = map.observe(Self.frontCamera(x: 0.3), trackingNormal: true)
        #expect(delta.newlyCovered > 0)
        #expect(map.revision == 2)
        for band in SurfaceBand.allCases {
            for index in [-1, 0] {
                #expect(map.level(band, index) == .covered, "\(band) \(index)")
            }
        }
        #expect(map.coveredCount == delta.newlyCovered)
    }

    @Test func limitedTrackingChangesNothing() {
        var map = CoverageMap(wall: standardWall())
        #expect(!map.observe(Self.frontCamera(), trackingNormal: false).changed)
        #expect(map.revision == 0)
        #expect(map.seenExtent == nil)
        #expect(map.level(.wall, 0) == .unseen)
    }

    @Test func cameraBehindTheWallSeesNothing() {
        // At z = -3 looking at the wall's back: wall samples face +z, away from it. The nearest
        // ground sample (0, 0, 0.2) is 3.49 m away and 1.4 up: cos = 0.40 < cos 65 = 0.42.
        var map = CoverageMap(wall: standardWall())
        let behind = portraitCamera(at: SIMD3(0, 1.4, -3), lookingAt: SIMD3(0, 0.5, 0))
        #expect(map.newlySeenCount(from: behind) == 0)
        #expect(!map.observe(behind, trackingNormal: true).changed)
        #expect(map.seenExtent == nil)
    }

    @Test func grazingViewDoesNotSeeFarCells() throws {
        // Standing 1 m out and looking along the wall at s = -4: a wall sample there is
        // (4, 0.2, 1) from the camera, cos = 1 / 4.13 = 0.24, 76 degrees from the normal. The ground
        // sample there is (4, 1.4, 0.4) away, cos = 1.4 / 4.26 = 0.33, 71 degrees.
        let map = CoverageMap(wall: standardWall())
        let camera = portraitCamera(at: SIMD3(0, 1.4, 1), lookingAt: SIMD3(-4, 0.8, 0))
        let index = map.cellIndex(forS: -4)
        #expect(index == -27)
        // The cell is in the picture, so only the angle rules it out.
        let pixel = try #require(camera.pixel(of: SIMD3(-4, 1.2, 0)))
        #expect(camera.contains(pixel: pixel, margin: 0.03))
        #expect(!map.isVisible(.wall, index, from: camera))
        #expect(!map.isVisible(.ground, index, from: camera))
    }

    @Test func tooFarSeesNothing() {
        // 7 m out: every wall sample is at least 7 m away, the nearest ground sample
        // sqrt(6^2 + 1.4^2) = 6.16 m. Both exceed maxDistance 6.
        var map = CoverageMap(wall: standardWall())
        let far = portraitCamera(at: SIMD3(0, 1.4, 7), lookingAt: SIMD3(0, 0.8, 0))
        #expect(map.newlySeenCount(from: far) == 0)
        #expect(!map.observe(far, trackingNormal: true).changed)
    }

    @Test func cellEdgesMapToExactlyTheirCell() {
        // A span built from cell edges (gap spans, seen extents) must not pick up a neighbour through
        // Float rounding: that inflated GapPlanner progress, e.g. 3 of 4 cells read as 4 of 5 (80 %).
        let map = CoverageMap(wall: standardWall())
        for index in -60...60 {
            #expect(map.indices(overlapping: map.cellRange(index)) == index...index, "cell \(index)")
        }
        let run = map.cellRange(-6).lowerBound...map.cellRange(5).upperBound
        #expect(map.indices(overlapping: run) == -6...5)
        // Ranges inside one cell, including a point, stay one cell.
        #expect(map.indices(overlapping: 0.05...0.1) == 0...0)
        #expect(map.indices(overlapping: 0...0) == 0...0)
        #expect(map.indices(overlapping: -3...3) == -20...19)
    }

    @Test func visibleRangeBeforeAnythingIsSeen() {
        let map = CoverageMap(wall: standardWall())
        #expect(map.visibleRange == -2.5...2.5)
    }

    @Test func endsClipObservationAndVisibleRange() throws {
        var map = CoverageMap(wall: standardWall())
        map.setEnd(.left, at: 0)
        #expect(map.revision == 1)
        map.observe(Self.frontCamera(), trackingNormal: true)
        // Cell -1 ends at 0, on the left end: excluded. Cell 0 starts there: allowed.
        #expect(map.level(.wall, -1) == .unseen)
        #expect(map.level(.ground, -1) == .unseen)
        #expect(map.level(.wall, 0) == .seen)
        let seen = try #require(map.seenExtent)
        #expect(seen.lowerBound == 0)
        #expect(nearlyEqual(map.visibleRange, 0...(seen.upperBound + 2.5)))
        map.setEnd(.right, at: 0.5)
        #expect(map.visibleRange == 0...0.5)
    }

    @Test func skippingNeverDowngradesCoveredCells() {
        var map = CoverageMap(wall: standardWall())
        map.observe(Self.frontCamera(), trackingNormal: true)
        map.observe(Self.frontCamera(x: 0.3), trackingNormal: true)
        let revision = map.revision
        map.markSkipped(.ground, -3...3)
        #expect(map.revision == revision + 1)
        #expect(map.level(.ground, 0) == .covered)
        // Cell 19 is [2.90, 3.05]: about 2.7 m sideways of the cameras, out of their 24 degree half view.
        #expect(map.level(.ground, 19) == .skipped)
        #expect(map.level(.wall, 19) == .unseen)
        // A skipped cell is never counted as covered.
        #expect(map.coveredFraction(.ground, in: 2.95...3.0) == 0)
    }

    @Test func coveredIntervalsMergeAdjacentCells() throws {
        var map = CoverageMap(wall: standardWall())
        map.observe(Self.frontCamera(), trackingNormal: true)
        map.observe(Self.frontCamera(x: 0.3), trackingNormal: true)
        let intervals = map.coveredIntervals(.wall)
        #expect(intervals.count == 1)
        let run = try #require(intervals.first)
        #expect(run.contains(-0.1524) && run.contains(0.1524))
        // One run of whole cells: its length is the covered wall cells times the width.
        let wallCovered = (-40...40).filter { map.level(.wall, $0) == .covered }.count
        #expect(nearlyEqual(run.upperBound - run.lowerBound, Float(wallCovered) * 0.1524, 1e-3))
    }

    @Test func coveredIntervalsOfHandBuiltRuns() {
        // Wall cameras at 0 and 0.3 cover cells whose lower edge L satisfies both 0.3 <= L + 0.9405
        // and 0 >= L - 0.7881: L in [-0.6405, 0.7881], cells -4 ... 5, i.e. [-0.6096, 0.9144].
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true)
        map.observe(wallCamera(s: 0.3), trackingNormal: true)
        let intervals = map.coveredIntervals(.wall)
        #expect(intervals.count == 1)
        #expect(nearlyEqual(intervals[0], -0.6096...0.9144))
        #expect(map.coveredIntervals(.ground).isEmpty)
        // A right end at 0.5 trims the last run.
        map.setEnd(.right, at: 0.5)
        #expect(nearlyEqual(map.coveredIntervals(.wall)[0], -0.6096...0.5))
    }
}
