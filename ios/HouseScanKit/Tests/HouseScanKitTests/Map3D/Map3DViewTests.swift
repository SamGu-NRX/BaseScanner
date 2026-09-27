import Foundation
import HouseScanKit
import simd
import Testing

// Fog of war and the next view, on the bush scene with a small region of interest (3 m either
// way along the wall, 2 m out) walked 3 m out so the whole region is in front of the cameras.
@Suite struct Map3DViewTests {
    static let config: Map3DConfig = {
        var config = Map3DConfig()
        config.alongExtent = 3
        config.outDepth = 2
        return config
    }()
    static let scene = bushScene()
    static let wall = standardWall()

    /// Every 0.3 m from x = -4 to 4 at 3 m out: at the wall, at the ground and up past the eaves.
    static let walk: [CameraFrame] = Swift.stride(from: Float(-4), through: 4, by: 0.3).flatMap { x in
        [SIMD3<Float>(x, 1.0, 0), SIMD3(x, 0, 1.0), SIMD3(x, 2.8, 0)].map { lidarCamera(at: SIMD3(x, 1.4, 3), lookingAt: $0) }
    }

    static let walked: Map3D = {
        var map = Map3D(frame: sceneFrame(), config: config)
        for (index, camera) in walk.enumerated() { map.integrate(scene.depthFrame(from: camera, noise: 0.02, seed: UInt64(index))) }
        return map
    }()

    @Test func anEmptyMapIsAllFogWithNoViewToSuggest() {
        let map = Map3D(frame: sceneFrame(), config: Self.config)
        let fog = map.fogOfWar(along: Self.wall)
        #expect(fog.seen == 0)
        #expect(!fog.cells.isEmpty)
        #expect(fog.cells.allSatisfy { $0.unknown == 1 })
        #expect(map.nextBestView(along: Self.wall) == nil)
    }

    @Test func walkingClearsFogExceptBehindTheBush() {
        let fog = Self.walked.fogOfWar(along: Self.wall)
        #expect(fog.seen > 0.9, "seen \(fog.seen)")
        // Fog cells are 0.3 m cubes; the unknown left is behind and inside the bush.
        let heavy = fog.cells.filter { $0.unknown > 0.5 }
        #expect(!heavy.isEmpty)
        #expect(heavy.allSatisfy { $0.center.x > 0.5 && $0.center.x < 2.5 && $0.center.z < 1.3 && $0.center.y < 1.2 }, "\(heavy.map(\.center))")
    }

    @Test func theNextViewLooksBehindTheBushAndRevealsIt() throws {
        let map = Self.walked
        let view = try #require(map.nextBestView(along: Self.wall))
        // The target is on the unseen region's boundary behind the bush.
        #expect(view.target.x > 0.8 && view.target.x < 2.2, "target \(view.target)")
        #expect(view.target.z > -0.1 && view.target.z < 1.1, "target \(view.target)")
        #expect(view.inSight > 0)
        // It stands in front of the wall, not in the bush, and at eye height.
        #expect(view.stand.z > 0.25)
        #expect(!(view.stand.x > 1 && view.stand.x < 2 && view.stand.z > 0.4 && view.stand.z < 1.0))
        #expect(view.eye.y == map.config.eyeHeight)

        // Taking the view shrinks the unseen region.
        var after = map
        after.integrate(Self.scene.depthFrame(from: lidarCamera(at: view.eye, lookingAt: view.target), noise: 0.02, seed: 99))
        let before = map.fogOfWar(along: Self.wall)
        let later = after.fogOfWar(along: Self.wall)
        #expect(later.seen > before.seen, "seen \(before.seen) -> \(later.seen)")
        let region = { (fog: FogOfWar) in
            fog.cells.filter { $0.center.x > view.regionMin.x && $0.center.x < view.regionMax.x && $0.center.z < view.regionMax.z }
                .reduce(Float(0)) { $0 + $1.unknown }
        }
        #expect(region(later) < region(before), "unknown behind the bush \(region(before)) -> \(region(later))")
    }
}
