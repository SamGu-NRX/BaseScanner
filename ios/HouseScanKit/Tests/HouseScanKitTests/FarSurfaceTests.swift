import HouseScanKit
import simd
import Testing

// Where the space in front of the wall ends (#160, #164), on the standard wall (face z = 0, s = x,
// ground y = 0). The far wall is a slab 0.1 m thick and 2.5 m tall standing parallel in front of
// the whole wall, and ARKit's plane of its face toward the wall is what marks where the space
// ends. Depth images are rendered from the scene mesh (`renderDepth`).
@Suite struct FarSurfaceTests {
    /// A slab from `out` to `out + 0.1` in front of the standard wall, s in [-10, 10].
    static func farWall(at out: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        (SIMD3(-10, 0, out), SIMD3(10, 2.5, out + 0.1))
    }

    /// The slab's face toward the wall as ARKit reports a detected plane, over s in [low, high].
    static func plane(at out: Float, from low: Float = -10, to high: Float = 10, normal: SIMD3<Float> = SIMD3(0, 0, -1)) -> WallPlaneEvidence {
        WallPlaneEvidence(
            id: "far", kind: .wall, center: SIMD3((low + high) / 2, 1.25, out), normal: normal,
            boundary: [SIMD3(low, 0, out), SIMD3(high, 0, out), SIMD3(high, 2.5, out), SIMD3(low, 2.5, out)])
    }

    static func ended(at out: Float) -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        map.setFarSurface(FarSurface.spans(planes: [plane(at: out)], wall: map.wall, over: -3...3))
        return map
    }

    /// A plane 2 m out over s in [-1, 3] ends the space 2 m out, rounded down to 0.1 ft
    /// (65 x 0.03048 = 1.9812 m), over the cells whose samples meet it within 0.15 m of its
    /// outline: from cell -8 (s = -1.2192, its sample at -1.1049) to cell 20 (s = 3.2004, its
    /// sample at 3.0861). A plane turned 30 degrees, one 0.3 m out (the wall's own), one 1 m wide
    /// and a door don't end it.
    @Test func aLargeParallelPlaneInFrontEndsTheSpace() throws {
        let wall = standardWall()
        let spans = FarSurface.spans(planes: [Self.plane(at: 2.0, from: -1, to: 3)], wall: wall, over: -2...4)
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(nearlyEqual(span.out, 65 * 0.03048))
        #expect(nearlyEqual(span.span, -1.2192...3.2004, 1e-3))

        let turned = SIMD3<Float>(sin(Float.pi / 6), 0, -cos(Float.pi / 6))
        #expect(FarSurface.spans(planes: [Self.plane(at: 2.0, normal: turned)], wall: wall, over: -2...4).isEmpty)
        #expect(FarSurface.spans(planes: [Self.plane(at: 0.3)], wall: wall, over: -2...4).isEmpty)
        #expect(FarSurface.spans(planes: [Self.plane(at: 2.0, from: 0, to: 1)], wall: wall, over: -2...4).isEmpty)
        var door = Self.plane(at: 2.0)
        door.kind = .other
        #expect(FarSurface.spans(planes: [door], wall: wall, over: -2...4).isEmpty)
    }

    /// A vertical plane from `a` to `b` on the ground, 2.5 m tall, facing `normal`.
    static func plane(_ id: String, from a: SIMD3<Float>, to b: SIMD3<Float>, normal: SIMD3<Float>) -> WallPlaneEvidence {
        let top = SIMD3<Float>(0, 2.5, 0)
        return WallPlaneEvidence(id: id, kind: .wall, center: (a + b) / 2 + top / 2, normal: normal, boundary: [a, b, b + top, a + top])
    }

    /// A wall's own plane turned off the chain's piece is not where the space ends. The standard
    /// wall turns a corner 0.6 m right of the meter, away from the homeowner, into a corridor: the
    /// next piece runs along -z from (0.6, 0, 0), facing +x, with s = 0.6 + distance along it.
    /// ARKit's plane of that piece's wall runs 10 degrees off it from the corner for 6 m, so it
    /// stands 0.5 m in front of the piece from s = 3.44 on and 1.04 m at its far end: measured
    /// cell by cell it would end the space there. Its near end touches the wall, so it never
    /// counts. The corridor's far wall, 1.8 m out along the whole piece, is found over the
    /// requested 1 to 6 m (1.798 m, 1.8 rounded down to 0.1 ft); its near end lies at the
    /// corridor's mouth, in front of the corner and along no piece but the corridor's.
    @Test func aWallsOwnPlaneTurnedOffThePieceIsNotAFarSurface() throws {
        var wall = standardWall()
        let corner = try wall.corner(on: .right, meeting: SIMD3(0.6, 0, -2), outward: SIMD3(1, 0, 0))
        wall.turn(.right, at: corner)
        #expect(nearlyEqual(corner.s, 0.6))
        let turn = Float.pi / 18
        let own = Self.plane(
            "own", from: SIMD3(0.6, 0, 0), to: SIMD3(0.6 + 6 * sin(turn), 0, -6 * cos(turn)), normal: SIMD3(cos(turn), 0, sin(turn)))
        #expect(FarSurface.spans(planes: [own], wall: wall, over: 1...6).isEmpty)

        let far = Self.plane("far", from: SIMD3(2.4, 0, 0), to: SIMD3(2.4, 0, -6), normal: SIMD3(-1, 0, 0))
        let spans = FarSurface.spans(planes: [own, far], wall: wall, over: 1...6)
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { nearlyEqual($0.out, 59 * 0.03048) })
        #expect(nearlyEqual(spans.first?.span.lowerBound ?? 0, 1) && nearlyEqual(spans.last?.span.upperBound ?? 0, 6))
    }

    /// The corridor wall's own plane, 10 degrees off its piece as above, reaching 0.52 m past the
    /// corner into the space in front of the meter's wall: its near end, at (0.51, 0, 0.52), lies
    /// along the meter's piece and 0.52 m in front of it, past `minOut`. It is held to the
    /// corridor's piece, the only one near parallel to it, whose line it stands 0.09 m behind
    /// there, so it still never counts (review of #168).
    @Test func aWallsOwnPlaneRunningPastTheCornerIsNotAFarSurface() throws {
        var wall = standardWall()
        let corner = try Self.corner(on: wall, at: SIMD3(0.6, 0, -2), outward: SIMD3(1, 0, 0))
        wall.turn(.right, at: corner)
        let turn = Float.pi / 18
        let near = SIMD3<Float>(0.6 - 0.52 * tan(turn), 0, 0.52)
        let own = Self.plane("own", from: near, to: SIMD3(0.6 + 6 * tan(turn), 0, -6), normal: SIMD3(cos(turn), 0, sin(turn)))
        #expect(FarSurface.spans(planes: [own], wall: wall, over: 1...6).isEmpty)
    }

    /// A fence 2 m in front of the meter's wall, parallel to it, runs from s = -2 up to 0.2 m short
    /// of a side wall that comes forward at a corner 3 m right of the meter (the next piece runs
    /// along +z from (3, 0, 0), facing -x). Its end at (2.8, 0, 2) lies along that side piece and
    /// 0.2 m in front of it, but the side piece is turned 90 degrees from the fence: the fence is
    /// held to the meter's piece, 2 m in front, and ends the space (1.9812 m, 2 rounded down to
    /// 0.1 ft) over s -1 to 2.
    @Test func aFenceRunningUpToASideWallStillEndsTheSpace() throws {
        var wall = standardWall()
        let corner = try Self.corner(on: wall, at: SIMD3(3, 0, 2), outward: SIMD3(-1, 0, 0))
        wall.turn(.right, at: corner)
        #expect(nearlyEqual(corner.s, 3))
        let fence = Self.plane("fence", from: SIMD3(-2, 0, 2), to: SIMD3(2.8, 0, 2), normal: SIMD3(0, 0, -1))
        let spans = FarSurface.spans(planes: [fence], wall: wall, over: -1...2)
        #expect(spans.count == 1)
        #expect(spans.allSatisfy { nearlyEqual($0.out, 65 * 0.03048) })
    }

    static func corner(on wall: WallFrame, at point: SIMD3<Float>, outward: SIMD3<Float>) throws -> WallCorner {
        try wall.corner(on: .right, meeting: point, outward: outward)
    }

    /// A far wall found turned 11 degrees off the piece still ends the space: a 7.6 m wide plane
    /// along z = 1.8 + x tan 11 degrees, from x = -0.5 (1.70 m out) to 6.96 (3.15 m out), meets
    /// the cells over s 0 to 2 between 1.8 and 2.19 m out. A plane 0.75 m wide, 1.5 m out, is
    /// narrower than a fence or a wall is found and doesn't count.
    @Test func aWideFarWallTurnedOffTheWallCountsAndANarrowPlaneDoesNot() {
        let wall = standardWall()
        let turn = 11 * Float.pi / 180
        let start = SIMD3<Float>(-0.5, 0, 1.8 - 0.5 * tan(turn))
        let far = Self.plane("far", from: start, to: start + 7.6 * SIMD3(cos(turn), 0, sin(turn)), normal: SIMD3(-sin(turn), 0, cos(turn)))
        let narrow = Self.plane("narrow", from: SIMD3(0.5, 0, 1.5), to: SIMD3(1.25, 0, 1.5), normal: SIMD3(0, 0, -1))
        #expect(FarSurface.spans(planes: [narrow], wall: wall, over: 0...2).isEmpty)

        let spans = FarSurface.spans(planes: [far, narrow], wall: wall, over: 0...2)
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { $0.out >= 1.79 && $0.out <= 2.2 })
        #expect(nearlyEqual(spans.first?.span.lowerBound ?? 1, 0) && nearlyEqual(spans.last?.span.upperBound ?? 0, 2))
        #expect(spans.last.map { $0.out > 2.1 } == true)
    }

    /// The plane the meter's wall was refit to is the wall's own, and is left out by its id.
    @Test func theRefitPlaneIsLeftOut() {
        let wall = standardWall()
        #expect(!FarSurface.spans(planes: [Self.plane(at: 2.0)], wall: wall, over: 0...1).isEmpty)
        #expect(FarSurface.spans(planes: [Self.plane(at: 2.0)], wall: wall, over: 0...1, excluding: ["far"]).isEmpty)
    }

    /// A camera in a 2 m corridor, at (x, 1.4, 0.6) for x = -0.3, 0 and 0.3, looking out at the
    /// far wall pitched down 30 degrees. It sees the ground from 1.375 m out (61 degrees down,
    /// the image's 31 past its axis) to the far wall's foot, and the depth rows behind the wall
    /// out to 3.5 m (row 23, where the 65 degree limit stops them) project onto the wall's face.
    /// Row 14 (2.13 m) reads 0.18 m nearer than itself, past the 0.14 m tolerance, and the rows
    /// beyond it more: without the far surface they are hidden, as on build 5.1 (#160). With it
    /// they are the end of the space, and no ground row is hidden.
    @Test func groundPastACorridorsFarWallIsNotHidden() {
        let scene = standardScene(boxes: [Self.farWall(at: 2.0)])
        let pitch = Float.pi / 6
        let cameras = [Float(-0.3), 0, 0.3].map { portraitCamera(at: SIMD3($0, 1.4, 0.6), forward: SIMD3(0, -sin(pitch), cos(pitch))) }
        var plain = CoverageMap(wall: standardWall())
        var ended = Self.ended(at: 2.0)
        for camera in cameras {
            let depth = renderDepth(scene, from: camera)
            plain.observe(camera, trackingNormal: true, depth: depth)
            ended.observe(camera, trackingNormal: true, depth: depth)
        }
        let rows = plain.groundDepthRows
        #expect(plain.groundDepthHiddenRows(at: 0).contains { rows[$0] > 2.0 })
        for index in -2...1 {
            #expect(ended.groundDepthHiddenRows(at: index).isEmpty)
            #expect(SurfaceBand.allCases.allSatisfy { ended.level($0, index) != .hidden })
        }
        var planner = GuidancePlanner()
        for (time, camera) in cameras.enumerated() {
            if case .seeBehind = planner.update(coverage: ended, camera: camera, time: Double(time)).task {
                Issue.record("asked to see past the corridor's far wall")
            }
        }
    }

    /// From beyond the far wall, at (0, 1.4, 3.0) with the wall's back 1.3 m in front, the far
    /// wall stands between the camera and both bands: every sight line to the wall's face up to
    /// the walk's 4.5 ft, and to the ground band, crosses its back (z = 1.7) between 0.79 and
    /// 1.39 m up. Without the far surface both bands read hidden and the planner asks to see past
    /// it; with it, what the depth met is the far wall's back, 1.7 m out and past where the space
    /// ends (1.585 m, 1.6 rounded down to 0.1 ft), so nothing is hidden and nothing is asked.
    @Test func theFarWallSeenFromBeyondItIsNotSomethingToLookPast() {
        let scene = standardScene(boxes: [Self.farWall(at: 1.6)])
        let camera = portraitCamera(at: SIMD3(0, 1.4, 3.0), lookingAt: SIMD3(0, 0.6, 0))
        let depth = renderDepth(scene, from: camera)
        var plain = CoverageMap(wall: standardWall())
        plain.observe(camera, trackingNormal: true, depth: depth)
        var ended = Self.ended(at: 1.6)
        ended.observe(camera, trackingNormal: true, depth: depth)

        #expect(plain.level(.wall, 0) == .hidden)
        #expect(plain.level(.ground, 0) == .hidden)
        var before = GuidancePlanner()
        let task = before.update(coverage: plain, camera: camera, time: 0).task
        guard case .seeBehind = task else {
            Issue.record("expected seeBehind without the far surface, got \(task)")
            return
        }

        for index in -3...3 {
            #expect(SurfaceBand.allCases.allSatisfy { ended.level($0, index) != .hidden })
        }
        var after = GuidancePlanner()
        if case .seeBehind = after.update(coverage: ended, camera: camera, time: 0).task {
            Issue.record("asked to see past the far wall")
        }
    }

    /// #164: a wall with a parallel wall 1.8 m in front, walked 1.65 m out, and a server walk-out
    /// of 1.47 m (4.83 ft, D + r under the public rules) over s 1 to 3. The walk counts only past
    /// 1.47 m plus the tapped wall's error, 0.09 + 0.16 m per meter from the meter at a cell's far
    /// edge: 1.73 to 2.05 m over the span, all past the far wall (1.798 m, 1.8 rounded down to
    /// 0.1 ft) less the 0.3 m a homeowner stands behind the phone. The walk shows 1.65 m less the
    /// error, 1.07 to 1.39 m, so progress stays at 0; the planner says the line can't be walked
    /// and where the space ends, instead of holding the request there. With the far wall 4 m out,
    /// or none found, the line can be walked.
    @Test func aWalkOutLinePastTheFarWallIsUnreachable() throws {
        let planner = GapPlanner()
        let gap = GapPlan(band: .ground, span: 1...3, reason: .server, need: .walkOut(1.47))
        var map = Self.ended(at: 1.8)
        FacingTests.walk(&map, out: 1.65, from: -1, to: 4)
        #expect(planner.progress(of: gap, map) == 0)
        let block = try #require(planner.walkOutBlock(gap, map))
        #expect(nearlyEqual(block.spaceEnds, 59 * 0.03048))
        #expect(nearlyEqual(block.span, 1...3))
        #expect(nearlyEqual(block.needed, 1.47 + ServerErrorDefaults.wall(.tap, atS: 20 * 0.1524)))
        // Where the phone is, what counts: 1.47 m plus the error there, kept to the span.
        #expect(nearlyEqual(planner.walkOutNeeded(gap, map, atS: 2) ?? 0, 1.47 + ServerErrorDefaults.wall(.tap, atS: 2)))
        #expect(nearlyEqual(planner.walkOutNeeded(gap, map, atS: 5) ?? 0, 1.47 + ServerErrorDefaults.wall(.tap, atS: 3)))

        var open = CoverageMap(wall: standardWall())
        FacingTests.walk(&open, out: 1.65, from: -1, to: 4)
        #expect(planner.walkOutBlock(gap, open) == nil)
        var wide = Self.ended(at: 4)
        FacingTests.walk(&wide, out: 1.65, from: -1, to: 4)
        #expect(planner.walkOutBlock(gap, wide) == nil)
    }

    /// Something standing nearer the wall than where the space ends still hides it: the box of
    /// `CoverageDepthTests` (0.5 to 1.0 m out, 1.5 m tall) in a space that ends 2.5 m out, seen
    /// straight on from 2 m. What the depth met is the box's front, 1 m out, well short of the
    /// far surface.
    @Test func somethingNearerTheWallThanTheFarSurfaceStillHides() {
        let scene = standardScene(boxes: [CoverageDepthTests.box, Self.farWall(at: 2.5)])
        var map = Self.ended(at: 2.5)
        map.observe(wallCamera(s: 0), trackingNormal: true, depth: renderDepth(scene, from: wallCamera(s: 0)))
        #expect(map.level(.wall, 0) == .hidden)
    }
}
