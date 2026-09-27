import Foundation
@testable import HouseScanKit
import simd
import Testing

// The #10 caretaker's findings at 2641027 about the meter anchor, the ground, the frame source
// and the scan folders.

/// ARKit corrects the meter's anchor, turning it about gravity as well as moving it.
@Suite struct MeterAnchorCorrectionTests {
    /// An anchor as a wall tap makes it: at `meter`, its y axis the wall's normal (horizontal),
    /// its z axis up.
    static func wallHitPose(meter: SIMD3<Float>, outward: SIMD3<Float>) -> simd_float4x4 {
        let up = SIMD3<Float>(0, 1, 0)
        let x = simd_normalize(simd_cross(outward, up))
        return simd_float4x4(SIMD4(x, 0), SIMD4(outward, 0), SIMD4(simd_cross(x, outward), 0), SIMD4(meter, 1))
    }

    /// The anchor at `pose` turned by `degrees` about the vertical through its own origin.
    static func turned(_ pose: simd_float4x4, degrees: Float) -> simd_float4x4 {
        let origin = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let spin = YawCorrection(yaw: degrees * .pi / 180, translation: .zero)
        return YawCorrection(yaw: spin.yaw, translation: origin - spin.direction(origin)).matrix * pose
    }

    static func walkedMap() -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        for step in 0...10 { map.observe(wallCamera(s: -1.5 + 0.3 * Float(step)), trackingNormal: true, time: Double(step)) }
        return map
    }

    @Test func theCorrectionOfATiltedAnchorIsItsTurnAboutGravity() {
        let old = Self.wallHitPose(meter: SIMD3(0.4, 1.5, -0.2), outward: SIMD3(0, 0, 1))
        var new = Self.turned(old, degrees: 5)
        new.columns.3 += SIMD4(0.03, 0.01, -0.02, 0)
        let correction = YawCorrection(from: old, to: new)
        #expect(nearlyEqual(correction.yaw, 5 * .pi / 180, 1e-5))
        #expect(nearlyEqual(correction.point(SIMD3(0.4, 1.5, -0.2)), SIMD3(new.columns.3.x, new.columns.3.y, new.columns.3.z)))
    }

    /// Turned 5 degrees before the AR result opens: the wall, and a spot 3 m out on it, turn with
    /// the anchor (about 26 cm at 3 m), while what the scan saw of the wall stays as it was. In
    /// the anchor's own frame, where the AR model is attached, nothing moves at all.
    @Test func rotationBeforeDisplay() throws {
        var map = Self.walkedMap()
        let before = map
        let pose = Self.wallHitPose(meter: map.wall.meter, outward: map.wall.outward)
        var tracking = MeterAnchorTracking(pose: pose)
        let spot = map.wall.world(s: 0, height: 0, out: 3)
        let update = tracking.update(to: Self.turned(pose, degrees: 5))
        let correction = try #require(update)
        map.apply(correction)

        let moved = map.wall.world(s: 0, height: 0, out: 3)
        #expect(nearlyEqual(simd_distance(moved, spot), 2 * 3 * sin(2.5 * .pi / 180), 1e-4))
        #expect(nearlyEqual(simd_dot(map.wall.outward, before.wall.outward), cos(5 * .pi / 180), 1e-5))
        #expect(map.wallSeenSpans() == before.wallSeenSpans())
        #expect(map.groundDepthSpans() == before.groundDepthSpans())
        #expect((-10...10).allSatisfy { map.level(.wall, $0) == before.level(.wall, $0) })

        func anchorLocal(_ world: SIMD3<Float>, _ pose: simd_float4x4) -> SIMD3<Float> {
            let local = pose.inverse * SIMD4(world, 1)
            return SIMD3(local.x, local.y, local.z)
        }
        #expect(nearlyEqual(anchorLocal(moved, tracking.pose), anchorLocal(spot, pose)))
    }

    /// A turn followed by a correction that only moves the anchor, and then a rebuild (the ground
    /// measured): the turn stays, and the rebuilt coverage is what the moved cameras saw of the
    /// moved wall.
    @Test func rotationThenRebuild() throws {
        var map = Self.walkedMap()
        let pose = Self.wallHitPose(meter: map.wall.meter, outward: map.wall.outward)
        var tracking = MeterAnchorTracking(pose: pose)
        let turnedPose = Self.turned(pose, degrees: 5)
        let turn = tracking.update(to: turnedPose)
        map.apply(try #require(turn))
        let outward = map.wall.outward
        var shifted = turnedPose
        shifted.columns.3 += SIMD4(0.05, 0, 0, 0)
        let shift = tracking.update(to: shifted)
        let slide = try #require(shift)
        #expect(nearlyEqual(slide.yaw, 0, 1e-5))
        map.apply(slide)
        #expect(nearlyEqual(map.wall.outward, outward, 1e-5))

        var wall = map.wall
        wall.groundY += 0.02
        map.updateWall(wall)
        #expect(nearlyEqual(map.wall.outward, outward, 1e-5))
        var fresh = CoverageMap(wall: wall)
        for camera in map.observedCameras { fresh.observe(camera, trackingNormal: true) }
        #expect((-10...10).allSatisfy { map.level(.wall, $0) == fresh.level(.wall, $0) && map.level(.ground, $0) == fresh.level(.ground, $0) })
    }

    /// Past a corner the next piece turns with the rest, keeping its s.
    @Test func cornersTurnWithTheWall() {
        var wall = standardWall()
        wall.turn(.right, at: WallCorner(s: 2, outward: SIMD3(1, 0, 0)))
        let far = wall.world(s: 3, height: 0, out: 0)
        var map = CoverageMap(wall: wall)
        let correction = YawCorrection(yaw: 5 * .pi / 180, translation: .zero)
        map.apply(correction)
        #expect(map.wall.rightCorners[0].s == 2)
        #expect(nearlyEqual(map.wall.world(s: 3, height: 0, out: 0), correction.point(far)))
    }

    /// Nudges under 2 cm and 0.4 degrees wait, and add up until they reach it.
    @Test func smallCorrectionsAddUp() throws {
        let pose = Self.wallHitPose(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1))
        var tracking = MeterAnchorTracking(pose: pose)
        let small = tracking.update(to: Self.turned(pose, degrees: 0.3))
        #expect(small == nil)
        #expect(tracking.pose == pose)
        let added = tracking.update(to: Self.turned(pose, degrees: 0.6))
        let correction = try #require(added)
        #expect(nearlyEqual(correction.yaw, 0.6 * .pi / 180, 1e-5))
    }
}

/// The ground at the wall comes from a plane that reaches the wall's foot, never from furniture.
@Suite struct GroundPlaneChoiceTests {
    static let meter = SIMD3<Float>(0, 1.5, 0)
    static let along = SIMD3<Float>(1, 0, 0)

    static func rectangle(x: ClosedRange<Float>, z: ClosedRange<Float>) -> [SIMD2<Float>] {
        [SIMD2(x.lowerBound, z.lowerBound), SIMD2(x.upperBound, z.lowerBound), SIMD2(x.upperBound, z.upperBound), SIMD2(x.lowerBound, z.upperBound)]
    }

    /// The meter 1.5 m above a lawn that reaches to 0.2 m from the wall, and a 0.9 m tabletop 1 m
    /// out. The highest plane 0.3 m below the meter within 2 m, the rule before, was the table.
    @Test func aLawnAndAHigherTabletopNearby() {
        let lawn = GroundPlaneEvidence(y: 0, kind: .unclassified, boundary: Self.rectangle(x: -3...3, z: 0.2...4))
        let table = GroundPlaneEvidence(y: 0.9, kind: .unclassified, boundary: Self.rectangle(x: 0.5...1.5, z: 0.8...1.6))
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [lawn, table]) == 0)
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [table, lawn]) == 0)
        // The table alone is not ground: it doesn't reach the wall's foot.
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [table]) == nil)
    }

    @Test func furnitureAgainstTheWallIsNotGround() {
        let bench = GroundPlaneEvidence(y: 0.45, kind: .furniture, boundary: Self.rectangle(x: -0.5...0.5, z: 0...0.4))
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [bench]) == nil)
        let ceiling = GroundPlaneEvidence(y: 0.2, kind: .other, boundary: Self.rectangle(x: -1...1, z: 0...1))
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [ceiling]) == nil)
    }

    /// A plane classified floor wins over an unclassified one, even a lower one.
    @Test func floorIsPreferred() {
        let floor = GroundPlaneEvidence(y: 0.1, kind: .floor, boundary: Self.rectangle(x: -2...2, z: 0...3))
        let lower = GroundPlaneEvidence(y: -0.4, kind: .unclassified, boundary: Self.rectangle(x: -2...2, z: 0.1...3))
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [lower, floor]) == 0.1)
    }

    /// The plane must reach the wall's foot near the meter: 0.5 m from the foot line, within 2 m
    /// along it. A lawn far along the wall, or one stopping 0.6 m short of the wall, doesn't.
    @Test func thePlaneMustReachTheWallsFootNearTheMeter() {
        let farAlong = GroundPlaneEvidence(y: 0, kind: .floor, boundary: Self.rectangle(x: 2.6...6, z: 0...3))
        let short = GroundPlaneEvidence(y: 0, kind: .floor, boundary: Self.rectangle(x: -3...3, z: 0.6...3))
        let reaching = GroundPlaneEvidence(y: 0, kind: .floor, boundary: Self.rectangle(x: -3...3, z: 0.45...3))
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [farAlong]) == nil)
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [short]) == nil)
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [reaching]) == 0)
        // A plane under the whole stretch, the wall's foot inside its outline, reaches it.
        let under = GroundPlaneEvidence(y: 0, kind: .floor, boundary: Self.rectangle(x: -5...5, z: -1...4))
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [under]) == 0)
    }

    @Test func aPlaneJustUnderTheMeterIsNotGround() {
        let sill = GroundPlaneEvidence(y: 1.3, kind: .unclassified, boundary: Self.rectangle(x: -1...1, z: 0...0.3))
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [sill]) == nil)
    }
}

/// The frame source through failures and Start over.
@Suite struct CaptureSourceStateTests {
    /// A camera failure before the scan is sent shows the failure; Start over discards the failed
    /// source and lets a new one start. Before, the failure and the old session stayed, and no
    /// new session could start.
    @Test func startOverAfterAFailureStartsANewSource() {
        var state = CaptureSourceState()
        #expect(state.mayStartSource)
        state.sourceStarted()
        #expect(!state.mayStartSource)
        let response = state.sourceFailed(.recoverable, afterCapture: false)
        #expect(response == .showFailure)
        #expect(state.failure == .recoverable && !state.mayStartSource)
        let discard = state.startOver()
        #expect(discard)
        #expect(state.failure == nil && state.mayStartSource)
        state.sourceStarted()
        #expect(state.spatialAvailable)
    }

    /// After the scan is sent a failure keeps the answer, but nothing spatial: no further frame
    /// will arrive to say tracking was lost.
    @Test func aFailureAfterCaptureKeepsTheAnswerWithoutAR() {
        var state = CaptureSourceState()
        state.sourceStarted()
        #expect(state.spatialAvailable)
        let response = state.sourceFailed(.recoverable, afterCapture: true)
        #expect(response == .keepAnswer)
        #expect(state.failure == nil)
        #expect(!state.spatialAvailable)
        #expect(!state.mayStartSource)
        let discard = state.startOver()
        #expect(discard)
        #expect(state.mayStartSource && !state.spatialAvailable)
        state.sourceStarted()
        #expect(state.spatialAvailable)
    }

    /// Camera access refused on the onboarding, before any source ran, then turned on in
    /// Settings: letting the failed source go (`ScanEngine.recheckCameraAccess`) clears the
    /// failure, and a new source may start without Start over (#112).
    @Test func cameraRefusedBeforeASourceCanStartOnceReleased() {
        var state = CaptureSourceState()
        let response = state.sourceFailed(.recoverable, afterCapture: false)
        #expect(response == .showFailure)
        #expect(!state.mayStartSource)
        let discard = state.startOver()
        #expect(discard)
        #expect(state.failure == nil && state.mayStartSource)
    }

    /// A device that can't run world tracking stays failed through Start over.
    @Test func anUnsupportedDeviceStaysFailed() {
        var state = CaptureSourceState()
        let response = state.sourceFailed(.unsupported, afterCapture: false)
        #expect(response == .showFailure)
        let discard = state.startOver()
        #expect(!discard)
        #expect(state.failure == .unsupported && !state.mayStartSource)
    }

    /// Start over with nothing failed changes nothing.
    @Test func startOverWithARunningSourceKeepsIt() {
        var state = CaptureSourceState()
        state.sourceStarted()
        let discard = state.startOver()
        #expect(!discard)
        #expect(state.source == .running)
    }
}

/// An old scan's cleanup deletes only what was obsolete when it was made.
@Suite struct ScanFolderCleanupTests {
    @Test func aLateCleanupLeavesTheNewerScan() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scan-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        for name in ["old", "A"] { try files.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true) }
        // Store A is made: its cleanup lists what is obsolete now.
        let cleanupA = ScanFolderCleanup(root: root, keeping: "A")
        #expect(cleanupA.obsolete.map(\.lastPathComponent) == ["old"])
        // Start over makes B before A's cleanup gets to run.
        try files.createDirectory(at: root.appending(path: "B"), withIntermediateDirectories: true)
        let cleanupB = ScanFolderCleanup(root: root, keeping: "B")
        #expect(cleanupB.obsolete.map(\.lastPathComponent) == ["A", "old"])
        // A's cleanup runs late: B, the scan in use, stays.
        let failedA = cleanupA.run()
        #expect(failedA.isEmpty)
        #expect(files.fileExists(atPath: root.appending(path: "B").path))
        #expect(!files.fileExists(atPath: root.appending(path: "old").path))
        // B's own cleanup then removes A; "old" already gone is not an error.
        let failedB = cleanupB.run()
        #expect(failedB.isEmpty)
        #expect(try files.contentsOfDirectory(atPath: root.path) == ["B"])
    }
}
