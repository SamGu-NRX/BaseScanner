import Foundation
@testable import HouseScanKit
import simd
import Testing

// #69: a meter tap on an estimated plane put the wall behind the real one and turned from it, and
// nothing corrected it. Made-up numbers, not field values. The real wall is the plane z = 0,
// facing +z, detected by ARKit from x = -3 to 3 m and 0 to 2.4 m up; the meter is 1.5 m up at x = 0.

@Suite struct MeterTapTests {
    static let house = WallPlaneEvidence(
        id: "house", kind: .wall, center: SIMD3(0, 1.2, 0), normal: SIMD3(0, 0, 1),
        boundary: [SIMD3(-3, 0, 0), SIMD3(3, 0, 0), SIMD3(3, 2.4, 0), SIMD3(-3, 2.4, 0)]
    )

    /// A phone `distance` in front of the meter, facing the wall.
    static func phone(_ distance: Float) -> CameraFrame {
        portraitCamera(at: SIMD3(0, 1.5, distance), forward: SIMD3(0, 0, -1))
    }

    static func turned(_ degrees: Float) -> SIMD3<Float> {
        let a = degrees * .pi / 180
        return SIMD3(sin(a), 0, cos(a))
    }

    static func refusal(hit: SIMD3<Float>, normal: SIMD3<Float>, source: MeterPlaneSource = .estimatedPlane, camera: CameraFrame = MeterTapTests.phone(0.4), planes: [WallPlaneEvidence] = [MeterTapTests.house]) -> MeterTap.Refusal? {
        MeterTap.refusal(hit: hit, normal: normal, source: source, camera: camera, planes: planes)
    }

    /// An estimated hit 1.1 m behind the wall, its plane turned 46 degrees: refused for its turn,
    /// and, square-on, for lying behind the wall the phone looks through.
    @Test func anEstimatedHitTurnedAndBehindTheWallIsRefused() throws {
        let hit = SIMD3<Float>(0, 1.5, -1.1)
        let turned = try #require(Self.refusal(hit: hit, normal: Self.turned(46)))
        guard case .turnedFromPhone(let degrees) = turned else {
            Issue.record("expected a turn, got \(turned)")
            return
        }
        #expect(nearlyEqual(degrees, 46, 1e-3))
        let behind = try #require(Self.refusal(hit: hit, normal: SIMD3(0, 0, 1)))
        guard case .behindDetectedPlane(let planeID, let meters) = behind else {
            Issue.record("expected behind a plane, got \(behind)")
            return
        }
        #expect(planeID == "house")
        #expect(nearlyEqual(meters, 1.1, 1e-4))
        // With no plane detected yet, the square-on hit behind the wall can't be told apart.
        #expect(Self.refusal(hit: hit, normal: SIMD3(0, 0, 1), planes: []) == nil)
    }

    @Test func anEstimatedHitOutOfReachIsRefused() throws {
        let refusal = try #require(Self.refusal(hit: SIMD3(0, 1.5, -1.7), normal: SIMD3(0, 0, 1), planes: []))
        guard case .tooFar(let meters) = refusal else {
            Issue.record("expected out of reach, got \(refusal)")
            return
        }
        #expect(nearlyEqual(meters, 2.1, 1e-4))
    }

    /// A square-on hit on the wall 0.5 m from the phone, either way round, and one on the meter's
    /// face 0.15 m in front of the wall, are taken.
    @Test func aSquareOnHitAtHalfAMeterIsAccepted() {
        #expect(Self.refusal(hit: SIMD3(0, 1.5, 0), normal: SIMD3(0, 0, 1), camera: Self.phone(0.5)) == nil)
        #expect(Self.refusal(hit: SIMD3(0, 1.5, 0), normal: SIMD3(0, 0, -1), camera: Self.phone(0.5)) == nil)
        #expect(Self.refusal(hit: SIMD3(0, 1.5, 0.15), normal: Self.turned(20), camera: Self.phone(0.6)) == nil)
    }

    /// A hit on a detected plane is taken as it is, however it lies.
    @Test func aHitOnADetectedPlaneIsAccepted() {
        #expect(Self.refusal(hit: SIMD3(0, 1.5, -1.1), normal: Self.turned(46), source: .detectedPlane) == nil)
        #expect(Self.refusal(hit: SIMD3(0, 1.5, -3), normal: SIMD3(0, 0, 1), source: .detectedPlane) == nil)
    }

    /// A door or a window may stand in front of a wall; only wall and unclassified planes refuse.
    /// Neither does a plane the line of sight passes beside.
    @Test func onlyAWallPlaneOnTheLineOfSightRefuses() {
        var door = Self.house
        door.kind = .other
        #expect(Self.refusal(hit: SIMD3(0, 1.5, -1.1), normal: SIMD3(0, 0, 1), planes: [door]) == nil)
        var unclassified = Self.house
        unclassified.kind = .unclassified
        #expect(Self.refusal(hit: SIMD3(0, 1.5, -1.1), normal: SIMD3(0, 0, 1), planes: [unclassified]) != nil)
        var beside = Self.house
        beside.center = SIMD3(5, 1.2, 0)
        beside.boundary = beside.boundary.map { $0 + SIMD3(5, 0, 0) }
        #expect(Self.refusal(hit: SIMD3(0, 1.5, -1.1), normal: SIMD3(0, 0, 1), planes: [beside]) == nil)
    }

    /// The meter was marked on the tap's line of sight; the detected wall plane moves it to where
    /// that line meets the plane once it would move more than 0.2 m.
    @Test func theRefitMovesTheMeterOnceItIsOffByMoreThanTwentyCentimetres() throws {
        let tapCamera = SIMD3<Float>(0, 1.5, 0.4)
        #expect(MeterTap.refit(meter: SIMD3(0, 1.5, -0.15), outward: SIMD3(0, 0, 1), tapCamera: tapCamera, planes: [Self.house]) == nil)
        let refit = try #require(MeterTap.refit(meter: SIMD3(0, 1.5, -0.25), outward: SIMD3(0, 0, 1), tapCamera: tapCamera, planes: [Self.house]))
        #expect(nearlyEqual(refit.meter, SIMD3(0, 1.5, 0)))
        #expect(nearlyEqual(refit.outward, SIMD3(0, 0, 1)))
        #expect(nearlyEqual(refit.moved, 0.25))
        #expect(refit.planeID == "house")
    }

    /// A meter in the right place on a wall turned from the detected one: re-fitted once the turn
    /// passes 10 degrees.
    @Test func theRefitTurnsTheWallOnceItIsOffByMoreThanTenDegrees() throws {
        let tapCamera = SIMD3<Float>(0, 1.5, 0.4)
        let meter = SIMD3<Float>(0, 1.5, 0)
        #expect(MeterTap.refit(meter: meter, outward: Self.turned(8), tapCamera: tapCamera, planes: [Self.house]) == nil)
        let refit = try #require(MeterTap.refit(meter: meter, outward: Self.turned(12), tapCamera: tapCamera, planes: [Self.house]))
        #expect(nearlyEqual(refit.turned, 12 * .pi / 180, 1e-4))
        #expect(nearlyEqual(refit.outward, SIMD3(0, 0, 1)))
    }

    /// The tap that put the meter 1.1 m behind the wall and turned 46 degrees is moved onto the
    /// wall, facing the phone, by a wall plane; not by an unclassified one, nor by one the tap's
    /// line of sight misses.
    @Test func aBadTapIsRefittedOnlyToAWallPlaneOnItsLineOfSight() throws {
        let tapCamera = SIMD3<Float>(0.2, 1.5, 0.4)
        let meter = SIMD3<Float>(-0.35, 1.5, -1.1)
        let refit = try #require(MeterTap.refit(meter: meter, outward: Self.turned(46), tapCamera: tapCamera, planes: [Self.house]))
        #expect(nearlyEqual(refit.meter.z, 0, 1e-4))
        #expect(refit.meter.x > -0.35 && refit.meter.x < 0.2)
        #expect(nearlyEqual(refit.outward, SIMD3(0, 0, 1)))
        var unclassified = Self.house
        unclassified.kind = .unclassified
        #expect(MeterTap.refit(meter: meter, outward: Self.turned(46), tapCamera: tapCamera, planes: [unclassified]) == nil)
        var beside = Self.house
        beside.center = SIMD3(5, 1.2, 0)
        beside.boundary = beside.boundary.map { $0 + SIMD3(5, 0, 0) }
        #expect(MeterTap.refit(meter: meter, outward: Self.turned(46), tapCamera: tapCamera, planes: [beside]) == nil)
    }

    /// A wall plane ARKit already knew at the tap: the gate takes an estimated hit on the meter
    /// 0.05 m in front of it, turned 20 degrees, and the same planes re-fit it straight away. The
    /// engine tries the re-fit on entering the close-up, not only when the planes change.
    @Test func aTapTheGatePassesIsRefittedAgainstThePlanesAlreadyKnown() throws {
        let camera = Self.phone(0.5)
        let hit = SIMD3<Float>(0, 1.5, 0.05)
        let planes = [Self.house]
        #expect(Self.refusal(hit: hit, normal: Self.turned(20), camera: camera, planes: planes) == nil)
        let refit = try #require(MeterTap.refit(meter: hit, outward: Self.turned(20), tapCamera: camera.position, planes: planes))
        #expect(nearlyEqual(refit.turned, 20 * .pi / 180, 1e-4))
        #expect(nearlyEqual(refit.meter, SIMD3(0, 1.5, 0)))
        #expect(nearlyEqual(refit.outward, SIMD3(0, 0, 1)))
    }

    /// A meter standing proud of the house wall (on a pedestal, say) tapped 0.5 m in front of it:
    /// the wall behind isn't a better fit, and the meter stays. One 0.25 m in front, a meter box's
    /// depth, is still moved onto the wall.
    @Test func aWallFarBehindTheTapDoesNotPullTheMeterBack() throws {
        let tapCamera = SIMD3<Float>(0, 1.5, 0.9)
        #expect(MeterTap.refit(meter: SIMD3(0, 1.5, 0.5), outward: SIMD3(0, 0, 1), tapCamera: tapCamera, planes: [Self.house]) == nil)
        let refit = try #require(MeterTap.refit(meter: SIMD3(0, 1.5, 0.25), outward: SIMD3(0, 0, 1), tapCamera: tapCamera, planes: [Self.house]))
        #expect(nearlyEqual(refit.meter, SIMD3(0, 1.5, 0)))
        #expect(nearlyEqual(refit.moved, 0.25))
    }
}
