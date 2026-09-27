import Foundation
import simd
import Testing
@testable import LiveDotsCore

struct GeometryTests {
    let depthIntrinsics = SIMD4<Float>(200, 200, 128, 96)

    @Test func `unprojection matches a hand-computed point`() {
        // Pixel (178, 46), centre (178.5, 46.5), 2 m: x = 50.5 * 2 / 200, y = -(-49.5) * 2 / 200.
        let camera = CameraMath.unproject(u: 178.5, v: 46.5, depth: 2, intrinsics: depthIntrinsics)
        #expect(simd_distance(camera, SIMD3(0.505, 0.495, -2)) < 1e-5)

        // The fixture's portrait pose: camera +x is world down, +y world right, +z world +z.
        let pose = simd_float4x4(columns: (SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1.5, 2.6, 1)))
        let world = CameraMath.transform(pose, camera)
        #expect(simd_distance(world, SIMD3(0.495, 0.995, 0.6)) < 1e-5)
    }

    @Test func `projection inverts unprojection`() throws {
        let p = CameraMath.unproject(u: 17.25, v: 150.5, depth: 3.3, intrinsics: depthIntrinsics)
        let pixel = try #require(CameraMath.project(p, intrinsics: depthIntrinsics))
        #expect(abs(pixel.u - 17.25) < 1e-3 && abs(pixel.v - 150.5) < 1e-3 && abs(pixel.depth - 3.3) < 1e-5)
        #expect(CameraMath.project(SIMD3(0, 0, 1), intrinsics: depthIntrinsics) == nil)
    }

    @Test func `the clip matrix lands where screenPoint does`() throws {
        let keyframe = Keyframe.fixtureStyle(x: 0.7)
        let projection = ScreenProjection(keyframe: keyframe, viewSize: SIMD2(390, 844))
        for world in [SIMD3<Float>(0.7, 1.5, 0), SIMD3(1.4, 0.2, 0.3), SIMD3(-0.1, 2.0, 0)] {
            let screen = try #require(projection.screenPoint(world))
            let clip = projection.clipMatrix * SIMD4(world, 1)
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            let fromClip = SIMD2((ndc.x + 1) / 2 * 390, (1 - ndc.y) / 2 * 844)
            #expect(simd_distance(screen, fromClip) < 1e-2)
        }
        // Straight ahead of a camera aimed square at the wall is the screen's centre.
        let centre = try #require(ScreenProjection(keyframe: .fixtureStyle(x: 0, pitch: 0), viewSize: SIMD2(390, 844))
            .screenPoint(SIMD3(0, 1.5, 0)))
        #expect(simd_distance(centre, SIMD2(195, 422)) < 1e-3)
    }

    @Test func `jitter is deterministic, in the tangent plane and within 30 percent of the cell`() {
        let normal = simd_normalize(SIMD3<Float>(0.2, 0.3, 1))
        var longest: Float = 0
        for x in Int32(-20)..<20 {
            for y in Int32(-10)..<10 {
                let key = VoxelKey(x, y, 3)
                let a = Jitter.offset(for: key, normal: normal, cellSize: 0.05)
                #expect(a == Jitter.offset(for: key, normal: normal, cellSize: 0.05))
                #expect(simd_length(a) <= 0.3 * 0.05 + 1e-6)
                #expect(abs(simd_dot(a, normal)) < 1e-5)
                longest = max(longest, simd_length(a))
            }
        }
        // The offsets fill the disc rather than collapsing to its centre.
        #expect(longest > 0.25 * 0.05)
    }

    @Test func `easing curve runs from 0 to 1 and front-loads the motion`() {
        let curve = CubicBezier.strongEaseOut
        #expect(curve(0) == 0 && curve(1) == 1 && curve(-1) == 0 && curve(2) == 1)
        var previous: Float = 0
        for step in 1...100 {
            let value = curve(Float(step) / 100)
            #expect(value >= previous)
            previous = value
        }
        #expect(curve(0.25) > 0.7)
    }
}

extension Keyframe {
    /// A keyframe like the fixture's walk: 640 x 480, phone in portrait at 1.5 m height and 2.6 m
    /// from the wall, pitched down by `pitch` degrees.
    static func fixtureStyle(x: Float, pitch: Float = 20, depth: DepthReference? = nil) -> Keyframe {
        let angle = pitch * .pi / 180
        let forward = SIMD3<Float>(0, -sin(angle), -cos(angle))
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let pose = simd_float4x4(columns: (SIMD4(-up, 0), SIMD4(right, 0), SIMD4(-forward, 0), SIMD4(x, 1.5, 2.6, 1)))
        return Keyframe(
            id: "k", imagePath: "k.jpg", width: 640, height: 480, intrinsics: SIMD4(500, 500, 320, 240),
            cameraToWorld: pose, timestamp: 0, depth: depth)
    }
}
