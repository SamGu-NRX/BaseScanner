import CoreGraphics
import Foundation
import HouseScanKit
import OSLog
import simd

/// Plays a recorded measure-lab-session v2 folder (contract C3) as if it were the camera.
///
/// Frames are delivered at their recorded timing divided by `speed`, each with its own pose and
/// intrinsics, and its LiDAR depth when the session recorded some (`keyframes[].depth`, read by
/// `ReplaySession.loadDepth`), through the same engine path as live frames. JPEGs and depth are
/// decoded off the main actor.
@MainActor
final class ReplayPlayer {
    let folder: URL
    let session: ReplaySession
    var frames: [ReplayFrame] { session.frames }
    let planned: [PlannedFrame]
    /// The wall the replay measures: the recorded one, or one assumed from the trajectory.
    let wall: WallFrame
    let wallDescription: String
    /// True when the ground height comes from the recording's wall taps; an assumed wall puts
    /// the ground 1.4 m under the mean camera height, a guess.
    let groundMeasured: Bool
    /// Frames the autopilot holds back from the walk for the gap loop, once prepared.
    private(set) var heldBack: ReplayPlanning.HeldBackWindow?
    private(set) var isPlaying = false
    private(set) var shownIndex: Int?

    private let onFrame: @MainActor (SourceFrame) -> Void
    private var task: Task<Void, Never>?

    /// What loading a replay produces: the session, its frames as cameras, and its wall.
    struct Loaded: Sendable {
        let session: ReplaySession
        let planned: [PlannedFrame]
        let wall: WallFrame
        let wallDescription: String
        let groundMeasured: Bool
    }

    /// Reads session.json and settles the wall. Deriving an assumed wall projects every frame
    /// against many candidate walls, so call this off the main actor.
    nonisolated static func load(folder: URL) throws -> Loaded {
        let session = try ReplaySession.load(folder: folder)
        let planned = session.frames.map {
            PlannedFrame(
                camera: CameraFrame(cameraToWorld: $0.cameraToWorld, intrinsics: $0.intrinsics, imageSize: SIMD2(Float($0.width), Float($0.height))),
                timestamp: $0.timestamp, trackingNormal: $0.trackingNormal
            )
        }
        if let declared = session.declaredWall, let frame = WallFrame(meter: declared.meter, outward: declared.outward, groundY: declared.groundY) {
            return Loaded(session: session, planned: planned, wall: frame, wallDescription: "recorded (wall taps in session.json)", groundMeasured: true)
        }
        guard let assumed = ReplayPlanning.assumedWall(frames: planned) else { throw ReplayError.noFrames }
        let description = String(
            format: "assumed from the trajectory: parallel to the walk, %.2f m to the side the camera faces, meter where the walk covers most, %d cells covered within 20 ft of it with every frame; not a measured wall",
            assumed.offset, assumed.coveredCells
        )
        return Loaded(session: session, planned: planned, wall: assumed.wall, wallDescription: description, groundMeasured: false)
    }

    /// One frame's depth, read off the main actor; nil when the session recorded none for it. A
    /// frame whose depth files are missing or the wrong size plays without depth, logged.
    nonisolated private static func loadDepth(_ frame: ReplayFrame, folder: URL) -> DepthImage? {
        do {
            return try ReplaySession.loadDepth(for: frame, folder: folder)
        } catch {
            RuntimeLog.engine.error("replay depth for \(frame.id, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    init(folder: URL, loaded: Loaded, onFrame: @escaping @MainActor (SourceFrame) -> Void) {
        self.folder = folder
        self.onFrame = onFrame
        session = loaded.session
        planned = loaded.planned
        wall = loaded.wall
        wallDescription = loaded.wallDescription
        groundMeasured = loaded.groundMeasured
    }

    /// Finds the frames to hold back for the autopilot's gap loop. Heavy, so it runs off the
    /// main actor; call once before the walk.
    /// Planned over the walk's frames only: the recording's closing tilt-up run is played for the
    /// tilt-up step and for requests above the walk (`ScanEngine.tiltUpFrames`), never in the walk.
    /// With `endsWherePhoneStood`, against the ends a walk ended by "Can't get there" sets,
    /// 1 m inside them (the cells skipped there are within 0.5 m of the phone).
    func prepareHeldBack(endsWherePhoneStood: Bool = false) async {
        let walkEnd = ScanEngine.tiltUpFrames(in: self, map: CoverageMap(wall: wall)).lowerBound
        let planned = Array(planned[..<walkEnd])
        let wall = wall
        let policy: ReplayPlanning.EndPolicy = endsWherePhoneStood ? .walked(margin: 1) : .coveredExtremes
        heldBack = await Task.detached(priority: .userInitiated) {
            ReplayPlanning.heldBackWindow(frames: planned, wall: wall, ends: policy)
        }.value
    }

    func camera(at index: Int) -> CameraFrame { planned[index].camera }

    // MARK: Playback

    /// Plays `range` in order, skipping `excluding`, at `speed` times the recorded pace.
    func play(range: Range<Int>, excluding: Range<Int>? = nil, speed: Double) {
        stop()
        let indices = range.filter { !(excluding?.contains($0) ?? false) }
        guard !indices.isEmpty else { return }
        isPlaying = true
        let frames = frames
        let folder = folder
        task = Task { [weak self] in
            var previous: Double?
            for index in indices {
                let frame = frames[index]
                let url = folder.appending(path: frame.imagePath)
                let started = ContinuousClock.now
                let (decoded, frameDepth) = await Task.detached(priority: .userInitiated) {
                    (ImageWork.decode(url), Self.loadDepth(frame, folder: folder))
                }.value
                if let previous {
                    let wait = Duration.seconds(max(0, (frame.timestamp - previous) / speed)) - (ContinuousClock.now - started)
                    if wait > .zero { try? await Task.sleep(for: wait) }
                }
                previous = frame.timestamp
                guard !Task.isCancelled, let self else { return }
                self.deliver(index: index, decoded: decoded, depth: frameDepth, isReview: false)
            }
            self?.isPlaying = false
        }
    }

    /// Shows one frame for tapping or review, outside auto-capture.
    func show(index: Int) {
        stop()
        guard frames.indices.contains(index) else { return }
        let url = folder.appending(path: frames[index].imagePath)
        task = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { ImageWork.decode(url) }.value
            guard !Task.isCancelled else { return }
            self?.deliver(index: index, decoded: decoded, depth: nil, isReview: true)
        }
    }

    /// Waits until the frame being shown is `index` (after `show`).
    func waitUntilShown(_ index: Int) async {
        for _ in 0..<100 where shownIndex != index {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isPlaying = false
    }

    /// A frame shown for review is never kept, so it goes without depth.
    private func deliver(index: Int, decoded: (CGImage, FrameQuality)?, depth: DepthImage?, isReview: Bool) {
        let frame = frames[index]
        shownIndex = index
        onFrame(SourceFrame(
            id: frame.id,
            timestamp: frame.timestamp,
            camera: planned[index].camera,
            tracking: frame.trackingNormal ? .normal : .limited(.unknown),
            quality: decoded?.1,
            jpeg: .file(folder.appending(path: frame.imagePath)),
            still: decoded?.0,
            meterAnchor: nil,
            depth: depth,
            isReview: isReview
        ))
    }

    // MARK: Choosing frames

    /// The frame that shows `point` best: in front of the camera, inside the image with the
    /// largest margin, preferring nearer cameras.
    func bestFrame(showing point: SIMD3<Float>) -> Int? {
        var best: (index: Int, score: Float)?
        for index in planned.indices {
            let camera = planned[index].camera
            guard let pixel = camera.pixel(of: point), camera.contains(pixel: pixel, margin: 0.1) else { continue }
            let centered = simd_length((pixel - camera.imageSize / 2) / camera.imageSize)
            let score = centered + 0.05 * simd_distance(camera.position, point)
            if score < best?.score ?? .infinity { best = (index, score) }
        }
        return best?.index
    }
}
