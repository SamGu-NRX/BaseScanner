import Foundation
import HouseScanKit
import simd
import Testing

// One kind of input at a time: a single LiDAR frame, frames from a phone without LiDAR,
// estimated depth, and mesh chunks.
@Suite struct Map3DInputTests {
    /// One frame of a bare wall from 2.5 m out, aimed straight at it 1.4 m up.
    @Test func oneFrameSeparatesUnknownFreeAndSurface() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(5, 0))])
        let camera = lidarCamera(at: SIMD3(0, 1.4, 2.5), lookingAt: SIMD3(0, 1.4, 0))
        var map = Map3D(frame: sceneFrame())
        #expect(map.state(at: SIMD3(0, 1.4, 1.5)) == .unknown)
        map.integrate(scene.depthFrame(from: camera))
        // On the face, between the camera and the face, behind the wall, and outside the view
        // (26.5 degrees either side across a portrait image: 0.75 m either side 1 m from the camera).
        #expect(map.state(at: SIMD3(0, 1.4, 0)) == .surface)
        #expect(map.state(at: SIMD3(0.3, 1.0, 0)) == .surface)
        #expect(map.state(at: SIMD3(0, 1.4, 1.5)) == .free)
        #expect(map.state(at: SIMD3(0, 1.4, 0.3)) == .free)
        #expect(map.state(at: SIMD3(0, 1.4, -0.3)) == .unknown)
        #expect(map.state(at: SIMD3(-2, 1.4, 1.5)) == .unknown)
        // Evidence on the face: one frame, 2.5 m away, seen head on, facing the camera.
        let evidence = map.evidence(at: SIMD3(0, 1.4, 0))
        #expect(evidence.hits == 1)
        #expect(evidence.passes == 0)
        #expect(evidence.nearestDistance.map { abs($0 - 2.5) < 0.05 } == true)
        // The cosine is stored in 1/255 steps, rounded down, which near square on is about 5 degrees.
        #expect(evidence.bestViewAngle.map { $0 < 6 * .pi / 180 } == true)
        #expect(evidence.normal.map { simd_dot($0, SIMD3(0, 0, 1)) > 0.99 } == true)
        #expect(evidence.sources == .lidar)
        // One frame counts once however many of its rays pass through a voxel.
        #expect(map.evidence(at: SIMD3(0, 1.4, 1.5)).passes == 1)
    }

    @Test func lowConfidenceAndOutOfRangeDepthIsIgnored() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(5, 0))])
        let camera = lidarCamera(at: SIMD3(0, 1.4, 2.5), lookingAt: SIMD3(0, 1.4, 0))
        let frame = scene.depthFrame(from: camera)
        var low = Map3D(frame: sceneFrame())
        low.integrate(DepthFrame(camera: camera, width: frame.width, height: frame.height, depth: frame.depth, kind: .lidar(confidence: [UInt8](repeating: 0, count: frame.depth.count))))
        #expect(low.state(at: SIMD3(0, 1.4, 0)) == .unknown)
        #expect(low.state(at: SIMD3(0, 1.4, 1.5)) == .unknown)
        var far = Map3D(frame: sceneFrame())
        let distant = lidarCamera(at: SIMD3(0, 1.4, 6), lookingAt: SIMD3(0, 1.4, 0))
        far.integrate(scene.depthFrame(from: distant))
        #expect(far.state(at: SIMD3(0, 1.4, 0)) == .unknown)
    }

    /// Without LiDAR: feature points on everything the camera sees (the bush included, one
    /// every 5 cm or so) and the wall and ground as detected planes.
    @Test func planesAndFeaturePointsMakeAMapThatHonoursTheBush() throws {
        let scene = bushScene()
        var map = Map3D(frame: sceneFrame())
        // The wall plane: local y (its normal) is +z, local x is +x, so local z is -y.
        let wallPlane = PlaneObservation(
            id: UUID(), worldFromPlane: simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1)),
            alignment: .vertical, center: SIMD2(0.5, -1.5), width: 11, length: 3)
        let groundPlane = PlaneObservation(
            id: UUID(), worldFromPlane: matrix_identity_float4x4, alignment: .horizontal, center: SIMD2(0.5, 3), width: 13, length: 6)
        map.update(wallPlane)
        map.update(groundPlane)
        let cameras = bushWalk().map { CameraFrame(cameraToWorld: $0.cameraToWorld, intrinsics: SIMD4(1450, 1450, 960, 720), imageSize: SIMD2(1920, 1440)) }
        for camera in cameras {
            map.integrate(FeatureFrame(camera: camera, points: scene.featurePoints(from: camera, columns: 32, rows: 24)))
        }
        #expect(map.state(at: SIMD3(-1, 1.4, 0)) == .surface)
        #expect(map.evidence(at: SIMD3(-1, 1.4, 0)).sources.contains(.plane))
        #expect(map.state(at: SIMD3(-1, 1.4, 1.5)) == .free)
        #expect(map.state(at: SIMD3(-1, 1.4, -0.5)) == .unknown)

        let chain = try #require(map.measuredWalls())
        #expect(chain.walls.count == 1)
        #expect(chain.walls.allSatisfy { $0.source == .plane && abs($0.start.y) < 0.06 && abs($0.end.y) < 0.06 })

        let wall = standardWall()
        let coverage = map.coverage(along: wall)
        let behindBush = map.cellIndices.filter { map.cellRange($0).lowerBound >= 1.1 && map.cellRange($0).upperBound <= 1.9 }
        for index in behindBush {
            let middle = (map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2
            #expect(!coverage.wall.contains { $0.contains(middle) }, "cell \(index) behind the bush claimed seen")
            #expect(map.groundReach(cell: index, along: wall) == nil)
        }
        let open = map.cellIndices.filter { map.cellRange($0).lowerBound >= -2 && map.cellRange($0).upperBound <= 0.6 }
        #expect(open.allSatisfy { index in coverage.wall.contains { $0.contains(map.cellRange(index).lowerBound + 0.07) } })
    }

    /// Estimated depth with 3 % error: a surface only where two deviations are within 15 cm
    /// (2.5 m and nearer), free space short of that, and never a wall.
    @Test func estimatedDepthCarvesWhatItIsSureOf() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(5, 0))])
        let near = lidarCamera(at: SIMD3(0, 1.4, 2.0), lookingAt: SIMD3(0, 1.4, 0))
        let far = lidarCamera(at: SIMD3(3, 1.4, 4.0), lookingAt: SIMD3(3, 1.4, 0))
        var map = Map3D(frame: sceneFrame())
        for camera in [near, far] {
            let lidar = scene.depthFrame(from: camera)
            map.integrate(DepthFrame(camera: camera, width: lidar.width, height: lidar.height, depth: lidar.depth, kind: .estimated(sigma: lidar.depth.map { $0 * 0.03 })))
        }
        #expect(map.state(at: SIMD3(0, 1.4, 0)) == .surface)
        #expect(map.evidence(at: SIMD3(0, 1.4, 0)).sources == .estimated)
        #expect(map.state(at: SIMD3(0, 1.4, 1.0)) == .free)
        // 4 m away the deviation is 12 cm: no surface, and free space stops 24 cm short.
        #expect(map.state(at: SIMD3(3, 1.4, 0)) == .unknown)
        #expect(map.state(at: SIMD3(3, 1.4, 0.1)) == .unknown)
        #expect(map.state(at: SIMD3(3, 1.4, 1.0)) == .free)
        #expect(map.measuredWalls() == nil)
    }

    /// A wall and a floor as mesh chunks: the mesh labels voxels and gives them normals but no
    /// occupancy, and replacing a chunk clears what its old faces labelled.
    @Test func meshChunksLabelVoxelsAndReplaceCleanly() {
        var map = Map3D(frame: sceneFrame())
        let id = UUID()
        func chunk(atZ z: Float) -> MeshChunk {
            MeshChunk(
                id: id, worldFromChunk: matrix_identity_float4x4,
                vertices: [SIMD3(-1, 0, z), SIMD3(1, 0, z), SIMD3(1, 2, z), SIMD3(-1, 2, z), SIMD3(-1, 0, 1), SIMD3(1, 0, 1)],
                faces: [SIMD3(0, 1, 2), SIMD3(0, 2, 3), SIMD3(0, 4, 5), SIMD3(0, 5, 1)],
                classes: [.wall, .wall, .floor, .floor])
        }
        map.update(chunk(atZ: 0))
        let face = map.evidence(at: SIMD3(0, 1, 0))
        #expect(face.meshClass == .wall)
        #expect(face.sources == .mesh)
        #expect(face.state == .unknown)
        #expect(face.normal.map { abs($0.z) > 0.99 } == true)
        #expect(map.evidence(at: SIMD3(0, 0, 0.5)).meshClass == .floor)
        map.update(chunk(atZ: -0.5))
        #expect(map.evidence(at: SIMD3(0, 1, 0)).meshClass == nil)
        #expect(map.evidence(at: SIMD3(0, 1, -0.5)).meshClass == .wall)
        map.removeMeshChunk(id: id)
        #expect(map.evidence(at: SIMD3(0, 1, -0.5)).meshClass == nil)
    }

    /// The map moves with the meter's anchor: a map point keeps its place relative to it.
    @Test func frameFollowsTheMeterAnchor() {
        let frame = sceneFrame()
        let old = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1.5, 0, 1))
        // ARKit refines the anchor: 5 cm along x and 2 degrees about +y.
        let turn = simd_float4x4(simd_quatf(angle: 2 * .pi / 180, axis: SIMD3(0, 1, 0)))
        var new = turn * old
        new.columns.3 = SIMD4(0.05, 1.5, 0, 1)
        let moved = frame.following(anchorMovedFrom: old, to: new)
        let point = SIMD3<Float>(2, 1, 1)
        let relative = old.inverse * SIMD4(frame.world(point), 1)
        let expected = new * relative
        #expect(simd_distance(moved.world(point), SIMD3(expected.x, expected.y, expected.z)) < 1e-4)
        #expect(abs(moved.worldDirection(SIMD3(0, 1, 0)).y - 1) < 1e-5)
    }

    // MARK: Capture packet conventions (packet/README.md on t3/packet)

    /// The map frame is the packet's meter frame: origin at the meter anchor, +y up, +z the
    /// wall's outward normal, +x = y × z, and the ground's height below the anchor.
    @Test func mapFrameIsThePacketMeterFrame() throws {
        let frame = try #require(MapFrame(meter: SIMD3(2, 1.5, -1), outward: SIMD3(1, 0.2, 0), worldGroundY: 0.1))
        #expect(simd_distance(frame.world(.zero), SIMD3(2, 1.5, -1)) < 1e-5)
        #expect(abs(frame.groundY - -1.4) < 1e-5)
        let x = frame.worldDirection(SIMD3(1, 0, 0))
        let y = frame.worldDirection(SIMD3(0, 1, 0))
        let z = frame.worldDirection(SIMD3(0, 0, 1))
        #expect(simd_distance(z, SIMD3(1, 0, 0)) < 1e-5)
        #expect(simd_distance(y, SIMD3(0, 1, 0)) < 1e-5)
        #expect(simd_distance(x, simd_cross(y, z)) < 1e-5)
        // The packet's meter_anchor fields give the same frame back.
        let packet = MapFrame(poseInWorld: frame.poseInWorld, groundY: frame.groundY)
        #expect(packet == frame)
    }

    /// Where the anchor sits changes nothing the map reports along the wall: the bush scene's
    /// coverage with the anchor on the meter 1.5 m up equals it with the anchor on the ground,
    /// ground reach to within a row.
    @Test func coverageDoesNotDependOnTheAnchorHeight() throws {
        let scene = bushScene()
        let raised = try #require(MapFrame(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), worldGroundY: 0))
        var onMeter = Map3D(frame: raised)
        var onGround = Map3D(frame: sceneFrame())
        for camera in bushWalk() {
            let frame = scene.depthFrame(from: camera)
            onMeter.integrate(frame)
            onGround.integrate(frame)
        }
        let a = onMeter.coverage(along: standardWall())
        let b = onGround.coverage(along: standardWall())
        #expect(a.wall == b.wall && a.facing == b.facing && a.overhead == b.overhead)
        // Ground at the ends of the walk rests on rays that just cross a voxel or just stop in
        // it, which float rounding in either frame can tip: at most one row apart.
        for index in onGround.cellIndices {
            let reaches = [onMeter, onGround].map { $0.groundReach(cell: index, along: standardWall()) }
            #expect(abs((reaches[0] ?? -0.1524) - (reaches[1] ?? -0.1524)) <= 0.1525, "cell \(index): \(reaches)")
        }
        #expect(onMeter.state(at: SIMD3(-1, -0.1, 0)) == .surface)
    }

    /// A depth image aligned to a photo: depth pixel (c, r) covers photo pixels c W / w to
    /// (c + 1) W / w, so a point lands on the depth pixel under its photo pixel.
    @Test func depthIntrinsicsFollowThePacketAlignment() {
        let photo = CameraFrame(
            cameraToWorld: lidarCamera(at: SIMD3(0, 1.4, 2.5), lookingAt: SIMD3(0.3, 1.1, 0)).cameraToWorld,
            intrinsics: SIMD4(1450, 1452, 962, 718), imageSize: SIMD2(1920, 1440))
        let depth = DepthFrame(photo: photo, width: 256, height: 192, depth: [Float](repeating: 0, count: 256 * 192), kind: .lidar(confidence: nil))
        for point in [SIMD3<Float>(0.3, 1.1, 0), SIMD3(-0.4, 0.2, 0), SIMD3(0.8, 2.0, 0)] {
            let a = photo.pixel(of: point)!
            let b = depth.camera.pixel(of: point)!
            #expect(simd_distance(a / 7.5, b) < 1e-3, "photo \(a), depth \(b)")
        }
    }

    /// A packet's merged mesh is in the meter frame: fed as one chunk placed at the anchor, its
    /// faces label the voxels at their meter-frame positions.
    @Test func aPacketMeshIsOneChunkInTheMeterFrame() throws {
        let frame = try #require(MapFrame(meter: SIMD3(3, 1.5, 2), outward: SIMD3(-1, 0, 0), worldGroundY: 0))
        var map = Map3D(frame: frame)
        map.update(MeshChunk(
            id: UUID(), worldFromChunk: frame.poseInWorld,
            vertices: [SIMD3(-1, -1.5, 0), SIMD3(1, -1.5, 0), SIMD3(1, 0.5, 0), SIMD3(-1, 0.5, 0)],
            faces: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)], classes: [.wall, .wall]))
        #expect(map.evidence(at: SIMD3(0.5, -0.5, 0)).meshClass == .wall)
        #expect(map.evidence(at: SIMD3(0.5, -0.5, 0.3)).meshClass == nil)
    }

    @Test func lidarDepthWithoutConfidenceIsTakenAsHigh() {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(5, 0))])
        let camera = lidarCamera(at: SIMD3(0, 1.4, 2.5), lookingAt: SIMD3(0, 1.4, 0))
        let frame = scene.depthFrame(from: camera)
        var map = Map3D(frame: sceneFrame())
        map.integrate(DepthFrame(camera: camera, width: frame.width, height: frame.height, depth: frame.depth, kind: .lidar(confidence: nil)))
        #expect(map.state(at: SIMD3(0, 1.4, 0)) == .surface)
    }
}
