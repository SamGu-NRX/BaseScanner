import Foundation
@testable import HouseScanKit
import simd
import Testing

// The #10 caretaker's repair review of 4b71161: the anchor correction, the ground's evidence and
// the frame source, through the transitions and interleavings the app goes through.

@Suite struct AnchorRepairTests {
    static let shift = YawCorrection(yaw: 0, translation: SIMD3(0.30, 0, 0))

    /// One view, then the anchor shifts 0.30 m, then the same physical view again (its pose now
    /// reads 0.30 m over). It is one position, not two 0.30 m apart: no parallax, not covered.
    @Test func aCorrectionDoesNotMakeTheSameViewASecondPosition() {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true)
        #expect(map.level(.wall, 0) == .seen)
        map.apply(Self.shift)
        map.observe(Self.shift.moved(wallCamera(s: 0)), trackingNormal: true)
        #expect(map.level(.wall, 0) == .seen)
        #expect(map.wallSeenHeight(at: 0) == nil)
        // A second real position, 0.3 m from the first, still covers it.
        map.observe(Self.shift.moved(wallCamera(s: 0.3)), trackingNormal: true)
        #expect(map.level(.wall, 0) == .covered)
    }

    /// Review of #120: the sightings the "step to the side" hint (`needsSecondPosition`) measures
    /// from move with a correction. The spot the ground was seen from still needs a second
    /// position once its pose reads 0.30 m over, and the old coordinates, now 0.30 m from it,
    /// don't.
    @Test func aCorrectionKeepsTheSecondPositionHintWithTheView() {
        var map = CoverageMap(wall: standardWall())
        map.observe(CoverageMapTests.frontCamera(), trackingNormal: true)
        map.observe(CoverageMapTests.frontCamera(), trackingNormal: true)
        let front = CoverageMapTests.front
        #expect(map.needsSecondPosition(band: .ground, range: -0.3...0.3, from: front))
        map.apply(Self.shift)
        #expect(map.needsSecondPosition(band: .ground, range: -0.3...0.3, from: Self.shift.point(front)))
        #expect(!map.needsSecondPosition(band: .ground, range: -0.3...0.3, from: front))
    }

    /// A frame captured before a correction and stored (observed) after it lands where the same
    /// frame observed before the correction would have been moved to.
    @Test func aSaveThatFinishesAfterACorrectionIsInterpretedInTheNewFrame() throws {
        let pose = MeterAnchorCorrectionTests.wallHitPose(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1))
        var tracking = MeterAnchorTracking(pose: pose)
        var early = CoverageMap(wall: standardWall())
        var late = early
        let first = wallCamera(s: 0), second = wallCamera(s: 0.3)
        early.observe(first, trackingNormal: true, time: 1)
        late.observe(first, trackingNormal: true, time: 1)
        early.observe(second, trackingNormal: true, time: 2)
        // The anchor turns 5 degrees on the frame at t = 3, while `second`'s photo is saving.
        let update = tracking.update(to: MeterAnchorCorrectionTests.turned(pose, degrees: 5), at: 3)
        let correction = try #require(update)
        early.apply(correction)
        late.apply(correction)
        late.observe(tracking.correctedCamera(second, capturedAt: 2), trackingNormal: true, time: 2)
        #expect((-8...8).allSatisfy { early.level(.wall, $0) == late.level(.wall, $0) && early.level(.ground, $0) == late.level(.ground, $0) })
        #expect(early.wallSeenSpans() == late.wallSeenSpans())
        // A frame captured after the correction is already in the new frame.
        #expect(tracking.correctedPose(second.cameraToWorld, capturedAt: 3) == second.cameraToWorld)
    }

    /// Exported photo poses agree with the corrected wall: a photo taken before two corrections
    /// sits where it did relative to the wall, and the packet's corrections give the same pose.
    @Test func exportedPosesAgreeWithTheCorrectedWall() throws {
        let pose = MeterAnchorCorrectionTests.wallHitPose(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1))
        var tracking = MeterAnchorTracking(pose: pose)
        var map = CoverageMap(wall: standardWall())
        let photo = wallCamera(s: 0.7)
        let before = map.wall.wallPoint(photo.position)
        let turn = tracking.update(to: MeterAnchorCorrectionTests.turned(pose, degrees: 5), at: 2)
        map.apply(try #require(turn))
        var moved = tracking.pose
        moved.columns.3 += SIMD4(0.04, -0.02, 0.03, 0)
        let slide = tracking.update(to: moved, at: 4)
        map.apply(try #require(slide))
        let corrected = tracking.correctedPose(photo.cameraToWorld, capturedAt: 1)
        let after = map.wall.wallPoint(SIMD3(corrected.columns.3.x, corrected.columns.3.y, corrected.columns.3.z))
        #expect(nearlyEqual(after.s, before.s) && nearlyEqual(after.out, before.out) && nearlyEqual(after.height, before.height))
        #expect(PoseCorrections(tracking).pose(photo.cameraToWorld, capturedAt: 1) == corrected)
        // A trajectory row between the two corrections gets only the later one.
        #expect(PoseCorrections(tracking).pose(photo.cameraToWorld, capturedAt: 3) == slide.map { $0.pose(photo.cameraToWorld) })
        // The raw pose is untouched.
        #expect(photo.cameraToWorld == wallCamera(s: 0.7).cameraToWorld)
    }
}

@Suite struct SpatialUpdateTests {
    static let lawn = GroundPlaneEvidence(y: -0.10, kind: .unclassified, boundary: GroundPlaneChoiceTests.rectangle(x: -3...3, z: 0.2...4))

    static func setUp() -> (map: CoverageMap, tracking: MeterAnchorTracking?, ground: GroundEvidence, pose: simd_float4x4) {
        let pose = MeterAnchorCorrectionTests.wallHitPose(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1))
        var map = CoverageMap(wall: standardWall())
        map.heightError = 0.3
        return (map, MeterAnchorTracking(pose: pose), GroundEvidence(measured: false, guessError: 0.3), pose)
    }

    /// The anchor and a new plane both come 0.10 m lower on one frame: the ground ends 0.10 m
    /// lower, not 0.20, and the same frame again changes nothing.
    @Test func theCorrectionComesBeforeTheGround() {
        var (map, tracking, ground, pose) = Self.setUp()
        var lowered = pose
        lowered.columns.3.y -= 0.10
        let outcome = SpatialUpdate.apply(anchor: lowered, planes: [Self.lawn], time: 1, map: &map, tracking: &tracking, ground: &ground)
        #expect(outcome.correction != nil && outcome.groundChanged)
        #expect(nearlyEqual(map.wall.groundY, -0.10))
        #expect(ground.measured && map.heightError == 0)
        let again = SpatialUpdate.apply(anchor: lowered, planes: [Self.lawn], time: 2, map: &map, tracking: &tracking, ground: &ground)
        #expect(again.correction == nil && !again.groundChanged)
        #expect(nearlyEqual(map.wall.groundY, -0.10))
    }

    /// An unclassified plane measures the ground; once ARKit classifies it as furniture, the
    /// ground goes back to a guess, its error back on every height.
    @Test func aPlaneReclassifiedAsFurnitureRevokesTheGround() {
        var (map, tracking, ground, _) = Self.setUp()
        _ = SpatialUpdate.apply(anchor: nil, planes: [Self.lawn], time: 1, map: &map, tracking: &tracking, ground: &ground)
        #expect(ground.measured && map.heightError == 0)
        var table = Self.lawn
        table.kind = .furniture
        let outcome = SpatialUpdate.apply(anchor: nil, planes: [table], time: 2, map: &map, tracking: &tracking, ground: &ground)
        #expect(outcome.groundChanged)
        #expect(!ground.measured && map.heightError == 0.3)
    }

    /// ARKit removes the plane: an empty list revokes it. A frame that carries no plane
    /// information (nil) says nothing either way.
    @Test func aRemovedPlaneRevokesTheGroundAndAPoseOnlyFrameDoesNot() {
        var (map, tracking, ground, _) = Self.setUp()
        _ = SpatialUpdate.apply(anchor: nil, planes: [Self.lawn], time: 1, map: &map, tracking: &tracking, ground: &ground)
        _ = SpatialUpdate.apply(anchor: nil, planes: nil, time: 2, map: &map, tracking: &tracking, ground: &ground)
        #expect(ground.measured)
        _ = SpatialUpdate.apply(anchor: nil, planes: [], time: 3, map: &map, tracking: &tracking, ground: &ground)
        #expect(!ground.measured && map.heightError == 0.3)
    }
}

@Suite struct SourceGenerationTests {
    /// Callbacks carry the generation of the source that sent them: after a failure none are
    /// accepted, and after a restart only the new source's.
    @Test func onlyTheRunningSourcesCallbacksAreAccepted() {
        var state = CaptureSourceState()
        let first = state.sourceStarted()
        #expect(state.accepts(first) && state.mayCapture)
        _ = state.sourceFailed(.recoverable, afterCapture: true)
        #expect(!state.accepts(first) && !state.mayCapture)
        _ = state.startOver()
        let second = state.sourceStarted()
        #expect(state.accepts(second) && !state.accepts(first) && state.mayCapture)
    }
}
