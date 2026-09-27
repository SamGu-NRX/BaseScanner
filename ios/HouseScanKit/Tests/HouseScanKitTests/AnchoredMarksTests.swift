import Foundation
@testable import HouseScanKit
import simd
import Testing

// #73 (build 4.1, run 2): a window's outline stayed where it was tapped while the meter pin
// followed the anchor, and ended up on the panel boxes. In that build a correction moved only the
// meter, and the marks kept their world points. The engine now moves the tapped points with the
// same correction as the wall (`ScanEngine.refreshMeterFromAnchor`); these pin what that has to
// keep true.

/// The marks move with the meter's anchor as one body with the wall.
@Suite struct AnchoredMarksTests {
    /// The anchor moved by (0.2, 0, 0.1) m and turned 3 degrees about its own vertical, as ARKit
    /// might correct it after a walk 5 m away and back.
    static func corrected(_ pose: simd_float4x4) -> simd_float4x4 {
        var new = MeterAnchorCorrectionTests.turned(pose, degrees: 3)
        new.columns.3 += SIMD4(0.2, 0, 0.1, 0)
        return new
    }

    static func anchorLocal(_ world: SIMD3<Float>, _ pose: simd_float4x4) -> SIMD3<Float> {
        let local = pose.inverse * SIMD4(world, 1)
        return SIMD3(local.x, local.y, local.z)
    }

    /// A window's two corners 1.2 to 2.0 m along, a fence tap 2 m out: moved with the correction,
    /// each keeps its place in the anchor's frame, and its s, height and distance out from the
    /// moved wall (what `ScanEngine.project` reads) are what they were at the tap. Left where they
    /// were tapped, as in 4.1, the window's s is off by centimetres.
    @Test func marksKeepTheirPlaceRelativeToTheMeter() throws {
        var wall = standardWall()
        let pose = MeterAnchorCorrectionTests.wallHitPose(meter: wall.meter, outward: wall.outward)
        var tracking = MeterAnchorTracking(pose: pose)
        let taps = [WallPoint(s: 1.2, height: 1.0, out: 0), WallPoint(s: 2.0, height: 2.2, out: 0), WallPoint(s: -0.8, height: 0, out: 2)]
        let points = taps.map { wall.world($0) }

        let newPose = Self.corrected(pose)
        let update = tracking.update(to: newPose)
        let correction = try #require(update)
        wall.apply(correction)
        let moved = points.map(correction.point)

        #expect(nearlyEqual(wall.meter, SIMD3(newPose.columns.3.x, newPose.columns.3.y, newPose.columns.3.z)))
        for (point, after) in zip(points, moved) {
            #expect(nearlyEqual(Self.anchorLocal(after, newPose), Self.anchorLocal(point, pose)))
        }
        for (tap, after) in zip(taps, moved) {
            let now = wall.wallPoint(after)
            #expect(nearlyEqual(now.s, tap.s))
            #expect(nearlyEqual(now.height, tap.height))
            #expect(nearlyEqual(now.out, tap.out))
        }
        let stale = wall.wallPoint(points[1])
        #expect(abs(stale.s - taps[1].s) > 0.05)
    }

    /// The drift log's totals: every correction applied since the meter was anchored, and none
    /// still waiting under the 2 cm and 0.4 degree thresholds.
    @Test func correctionsSinceAnchoredAddUp() throws {
        let pose = MeterAnchorCorrectionTests.wallHitPose(meter: SIMD3(0.4, 1.5, -0.2), outward: SIMD3(0, 0, 1))
        var tracking = MeterAnchorTracking(pose: pose)
        #expect(tracking.corrections == 0)
        #expect(nearlyEqual(tracking.sinceAnchored.moved, .zero))
        #expect(nearlyEqual(tracking.sinceAnchored.yaw, 0, 1e-6))

        let first = Self.corrected(pose)
        let firstUpdate = tracking.update(to: first)
        _ = try #require(firstUpdate)
        #expect(tracking.corrections == 1)
        #expect(nearlyEqual(tracking.sinceAnchored.moved, SIMD3(0.2, 0, 0.1)))
        #expect(nearlyEqual(tracking.sinceAnchored.yaw, 3 * .pi / 180, 1e-5))

        // Under both thresholds: waits, and isn't in the total yet.
        let small = tracking.update(to: MeterAnchorCorrectionTests.turned(first, degrees: 0.1))
        #expect(small == nil)
        #expect(tracking.corrections == 1)
        #expect(nearlyEqual(tracking.sinceAnchored.yaw, 3 * .pi / 180, 1e-5))

        var second = first
        second.columns.3 += SIMD4(0, 0, -0.05, 0)
        let secondUpdate = tracking.update(to: second)
        _ = try #require(secondUpdate)
        #expect(tracking.corrections == 2)
        #expect(nearlyEqual(tracking.sinceAnchored.moved, SIMD3(0.2, 0, 0.05)))
        #expect(nearlyEqual(tracking.sinceAnchored.yaw, 3 * .pi / 180, 1e-5))
        #expect(tracking.anchoredPose == pose)
    }

    /// The drift log's anchor lines: one for the first frame, one per change, none while the
    /// frames go on the same, and a count of every frame.
    @Test func anchorPresenceReportsOnlyChanges() {
        var presence = MeterAnchorPresence()
        #expect(presence.last == nil)
        let frames: [MeterAnchorPresence.Sighting] = [.missing, .present, .present, .present, .missing, .missing, .otherAnchor, .present]
        var lines: [MeterAnchorPresence.Sighting?] = []
        for sighting in frames { lines.append(presence.observe(sighting)) }
        #expect(lines == [.missing, .present, nil, nil, .missing, nil, .otherAnchor, .present])
        #expect(presence.last == .present)
        #expect(presence.present == 4)
        #expect(presence.missing == 3)
        #expect(presence.otherAnchor == 1)
        #expect(MeterAnchorPresence.Sighting.otherAnchor.rawValue == "other anchor")
    }
}
