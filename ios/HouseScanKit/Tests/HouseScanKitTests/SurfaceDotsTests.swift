import HouseScanKit
import simd
import Testing

// The LiDAR dot field on the standard wall (face z = 0, ground y = 0), with depth rendered from
// the scene mesh at 128 x 96 (`renderDepth`, fx = fy = 100): at 2 m a pixel is 2 cm, so every
// sampled pixel (stride 2) lands within one 5 cm voxel of the next.
@Suite struct SurfaceDotsTests {
    /// A box standing in front of the wall: s in [-0.5, 0.5], 0.5 to 1.0 m out, 1.5 m tall.
    static let box = (SIMD3<Float>(-0.5, 0, 0.5), SIMD3<Float>(0.5, 1.5, 1.0))

    static func field(_ scene: TriangleMesh, cameras: [CameraFrame], config: SurfaceDotConfig = SurfaceDotConfig()) -> SurfaceDots {
        var field = SurfaceDots(config: config)
        for camera in cameras { field.integrate(camera: camera, depth: renderDepth(scene, from: camera)) }
        return field
    }

    /// Level at 1.5 m, 2 m from the wall: the view spans heights 0.22 to 2.78 m, all wall, so no
    /// neighbour is ever seen empty and nothing creases. Every dot is flat, on the wall, one per
    /// 2 x 2 x 2 group (four wall voxels share a group), at 45% for one view.
    @Test func aPlainWallGivesSparseFlatDotsOnTheWall() {
        let camera = makeCamera(at: SIMD3(0, 1.5, 2.0), forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))
        let field = Self.field(standardScene(), cameras: [camera])
        let dots = field.dots(near: camera.position, wall: standardWall())
        #expect(!dots.isEmpty)
        #expect(dots.allSatisfy { !$0.isEdge })
        #expect(dots.allSatisfy { abs($0.position.z) < 0.02 })
        #expect(dots.allSatisfy { $0.opacity == 0.45 && !$0.onOccluder })
        #expect(dots.count * 3 <= field.voxelCount)
    }

    /// Pitched down at the foot of the wall: the wall's and the ground's normals differ by 90
    /// degrees, so the voxels along the corner are edges, and only they are.
    @Test func theWallToGroundCornerIsAnEdge() {
        let camera = portraitCamera(at: SIMD3(0, 1.0, 2.0), forward: forwardFacingWall(pitchedDown: 30))
        let dots = Self.field(standardScene(), cameras: [camera]).dots(near: camera.position, wall: standardWall())
        let edges = dots.filter(\.isEdge)
        #expect(edges.count > 20)
        // The corner line is y = 0, z = 0; a corner voxel's centre is within one voxel diagonal,
        // plus its jitter.
        #expect(edges.allSatisfy { simd_length(SIMD2($0.position.y, $0.position.z)) < 0.1 })
    }

    /// The box's front stands 1 m out: its dots are on an occluder, the wall's are not, and its
    /// silhouette against the wall behind is a boundary edge.
    @Test func aBoxInFrontOfTheWallIsAnOccluderWithAnOutline() {
        let camera = wallCamera(s: 0)
        let dots = Self.field(standardScene(boxes: [Self.box]), cameras: [camera]).dots(near: camera.position, wall: standardWall())
        let onBox = dots.filter { $0.position.z > 0.9 && $0.position.y > 0.2 }
        let onWall = dots.filter { abs($0.position.z) < 0.05 && $0.position.y > 0.2 }
        #expect(!onBox.isEmpty && !onWall.isEmpty)
        #expect(onBox.allSatisfy { $0.onOccluder })
        #expect(onWall.allSatisfy { !$0.onOccluder })
        let sides = onBox.filter { $0.isEdge && abs(abs($0.position.x) - 0.5) < 0.1 }
        #expect(!sides.isEmpty)
    }

    /// Opacity follows the distinct views: two positions 30 degrees apart as seen from the wall
    /// give 60% where both saw it.
    @Test func aSecondViewRaisesOpacity() {
        let target = SIMD3<Float>(0, 1.0, 0)
        let first = portraitCamera(at: SIMD3(0, 1.2, 2.0), lookingAt: target)
        let second = portraitCamera(at: SIMD3(2.0 * tan(30 * .pi / 180), 1.2, 2.0), lookingAt: target)
        let dots = Self.field(standardScene(), cameras: [first, second]).dots(near: second.position, wall: standardWall())
        #expect(dots.contains { $0.views == 2 && $0.opacity == 0.6 })
        #expect(dots.allSatisfy { $0.views <= 2 })
    }

    /// Low-confidence readings and readings past 5 m make no dots.
    @Test func unconfidentOrFarDepthMakesNothing() {
        let camera = wallCamera(s: 0)
        var field = SurfaceDots()
        field.integrate(camera: camera, depth: uniformDepth(2000, confidence: 0))
        field.integrate(camera: camera, depth: uniformDepth(5500))
        #expect(field.isEmpty)
    }

    /// Past `maxVoxels` the field sheds the far voxels, so a long walk never grows it past the
    /// cap; past `maxDots`, flat dots go before any edge.
    @Test func dotsAndVoxelsStayUnderTheirCaps() {
        var config = SurfaceDotConfig()
        config.maxVoxels = 800
        var capped = config
        capped.maxDots = 20
        var field = SurfaceDots(config: config)
        var small = SurfaceDots(config: capped)
        let scene = standardScene()
        var last = portraitCamera(at: SIMD3(-4, 1.0, 2.0), forward: forwardFacingWall(pitchedDown: 30))
        for step in 0..<17 {
            last = portraitCamera(at: SIMD3(-4 + Float(step) * 0.5, 1.0, 2.0), forward: forwardFacingWall(pitchedDown: 30))
            let depth = renderDepth(scene, from: last)
            field.integrate(camera: last, depth: depth)
            small.integrate(camera: last, depth: depth)
            #expect(field.voxelCount <= config.maxVoxels)
        }
        let all = field.dots(near: last.position, wall: standardWall())
        let dots = small.dots(near: last.position, wall: standardWall())
        #expect(all.count > 20)
        #expect(dots.count == 20)
        #expect(dots.filter { $0.isEdge }.count == min(20, all.filter { $0.isEdge }.count))
    }

    /// An anchor correction moves the field with the wall, exactly, however small the steps:
    /// ten 2.1 cm corrections, each under half a voxel, move every dot 21 cm, and a turn turns
    /// them about the vertical.
    @Test func correctionsMoveTheDotsExactly() {
        let camera = wallCamera(s: 0)
        var field = Self.field(standardScene(), cameras: [camera])
        let before = field.dots(near: camera.position, wall: nil)
        for _ in 0..<10 { field.apply(YawCorrection(yaw: 0, translation: SIMD3(0.021, 0, 0))) }
        let turn = YawCorrection(yaw: 0.1, translation: .zero)
        field.apply(turn)
        let after = field.dots(near: turn.point(camera.position + SIMD3(0.21, 0, 0)), wall: nil)
        #expect(after.count == before.count)
        for (a, b) in zip(before, after) {
            #expect(a.id == b.id)
            #expect(nearlyEqual(b.position, turn.point(a.position + SIMD3(0.21, 0, 0)), 1e-4))
        }
    }

    /// The same keyframes give the same dots: jitter, thinning and order come from stable hashes.
    @Test func theFieldIsDeterministic() {
        let cameras = [wallCamera(s: 0), wallCamera(s: 0.5)]
        let a = Self.field(standardScene(boxes: [Self.box]), cameras: cameras).dots(near: cameras[1].position, wall: standardWall())
        let b = Self.field(standardScene(boxes: [Self.box]), cameras: cameras).dots(near: cameras[1].position, wall: standardWall())
        #expect(a == b)
    }
}
