import HouseScanKit
import simd
import Testing

// Where the space in front of the wall ends (#160), on the standard wall (face z = 0, s = x,
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
