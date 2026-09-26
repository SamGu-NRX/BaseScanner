import Testing
@testable import MeasureGeometry

struct MeasurementTests {
    @Test func `separation between two points`() {
        // Δ = (3, 4, −4): straight √41, horizontal √(3² + (−4)²) = 5, and rise is Δy = 4.
        let separation = PointSeparation(from: SIMD3(1, 2, 3), to: SIMD3(4, 6, -1))
        #expect(isClose(separation.straight, 41.0.squareRoot()))
        #expect(separation.horizontal == 5)
        #expect(separation.rise == 4)
        #expect(PointSeparation(from: SIMD3(4, 6, -1), to: SIMD3(1, 2, 3)).rise == -4)
    }

    @Test func `tape comparison reports app minus tape`() {
        // Tape 6 ft 3.5 in = 75.5 in = 1.9177 m; the app read 1.95 m.
        let comparison = TapeComparison(measured: 1.95, tape: 1.9177)
        #expect(isClose(comparison.error, 0.0323))
        #expect(isClose(comparison.errorInches, 0.0323 / 0.0254))
        #expect(TapeComparison(measured: 1.0, tape: 1.0254).errorInches < 0)
    }
}

struct MeasuredValuesTests {
    let wall: Wall

    init() throws {
        wall = try Wall(contact1: SIMD3(0, 0, 0), contact2: SIMD3(4, 0, 0), cameraPosition: SIMD3(2, 1.5, 3))
    }

    @Test func `point to point without a wall`() {
        let values = measuredValues(from: SIMD3(1, 2, 3), to: .point(SIMD3(4, 6, -1)))
        #expect(values.count == 3)
        #expect(isClose(values[.straight] ?? .nan, 41.0.squareRoot()))
        #expect(values[.horizontal] == 5)
        #expect(values[.vertical] == 4)
    }

    @Test func `point to point along a wall`() {
        // Along-wall distance is the difference in x for a wall on the x axis, sign dropped.
        let values = measuredValues(from: SIMD3(3.5, 0, 2), to: .point(SIMD3(1, 1, 0.5)), referenceWall: wall)
        #expect(values[.alongWall] == 2.5)
        #expect(values[.vertical] == 1)
    }

    @Test func `point to wall gives the facing gap and height`() {
        // A fence post 1.2 m out from the wall, 0.9 m up.
        let values = measuredValues(from: SIMD3(2, 0.9, 1.2), to: .wall(wall))
        #expect(values.count == 2)
        #expect(isClose(values[.gapToWall] ?? .nan, 1.2))
        #expect(isClose(values[.heightAboveGround] ?? .nan, 0.9))
    }
}
