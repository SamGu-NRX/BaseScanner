import Foundation
@testable import HouseScanKit
import simd
import Testing

// #62: the ground at the wall was taken from a tabletop, and a later plane could raise a ground
// already measured. Made-up numbers, not field values. The wall is the plane z = 0, running along
// +x, facing +z; the meter is 1.5 m up at the origin.

@Suite struct GroundPlaneTests {
    static let meter = SIMD3<Float>(0, 1.5, 0)
    static let along = SIMD3<Float>(1, 0, 0)

    static func rectangle(x: ClosedRange<Float>, z: ClosedRange<Float>) -> [SIMD2<Float>] {
        [SIMD2(x.lowerBound, z.lowerBound), SIMD2(x.upperBound, z.lowerBound), SIMD2(x.upperBound, z.upperBound), SIMD2(x.lowerBound, z.upperBound)]
    }

    static func choose(_ planes: [GroundPlaneEvidence], phone: SIMD3<Float>? = nil, current: Float? = nil) -> GroundPlaneChoice.Choice? {
        GroundPlaneChoice.choose(meter: meter, along: along, phone: phone, current: current, planes: planes)
    }

    /// A tabletop 0.5 m under the meter and a floor 1 m below it. The table is refused whatever
    /// its class or reach: the meter would be only 0.5 m above it.
    @Test func aTabletopNearTheMeterLosesToTheFloor() {
        let floor = GroundPlaneEvidence(y: 0, kind: .floor, boundary: Self.rectangle(x: -6...6, z: 0...8), id: "floor")
        let farTable = GroundPlaneEvidence(y: 1, kind: .furniture, boundary: Self.rectangle(x: -1...5, z: 1.4...2.4), id: "table")
        #expect(Self.choose([farTable, floor])?.plane.id == "floor")
        // Unclassified and against the wall, under the phone: still not ground.
        let nearTable = GroundPlaneEvidence(y: 1, kind: .unclassified, boundary: Self.rectangle(x: -1...1, z: 0...1), id: "table")
        #expect(Self.choose([nearTable], phone: SIMD3(0, 1.4, 0.5)) == nil)
        #expect(Self.choose([nearTable, floor], phone: SIMD3(0, 1.4, 0.5))?.plane.id == "floor")
    }

    /// Two floors where the ground steps down: the one under the phone that marked the meter wins,
    /// though the other is lower.
    @Test func theFloorUnderThePhoneWinsOverALowerOne() {
        let upper = GroundPlaneEvidence(y: 0, kind: .floor, boundary: Self.rectangle(x: -2...2, z: 0.05...2), id: "upper")
        let lower = GroundPlaneEvidence(y: -0.3, kind: .floor, boundary: Self.rectangle(x: 2.3...10, z: 0...10), id: "lower")
        let phone = SIMD3<Float>(0.3, 1.4, 0.6)
        let chosen = Self.choose([lower, upper], phone: phone)
        #expect(chosen?.plane.id == "upper")
        #expect(chosen?.reason == .underThePhone)
        // Without the phone's position neither contains anything; the lowest is taken.
        let unplaced = Self.choose([lower, upper])
        #expect(unplaced?.plane.id == "lower")
        #expect(unplaced?.reason == .lowest)
    }

    /// A floor whose outline contains the point below the meter beats a lower one beside it,
    /// unless the phone stood over the other: the phone's position is checked first.
    @Test func theFloorAtTheMetersFootWinsOverALowerOne() {
        let under = GroundPlaneEvidence(y: 0, kind: .floor, boundary: Self.rectangle(x: -2...2, z: -0.1...2), id: "under")
        let lower = GroundPlaneEvidence(y: -0.3, kind: .floor, boundary: Self.rectangle(x: 2.3...10, z: 0...10), id: "lower")
        let footOnly = Self.choose([lower, under])
        #expect(footOnly?.plane.id == "under")
        #expect(footOnly?.reason == .atTheMetersFoot)
        let phoneOverLower = Self.choose([lower, under], phone: SIMD3(3, 1.1, 1))
        #expect(phoneOverLower?.plane.id == "lower")
        #expect(phoneOverLower?.reason == .underThePhone)
    }

    /// The meter must be 0.9 to 2.0 m above the plane.
    @Test func aPlaneThatPutsTheMeterTooLowOrTooHighIsNotGround() {
        func plane(_ y: Float) -> GroundPlaneEvidence {
            GroundPlaneEvidence(y: y, kind: .floor, boundary: Self.rectangle(x: -3...3, z: 0...3), id: "y\(y)")
        }
        #expect(Self.choose([plane(1.1)]) == nil)
        #expect(Self.choose([plane(-1)]) == nil)
        #expect(Self.choose([plane(0.55)])?.plane.y == 0.55)
        #expect(Self.choose([plane(-0.45)])?.plane.y == -0.45)
    }

    /// Once the ground is measured, a plane more than 0.1 m above it is refused; one a little
    /// above it, or any lower one, may replace it.
    @Test func aMeasuredGroundIsNeverRaisedMuch() {
        func plane(_ y: Float) -> GroundPlaneEvidence {
            GroundPlaneEvidence(y: y, kind: .floor, boundary: Self.rectangle(x: -3...3, z: 0...3), id: "y\(y)")
        }
        #expect(Self.choose([plane(0.15)], current: 0) == nil)
        #expect(Self.choose([plane(0.15)]) != nil)
        #expect(Self.choose([plane(0.08)], current: 0)?.plane.y == 0.08)
        #expect(Self.choose([plane(-0.3)], current: 0)?.plane.y == -0.3)
        // A higher plane can't win over a lower one by containing the phone.
        let higher = GroundPlaneEvidence(y: 0.3, kind: .floor, boundary: Self.rectangle(x: -1...1, z: 0...1), id: "higher")
        #expect(Self.choose([higher, plane(0)], phone: SIMD3(0, 1.4, 0.5), current: 0)?.plane.id == "y0.0")
    }

    /// Without plane classification every plane is unclassified, and every one is a candidate.
    @Test func withoutClassificationEveryPlaneIsACandidate() {
        let upper = GroundPlaneEvidence(y: 0, kind: .unclassified, boundary: Self.rectangle(x: -2...2, z: 0.05...2), id: "upper")
        let lower = GroundPlaneEvidence(y: -0.3, kind: .unclassified, boundary: Self.rectangle(x: 2.3...10, z: 0...10), id: "lower")
        #expect(Self.choose([lower, upper], phone: SIMD3(0.3, 1.4, 0.6))?.plane.id == "upper")
        #expect(Self.choose([lower, upper])?.plane.id == "lower")
        #expect(GroundPlaneChoice.groundY(meter: Self.meter, along: Self.along, planes: [upper]) == 0)
    }
}

/// The ground as frames update it (`SpatialUpdate`): the raise limit holds only once the walk has
/// kept a view, and the phone's position at the tap moves with an anchor correction.
@Suite struct GroundUpdateTests {
    /// Two floors where the ground steps down, as in `theFloorUnderThePhoneWinsOverALowerOne`.
    static let upper = GroundPlaneEvidence(y: 0, kind: .floor, boundary: GroundPlaneTests.rectangle(x: -2...2, z: 0.05...2), id: "upper")
    static let lower = GroundPlaneEvidence(y: -0.3, kind: .floor, boundary: GroundPlaneTests.rectangle(x: 2.3...10, z: 0...10), id: "lower")
    static let phone = SIMD3<Float>(0.3, 1.4, 0.6)

    static func setUp() -> (map: CoverageMap, tracking: MeterAnchorTracking?, ground: GroundEvidence) {
        var map = CoverageMap(wall: standardWall())
        map.heightError = 0.3
        return (map, nil, GroundEvidence(measured: false, guessError: 0.3))
    }

    /// The lower floor is detected first and measures the ground. The floor under the phone
    /// arrives during the close-up, 0.3 m higher: nothing has been kept yet, so it replaces the
    /// lower one. Without this the choice depended on which plane ARKit found first.
    @Test func theFloorUnderThePhoneRaisesTheGroundBeforeTheWalk() {
        var (map, tracking, ground) = Self.setUp()
        var phone: SIMD3<Float>? = Self.phone
        let first = SpatialUpdate.apply(anchor: nil, planes: [Self.lower], time: 1, phone: &phone, map: &map, tracking: &tracking, ground: &ground)
        #expect(first.groundChoice?.plane.id == "lower" && first.groundChoice?.reason == .lowest)
        #expect(ground.measured && nearlyEqual(map.wall.groundY, -0.3))
        #expect(SpatialUpdate.raiseLimit(map: map, ground: ground) == nil)
        let second = SpatialUpdate.apply(anchor: nil, planes: [Self.lower, Self.upper], time: 2, phone: &phone, map: &map, tracking: &tracking, ground: &ground)
        #expect(second.groundChanged)
        #expect(second.groundChoice?.plane.id == "upper" && second.groundChoice?.reason == .underThePhone)
        #expect(nearlyEqual(map.wall.groundY, 0))
    }

    /// Once the walk has kept a view, the same higher floor is refused (#62): the ground stays
    /// measured on the lower one.
    @Test func onceAViewIsKeptTheGroundIsNotRaised() {
        var (map, tracking, ground) = Self.setUp()
        var phone: SIMD3<Float>? = Self.phone
        _ = SpatialUpdate.apply(anchor: nil, planes: [Self.lower], time: 1, phone: &phone, map: &map, tracking: &tracking, ground: &ground)
        map.observe(wallCamera(s: 0), trackingNormal: true)
        #expect(SpatialUpdate.raiseLimit(map: map, ground: ground).map { nearlyEqual($0, -0.3) } == true)
        let outcome = SpatialUpdate.apply(anchor: nil, planes: [Self.lower, Self.upper], time: 2, phone: &phone, map: &map, tracking: &tracking, ground: &ground)
        #expect(!outcome.groundChanged)
        #expect(ground.measured && nearlyEqual(map.wall.groundY, -0.3))
    }

    /// Where the phone stood is a point in the old frame: a correction moves it with the wall, so
    /// the plane under it in the new frame is still found. Left where it was, it misses the
    /// upper floor and the lower one wins.
    @Test func thePhonesPositionMovesWithACorrection() throws {
        let shift = SIMD4<Float>(2.6, 0, 0, 0)
        func shifted(_ plane: GroundPlaneEvidence) -> GroundPlaneEvidence {
            var moved = plane
            moved.boundary = plane.boundary.map { $0 + SIMD2(shift.x, shift.z) }
            return moved
        }
        let pose = MeterAnchorCorrectionTests.wallHitPose(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1))
        var moved = pose
        moved.columns.3 += shift
        let planes = [shifted(Self.lower), shifted(Self.upper)]

        var (map, _, ground) = Self.setUp()
        var tracking: MeterAnchorTracking? = MeterAnchorTracking(pose: pose)
        var phone: SIMD3<Float>? = Self.phone
        let outcome = SpatialUpdate.apply(anchor: moved, planes: planes, time: 1, phone: &phone, map: &map, tracking: &tracking, ground: &ground)
        #expect(outcome.correction != nil)
        let movedPhone = try #require(phone)
        #expect(nearlyEqual(movedPhone, Self.phone + SIMD3(2.6, 0, 0)))
        #expect(outcome.groundChoice?.plane.id == "upper" && outcome.groundChoice?.reason == .underThePhone)

        let unmoved = GroundPlaneChoice.choose(meter: map.wall.meter, along: map.wall.along, phone: Self.phone, current: nil, planes: planes)
        #expect(unmoved?.plane.id == "lower" && unmoved?.reason == .lowest)
    }
}
