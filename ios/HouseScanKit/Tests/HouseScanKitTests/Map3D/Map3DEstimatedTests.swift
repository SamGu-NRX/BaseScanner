import Foundation
import HouseScanKit
import simd
import Testing

// Estimated (monocular) depth at the worst noise Map3D's rule lets mark a surface: Gaussian, 7 cm
// per pixel, reported honestly as each pixel's sigma. Every coverage claim is checked against
// exact ray casting of the scene from the same cameras. A monocular model's error is not this
// (it is smooth and regional); independent noise at the limit is the case a per-ray rule alone
// lets through, because one ray in forty lands two deviations too far and a wall voxel behind an
// occluder is never passed through, so nothing takes such a stray hit back.

/// Whether any point within a voxel (0.1 m) of `point` along `u` and `v` on its surface is truly
/// visible from one of `cameras`: the resolution coverage is judged at.
func nearlyVisible(_ scene: SyntheticScene, _ cameras: [CameraFrame], _ point: SIMD3<Float>, normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) -> Bool {
    for du: Float in [-0.1, 0, 0.1] {
        for dv: Float in [-0.1, 0, 0.1] {
            let p = point + u * du + v * dv + normal * 1e-3
            if cameras.contains(where: { scene.isVisible(p, normal: normal, from: $0) }) { return true }
        }
    }
    return false
}

@Suite struct Map3DEstimatedTests {
    static let sigma: Float = 0.07
    static let wall = standardWall()

    /// A wall along x from -5 to 6 with a box 3.5 m wide (x 1 to 4.5) and 1 m tall whose front
    /// face stands `offset` out: the nearest surface in front of the wall there. It is 0.3 m deep,
    /// or less where that would reach within 5 cm of the wall.
    static func occluderScene(offset: Float) -> SyntheticScene {
        SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))],
            boxes: [SyntheticScene.Box(min: SIMD3(1, 0, max(0.05, offset - 0.3)), max: SIMD3(4.5, 1, offset))])
    }

    /// Every 0.5 m from x = -1.5 to 4.5, the phone 1 m from the box's front, aimed at the wall
    /// low and high, straight on and about 35 degrees to either side.
    static func walk(offset: Float) -> [CameraFrame] {
        let z = offset + 1
        return Swift.stride(from: Float(-1.5), through: 4.5, by: 0.5).flatMap { x in
            [Float(0), -0.75 * z, 0.75 * z].flatMap { dx in
                [Float(0.5), 1.5].map { y in lidarCamera(at: SIMD3(x, 1.2, z), lookingAt: SIMD3(x + dx, y, 0)) }
            }
        }
    }

    static func map(_ scene: SyntheticScene, _ cameras: [CameraFrame], config: Map3DConfig = Map3DConfig()) -> Map3D {
        var map = Map3D(frame: sceneFrame(), config: config)
        for (index, camera) in cameras.enumerated() { map.integrate(scene.estimatedFrame(from: camera, sigma: sigma, seed: UInt64(index + 1))) }
        return map
    }

    static func covers(_ map: Map3D, _ spans: [ClosedRange<Float>], _ index: Int) -> Bool {
        let middle = (map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2
        return spans.contains { $0.contains(middle) }
    }

    static func wallSamples(_ map: Map3D, _ index: Int) -> [SIMD3<Float>] {
        let range = map.cellRange(index)
        let width = range.upperBound - range.lowerBound
        let heights = Array(Swift.stride(from: Float(0.1), to: 1.9812, by: 0.2)) + [1.9812]
        return [0.25, 0.75].flatMap { f in heights.map { SIMD3(range.lowerBound + f * width, $0, 0) } }
    }

    /// Cells with a wall sample no camera saw, even within a voxel.
    static func hiddenCells(_ map: Map3D, _ scene: SyntheticScene, _ cameras: [CameraFrame]) -> [Int] {
        map.cellIndices.filter { index in
            wallSamples(map, index).contains { !nearlyVisible(scene, cameras, $0, normal: SIMD3(0, 0, 1), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0)) }
        }
    }

    @Test(arguments: [Float(0.2), 0.5, 1.0])
    func wallHiddenBehindAnOccluderIsNeverClaimed(offset: Float) {
        let scene = Self.occluderScene(offset: offset)
        let cameras = Self.walk(offset: offset)
        let map = Self.map(scene, cameras)
        let coverage = map.coverage(along: Self.wall)
        let hidden = Self.hiddenCells(map, scene, cameras)
        #expect(hidden.contains { abs(map.cellRange($0).lowerBound - 2.75) < 0.3 }, "no hidden cell behind the box: \(hidden)")
        let claimed = hidden.filter { Self.covers(map, coverage.wall, $0) }
        #expect(claimed.isEmpty, "hidden cells claimed seen: \(claimed.map { map.cellRange($0) })")
        // Height too: a wall span with a height claims the face seen up to it.
        for span in coverage.wallHeight {
            for index in map.cellIndices where span.span.contains((map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2) {
                let range = map.cellRange(index)
                for f: Float in [0.25, 0.75] {
                    for height in Swift.stride(from: Float(0.1), through: span.out, by: 0.1) {
                        let p = SIMD3(range.lowerBound + f * (range.upperBound - range.lowerBound), height, 0)
                        #expect(nearlyVisible(scene, cameras, p, normal: SIMD3(0, 0, 1), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0)), "cell \(index) seen to \(span.out) but not at \(height)")
                    }
                }
            }
        }
    }

    /// Estimated evidence never certifies coverage (`VoxelGrid.isWellSeenSurface`, since the
    /// review of 2f17d67), so the same walks claim not even the wall away from the box. The
    /// tests here then hold vacuously; they stay to catch estimated claims coming back.
    @Test(arguments: [Float(0.2), 0.5, 1.0])
    func estimatedDepthClaimsNotEvenTheClearWall(offset: Float) {
        let scene = Self.occluderScene(offset: offset)
        let map = Self.map(scene, Self.walk(offset: offset))
        let coverage = map.coverage(along: Self.wall)
        let clear = map.cellIndices.filter { let r = map.cellRange($0); return r.lowerBound >= -0.8 && r.upperBound <= 0.4 }
        let seen = clear.filter { Self.covers(map, coverage.wall, $0) }
        #expect(seen.isEmpty, "clear cells claimed from estimated depth: \(seen.count) of \(clear.count)")
    }

    @Test(arguments: [Float(0.2), 0.5, 1.0])
    func groundFacingAndOverheadNeverClaimWhatNoCameraSaw(offset: Float) {
        let scene = Self.occluderScene(offset: offset)
        let cameras = Self.walk(offset: offset)
        let map = Self.map(scene, cameras)
        let coverage = map.coverage(along: Self.wall)
        for span in coverage.ground {
            for index in map.cellIndices where span.span.contains((map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2) {
                let range = map.cellRange(index)
                for out in Swift.stride(from: Float(0.1), through: span.out, by: 0.1524) {
                    let point = SIMD3(range.lowerBound + 0.5 * (range.upperBound - range.lowerBound), 0, out)
                    #expect(nearlyVisible(scene, cameras, point, normal: SIMD3(0, 1, 0), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1)), "ground \(point) claimed seen, reach \(span.out) over \(span.span)")
                }
            }
        }
        let box = scene.boxes[0]
        for index in map.cellIndices {
            let range = map.cellRange(index)
            guard range.upperBound > box.min.x, range.lowerBound < box.max.x else { continue }
            #expect((map.facingReach(cell: index, along: Self.wall) ?? 0) < box.max.z, "facing at cell \(index) passes the box")
            if box.min.z < map.config.overheadDepth { #expect(map.overheadReach(cell: index, along: Self.wall) == nil, "overhead at cell \(index) over the box") }
        }
    }

    /// The bush scene (0.4 to 1.0 m out, 0.9 m tall) walked 1 m from the bush's front.
    @Test func wallBehindTheBushIsNeverClaimed() {
        let scene = bushScene()
        let cameras = Self.walk(offset: 1.0)
        let map = Self.map(scene, cameras)
        let coverage = map.coverage(along: Self.wall)
        let hidden = Self.hiddenCells(map, scene, cameras)
        #expect(!hidden.isEmpty)
        let claimed = hidden.filter { Self.covers(map, coverage.wall, $0) }
        #expect(claimed.isEmpty, "hidden cells claimed seen: \(claimed.map { map.cellRange($0) })")
    }

    /// Pilasters 0.36 m proud: every claimed wall sample has a truly visible facade face, wall
    /// or pilaster, straight out from it. The wall beside a pilaster that the pilaster hides
    /// from the oblique views must not be claimed from strays.
    @Test func pilasterFacadeClaimsOnlyVisibleFaces() {
        let scene = pilasterScene()
        let cameras = Swift.stride(from: Float(-4), through: 6, by: 0.5).flatMap { x in
            [Float(0), -1.2, 1.2].flatMap { dx in [Float(0.5), 1.5].map { y in lidarCamera(at: SIMD3(x, 1.2, 1.6), lookingAt: SIMD3(x + dx, y, 0)) } }
        }
        let map = Self.map(scene, cameras)
        let coverage = map.coverage(along: Self.wall)
        var checked = 0
        for index in map.cellIndices where Self.covers(map, coverage.wall, index) {
            let range = map.cellRange(index)
            for s in [range.lowerBound + 0.03, range.upperBound - 0.03] {
                for height: Float in [0.3, 1.0, 1.9] {
                    checked += 1
                    let visible = [Float(0), 0.36].contains { out in
                        [Float(-0.1), 0, 0.1].contains { ds in
                            let p = SIMD3(s + ds, height, out + 1e-3)
                            return scene.intersect(origin: p + SIMD3(0, 0, 0.01), direction: SIMD3(0, 0, -1)).map { $0.t < 0.02 } == true
                                && cameras.contains { scene.isVisible(p, normal: SIMD3(0, 0, 1), from: $0) }
                        }
                    }
                    #expect(visible, "cell \(index) s \(s) h \(height) claimed without a visible face")
                }
            }
        }
        // Estimated evidence certifies nothing, so nothing is claimed at all.
        #expect(checked == 0, "\(checked) wall samples claimed from estimated depth")
    }
}
