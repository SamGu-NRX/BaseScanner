@testable import HouseScanKit
import Foundation
import simd
import Testing

/// Estimated (monocular) depth never certifies coverage: the review of 2f17d67 made it claim
/// walls hidden behind occluders several ways (a plane scaling a model into the wall, regional
/// bias, a hit share taken where few rays could reach, an adjusted view angle dropped). It still
/// tells seen from unknown for the fog of war and the next view.
@Suite struct Map3DEstimatedEvidenceTests {
    static let wall = standardWall()
    static let cameras = bushWalk()

    /// A depth frame of `scene` from `camera` reported as estimated, with a small honest sigma:
    /// the best case an estimate can be.
    static func estimated(_ scene: SyntheticScene, _ camera: CameraFrame) -> DepthFrame {
        let exact = scene.depthFrame(from: camera)
        return DepthFrame(
            camera: camera, width: exact.width, height: exact.height, depth: exact.depth,
            kind: .estimated(sigma: [Float](repeating: 0.02, count: exact.depth.count)))
    }

    static func claims(_ coverage: Map3DCoverage) -> Bool {
        !coverage.wall.isEmpty || !coverage.wallHeight.isEmpty || !coverage.ground.isEmpty || !coverage.facing.isEmpty || !coverage.overhead.isEmpty
    }

    @Test func estimatedDepthAloneClaimsNothingButClearsFog() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))])
        var map = Map3D(frame: sceneFrame())
        let before = map.fogOfWar(along: Self.wall).seen
        for camera in Self.cameras { map.integrate(Self.estimated(scene, camera)) }
        let coverage = map.coverage(along: Self.wall)
        #expect(!Self.claims(coverage), "estimated depth claimed \(coverage)")
        #expect(map.cellIndices.allSatisfy { map.facadeOffset(cell: $0, along: Self.wall) == nil })
        #expect(map.fogOfWar(along: Self.wall).seen > before + 0.2)
    }

    /// LiDAR shows the wall behind the bush hidden; a model that sees straight through the bush
    /// (regional bias, as the review's probes found) adds nothing to what LiDAR claims, and never
    /// clears the space the bush fills.
    @Test func estimatedFramesAfterLidarClaimNothingLidarDidNot() {
        let bush = bushScene()
        let throughTheBush = SyntheticScene(walls: bush.walls)
        var map = Map3D(frame: sceneFrame())
        for camera in Self.cameras { map.integrate(bush.depthFrame(from: camera)) }
        let lidar = map.coverage(along: Self.wall)
        for camera in Self.cameras { map.integrate(Self.estimated(throughTheBush, camera)) }
        let mixed = map.coverage(along: Self.wall)
        func within(_ spans: [ObservedSpan], _ claimed: [ObservedSpan]) -> Bool {
            spans.allSatisfy { item in claimed.contains { $0.span.lowerBound <= item.span.lowerBound + 1e-4 && $0.span.upperBound >= item.span.upperBound - 1e-4 && $0.out >= item.out - 1e-4 } }
        }
        #expect(mixed.wall.allSatisfy { span in lidar.wall.contains { $0.lowerBound <= span.lowerBound + 1e-4 && $0.upperBound >= span.upperBound - 1e-4 } }, "wall \(mixed.wall) past LiDAR's \(lidar.wall)")
        #expect(within(mixed.wallHeight, lidar.wallHeight), "wall heights \(mixed.wallHeight) past LiDAR's \(lidar.wallHeight)")
        #expect(within(mixed.ground, lidar.ground), "ground \(mixed.ground) past LiDAR's \(lidar.ground)")
        #expect(within(mixed.facing, lidar.facing), "facing \(mixed.facing) past LiDAR's \(lidar.facing)")
        #expect(within(mixed.overhead, lidar.overhead), "overhead \(mixed.overhead) past LiDAR's \(lidar.overhead)")
        // The bush fills x 1 to 2 from 0.4 to 1.0 m out.
        #expect(!mixed.facing.contains { $0.span.upperBound > 1.1 && $0.span.lowerBound < 1.9 }, "space the bush fills claimed clear: \(mixed.facing)")
    }

    /// The viewing angle a ray carries (an estimated ray's is widened for its normal's error)
    /// is the one the voxel keeps.
    @Test func aRaysOwnCosineIsTheOneRecorded() throws {
        var grid = VoxelGrid(bounds: MapBounds(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)), voxelSize: 0.1, center: .zero)
        let camera = SIMD3<Float>(0, 0, 0.9)
        let end = SIMD3<Float>(0.05, 0.05, 0.05)
        let normal = simd_normalize(camera - end)
        grid.integrate(camera: camera, rays: [RaySample(end: end, normal: normal, freeLength: 0, hit: true, cosine: 0.5)], sources: .lidar, config: Map3DConfig())
        let angle = try #require(grid.voxel(at: end)?.evidence(Map3DConfig()).bestViewAngle)
        #expect(abs(angle - acos(Float(0.5))) < 0.01)
    }
}
