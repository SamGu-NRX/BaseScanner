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
