import HouseScanKit
import simd
import Testing

/// Relief counts as the facade only with positive evidence it is attached: a side face running
/// from its front back to the wall. The review of 2f17d67 found relief accepted wherever no free
/// voxel was seen behind it, so a tall freestanding object whose gap nobody saw passed.
@Suite struct Map3DAttachedReliefTests {
    static let wall = standardWall()

    /// A freestanding slab 3 m tall and 1 m wide, standing 0.3 to 0.4 m out over x 1 to 2, walked
    /// straight on: no view reaches the gap behind its middle, and none sees the wall there.
    @Test func aFreestandingSlabWithAnUnseenGapIsNotRelief() {
        let scene = SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))],
            boxes: [SyntheticScene.Box(min: SIMD3(1, 0, 0.3), max: SIMD3(2, 3, 0.4))])
        var map = Map3D(frame: sceneFrame())
        for camera in bushWalk() { map.integrate(scene.depthFrame(from: camera)) }
        let coverage = map.coverage(along: Self.wall)
        for index in map.cellIndices where map.cellRange(index).lowerBound >= 1.2 && map.cellRange(index).upperBound <= 1.8 {
            #expect(map.wallHeight(cell: index, along: Self.wall) == nil, "wall behind the slab at cell \(index) seen to \(map.wallHeight(cell: index, along: Self.wall) ?? -1)")
            let middle = (map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2
            #expect(!coverage.wall.contains { $0.contains(middle) }, "wall behind the slab claimed at cell \(index)")
        }
    }
}
