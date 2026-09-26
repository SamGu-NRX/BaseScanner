import Foundation
import HouseScanKit
import simd
import Testing

// Walls measured from depth frames of non-straight houses, with up to 2 cm of depth error on
// every pixel. Tolerances: every piece's direction within 3 degrees and its length within 0.2 m
// of the truth, every corner within 0.15 m. A voxel is 0.1 m, so a piece's end is placed to
// within half a voxel plus fitting error.
@Suite struct Map3DWallTests {
    static let angleTolerance: Float = 3 * .pi / 180
    static let lengthTolerance: Float = 0.2
    static let cornerTolerance: Float = 0.15

    /// Cameras 2.2 m in front of each piece every 0.4 m along it, aimed at the wall 1 m up,
    /// plus one on the bisector of each corner looking into it.
    static func walk(_ points: [SIMD2<Float>]) -> [CameraFrame] {
        var cameras: [CameraFrame] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let along = simd_normalize(b - a)
            let outward = SIMD2(-along.y, along.x)
            let length = simd_distance(a, b)
            for t in Swift.stride(from: Float(0.2), through: length - 0.2, by: 0.4) {
                let foot = a + along * t
                let eye = foot + outward * 2.2
                cameras.append(lidarCamera(at: SIMD3(eye.x, 1.4, eye.y), lookingAt: SIMD3(foot.x, 1, foot.y)))
            }
        }
        for index in points.indices.dropFirst().dropLast() {
            let before = simd_normalize(points[index] - points[index - 1])
            let after = simd_normalize(points[index + 1] - points[index])
            let outward = simd_normalize(SIMD2(-before.y, before.x) + SIMD2(-after.y, after.x))
            let eye = points[index] + outward * 2.5
            cameras.append(lidarCamera(at: SIMD3(eye.x, 1.4, eye.y), lookingAt: SIMD3(points[index].x, 1, points[index].y)))
        }
        return cameras
    }

    static func measure(_ points: [SIMD2<Float>]) -> MeasuredWallChain? {
        let scene = SyntheticScene(walls: SyntheticScene.chain(points))
        var map = Map3D(frame: sceneFrame())
        for (index, camera) in walk(points).enumerated() {
            map.integrate(scene.depthFrame(from: camera, noise: 0.02, seed: UInt64(index)))
        }
        return map.measuredWalls()
    }

    static func check(_ chain: MeasuredWallChain?, against truth: [SIMD2<Float>], meterPiece: Int) {
        guard let chain else {
            Issue.record("no chain measured")
            return
        }
        #expect(chain.walls.count == truth.count - 1, "measured \(chain.vertices) for \(truth)")
        #expect(chain.meterIndex == meterPiece)
        guard chain.walls.count == truth.count - 1 else { return }
        for (index, wall) in chain.walls.enumerated() {
            let a = truth[index]
            let b = truth[index + 1]
            let angle = acos(min(1, simd_dot(wall.along, simd_normalize(b - a))))
            #expect(angle <= angleTolerance, "piece \(index) is \(angle * 180 / .pi) degrees off")
            #expect(abs(wall.length - simd_distance(a, b)) <= lengthTolerance, "piece \(index) is \(wall.length) m, truth \(simd_distance(a, b))")
            #expect(wall.source == .mesh)
            // Outward is the truth's direction turned 90 degrees, facing where the cameras were.
            let outward = simd_normalize(SIMD2(-(b - a).y, (b - a).x))
            #expect(simd_dot(wall.outward, outward) > 0.99)
        }
        for (measured, point) in zip(chain.vertices.dropFirst().dropLast(), truth.dropFirst().dropLast()) {
            #expect(simd_distance(measured, point) <= cornerTolerance, "corner \(measured), truth \(point)")
        }
    }

    /// An L: a wing juts out left of the meter's wall (an inside corner at (-3, 0), an outside
    /// one at (-3, 2.5)) and the house turns away at an outside corner at (4, 0).
    @Test func lShapedHouse() {
        let truth: [SIMD2<Float>] = [SIMD2(-4.5, 2.5), SIMD2(-3, 2.5), SIMD2(-3, 0), SIMD2(4, 0), SIMD2(4, -3)]
        Self.check(Self.measure(truth), against: truth, meterPiece: 2)
    }

    /// A bay window right of the meter: sides at 45 degrees, 0.99 m long.
    @Test func angledBay() {
        let truth: [SIMD2<Float>] = [SIMD2(-2, 0), SIMD2(1.5, 0), SIMD2(2.2, 0.7), SIMD2(4.2, 0.7), SIMD2(4.9, 0), SIMD2(7, 0)]
        Self.check(Self.measure(truth), against: truth, meterPiece: 0)
    }

    @Test func chainBecomesAWallFrameWithTheSameCorners() throws {
        let truth: [SIMD2<Float>] = [SIMD2(-4.5, 2.5), SIMD2(-3, 2.5), SIMD2(-3, 0), SIMD2(4, 0), SIMD2(4, -3)]
        let chain = try #require(Self.measure(truth))
        let frame = sceneFrame()
        let wall = try #require(chain.wallFrame(meter: SIMD3(0, 1.5, 0), groundY: 0, frame: frame))
        #expect(wall.segments.count == chain.walls.count)
        #expect(wall.meterSegmentIndex == chain.meterIndex)
        // Each measured corner sits where the wall frame puts it.
        let s: [Float] = [-5.5, -3, 4]
        for (corner, point) in zip(s, [truth[1], truth[2], truth[3]]) {
            let world = wall.world(s: corner, height: 0, out: 0)
            #expect(simd_distance(SIMD2(world.x, world.z), point) <= 2 * Self.cornerTolerance, "s \(corner) at \(world), truth \(point)")
        }
    }

    @Test func aBushIsNotAWall() {
        let scene = bushScene()
        var map = Map3D(frame: sceneFrame())
        for camera in bushWalk() { map.integrate(scene.depthFrame(from: camera)) }
        let chain = map.measuredWalls()
        #expect(chain?.walls.count == 1, "\(chain?.vertices ?? [])")
        #expect(map.wallPieces().allSatisfy { abs($0.start.y) < 0.15 && abs($0.end.y) < 0.15 }, "\(map.wallPieces())")
    }
}
