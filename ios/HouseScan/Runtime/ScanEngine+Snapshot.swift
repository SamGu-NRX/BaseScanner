import Foundation
import HouseScanKit
import OSLog
import simd

/// Everything an upload sends, frozen on the main actor at one frame: scene.json, the mesh's
/// measurements and the packet are all built from it and read nothing live afterwards.
///
/// It is taken on the last frame the engine ingested (live, the one that also carried its own
/// mesh and planes, `LiveCapture.requestSpatialCapture`), after that frame's anchor correction
/// and ground update. So the wall, the ground, the coverage, the marks and the mesh describe one
/// world frame. Raw poses are kept as ARKit reported them (`StoredKeyframe.rawPose`); the
/// corrections to apply for scene.json and the 1.1 packet travel with them (`corrections`).
struct UploadSnapshot: Sendable {
    /// `ScanEngine.spatialRevision` when taken: an answer to a scan whose geometry has changed
    /// since is stale (`ScanEngine.upload`).
    var revision: Int
    /// The time of the last frame ingested when it was taken, whose corrections it includes;
    /// nil before any frame.
    var frameTime: Double?
    var map: CoverageMap
    var groundMeasured: Bool
    /// The marks with their tapped world points; their wall coordinates are worked out against
    /// `map.wall` when exported.
    var features: [MarkedFeature]
    /// Raw, as stored; `corrections` moves each for the export.
    var keyframes: [StoredKeyframe]
    var stills: [String: String]
    var stillFrames: [String: StoredKeyframe]
    var corrections: PoseCorrections
    var meterPlaneSource: MeterPlaneSource
    var leftEndIsLimit: Bool
    var rightEndIsLimit: Bool
    /// The ground at checked spots' footprints, against this snapshot's wall and ground.
    var groundPatches: [SceneGroundPatch]
    /// The frame's own mesh and planes, when the frame carried them; nil when it didn't (no
    /// LiDAR, a replay, or no matching frame arrived in time), and the scan goes without.
    var mesh: LiveCapture.MeshSnapshot?
    var planes: [LiveCapture.PlaneSnapshot]
}

extension ScanEngine {
    /// How long an upload waits for a frame carrying its mesh and planes. Frames are sampled
    /// about ten times a second; 2 s allows for a stall. A guess, not measured.
    static let spatialFrameWait: Duration = .seconds(2)

    /// The snapshot as of the last frame ingested, with `spatial` only when it came with that
    /// frame (same time).
    func makeUploadSnapshot(spatial: FrameSpatialCapture?) -> UploadSnapshot? {
        guard let map = coverage else { return nil }
        let frameTime = captureClock
        let matched = spatial.flatMap { $0.time == frameTime ? $0 : nil }
        if spatial != nil, matched == nil {
            RuntimeLog.engine.error("snapshot: the mesh came from another frame; the scan goes without it")
        }
        return UploadSnapshot(
            revision: spatialRevision, frameTime: frameTime, map: map, groundMeasured: groundMeasured,
            features: state.features, keyframes: store.keyframes, stills: store.stills, stillFrames: store.stillFrames,
            corrections: poseCorrections, meterPlaneSource: meterPlaneSource,
            leftEndIsLimit: wallEndKinds[.left] == .limit, rightEndIsLimit: wallEndKinds[.right] == .limit,
            groundPatches: spotGroundPatches, mesh: matched?.mesh, planes: matched?.planes ?? [])
    }

    /// Takes the upload's snapshot. Live, on the next frame that carries its own mesh and planes
    /// (taken in `ingest`, right after that frame's corrections); if none arrives within
    /// `spatialFrameWait`, or the source is gone, at the current frame without mesh or planes.
    /// On a replay, at once, without.
    func takeUploadSnapshot() async -> UploadSnapshot? {
        guard let live = liveCapture, mayCapture else { return makeUploadSnapshot(spatial: nil) }
        // A request still waiting belongs to an upload that was replaced: it gets nothing.
        cancelPendingSnapshot()
        snapshotRequest += 1
        let request = snapshotRequest
        return await withCheckedContinuation { (continuation: CheckedContinuation<UploadSnapshot?, Never>) in
            pendingSnapshot = continuation
            live.requestSpatialCapture()
            Task {
                try? await Task.sleep(for: Self.spatialFrameWait)
                guard snapshotRequest == request, let waiting = pendingSnapshot else { return }
                pendingSnapshot = nil
                RuntimeLog.engine.error("snapshot: no frame with its mesh arrived; the scan goes without the mesh")
                waiting.resume(returning: makeUploadSnapshot(spatial: nil))
            }
        }
    }

    /// Called by `ingest` after a frame's spatial update: a frame carrying its mesh completes a
    /// pending snapshot, taken on that frame.
    func completeUploadSnapshot(with frame: SourceFrame) {
        guard let spatial = frame.spatial, let waiting = pendingSnapshot else { return }
        pendingSnapshot = nil
        waiting.resume(returning: makeUploadSnapshot(spatial: spatial))
    }

    /// Ends a waiting snapshot request with nothing (a reset, a replaced upload).
    func cancelPendingSnapshot() {
        guard let waiting = pendingSnapshot else { return }
        pendingSnapshot = nil
        waiting.resume(returning: nil)
    }
}
