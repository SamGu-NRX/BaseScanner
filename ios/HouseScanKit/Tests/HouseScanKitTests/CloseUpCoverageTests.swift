import HouseScanKit
import Testing
import simd

// The meter close-up goes into coverage as a view with no time (ScanEngine.observeCloseUpView).
// These pin down what such a view does in the map: it is one of the two positions a cell needs,
// it is replayed when the wall moves, and it never joins the walked path. The close-up here is a
// `wallCamera`, whose footprint is worked out in TestSupport.swift.

@Suite struct CloseUpCoverageTests {
    static let closeUp = wallCamera(s: 0)
    static let walk = wallCamera(s: 0.3)

    @Test func closeUpIsOneOfTheTwoPositions() {
        var alone = CoverageMap(wall: standardWall())
        alone.observe(Self.walk, trackingNormal: true, time: 10)
        #expect(alone.coveredIntervals(.wall).isEmpty)

        var map = CoverageMap(wall: standardWall())
        map.observe(Self.closeUp, trackingNormal: true)
        #expect(map.coveredIntervals(.wall).isEmpty)
        map.observe(Self.walk, trackingNormal: true, time: 10)
        // Cells with lower edge L in [-0.6405, 0.7881] are seen from both, 0.3 m apart.
        let covered = map.coveredIntervals(.wall)
        #expect(covered.count == 1)
        #expect(nearlyEqual(covered[0], -0.6096...0.9144))
    }

    /// A view from under 0.25 m away adds no parallax, so it is not a second position.
    @Test func closeUpNearTheWalkFrameAddsNothing() {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0.1), trackingNormal: true)
        map.observe(Self.walk, trackingNormal: true, time: 10)
        #expect(map.coveredIntervals(.wall).isEmpty)
    }

    /// The close-up is kept with the walk's cameras, so moving the wall (the meter anchor
    /// refined, the ground measured) replays it: the map matches one built on the new wall.
    @Test func closeUpSurvivesAWallRebuild() {
        var map = CoverageMap(wall: standardWall())
        map.observe(Self.closeUp, trackingNormal: true)
        map.observe(Self.walk, trackingNormal: true, time: 10)
        var moved = standardWall()
        moved.meter = SIMD3(0.1, 1.5, 0)
        moved.groundY = 0.05
        map.updateWall(moved)
        #expect(map.observedCameras.count == 2)

        var fresh = CoverageMap(wall: moved)
        fresh.observe(Self.closeUp, trackingNormal: true)
        fresh.observe(Self.walk, trackingNormal: true, time: 10)
        #expect(!map.coveredIntervals(.wall).isEmpty)
        #expect(map.coveredIntervals(.wall) == fresh.coveredIntervals(.wall))
    }

    /// With no time the close-up's pose is never joined to the walk's first frame, so the space
    /// between them doesn't count as walked.
    @Test func closeUpIsNotWalkedPath() {
        var map = CoverageMap(wall: standardWall())
        map.observe(Self.closeUp, trackingNormal: true)
        map.observe(wallCamera(s: 0.5), trackingNormal: true, time: 10)
        map.observe(wallCamera(s: 1.0), trackingNormal: true, time: 10.5)
        let facing = map.facingSpans()
        #expect(!facing.isEmpty)
        #expect(facing.allSatisfy { $0.span.lowerBound >= 0.5 })
    }

    /// A view with tracking that isn't normal records nothing (the engine never passes one).
    @Test func closeUpWithoutNormalTrackingIsNotKept() {
        var map = CoverageMap(wall: standardWall())
        map.observe(Self.closeUp, trackingNormal: false)
        map.observe(Self.walk, trackingNormal: true, time: 10)
        #expect(map.observedCameras.count == 1)
        #expect(map.coveredIntervals(.wall).isEmpty)
    }
}
