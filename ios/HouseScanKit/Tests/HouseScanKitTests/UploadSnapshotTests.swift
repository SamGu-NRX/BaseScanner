import Foundation
@testable import HouseScanKit
import simd
import Testing

// The upload's one-frame snapshot (the app's `UploadSnapshot`): the lead's three regressions,
// through the kit's geometry. The app takes the snapshot after a frame's spatial update and keeps
// that frame's mesh only when its timestamp is the frame's; these tests pin down why each part
// matters.

@Suite struct UploadSnapshotTests {
    /// A box whose underside is 2.0 m above the ground, 0 to 1 m out from the standard wall, in
    /// a world `drop` meters lower than the standard one.
    static func overhangScene(drop: Float) -> TriangleMesh {
        var builder = MeshBuilder()
        builder.quad(SIMD3(-10, -drop, 0), SIMD3(10, -drop, 0), SIMD3(10, 4 - drop, 0), SIMD3(-10, 4 - drop, 0))
        builder.quad(SIMD3(-10, -drop, 0), SIMD3(-10, -drop, 10), SIMD3(10, -drop, 10), SIMD3(10, -drop, 0))
        builder.box(SIMD3(-2, 2.0 - drop, 0.01), SIMD3(2, 2.1 - drop, 1))
        return builder.mesh
    }

    static func clearance(_ mesh: TriangleMesh, _ wall: WallFrame) -> Float? {
        mesh.overheadSpans(wall: wall, over: -1...1).map(\.out).min()
    }

    /// A correction queued behind the frame whose mesh is read: ARKit's world moved 0.2 m down
    /// on that frame, and its mesh is in the moved world. Measured against the wall before the
    /// frame's correction, the 2.0 m overhang reads 1.8 m; against the wall after it, 2.0 m.
    /// Hence the snapshot is taken after the frame's update, with that frame's mesh only.
    @Test func theMeshIsMeasuredAgainstTheWallCorrectedOnItsOwnFrame() throws {
        var (map, tracking, ground, pose) = SpatialUpdateTests.setUp()
        let mesh = Self.overhangScene(drop: 0.2)
        let uncorrected = map.wall
        var lowered = pose
        lowered.columns.3.y -= 0.2
        let outcome = SpatialUpdate.apply(anchor: lowered, planes: nil, time: 1, map: &map, tracking: &tracking, ground: &ground)
        #expect(outcome.changed)
        let snapshot = map
        let right = try #require(Self.clearance(mesh, snapshot.wall))
        #expect(abs(right - 2.0) < 0.05)
        let wrong = try #require(Self.clearance(mesh, uncorrected))
        #expect(abs(wrong - 1.8) < 0.05)

        // A later frame's correction moves the live map, not the snapshot taken before it.
        var further = lowered
        further.columns.3.y -= 0.1
        let later = SpatialUpdate.apply(anchor: further, planes: nil, time: 2, map: &map, tracking: &tracking, ground: &ground)
        #expect(later.changed)
        #expect(snapshot.wall != map.wall)
        #expect(Self.clearance(mesh, snapshot.wall) == right)
    }

    /// The ground plane is revoked while the scene is at the server: the update reports a
    /// change, so the answer, about the measured ground, is stale and the scan goes again. A
    /// second change after that gives up; a frame that changes nothing keeps the answer.
    @Test func aPlaneRevokedDuringThePostMakesTheAnswerStale() {
        var (map, tracking, ground, _) = SpatialUpdateTests.setUp()
        var revision = 0
        func step(_ planes: [GroundPlaneEvidence]?, _ time: Double) {
            if SpatialUpdate.apply(anchor: nil, planes: planes, time: time, map: &map, tracking: &tracking, ground: &ground).changed {
                revision += 1
            }
        }
        step([SpatialUpdateTests.lawn], 1)
        let sent = revision
        step(nil, 2)
        #expect(AnswerFreshness.of(sent: sent, now: revision, resends: 0) == .current)
        step([], 3)
        #expect(!ground.measured)
        #expect(AnswerFreshness.of(sent: sent, now: revision, resends: 0) == .sendAgain)
        let resent = revision
        step([SpatialUpdateTests.lawn], 4)
        #expect(AnswerFreshness.of(sent: resent, now: revision, resends: 1) == .stillChanging)
        #expect(AnswerFreshness.of(sent: revision, now: revision, resends: 1) == .current)
    }

    /// The ground is refined 0.4 m up between a window's sill tap and its head tap. Kept as
    /// world points, both heights come from the one ground the export uses, and the window
    /// keeps its 1.2 m. Kept as heights over the ground of their moment, the sill would stay
    /// 0.9 m up while the head is measured from the new ground: 0.4 m of window lost.
    @Test func aGroundRaisedBetweenTwoTapsKeepsTheWindowsHeight() throws {
        var map = CoverageMap(wall: try #require(WallFrame(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: -0.4)))
        map.heightError = 0.3
        var tracking: MeterAnchorTracking? = nil
        var ground = GroundEvidence(measured: false, guessError: 0.3)
        let sillHit = WallPoint(s: 1, height: 0.9, out: 0)
        let sill = map.wall.world(sillHit)
        let raised = GroundPlaneEvidence(y: 0, kind: .unclassified, boundary: GroundPlaneChoiceTests.rectangle(x: -3...3, z: 0.2...4))
        let outcome = SpatialUpdate.apply(anchor: nil, planes: [raised], time: 1, map: &map, tracking: &tracking, ground: &ground)
        #expect(outcome.groundChanged && nearlyEqual(map.wall.groundY, 0))
        let headHit = WallPoint(s: 1, height: 1.7, out: 0)
        let head = map.wall.world(headHit)
        // Exported against the snapshot's wall: sill 0.5 m, head 1.7 m.
        let bottom = map.wall.wallPoint(sill).height, top = map.wall.wallPoint(head).height
        #expect(nearlyEqual(bottom, 0.5) && nearlyEqual(top, 1.7))
        #expect(nearlyEqual(top - bottom, simd_distance(sill, head)))
        // Heights kept as tapped would give a 0.8 m window.
        #expect(nearlyEqual(headHit.height - sillHit.height, 0.8))
    }
}

@Suite struct AnswerFreshnessTests {
    @Test func anUnchangedRevisionIsCurrentWhateverTheResends() {
        #expect(AnswerFreshness.of(sent: 3, now: 3, resends: 0) == .current)
        #expect(AnswerFreshness.of(sent: 3, now: 3, resends: 5) == .current)
    }

    @Test func aChangedRevisionIsSentAgainOnceThenGivenUp() {
        #expect(AnswerFreshness.resendLimit == 1)
        #expect(AnswerFreshness.of(sent: 3, now: 4, resends: 0) == .sendAgain)
        #expect(AnswerFreshness.of(sent: 4, now: 6, resends: 1) == .stillChanging)
    }
}
