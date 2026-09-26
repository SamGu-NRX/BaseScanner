import HouseScanKit
import simd
import Testing

/// Ground is judged from the first voxel past the facade's face, but scene.json reports it out
/// from the wall's line. The strip between is reported only where the facade shows at its foot.
@Suite struct Map3DFootTests {
    /// A straight wall along x with its face at z = `dz` and a box at its foot over x 1 to 2,
    /// walked like the bush scene. `dz` 0.05 puts the face mid-voxel, where a low box merges with
    /// the facade's voxels.
    static func map(box: (min: SIMD3<Float>, max: SIMD3<Float>)?, dz: Float = 0.05) -> (Map3D, WallFrame) {
        let wall = WallFrame(meter: SIMD3(0, 1.2, dz), outward: SIMD3(0, 0, 1), groundY: 0)!
        let boxes = box.map { [SyntheticScene.Box(min: $0.min + SIMD3(0, 0, dz), max: $0.max + SIMD3(0, 0, dz))] } ?? []
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, dz), b: SIMD2(6, dz))], boxes: boxes)
        var map = Map3D(frame: sceneFrame())
        for x in Swift.stride(from: Float(-3), through: 5, by: 0.3) {
            for target in [SIMD3(x, 1.0, dz), SIMD3(x, 0, 0.9 + dz)] {
                map.integrate(scene.depthFrame(from: lidarCamera(at: SIMD3(x, 1.4, 2.5 + dz), lookingAt: target)))
            }
        }
        return (map, wall)
    }

    static func cellsOverTheBox(_ map: Map3D) -> [Int] {
        map.cellIndices.filter { map.cellRange($0).lowerBound >= 1.0 && map.cellRange($0).upperBound <= 2.0 }
    }

    @Test func aLowObjectAtTheFootLeavesNoGroundReported() {
        // 0.1 m tall, 0.05 m out from the wall.
        let (map, wall) = Self.map(box: (SIMD3(1, 0, 0), SIMD3(2, 0.1, 0.05)))
        for index in Self.cellsOverTheBox(map) {
            #expect(map.groundReach(cell: index, along: wall) == nil, "ground claimed over the box at cell \(index)")
        }
    }

    @Test func aClearFootStillReportsTheGround() {
        let (map, wall) = Self.map(box: nil)
        for index in Self.cellsOverTheBox(map) {
            #expect((map.groundReach(cell: index, along: wall) ?? 0) >= 1.5, "clear ground at cell \(index) not reported")
        }
    }
}
