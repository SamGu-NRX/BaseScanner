import Foundation
import HouseScanKit
import simd
import Testing

// Ways coverage could claim what no ray measured, each reproduced from a review of the map and
// fixed after this test failed.
@Suite struct Map3DOverClaimTests {
    static let wall = standardWall()

    static func covers(_ map: Map3D, _ spans: [ClosedRange<Float>], _ index: Int) -> Bool {
        let middle = (map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2
        return spans.contains { $0.contains(middle) }
    }

    /// Space seen empty for many frames, then something is measured there: the voxel holding
    /// its face is no longer free after the first hit. Five passes saturate the log-odds at
    /// -2.0 and one hit adds only 0.85. (Its inside, never measured, keeps what the earlier
    /// frames saw: the map assumes nothing moves.)
    @Test func aHitEndsFreeSpaceAtOnce() {
        let open = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(5, 0))])
        let camera = lidarCamera(at: SIMD3(0, 1, 3), lookingAt: SIMD3(0, 1, 0))
        var map = Map3D(frame: sceneFrame())
        for _ in 0..<6 { map.integrate(open.depthFrame(from: camera)) }
        let point = SIMD3<Float>(0, 1, 1.8)
        #expect(map.state(at: point) == .free)
        var blocked = open
        blocked.boxes = [SyntheticScene.Box(min: SIMD3(-0.5, 0, 1.5), max: SIMD3(0.5, 2, 1.8))]
        map.integrate(blocked.depthFrame(from: camera))
        #expect(map.state(at: point) != .free)
    }

    /// A wall seen head on, then many rays grazing along it to a point farther on: the wall's
    /// voxels short of that point stay wall, not free.
    @Test func grazingRaysDoNotEraseAWall() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(8, 0))])
        var map = Map3D(frame: sceneFrame())
        for x: Float in [1.5, 2.5, 3.5] { map.integrate(scene.depthFrame(from: lidarCamera(at: SIMD3(x, 1, 2), lookingAt: SIMD3(x, 1, 0)))) }
        #expect(map.state(at: SIMD3(2.5, 1, 0)) == .surface)
        let grazing = lidarCamera(at: SIMD3(0, 1, 0.3), lookingAt: SIMD3(3, 1, 0))
        for _ in 0..<10 { map.integrate(scene.depthFrame(from: grazing)) }
        #expect(map.state(at: SIMD3(2.5, 1, 0)) != .free)
        #expect(map.state(at: SIMD3(2.0, 1, 0)) != .free)
    }

    /// Cell 0 runs from s = 0 to 0.1524; its last 2.4 mm lies in the voxel column centred on
    /// 0.2, where the wall has a hole. That column must be checked, so the cell is not seen.
    @Test func everyVoxelColumnUnderACellIsChecked() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(0.15, 0)), SyntheticScene.Wall(a: SIMD2(0.35, 0), b: SIMD2(6, 0))])
        var map = Map3D(frame: sceneFrame())
        for camera in bushWalk() { map.integrate(scene.depthFrame(from: camera)) }
        let coverage = map.coverage(along: Self.wall)
        #expect(Self.covers(map, coverage.wall, -1))
        #expect(!Self.covers(map, coverage.wall, 0))
    }

    /// A box 1.2 m tall whose front is only 14 cm out: its front falls in the voxel layer next
    /// to the wall's, and must not stand in for the wall behind it.
    @Test func aShallowBoxIsNotTheWall() {
        let scene = SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))],
            boxes: [SyntheticScene.Box(min: SIMD3(1, 0, 0.05), max: SIMD3(2, 1.2, 0.14))])
        var map = Map3D(frame: sceneFrame())
        for camera in bushWalk() { map.integrate(scene.depthFrame(from: camera)) }
        let coverage = map.coverage(along: Self.wall)
        for index in map.cellIndices where map.cellRange(index).lowerBound >= 1.2 && map.cellRange(index).upperBound <= 1.8 {
            #expect(!Self.covers(map, coverage.wall, index), "cell \(index) behind the box claimed seen")
        }
        #expect(map.cellIndices.filter { map.cellRange($0).lowerBound >= -2 && map.cellRange($0).upperBound <= 0.6 }.allSatisfy { Self.covers(map, coverage.wall, $0) })
    }

    /// The shallow box made 3.5 m wide, wider than the neighbourhood `facadeOffset` takes its
    /// mode over (about a meter either side): in its middle more samples meet the box's front
    /// than the wall above it, so the mode is the box. No view reaches the wall behind it.
    @Test func aWideShallowBoxIsNotTheWall() {
        let scene = SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))],
            boxes: [SyntheticScene.Box(min: SIMD3(1, 0, 0.05), max: SIMD3(4.5, 1.2, 0.14))])
        var map = Map3D(frame: sceneFrame())
        for camera in bushWalk() { map.integrate(scene.depthFrame(from: camera)) }
        let coverage = map.coverage(along: Self.wall)
        for index in map.cellIndices where map.cellRange(index).lowerBound >= 1.2 && map.cellRange(index).upperBound <= 4.3 {
            #expect(!Self.covers(map, coverage.wall, index), "cell \(index) behind the box claimed seen")
            #expect(!coverage.wallHeight.contains { $0.span.contains((map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2) },
                    "cell \(index) behind the box reported with a height")
        }
        #expect(map.cellIndices.filter { map.cellRange($0).lowerBound >= -2 && map.cellRange($0).upperBound <= 0.6 }.allSatisfy { Self.covers(map, coverage.wall, $0) })
    }

    /// Ground raised 0.2 m under part of the battery's depth and a beam 0.2 to 0.3 m over the
    /// rest: the beam is above that ground's clearance, so overhead is not clear from the ground.
    @Test func overheadStartsFromEachColumnsOwnGround() {
        let scene = SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))],
            boxes: [
                SyntheticScene.Box(min: SIMD3(1, 0, 0.15), max: SIMD3(2, 0.2, 0.35)),
                SyntheticScene.Box(min: SIMD3(1, 0.2, 0.45), max: SIMD3(2, 0.3, 0.6)),
            ])
        var map = Map3D(frame: sceneFrame())
        for camera in bushWalk() { map.integrate(scene.depthFrame(from: camera)) }
        for index in map.cellIndices where map.cellRange(index).lowerBound >= 1.1 && map.cellRange(index).upperBound <= 1.9 {
            let reach = map.overheadReach(cell: index, along: Self.wall)
            #expect(reach.map { $0 < 0.2 } ?? true, "cell \(index) overhead \(reach ?? -1)")
        }
    }

    /// A surface seen square on from beyond range and within range only at a glancing angle:
    /// no single view both reached it and saw it well, so it is not seen.
    @Test func oneViewMustBeBothNearAndSquareOn() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-8, 0), b: SIMD2(8, 0))])
        var map = Map3D(frame: sceneFrame())
        // 4.8 m deep on the camera's axis but 5.46 m along the ray to x = 0, 28 degrees off square.
        map.integrate(scene.depthFrame(from: lidarCamera(at: SIMD3(2.6, 1, 4.8), lookingAt: SIMD3(2.6, 1, 0))))
        // 2.93 m away but 70 degrees off square.
        map.integrate(scene.depthFrame(from: lidarCamera(at: SIMD3(2.75, 1, 1.0), lookingAt: SIMD3(0, 1, 0))))
        let evidence = map.evidence(at: SIMD3(0, 1, 0))
        #expect(evidence.state == .surface)
        #expect(!map.isWallSeen(cell: 0, along: Self.wall))
    }

    /// A vertical plane facing +z at `z`, 11 m wide and 3 m tall, as ARKit reports one.
    static func wallPlane(id: UUID, z: Float) -> PlaneObservation {
        PlaneObservation(
            id: id, worldFromPlane: simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, z, 1)),
            alignment: .vertical, center: SIMD2(0.5, -1.5), width: 11, length: 3)
    }

    /// Frames from a phone without LiDAR that tracked no points: only the planes speak.
    static func emptyFrames() -> [FeatureFrame] {
        bushWalk().map { FeatureFrame(camera: CameraFrame(cameraToWorld: $0.cameraToWorld, intrinsics: SIMD4(1450, 1450, 960, 720), imageSize: SIMD2(1920, 1440)), points: []) }
    }

    /// ARKit moves a plane from 0.3 m out to the wall: the old position leaves nothing behind.
    @Test func aMovedPlaneTakesItsMarksWithIt() {
        var map = Map3D(frame: sceneFrame())
        let id = UUID()
        map.update(Self.wallPlane(id: id, z: 0.3))
        for frame in Self.emptyFrames() { map.integrate(frame) }
        #expect(map.evidence(at: SIMD3(0, 1, 0.3)).sources.contains(.plane))
        map.update(Self.wallPlane(id: id, z: 0))
        for frame in Self.emptyFrames() { map.integrate(frame) }
        #expect(!map.evidence(at: SIMD3(0, 1, 0.3)).sources.contains(.plane))
        #expect(map.evidence(at: SIMD3(0, 1, 0)).sources.contains(.plane))
        map.removePlane(id: id)
        #expect(!map.evidence(at: SIMD3(0, 1, 0)).sources.contains(.plane))
    }

    /// A plane with nothing measured on it clears no fog: nobody has seen what stands there.
    @Test func planesAloneClearNoFog() {
        var map = Map3D(frame: sceneFrame())
        map.update(Self.wallPlane(id: UUID(), z: 0))
        for frame in Self.emptyFrames() { map.integrate(frame) }
        #expect(map.fogOfWar(along: Self.wall).seen == 0)
        #expect(map.state(at: SIMD3(0, 1, 0)) == .unknown)
    }

    /// Two mesh chunks cover one voxel; removing one keeps the other's label there.
    @Test func removingOneMeshChunkKeepsTheOthers() {
        var map = Map3D(frame: sceneFrame())
        func chunk(_ id: UUID, x: Float) -> MeshChunk {
            MeshChunk(
                id: id, worldFromChunk: matrix_identity_float4x4,
                vertices: [SIMD3(x - 0.5, 0, 0), SIMD3(x + 0.5, 0, 0), SIMD3(x + 0.5, 2, 0), SIMD3(x - 0.5, 2, 0)],
                faces: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)], classes: [.wall, .wall])
        }
        let a = UUID()
        map.update(chunk(a, x: 0))
        map.update(chunk(UUID(), x: 0.4))
        map.removeMeshChunk(id: a)
        #expect(map.evidence(at: SIMD3(0.2, 1, 0)).meshClass == .wall)
        #expect(map.evidence(at: SIMD3(-0.3, 1, 0)).meshClass == nil)
    }
}

