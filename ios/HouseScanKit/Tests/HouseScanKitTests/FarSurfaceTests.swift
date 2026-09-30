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

    /// A plane `out` in front of the wall over s in [-10, 10], its outline from `bottom` to `top`.
    static func plane(at out: Float, bottom: Float, top: Float) -> WallPlaneEvidence {
        WallPlaneEvidence(
            id: "far", kind: .wall, center: SIMD3(0, (bottom + top) / 2, out), normal: SIMD3(0, 0, -1),
            boundary: [SIMD3(-10, bottom, out), SIMD3(10, bottom, out), SIMD3(10, top, out), SIMD3(-10, top, out)])
    }

    /// Only a plane standing on the ground ends the space (review of #168). A plane 1.3 m tall
    /// but hanging from 1.2 m up, like an eave or an upper storey across a walkway, has open
    /// ground under it and doesn't end it. Neither does one whose outline stops 0.6 m up, past the
    /// 0.5 m allowed for a guessed ground and an outline not yet grown to the foot, nor one sunk
    /// into the ground up to 0.3 m, like the far side of a window well. A plane reaching down to
    /// 0.4 m does end it, 2 m out as the full-height plane does.
    @Test func onlyAPlaneStandingOnTheGroundEndsTheSpace() throws {
        let wall = standardWall()
        let full = FarSurface.spans(planes: [Self.plane(at: 2.0)], wall: wall, over: 0...1)
        #expect(full.count == 1)
        #expect(nearlyEqual(try #require(full.first).out, 65 * 0.03048))

        #expect(FarSurface.spans(planes: [Self.plane(at: 2.0, bottom: 1.2, top: 2.5)], wall: wall, over: 0...1).isEmpty)
        #expect(FarSurface.spans(planes: [Self.plane(at: 2.0, bottom: 0.6, top: 2.5)], wall: wall, over: 0...1).isEmpty)
        #expect(FarSurface.spans(planes: [Self.plane(at: 2.0, bottom: -2.0, top: 0.3)], wall: wall, over: 0...1).isEmpty)
        #expect(FarSurface.spans(planes: [Self.plane(at: 2.0, bottom: 0.4, top: 2.5)], wall: wall, over: 0...1) == full)
    }

    /// Standing on the ground is judged where each cell meets the plane, not from the lowest
    /// point of the whole outline. A plane 2 m out over s in [-10, 10] whose lower edge climbs
    /// 0.06 m per meter, from the ground at s = -10 to 1.2 m up at s = 10, is 0.5 m up at
    /// s = -1.667. It ends the space over -6 to the upper edge of cell -12 (s = -1.6764), whose
    /// sample at -1.7907 meets it 0.49 m up. From cell -11 on, both samples meet it more than
    /// 0.5 m up.
    @Test func aPlaneEndsTheSpaceOnlyWhereItStandsOnTheGround() throws {
        let plane = WallPlaneEvidence(
            id: "far", kind: .wall, center: SIMD3(0, 1.5, 2.0), normal: SIMD3(0, 0, -1),
            boundary: [SIMD3(-10, 0, 2.0), SIMD3(10, 1.2, 2.0), SIMD3(10, 2.5, 2.0), SIMD3(-10, 2.5, 2.0)])
        let spans = FarSurface.spans(planes: [plane], wall: standardWall(), over: -6...1)
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(nearlyEqual(span.out, 65 * 0.03048))
        #expect(nearlyEqual(span.span, -6...(-11 * 0.1524), 1e-3))
    }

    /// The ground is the wall's (`WallFrame.groundY`), not world y = 0. The full-height plane,
    /// from y = 0 to 2.5, stands 1 m above a ground at y = -1 and doesn't end the space there.
    /// Over a ground at y = 0.3 its outline reaches 0.3 m below the ground, and it does.
    @Test func aPlaneIsHeldToTheWallsGround() {
        let low = WallFrame(meter: SIMD3(0, 0.5, 0), outward: SIMD3(0, 0, 1), groundY: -1)!
        #expect(FarSurface.spans(planes: [Self.plane(at: 2.0)], wall: low, over: 0...1).isEmpty)
        let high = WallFrame(meter: SIMD3(0, 1.8, 0), outward: SIMD3(0, 0, 1), groundY: 0.3)!
        #expect(!FarSurface.spans(planes: [Self.plane(at: 2.0)], wall: high, over: 0...1).isEmpty)
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
        let cameras = Self.corridorCameras
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

    /// The cameras of `groundPastACorridorsFarWallIsNotHidden`.
    static let corridorCameras: [CameraFrame] = {
        let pitch = Float.pi / 6
        return [Float(-0.3), 0, 0.3].map { portraitCamera(at: SIMD3($0, 1.4, 0.6), forward: SIMD3(0, -sin(pitch), cos(pitch))) }
    }()

    /// What the map says about cells -3 to 3, to compare two maps built in different orders.
    struct Readout: Equatable {
        var levels: [SurfaceBand: [CoverageLevel]]
        var hiddenDepthRows: [Set<Int>]
        var groundDepths: [Float?]

        init(_ map: CoverageMap) {
            let cells = Array(-3...3)
            levels = Dictionary(uniqueKeysWithValues: SurfaceBand.allCases.map { band in (band, cells.map { map.level(band, $0) }) })
            hiddenDepthRows = cells.map(map.groundDepthHiddenRows(at:))
            groundDepths = cells.map(map.groundDepth(at:))
        }
    }

    /// ARKit finds the corridor's far wall after the depth frames (review of #168). The three
    /// corridor frames first mark the ground behind it hidden, as without a far surface. Once the
    /// wall is found, the map reads exactly as one that knew the far wall before the frames came:
    /// no ground row hidden and no request to see past the wall. When ARKit loses the plane
    /// again, the rows behind it are hidden once more, exactly as on a map that never knew it.
    @Test func aFarWallFoundAfterTheDepthFramesReclassifiesThem() {
        let scene = standardScene(boxes: [Self.farWall(at: 2.0)])
        var plain = CoverageMap(wall: standardWall())
        var live = Self.ended(at: 2.0)
        var late = CoverageMap(wall: standardWall())
        for camera in Self.corridorCameras {
            let depth = renderDepth(scene, from: camera)
            plain.observe(camera, trackingNormal: true, depth: depth)
            live.observe(camera, trackingNormal: true, depth: depth)
            late.observe(camera, trackingNormal: true, depth: depth)
        }
        let rows = late.groundDepthRows
        #expect(late.groundDepthHiddenRows(at: 0).contains { rows[$0] > 2.0 })
        #expect(Readout(late) == Readout(plain))

        let before = late.revision
        late.setFarSurface(live.farSurface)
        #expect(late.revision > before)
        #expect(Readout(late) == Readout(live))
        for index in -2...1 {
            #expect(late.groundDepthHiddenRows(at: index).isEmpty)
        }
        var planner = GuidancePlanner()
        for (time, camera) in Self.corridorCameras.enumerated() {
            if case .seeBehind = planner.update(coverage: late, camera: camera, time: Double(time)).task {
                Issue.record("asked to see past a far wall found after the depth frames")
            }
        }

        late.setFarSurface([])
        #expect(Readout(late) == Readout(plain))
    }

    /// The same for the bands, seen from beyond the far wall as in
    /// `theFarWallSeenFromBeyondItIsNotSomethingToLookPast`: hidden before the wall is found, not
    /// hidden once it is, and hidden again once it is lost. A cell the homeowner couldn't get to
    /// (wall cell 1, "I can't get there") and one they withdrew (cell 2, "Something's there")
    /// keep those answers through each replay.
    @Test func bandsBehindALateFarWallAreReclassifiedAndAnswersStay() {
        let scene = standardScene(boxes: [Self.farWall(at: 1.6)])
        let camera = portraitCamera(at: SIMD3(0, 1.4, 3.0), lookingAt: SIMD3(0, 0.6, 0))
        var map = CoverageMap(wall: standardWall())
        map.observe(camera, trackingNormal: true, depth: renderDepth(scene, from: camera))
        map.markSkipped(.wall, map.cellRange(1))
        map.withdrawClaims(over: map.cellRange(2))
        #expect(map.level(.wall, 0) == .hidden)
        #expect(map.level(.ground, 0) == .hidden)

        map.setFarSurface(Self.ended(at: 1.6).farSurface)
        for index in -3...3 {
            #expect(SurfaceBand.allCases.allSatisfy { map.level($0, index) != .hidden })
        }
        #expect(map.level(.wall, 1) == .skipped)
        #expect(map.level(.wall, 2) == .skipped)
        var planner = GuidancePlanner()
        if case .seeBehind = planner.update(coverage: map, camera: camera, time: 0).task {
            Issue.record("asked to see past a far wall found after the depth frame")
        }

        map.setFarSurface([])
        #expect(map.level(.wall, 0) == .hidden)
        #expect(map.level(.ground, 0) == .hidden)
        #expect(map.level(.wall, 1) == .skipped)
        #expect(map.level(.wall, 2) == .skipped)
    }

    /// Space past the far surface never earns credit from views without depth (review of the
    /// late-surface replay). From beyond the far wall of
    /// `theFarWallSeenFromBeyondItIsNotSomethingToLookPast`, two views without depth 0.4 m apart
    /// cover wall cell 0 on their own, since nothing but the wall is modelled in front of it. A
    /// depth frame from there then finds the far wall in the way. Without a far surface it hides
    /// the rows and takes back the unconfirmed sightings. With the far surface, whether it was
    /// found before the frames or after them, the rows are past the space. Their unconfirmed
    /// sightings go too, and the cell is neither covered nor hidden.
    @Test func viewsWithoutDepthEarnNoCreditPastTheFarSurface() {
        let scene = standardScene(boxes: [Self.farWall(at: 1.6)])
        let target = SIMD3<Float>(0, 0.6, 0)
        let blind = [portraitCamera(at: SIMD3(0, 1.4, 3.0), lookingAt: target), portraitCamera(at: SIMD3(0.4, 1.4, 3.0), lookingAt: target)]
        let checked = portraitCamera(at: SIMD3(0.2, 1.4, 3.0), lookingAt: target)
        func walk(_ map: inout CoverageMap) {
            for camera in blind { map.observe(camera, trackingNormal: true) }
            map.observe(checked, trackingNormal: true, depth: renderDepth(scene, from: checked))
        }
        var cameraOnly = CoverageMap(wall: standardWall())
        for camera in blind { cameraOnly.observe(camera, trackingNormal: true) }
        #expect(cameraOnly.level(.wall, 0) == .covered)

        var plain = CoverageMap(wall: standardWall())
        walk(&plain)
        #expect(plain.level(.wall, 0) == .hidden)
        var live = Self.ended(at: 1.6)
        walk(&live)
        var late = CoverageMap(wall: standardWall())
        walk(&late)
        late.setFarSurface(live.farSurface)
        for map in [live, late] {
            #expect(map.level(.wall, 0) != .covered)
            #expect(map.level(.wall, 0) != .hidden)
            #expect(map.wallSeenHeight(at: 0) == nil)
        }
        #expect(Readout(late) == Readout(live))
    }

    /// Something nearer the wall than a far surface found late still hides it: the box and far
    /// wall of `somethingNearerTheWallThanTheFarSurfaceStillHides`, the far surface set after the
    /// frame.
    @Test func somethingNearerTheWallThanALateFarSurfaceStillHides() {
        let scene = standardScene(boxes: [CoverageDepthTests.box, Self.farWall(at: 2.5)])
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true, depth: renderDepth(scene, from: wallCamera(s: 0)))
        map.setFarSurface(Self.ended(at: 2.5).farSurface)
        #expect(map.level(.wall, 0) == .hidden)
    }

    /// Without depth a far surface decides nothing, so setting one replays nothing and leaves the
    /// revision where it was.
    @Test func aFarSurfaceChangesNothingWithoutDepth() {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true)
        let revision = map.revision
        let readout = Readout(map)
        map.setFarSurface(Self.ended(at: 2.0).farSurface)
        #expect(map.revision == revision)
        #expect(Readout(map) == readout)
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
