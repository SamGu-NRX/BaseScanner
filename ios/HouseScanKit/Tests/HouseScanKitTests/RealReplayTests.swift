import Foundation
import HouseScanKit
import Testing

/// Runs the replay planning on a real recorded session when HOUSESCAN_REPLAY names one. Real
/// sessions are not in the repository (licenses, homes), so these tests are skipped in CI.
@Suite struct RealReplayTests {
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["HOUSESCAN_REPLAY"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @Test(.enabled(if: folder != nil, "set HOUSESCAN_REPLAY to a measure-lab-session folder"))
    func plansTheReplay() throws {
        let session = try ReplaySession.load(folder: try #require(Self.folder))
        let frames = session.frames.map {
            PlannedFrame(
                camera: CameraFrame(cameraToWorld: $0.cameraToWorld, intrinsics: $0.intrinsics, imageSize: SIMD2(Float($0.width), Float($0.height))),
                timestamp: $0.timestamp, trackingNormal: $0.trackingNormal
            )
        }
        let clock = ContinuousClock()
        var assumed: (wall: WallFrame, coveredCells: Int, offset: Float)?
        let wallTime = clock.measure { assumed = ReplayPlanning.assumedWall(frames: frames) }
        let wall = try #require(session.declaredWall.flatMap { WallFrame(meter: $0.meter, outward: $0.outward, groundY: $0.groundY) } ?? assumed?.wall)
        var window: ReplayPlanning.HeldBackWindow?
        let windowTime = clock.measure { window = ReplayPlanning.heldBackWindow(frames: frames, wall: wall) }
        let walked = ReplayPlanning.simulateWalk(frames, wall: wall)
        let besideMeter = frames.indices.min { abs(wall.wallPoint(frames[$0].camera.position).s) < abs(wall.wallPoint(frames[$1].camera.position).s) } ?? 0
        print("replay \(session.id): \(frames.count) frames; assumed wall offset \(assumed?.offset ?? .nan) m, \(assumed?.coveredCells ?? 0) cells within reach of the meter, which is beside frame \(besideMeter) (\(wallTime)); walk covers wall \(walked.coveredIntervals(.wall).count) runs, ground \(walked.coveredIntervals(.ground).count) runs; held-back window \(window.map { "\($0.frames) gap \($0.gap.band) \($0.gap.span)" } ?? "none") (\(windowTime))")
        #expect(walked.coveredCount > 0, "the replay covers nothing on its wall")
    }
}

/// Validates a scene.json the app wrote (unzip it from the scan bundle the engine logs) against
/// the server's schema, when HOUSESCAN_SCENE_JSON names one.
@Suite struct AppSceneFileTests {
    static var file: URL? {
        guard let path = ProcessInfo.processInfo.environment["HOUSESCAN_SCENE_JSON"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    @Test(.enabled(if: file != nil, "set HOUSESCAN_SCENE_JSON to a scene.json from an app scan bundle"))
    func appSceneMatchesTheSchema() throws {
        let errors = try SceneSchemas.scene().validate(Data(contentsOf: try #require(Self.file)))
        #expect(errors.isEmpty, "\(errors)")
    }
}
