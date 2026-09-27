@testable import HouseScanKit
import Foundation
import simd
import Testing

/// The #21 caretaker's findings on 2ce7d18, each reproduced before its fix.
@Suite struct Map3DCaretakerTests {
    static let config = Map3DConfig()

    /// A 2 m grid of 10 cm voxels with one centred on the origin.
    static func grid() -> VoxelGrid {
        VoxelGrid(bounds: MapBounds(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)), voxelSize: 0.1, center: .zero)
    }

    static let camera = SIMD3<Float>(0, 0, 0.9)
    /// A ray that stops square on the origin's voxel.
    static let hit = RaySample(end: .zero, normal: SIMD3(0, 0, 1), freeLength: 0, hit: true, cosine: 1)
    /// A ray that passes through the origin's voxel and stops far behind it.
    static let pass = RaySample(end: SIMD3(0, 0, -0.9), normal: .zero, freeLength: 1.8, hit: false)

    /// A measured hit then a measured pass leave 85 - 40 = 45, under the 50 a surface needs. An
    /// estimated hit in between or before must not count toward the measured strength.
    @Test(arguments: [[true, false, true], [false, true, true]])
    func estimatedHitsAddNothingToMeasuredStrength(hitsMeasured: [Bool]) {
        var grid = Self.grid()
        for measured in hitsMeasured.dropLast() {
            grid.integrate(camera: Self.camera, rays: [Self.hit], sources: measured ? .lidar : .estimated, config: Self.config)
        }
        grid.integrate(camera: Self.camera, rays: [Self.pass], sources: .lidar, config: Self.config)
        let voxel = grid.voxel(at: .zero)
        #expect(voxel?.state(Self.config) != .surface, "log-odds \(voxel?.logOdds ?? 0)")
        #expect(!grid.isWellSeenSurface(grid.coordinate(of: .zero)!, config: Self.config))
    }

    /// A ray from a voxel centre diagonally through the corners of the x-y grid spends no length
    /// in the voxels beside the diagonal; they stay unknown.
    @Test func aRayThroughVoxelCornersLeavesItsNeighboursUnknown() {
        var grid = Self.grid()
        let end = SIMD3<Float>(0.3, 0.3, 0)
        grid.integrate(camera: .zero, rays: [RaySample(end: end, normal: .zero, freeLength: simd_length(end), hit: false)], sources: .lidar, config: Self.config)
        for beside in [SIMD3<Float>(0.1, 0, 0), SIMD3(0, 0.1, 0), SIMD3(0.2, 0.1, 0), SIMD3(0.1, 0.2, 0)] {
            #expect((grid.voxel(at: beside)?.passes ?? 0) == 0, "\(beside) passed through")
        }
        #expect(grid.voxel(at: SIMD3(0.1, 0.1, 0))?.state(Self.config) == .free)
    }

    /// A batch holding both a move of the meter's anchor (+0.2 m out) and a mesh chunk ARKit sent
    /// in the corrected world: the chunk lands on the depth evidence, which moved with the anchor.
    @Test func meshSentWithAMeterMoveLandsOnTheMovedDepth() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-3, 0), b: SIMD2(3, 0))])
        var map = Map3D(frame: sceneFrame())
        for x in [Float(-0.5), 0, 0.5] { map.integrate(scene.depthFrame(from: lidarCamera(at: SIMD3(x, 1.2, 2), lookingAt: SIMD3(x, 1, 0)))) }
        #expect(map.state(at: SIMD3(0, 1, 0)) == .surface)
        var move = matrix_identity_float4x4
        move.columns.3 = SIMD4(0, 0, 0.2, 1)
        let moved = map.frame.following(anchorMovedFrom: matrix_identity_float4x4, to: move)
        // The wall as ARKit now places it, 0.2 m out in world.
        let chunk = MeshChunk(
            id: UUID(), worldFromChunk: matrix_identity_float4x4,
            vertices: [SIMD3(-1, 0.5, 0.2), SIMD3(1, 0.5, 0.2), SIMD3(1, 1.5, 0.2), SIMD3(-1, 1.5, 0.2)],
            faces: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)], classes: [.wall, .wall])
        map.apply(frame: moved, planes: [:], chunks: [chunk.id: chunk])
        // In map coordinates the depth wall stays at z = 0; the mesh must be there too.
        #expect(map.evidence(at: SIMD3(0, 1, 0)).meshClass == .wall)
        #expect(map.evidence(at: SIMD3(0, 1, 0.2)).meshClass == nil)
    }

    /// A slow model: more kept frames arrive than the worker takes. At most `limit` wait, the
    /// newest, and the rest are counted as dropped.
    @Test func pendingWorkKeepsTheNewestUpToItsLimit() {
        var work = PendingWork<Int>(limit: 2)
        for item in 1...10 { work.add(item) }
        #expect(work.count == 2)
        #expect(work.dropped == 8)
        #expect(work.take() == 9)
        #expect(work.take() == 10)
        #expect(work.take() == nil)
        work.add(11)
        work.removeAll()
        #expect(work.take() == nil)
    }

    /// Anchors ARKit sends before the meter is placed wait for the map, within a budget: the
    /// oldest go first once their vertices pass it, and an update replaces its anchor's entry.
    @Test func waitingAnchorsStayWithinTheirBudget() {
        var waiting = BoundedRecent<Int, [Int]>(budget: 10) { $0.count }
        for key in 0..<6 { waiting[key] = Array(repeating: 0, count: 3) }
        #expect(waiting.total <= 10)
        #expect(Set(waiting.values.map { $0.count }) == [3])
        #expect(waiting.keys == [3, 4, 5])
        waiting[3] = Array(repeating: 0, count: 4)
        #expect(waiting.keys == [4, 5, 3])
        #expect(waiting.total == 10)
        waiting[5] = nil
        #expect(waiting.keys == [4, 3])
        // One entry over the whole budget is not kept.
        waiting[9] = Array(repeating: 0, count: 11)
        #expect(waiting[9] == nil)
    }

    /// Two well-fitted parallel pieces 0.2 m apart joined straight: the chain's error must cover
    /// both, not only the kept line's own fit.
    @Test func aStraightJoinCoversTheJoinedPiecesOffset() throws {
        let map = Map3D(frame: sceneFrame())
        let kept = MeasuredWall(start: SIMD2(-2, 0), end: SIMD2(0.5, 0), outward: SIMD2(0, 1), source: .mesh, support: 25, plusMinus: 0.05)
        let joined = MeasuredWall(start: SIMD2(0.8, 0.2), end: SIMD2(3, 0.2), outward: SIMD2(0, 1), source: .mesh, support: 22, plusMinus: 0.05)
        let chain = try #require(map.chain([kept, joined]))
        #expect(chain.walls.count == 1)
        #expect(chain.walls[0].plusMinus >= 0.2 + 0.05 - 1e-4, "plus-minus \(chain.walls[0].plusMinus)")
    }
}
