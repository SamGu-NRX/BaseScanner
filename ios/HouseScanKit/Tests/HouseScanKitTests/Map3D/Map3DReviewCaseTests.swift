import Foundation
import HouseScanKit
import simd
import Testing

// Cases where coverage could claim more than a ray reached: something standing just in front of
// the wall, a strip of ground with no usable depth, an obstacle a phone without LiDAR tracked no
// points on. And a chain whose meter sits at the very end of its piece.
@Suite struct Map3DReviewCaseTests {
    static let wall = standardWall()

    static func covers(_ map: Map3D, _ spans: [ClosedRange<Float>], _ index: Int) -> Bool {
        let middle = (map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2
        return spans.contains { $0.contains(middle) }
    }

    static func cells(_ map: Map3D, from low: Float, to high: Float) -> [Int] {
        map.cellIndices.filter { map.cellRange($0).lowerBound >= low && map.cellRange($0).upperBound <= high }
    }

    /// A box 1.2 m tall standing 5 to 30 cm out from the wall hides the wall behind it; its
    /// front is not the wall face.
    @Test func aBoxAgainstTheWallHidesTheWall() {
        let scene = SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))],
            boxes: [SyntheticScene.Box(min: SIMD3(1, 0, 0.05), max: SIMD3(2, 1.2, 0.3))])
        var map = Map3D(frame: sceneFrame())
        for (index, camera) in bushWalk().enumerated() { map.integrate(scene.depthFrame(from: camera, noise: 0.02, seed: UInt64(index))) }
        let coverage = map.coverage(along: Self.wall)
        for index in Self.cells(map, from: 1.2, to: 1.8) {
            #expect(!Self.covers(map, coverage.wall, index), "cell \(index) behind the box claimed seen")
            #expect(map.facingReach(cell: index, along: Self.wall) == nil)
            #expect(map.overheadReach(cell: index, along: Self.wall) == nil)
        }
        #expect(Self.cells(map, from: -2, to: 0.6).allSatisfy { Self.covers(map, coverage.wall, $0) })
    }

    /// Ground 0.35 to 0.45 m out comes back low confidence (a dark hose, a drain): ground is
    /// never claimed across it.
    @Test func groundReachStopsAtGroundWithNoDepth() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))])
        var map = Map3D(frame: sceneFrame())
        for camera in bushWalk() {
            let frame = scene.depthFrame(from: camera)
            var confidence = [UInt8](repeating: 2, count: frame.depth.count)
            for v in 0..<frame.height {
                for u in 0..<frame.width {
                    let ray = camera.ray(throughPixel: SIMD2(Float(u) + 0.5, Float(v) + 0.5))
                    guard ray.direction.y < 0 else { continue }
                    let ground = ray.at(-ray.origin.y / ray.direction.y)
                    let t = frame.depth[v * frame.width + u] / simd_dot(ray.direction, camera.forward)
                    if ground.z >= 0.35, ground.z <= 0.45, abs(t - simd_distance(ground, ray.origin)) < 0.01 { confidence[v * frame.width + u] = 0 }
                }
            }
            map.integrate(DepthFrame(camera: camera, width: frame.width, height: frame.height, depth: frame.depth, kind: .lidar(confidence: confidence)))
        }
        for index in Self.cells(map, from: -2, to: 4) {
            let reach = map.groundReach(cell: index, along: Self.wall) ?? 0
            #expect(reach < 0.35, "cell \(index) reaches \(reach) across unmeasured ground")
        }
    }

    /// Without LiDAR, a box with no feature points on it: the planes behind it are not taken as
    /// seen, and its volume is not taken as free.
    @Test func withoutLidarAnUntrackedBoxIsNotSeenThrough() {
        let scene = bushScene()
        var map = Map3D(frame: sceneFrame())
        map.update(PlaneObservation(
            id: UUID(), worldFromPlane: simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1)),
            alignment: .vertical, center: SIMD2(0.5, -1.5), width: 11, length: 3))
        map.update(PlaneObservation(
            id: UUID(), worldFromPlane: matrix_identity_float4x4, alignment: .horizontal, center: SIMD2(0.5, 3), width: 13, length: 6))
        let bush = scene.boxes[0]
        for camera in bushWalk() {
            let color = CameraFrame(cameraToWorld: camera.cameraToWorld, intrinsics: SIMD4(1450, 1450, 960, 720), imageSize: SIMD2(1920, 1440))
            let points = scene.featurePoints(from: color, columns: 32, rows: 24).filter { p in
                !(p.x >= bush.min.x - 1e-3 && p.x <= bush.max.x + 1e-3 && p.z >= bush.min.z - 1e-3 && p.z <= bush.max.z + 1e-3 && p.y <= bush.max.y + 1e-3)
            }
            map.integrate(FeatureFrame(camera: color, points: points))
        }
        let coverage = map.coverage(along: Self.wall)
        for index in Self.cells(map, from: 1.1, to: 1.9) {
            #expect(!Self.covers(map, coverage.wall, index))
            #expect(map.groundReach(cell: index, along: Self.wall) == nil)
            #expect((map.facingReach(cell: index, along: Self.wall) ?? 0) < bush.min.z)
        }
        #expect(map.state(at: SIMD3(1.5, 0.5, 0.7)) != .free)
    }

    /// The meter projects past the end of its piece, where the next piece starts round a
    /// corner: the wall frame still builds, with the corner just past the meter.
    @Test func meterAtThePieceEndStillMakesAWallFrame() throws {
        let truth: [SIMD2<Float>] = [SIMD2(-3, 0), SIMD2(0, 0), SIMD2(0, -3)]
        let scene = SyntheticScene(walls: SyntheticScene.chain(truth))
        var map = Map3D(frame: sceneFrame())
        for camera in Map3DWallTests.walk(truth) { map.integrate(scene.depthFrame(from: camera)) }
        let chain = try #require(map.measuredWalls())
        #expect(chain.walls.count == 2)
        for meter in [SIMD3<Float>(0, 1.5, 0), SIMD3(0.05, 1.5, 0.05), SIMD3(-0.05, 1.5, 0.05)] {
            let frame = try #require(chain.wallFrame(meter: meter, groundY: 0, frame: sceneFrame()))
            #expect(frame.segments.count == 2)
        }
    }
}
