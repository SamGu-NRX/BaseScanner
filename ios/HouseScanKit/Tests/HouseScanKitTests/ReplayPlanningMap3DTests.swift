import Foundation
import HouseScanKit
import Testing
import simd

/// The frames the autopilot holds back for the gap loop when the 3D map is the coverage model
/// (`ReplayPlanning.heldBackWindow(frames:depths:wall:)`), on the UI tests' two synthetic replays.
@Suite struct ReplayPlanningMap3DTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../HouseScanUITests/Fixtures").standardizedFileURL

    struct Replay {
        var frames: [PlannedFrame]
        var wall: WallFrame
    }

    static func load(_ name: String) throws -> (Replay, ReplaySession, URL) {
        let folder = fixtures.appendingPathComponent(name)
        let session = try ReplaySession.load(folder: folder)
        let frames = session.frames.map {
            PlannedFrame(
                camera: CameraFrame(cameraToWorld: $0.cameraToWorld, intrinsics: $0.intrinsics, imageSize: SIMD2(Float($0.width), Float($0.height))),
                timestamp: $0.timestamp, trackingNormal: $0.trackingNormal)
        }
        let declared = try #require(session.declaredWall)
        let wall = try #require(WallFrame(meter: declared.meter, outward: declared.outward, groundY: declared.groundY))
        return (Replay(frames: frames, wall: wall), session, folder)
    }

    /// The gap planner's view of a map built from `indices`, with the window's ends marked.
    static func coverage(_ replay: Replay, depths: [DepthImage?], indices: [Int], ends: ClosedRange<Float>) -> CoverageMap {
        var map = Map3D(frame: MapFrame(wall: replay.wall))
        for index in indices where replay.frames[index].trackingNormal {
            if let depth = depths[index] { map.integrate(DepthFrame(image: depth, pose: replay.frames[index].camera)) }
        }
        var coverage = CoverageMap(wall: replay.wall)
        coverage.setEnd(.left, at: ends.lowerBound)
        coverage.setEnd(.right, at: ends.upperBound)
        coverage.setMeasuredCovered(coverage.cells(seenIn: map.coverage(along: replay.wall)))
        return coverage
    }

    /// Depth a LiDAR sensor would report for the synthetic wall's scene: the wall's plane above
    /// the ground and the ground's plane in front of the wall, nothing else. 128 x 96 pixels: at
    /// 64 x 48 the rays land farther apart than a voxel a few meters out, and nothing reads as seen.
    static func renderedDepth(_ camera: CameraFrame, wall: WallFrame) -> DepthImage {
        let width = 128
        let height = 96
        let intrinsics = DepthImage.intrinsics(scaling: camera.intrinsics, from: camera.imageSize, toWidth: width, height: height)
        let m = camera.cameraToWorld
        let rotation = simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let origin = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var meters = [Float](repeating: 0, count: width * height)
        for v in 0..<height {
            for u in 0..<width {
                // z-depth 1 along the camera's -z, as `DepthFrame` unprojects it.
                let ray = rotation * SIMD3((Float(u) + 0.5 - intrinsics.z) / intrinsics.x, -(Float(v) + 0.5 - intrinsics.w) / intrinsics.y, -1)
                var nearest = Float.infinity
                let towardWall = simd_dot(ray, wall.outward)
                if towardWall < 0 {
                    let t = simd_dot(wall.meter - origin, wall.outward) / towardWall
                    if t > 0, (origin + ray * t).y >= wall.groundY { nearest = min(nearest, t) }
                }
                if ray.y < 0 {
                    let t = (wall.groundY - origin.y) / ray.y
                    if t > 0, simd_dot(origin + ray * t - wall.meter, wall.outward) >= 0 { nearest = min(nearest, t) }
                }
                if nearest.isFinite { meters[v * width + u] = nearest }
            }
        }
        return DepthImage(meters: meters, width: width, height: height, confidence: nil, intrinsics: intrinsics)
    }

    @Test func aWindowOnADepthReplayLeavesAGapOnlyItsFramesClose() throws {
        let (replay, _, _) = try Self.load("synthetic-wall")
        let depths = replay.frames.map { Optional(Self.renderedDepth($0.camera, wall: replay.wall)) }
        let held = try #require(ReplayPlanning.heldBackWindow(frames: replay.frames, depths: depths, wall: replay.wall))

        // Checked again from scratch, as the app would see it: every other frame leaves the gap
        // open, and adding the frames replayed for it closes it.
        let rest = replay.frames.indices.filter { !held.frames.contains($0) }
        let planner = GapPlanner()
        let walked = Self.coverage(replay, depths: depths, indices: rest, ends: held.ends)
        #expect(planner.plan(walked) == held.gap)
        #expect(!planner.isSatisfied(held.gap, walked))
        let replayed = rest + Array(ReplayPlanning.gapReplayRange(held.frames))
        #expect(planner.isSatisfied(held.gap, Self.coverage(replay, depths: depths, indices: replayed, ends: held.ends)))
    }

    /// The LiDAR fixture's bin hides ground no frame's depth gets past. That stretch is the gap
    /// the planner asks for first whatever is held back, and no replayed frame closes it, so no
    /// window is chosen and the autopilot's gap loop runs on the bin's gap instead.
    @Test func theBinsShadowLeavesNoWindowOnTheLidarReplay() throws {
        let (replay, session, folder) = try Self.load("synthetic-wall-lidar")
        let depths = try session.frames.map { try ReplaySession.loadDepth(for: $0, folder: folder) }
        #expect(depths.allSatisfy { $0 != nil })
        #expect(ReplayPlanning.heldBackWindow(frames: replay.frames, depths: depths, wall: replay.wall) == nil)

        let all = Self.coverage(replay, depths: depths, indices: Array(replay.frames.indices), ends: -5.9...5.9)
        let standing = try #require(GapPlanner().plan(all))
        // The bin stands 4 to 6 ft (1.22 to 1.83 m) right of the meter.
        #expect(standing.band == .ground)
        #expect(standing.span.lowerBound <= 1.22 && standing.span.upperBound >= 1.83)
    }
}
