import Foundation
@testable import HouseScanKit
import Testing
import simd

// Ground patches from the ground coverage, on walls whose meter stands at plan (0, 0) facing +z:
// the meter's piece runs along +x, s = x, and out = z.

@Suite struct GroundPatchTests {
    static let straight = SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)

    /// Turns away from the homeowner at s = 2: the next piece runs from (2, 0) toward -z, facing +x.
    static let convex = SceneWall(
        meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0, rightCorners: [WallCorner(s: 2, outward: SIMD3(1, 0, 0))])

    /// Turns toward the homeowner at s = -2: the piece left of it runs from (-2, 1) at s = -3 to
    /// the corner (-2, 0), facing +x.
    static let concave = SceneWall(
        meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0, leftCorners: [WallCorner(s: -2, outward: SIMD3(1, 0, 0))])

    /// Turns 135 degrees toward the homeowner at s = 2, a 45 degree inside corner: the next piece
    /// runs from (2, 0) along (-1, 1)/sqrt 2, facing (-1, -1)/sqrt 2. Its front is x + z <= 2.
    static let sharp = SceneWall(
        meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0,
        rightCorners: [WallCorner(s: 2, outward: simd_normalize(SIMD3(-1, 0, -1)))])

    private func expectPolygon(
        _ actual: [SIMD2<Float>], _ expected: [SIMD2<Float>], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.count == expected.count, "\(actual)", sourceLocation: sourceLocation)
        for (a, e) in zip(actual, expected) {
            #expect(nearlyEqual(a, e, 1e-5), "\(actual) != \(expected)", sourceLocation: sourceLocation)
        }
    }

    private func area(_ polygons: [[SIMD2<Float>]]) -> Float {
        polygons.map { abs(SceneWall.signedArea($0)) }.reduce(0, +)
    }

    @Test func straightWallGivesTheRectangleTheSpanSaw() {
        let polygons = Self.straight.groundPatchPolygons(over: [ObservedSpan(span: -1...2, out: 1.5)], within: -5...5, joinGap: 0, inset: 0, behind: 0)
        #expect(polygons.count == 1)
        expectPolygon(polygons[0], [SIMD2(-1, 0), SIMD2(2, 0), SIMD2(2, 1.5), SIMD2(-1, 1.5)])
    }

    /// A rotated wall: the rectangle follows the wall's own along and outward.
    @Test func rectangleFollowsARotatedWall() {
        let wall = SceneWall(meter: SIMD3(1, 1.2, -2), outward: SIMD3(0.6, 0, 0.8), groundY: -0.3)
        let polygons = wall.groundPatchPolygons(over: [ObservedSpan(span: 0...1, out: 2)], within: -5...5, joinGap: 0, inset: 0, behind: 0)
        // along (0.8, -0.6), outward (0.6, 0.8), from the meter's plan point (1, -2).
        expectPolygon(polygons[0], [SIMD2(1, -2), SIMD2(1.8, -2.6), SIMD2(3.0, -1.0), SIMD2(2.2, -0.4)])
    }

    /// Touching spans on one piece make one stepped polygon, each step out to its own reach.
    @Test func eachSpanKeepsItsOwnReach() {
        let spans = [ObservedSpan(span: 0...1, out: 1.2), ObservedSpan(span: 1...1.5, out: 0.6)]
        let polygons = Self.straight.groundPatchPolygons(over: spans, within: -5...5, joinGap: 0, inset: 0, behind: 0)
        #expect(polygons.count == 1)
        expectPolygon(polygons[0], [SIMD2(0, 0), SIMD2(1.5, 0), SIMD2(1.5, 0.6), SIMD2(1, 0.6), SIMD2(1, 1.2), SIMD2(0, 1.2)])
        // Apart by more than the join gap, they stay two.
        let apart = [ObservedSpan(span: 0...1, out: 1.2), ObservedSpan(span: 1.1...1.5, out: 0.6)]
        #expect(Self.straight.groundPatchPolygons(over: apart, within: -5...5, joinGap: 0.05, inset: 0, behind: 0).count == 2)
    }

    /// A gap under the join gap takes the lower reach; the inset pulls in each run's ends, every
    /// top and each riser toward the lower step, and `behind` starts the polygon behind the wall.
    @Test func insetAndBehindBoundThePolygon() {
        let spans = [ObservedSpan(span: 0...1, out: 1.2), ObservedSpan(span: 1.01...1.5, out: 0.6)]
        let polygons = Self.straight.groundPatchPolygons(over: spans, within: -5...5, joinGap: 0.02, inset: 0.001, behind: 0.003)
        #expect(polygons.count == 1)
        expectPolygon(polygons[0], [
            SIMD2(0.001, -0.003), SIMD2(1.499, -0.003), SIMD2(1.499, 0.599), SIMD2(0.999, 0.599),
            SIMD2(0.999, 1.199), SIMD2(0.001, 1.199),
        ])
        // The lower span on the left: its reach runs across the gap to the higher span's start.
        let rising = [ObservedSpan(span: 0...1, out: 0.6), ObservedSpan(span: 1.01...1.5, out: 1.2)]
        let up = Self.straight.groundPatchPolygons(over: rising, within: -5...5, joinGap: 0.02, inset: 0.001, behind: 0)
        expectPolygon(up[0], [SIMD2(0.001, 0), SIMD2(1.499, 0), SIMD2(1.499, 1.199), SIMD2(1.011, 1.199), SIMD2(1.011, 0.599), SIMD2(0.001, 0.599)])
    }

    /// One rectangle per piece; the wedge outside the corner, in front of neither piece, is not
    /// drawn.
    @Test func spanOverAConvexCornerLeavesTheWedgeOut() {
        let polygons = Self.convex.groundPatchPolygons(over: [ObservedSpan(span: 1...3, out: 1)], within: -5...5, joinGap: 0, inset: 0, behind: 0)
        #expect(polygons.count == 2)
        expectPolygon(polygons[0], [SIMD2(1, 0), SIMD2(2, 0), SIMD2(2, 1), SIMD2(1, 1)])
        expectPolygon(polygons[1], [SIMD2(2, 0), SIMD2(2, -1), SIMD2(3, -1), SIMD2(3, 0)])
        #expect(nearlyEqual(area(polygons), 2))
    }

    /// At a 90 degree inside corner neither rectangle reaches past the other piece's line.
    @Test func spanOverAConcaveCornerStaysInFrontOfBothPieces() {
        let polygons = Self.concave.groundPatchPolygons(over: [ObservedSpan(span: -3 ... -1, out: 1)], within: -5...5, joinGap: 0, inset: 0, behind: 0)
        #expect(polygons.count == 2)
        expectPolygon(polygons[0], [SIMD2(-2, 1), SIMD2(-2, 0), SIMD2(-1, 0), SIMD2(-1, 1)])
        expectPolygon(polygons[1], [SIMD2(-2, 0), SIMD2(-1, 0), SIMD2(-1, 1), SIMD2(-2, 1)])
    }

    /// Sharper than 90 degrees, each rectangle crosses the other piece's line into the house and
    /// is cut there: the triangle x + z > 2 comes off the meter's piece, the half below z = 0 off
    /// the other.
    @Test func sharpInsideCornerIsCutAtTheNeighbouringWall() {
        let polygons = Self.sharp.groundPatchPolygons(over: [ObservedSpan(span: 0...3, out: 1)], within: -5...5, joinGap: 0, inset: 0, behind: 0)
        #expect(polygons.count == 2)
        expectPolygon(polygons[0], [SIMD2(0, 0), SIMD2(2, 0), SIMD2(1, 1), SIMD2(0, 1)])
        let r = Float(0.5).squareRoot()
        expectPolygon(polygons[1], [SIMD2(2, 0), SIMD2(2 - r, r), SIMD2(2 - 2 * r, 0)])
        #expect(nearlyEqual(area(polygons), 1.5 + 0.5))
        for point in polygons.flatMap({ $0 }) {
            #expect(point.y >= -1e-6 && point.x + point.y <= 2 + 1e-5, "\(point) is behind a wall")
        }
    }

    @Test func spanPastAChainEndStopsAtTheEnd() {
        let polygons = Self.straight.groundPatchPolygons(over: [ObservedSpan(span: -3...4, out: 1)], within: -1...2, joinGap: 0, inset: 0, behind: 0)
        #expect(polygons.count == 1)
        expectPolygon(polygons[0], [SIMD2(-1, 0), SIMD2(2, 0), SIMD2(2, 1), SIMD2(-1, 1)])
        // Ground past a limit end, wholly beyond the chain, gives nothing.
        #expect(Self.straight.groundPatchPolygons(over: [ObservedSpan(span: 2...4, out: 1)], within: -1...2, joinGap: 0, inset: 0, behind: 0).isEmpty)
        // Nor past the end of a piece round a corner.
        let polygons2 = Self.convex.groundPatchPolygons(over: [ObservedSpan(span: 1...5, out: 1)], within: -1...2.5, joinGap: 0, inset: 0, behind: 0)
        expectPolygon(polygons2[1], [SIMD2(2, 0), SIMD2(2, -0.5), SIMD2(3, -0.5), SIMD2(3, 0)])
    }

    /// scene.json requires `out_ft` on a ground span, so one without a reach is not a valid entry
    /// and vouches for no ground; `ObservedSpan` always has one. A reach of 0 (the wall line
    /// only), a negative one or a non-finite one likewise vouch for no area.
    @Test func spanWithNoReachGivesNoPatch() {
        for out: Float in [0, -0.5, .nan, .infinity] {
            #expect(Self.straight.groundPatchPolygons(over: [ObservedSpan(span: 0...2, out: out)], within: -5...5, joinGap: 0, inset: 0, behind: 0).isEmpty, "out \(out)")
        }
    }

    @Test func slivers() {
        // A span touching the chain end only at its edge, or 1 mm wide, leaves nothing to draw.
        #expect(Self.straight.groundPatchPolygons(over: [ObservedSpan(span: 2...3, out: 1)], within: -1...2, joinGap: 0, inset: 0, behind: 0).isEmpty)
        #expect(Self.straight.groundPatchPolygons(over: [ObservedSpan(span: 0...0.00001, out: 1)], within: -1...2, joinGap: 0, inset: 0, behind: 0).isEmpty)
    }
}

extension SceneGroundPatch {
    /// A patch over an area larger than any test's chain, so what it covers is what was seen.
    static func everywhere(_ type: SceneGroundType) -> SceneGroundPatch {
        SceneGroundPatch(type: type, span: -100...100, out: 100)
    }
}

@Suite struct GroundPatchExportTests {
    typealias Value = JSONSchemaValidator.Value

    static func polygons(_ data: Data, type: String) throws -> [[[Double]]] {
        let ground = try Value.parse(data)["ground"]?.array ?? []
        return ground.filter { $0["type"]?.string == type }.map { ($0["polygon"]?.array ?? []).compactMap(\.numbers) }
    }

    /// The chain export's scene (a concave left corner, a convex right one, a driveway-free
    /// feature list) with the ground seen out to 1.2 m over the whole chain.
    @Test func mulchPatchesFollowTheGroundCoverageAndValidate() throws {
        var input = ChainExportTests.input()
        input.features.append(.driveway(edge: [input.wall.world(s: 0, height: 0, out: 1), input.wall.world(s: 1, height: 0, out: 1)]))
        input.groundPatches = [.everywhere(.mulch)]
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let ground = try #require(try Value.parse(data)["ground"]?.array)
        // The driveway strip stays first and unchanged; one mulch patch per piece of the chain.
        #expect(ground.map { $0["type"]?.string } == ["drive", "mulch", "mulch", "mulch"])
        #expect(ground.allSatisfy { $0["plus_minus_ft"] == nil })
        // The meter's piece, s = -2...3 m, out to 1.2 m (3.937 ft). The server's corners are at
        // the written baseline points, -6.5617 and 9.8425 ft; the entry stops 0.002 ft short of
        // each, [-6.5597, 9.8405], and the patch is pulled in 0.0001 ft from 0.001 ft behind the
        // wall line.
        let patches = try Self.polygons(data, type: "mulch")
        Self.expectBox(patches[1], x: -6.5596...9.8404, z: -0.001...3.9369)
        // The right piece past the convex corner, s = 3...6 m, runs from (3, 0) to (3, -3) m:
        // written [9.8445, 19.685], so z from -(9.8446 - 9.84252) to -(19.6849 - 9.84252).
        Self.expectBox(patches[2], x: 9.8415...13.7794, z: -9.8424...(-0.0021))
    }

    /// The patch's extent in plan feet, within one rounding step of `x` and `z`.
    static func expectBox(
        _ polygon: [[Double]], x: ClosedRange<Double>, z: ClosedRange<Double>, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let xs = polygon.map { $0[0] }, zs = polygon.map { $0[1] }
        let actual = [xs.min() ?? .nan, xs.max() ?? .nan, zs.min() ?? .nan, zs.max() ?? .nan]
        let expected = [x.lowerBound, x.upperBound, z.lowerBound, z.upperBound]
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1.5e-4 }, "\(actual) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test func noPatchSendsNoGround() throws {
        let data = try SceneExport.jsonData(ChainExportTests.input())
        #expect(try Value.parse(data)["ground"]?.array == [])
    }

    @Test func noGroundCoverageSendsNoPatch() throws {
        var input = ChainExportTests.input()
        input.coverage.ground = []
        input.groundPatches = [.everywhere(.lawn)]
        #expect(try Value.parse(try SceneExport.jsonData(input))["ground"]?.array == [])
    }

    /// Hundreds of separate ground spans and 90 driveway strips still fit the schema's 200 ground
    /// entries: the strips all stay, the patches take the room left, and every patch lies over
    /// one of the spans.
    @Test func manySpansFitTheGroundLimit() throws {
        var input = ChainExportTests.input()
        let wall = input.wall
        for i in 0..<90 {
            let s = -3.5 + Float(i) * 0.1
            input.features.append(.driveway(edge: [wall.world(s: s, height: 0, out: 2), wall.world(s: s + 0.1, height: 0, out: 2)]))
        }
        let spans = (0..<400).map { i in
            let low = -4 + Float(i) * 0.025
            return ObservedSpan(span: low...(low + 0.02), out: 1)
        }
        input.coverage.ground = spans
        input.groundPatches = [.everywhere(.gravel)]
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let ground = try #require(try Value.parse(data)["ground"]?.array)
        #expect(ground.count <= 200)
        #expect(ground.filter { $0["type"]?.string == "drive" }.count == 90)
        // The 125 ground entries (`SceneExport.bandBudget`) are joined again to leave room for a
        // patch per corner: 110 room less 2 corners.
        let patches = try GroundPatchExportTests.polygons(data, type: "gravel")
        #expect(patches.count >= 100)
        for polygon in patches {
            let s = polygon.map { p in
                wall.wallCoordinates(of: SIMD3(Float(p[0] / SceneUnits.feetPerMeter), 0, Float(p[1] / SceneUnits.feetPerMeter))).s
            }
            let low = try #require(s.min()), high = try #require(s.max())
            #expect(spans.contains { $0.span.lowerBound - 1e-3 <= low && high <= $0.span.upperBound + 1e-3 }, "\(low)...\(high)")
        }
    }
}

@Suite struct WallSourceExportTests {
    typealias Value = JSONSchemaValidator.Value

    @Test func everyWallSaysHowItsLineWasFound() throws {
        var input = ChainExportTests.input()
        input.wall.source = .plane
        input.wall.leftCorners[0].source = .tap
        input.wall.rightCorners[0].source = .mesh
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let walls = try #require(try Value.parse(data)["walls"]?.array)
        #expect(walls.map { $0["id"]?.string } == ["wall-left-1", "wall", "wall-right-1"])
        #expect(walls.map { $0["source"]?.string } == ["tap", "plane", "mesh"])
    }

    /// A piece outside the exported stretch is left out with its source.
    @Test func sourcesStayWithTheirPieces() throws {
        var input = ChainExportTests.input()
        input.baselineS = -1...6
        input.wall.rightCorners[0].source = .plane
        let walls = try #require(try Value.parse(try SceneExport.jsonData(input))["walls"]?.array)
        #expect(walls.map { $0["id"]?.string } == ["wall", "wall-right-1"])
        #expect(walls.map { $0["source"]?.string } == ["tap", "plane"])
    }
}

@Suite struct CableRouteTests {
    /// Meter at (1, 0.9, 1) m facing +z, turning away at s = 2 onto a piece running toward -z
    /// from (3, 1): offsets are from the meter, in feet.
    static let wall = SceneWall(
        meter: SIMD3(1, 0.9, 1), outward: SIMD3(0, 0, 1), groundY: 0, rightCorners: [WallCorner(s: 2, outward: SIMD3(1, 0, 0))])

    static func feet(_ x: Double, _ z: Double) -> SIMD2<Double> { SIMD2(x, z) * SceneUnits.feetPerMeter }

    @Test func routeRoundACornerGetsAVertexAtTheCorner() {
        // From the meter straight to 1 m past the corner on the second piece.
        let s = Self.wall.chainS(ofPlanOffsetsFeet: [Self.feet(0, 0), Self.feet(2, -1)])
        #expect(s.count == 3)
        for (a, e) in zip(s, [Float(0), 2, 3]) { #expect(nearlyEqual(a, e), "\(s)") }
    }

    @Test func aRouteThatAlreadyBendsAtTheCornerIsKept() {
        let s = Self.wall.chainS(ofPlanOffsetsFeet: [Self.feet(0, 0), Self.feet(2, 0), Self.feet(2, -1.5)])
        #expect(s.count == 3)
        for (a, e) in zip(s, [Float(0), 2, 3.5]) { #expect(nearlyEqual(a, e), "\(s)") }
    }

    /// Projected along the meter's piece, as before, the point past the corner read as s = 2.
    @Test func pointsPastTheCornerAreMeasuredAlongTheirOwnPiece() {
        let s = Self.wall.chainS(ofPlanOffsetsFeet: [Self.feet(2, -0.4), Self.feet(2, -0.1), Self.feet(0.5, 0)])
        for (a, e) in zip(s, [Float(2.4), 2.1, 2, 0.5]) { #expect(nearlyEqual(a, e), "\(s)") }
        #expect(s.count == 4)
    }

    @Test func straightRouteIsUnchanged() {
        let s = SceneWall(meter: SIMD3(1, 0.9, 1), outward: SIMD3(0, 0, 1), groundY: 0)
            .chainS(ofPlanOffsetsFeet: [Self.feet(0, 0), Self.feet(-0.9144, 0)])
        #expect(s.count == 2 && nearlyEqual(s[0], 0) && nearlyEqual(s[1], -0.9144))
    }
}
