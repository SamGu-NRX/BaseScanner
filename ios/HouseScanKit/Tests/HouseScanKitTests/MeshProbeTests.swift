import HouseScanKit
import simd
import Testing

// Mesh measurements on the standard wall (face z = 0, s = x, ground y = 0). Cell 0 spans s
// [0, 0.1524]; its rays start at s = 0.0381 and 0.1143. The fan tilts 3 degrees: tan 3 = 0.0524,
// so at 2 m out a tilted ray has moved 0.105 m sideways.
@Suite struct MeshProbeTests {
    static let cell0: ClosedRange<Float> = 0...0.1524

    @Test func rayHitsATriangleFromEitherSide() throws {
        let mesh = TriangleMesh(vertices: [SIMD3(-1, -1, 2), SIMD3(1, -1, 2), SIMD3(0, 1, 2)], indices: [0, 1, 2])
        let forward = Ray(origin: .zero, direction: SIMD3(0, 0, 1))
        #expect(nearlyEqual(try #require(mesh.firstHit(forward, within: 0...10)), 2))
        let back = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(nearlyEqual(try #require(mesh.firstHit(back, within: 0...10)), 3))
        // Out of range, pointing away, beside the triangle, parallel to it.
        #expect(mesh.firstHit(forward, within: 0...1.5) == nil)
        #expect(mesh.firstHit(forward, within: 2.5...10) == nil)
        #expect(mesh.firstHit(Ray(origin: .zero, direction: SIMD3(0, 0, -1)), within: 0...10) == nil)
        #expect(mesh.firstHit(Ray(origin: SIMD3(0.9, 0.9, 0), direction: SIMD3(0, 0, 1)), within: 0...10) == nil)
        #expect(mesh.firstHit(Ray(origin: SIMD3(0, 0, 2), direction: SIMD3(1, 0, 0)), within: 0...10) == nil)
    }

    @Test func nearestOfSeveralHitsWins() throws {
        let mesh = standardScene(boxes: [(SIMD3(-1, 0, 2), SIMD3(1, 1, 3))])
        let ray = Ray(origin: SIMD3(0, 0.5, 0), direction: SIMD3(0, 0, 1))
        // The box's front face at z = 2, not its back at 3; the wall at t = 0 is under the range.
        #expect(nearlyEqual(try #require(mesh.firstHit(ray, within: 0.15...5)), 2))
    }

    /// A fence 2.0 to 2.2 m out, s in [-1, 1], 1.5 m tall. Every ray from cell 0 meets its front:
    /// the straight one at 2.0, the tilted ones 2.0 out as well (0.105 m aside, and 0.457 + 0.105
    /// = 0.56 m up at most, under its top). The downward ray would meet the ground only
    /// 0.457 / 0.0524 = 8.7 m out, past the 5 m range.
    @Test func facingDepthIsTheGapToTheFence() throws {
        let mesh = standardScene(boxes: [(SIMD3(-1, 0, 2.0), SIMD3(1, 1.5, 2.2))])
        let depth = try #require(mesh.facingDepth(wall: standardWall(), cell: Self.cell0))
        #expect(nearlyEqual(depth, 2.0))
        // At s = 3 nothing stands within 5 m: unknown, not open.
        #expect(mesh.facingDepth(wall: standardWall(), cell: 3...3.1524) == nil)
    }

    @Test func surfacePastTheLidarRangeIsUnknown() {
        let mesh = standardScene(boxes: [(SIMD3(-1, 0, 5.5), SIMD3(1, 1.5, 5.7))])
        #expect(mesh.facingDepth(wall: standardWall(), cell: Self.cell0) == nil)
    }

    /// Two fence panels with a gap at s [0, 0.13]. The straight ray from s = 0.0381 goes through
    /// the gap, but its fan's ray tilted toward -s is at s = -0.067 when it reaches the fence, on
    /// the left panel: the fan bridges the hole and the depth is still 2.0. A gap of s
    /// [-0.3, 0.45] swallows every ray of cell 0 (they reach the fence between s = -0.067 and
    /// 0.219), so the depth there is unknown.
    @Test func fanBridgesASmallHoleButNotALargeOne() throws {
        let small = standardScene(boxes: [
            (SIMD3(-1, 0, 2.0), SIMD3(0, 1.5, 2.2)), (SIMD3(0.13, 0, 2.0), SIMD3(1, 1.5, 2.2)),
        ])
        #expect(nearlyEqual(try #require(small.facingDepth(wall: standardWall(), cell: Self.cell0)), 2.0))
        let large = standardScene(boxes: [
            (SIMD3(-1, 0, 2.0), SIMD3(-0.3, 1.5, 2.2)), (SIMD3(0.45, 0, 2.0), SIMD3(1, 1.5, 2.2)),
        ])
        #expect(large.facingDepth(wall: standardWall(), cell: Self.cell0) == nil)
    }

    /// An eave 2.5 m up, reaching 1 m out, s in [-1, 1]. Rays start on the ground 0.3048 m out;
    /// tilted 3 degrees they are 0.131 m aside at 2.5 m up, still under the eave, so every hit is
    /// 2.5 m up. The ground under the start is at t = 0, under the 0.15 m minimum; the ray
    /// tilted toward the wall would meet it only 0.3048 / 0.0524 = 5.8 m up, past the range.
    @Test func overheadClearanceIsTheHeightOfTheEave() throws {
        let mesh = standardScene(boxes: [(SIMD3(-1, 2.5, 0), SIMD3(1, 2.7, 1.0))])
        let clearance = try #require(mesh.overheadClearance(wall: standardWall(), cell: Self.cell0))
        #expect(nearlyEqual(clearance, 2.5))
        #expect(mesh.overheadClearance(wall: standardWall(), cell: 3...3.1524) == nil)
    }

    /// Per-cell depths rounded down to 0.1 ft and merged: 2.0 m is 6.56 ft, so 6.5 ft (1.9812 m)
    /// over the whole range, whose end cells are clipped to it. Cells past the fence's end have
    /// no hit and are left out.
    @Test func spansMergeCellsOfEqualRoundedDepth() {
        let mesh = standardScene(boxes: [(SIMD3(-1, 0, 2.0), SIMD3(1, 1.5, 2.2))])
        let spans = mesh.facingSpans(wall: standardWall(), over: -0.5...0.5)
        #expect(spans.count == 1)
        #expect(nearlyEqual(spans.first?.span ?? 0...0, -0.5...0.5))
        #expect(nearlyEqual(spans.first?.out ?? 0, 1.9812))

        // The fence ends at s = 1. Tilted rays reach it (its front or its end face) from about
        // 0.11 m past that, so the span ends after cell 6 ([0.9144, 1.0668]) and before cell 8
        // ([1.2192, 1.3716], whose nearest ray passes the fence's end at s = 1.14).
        let wide = mesh.facingSpans(wall: standardWall(), over: 0...3)
        #expect(wide.count == 1)
        #expect(nearlyEqual(wide.first?.span.lowerBound ?? -1, 0))
        #expect((wide.first?.span.upperBound ?? 0) < 1.3)
        #expect((wide.first?.span.upperBound ?? 0) > 1.0)
    }

    /// Where the chain turns, each piece's rays leave along its own outward.
    @Test func raysFollowTheWallRoundACorner() throws {
        var wall = standardWall()
        // The right piece past s = 1 faces +x: its line is x = 1 going -z (along = (0, 0, -1)).
        wall.turn(.right, at: WallCorner(s: 1, outward: SIMD3(1, 0, 0)))
        let mesh = standardScene(boxes: [(SIMD3(3, 0, -5), SIMD3(3.2, 1.5, -1))])
        // s = 2.0 is 1 m along the right piece, at (1, 0, -1); its gap to the box's face x = 3 is 2 m.
        #expect(nearlyEqual(try #require(mesh.facingDepth(wall: wall, cell: 2...2.1524)), 2.0))
    }
}
