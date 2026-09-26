import ARKit
import Foundation
import HouseScanKit
import simd
import Synchronization

/// What the 3D map shows at one moment, read along the walk's wall.
struct Map3DSnapshot: Sendable {
    /// Increments whenever the map or the wall it is read along changes.
    var revision: Int
    var frame: MapFrame
    /// The walk's wall that `coverage`, `fog` and `nextView` are read along.
    var wall: WallFrame
    var coverage: Map3DCoverage
    var chain: MeasuredWallChain?
    var fog: FogOfWar
    var nextView: ViewSuggestion?
    /// The measured chain as a wall (`MeasuredWallChain.wallFrame`), with the coverage along it.
    /// Only `Map3DSession.finalSnapshot()` fills it: the export is its one reader, and reading
    /// coverage along a second wall twice a second would double the snapshot's cost.
    var measured: (wall: WallFrame, coverage: Map3DCoverage)?
    /// Whether measured depth (LiDAR or a replay's) went into the map since `start`. Without it
    /// the map holds only feature points, planes and estimated depth, which certify too little
    /// to report coverage from. Only `Map3DSession.finalSnapshot()` fills it, for the export.
    var integratedDepth = false
}

/// What the fog overlay draws from a snapshot (`ScanViewState.map3D`), in the map's frame:
/// `frame` converts it to world.
struct Map3DFog: Equatable, Sendable {
    var fog: FogOfWar
    var nextView: ViewSuggestion?
    var frame: MapFrame
}

/// The app's one `Map3D`: takes ARKit frames and anchors on the AR delegate queue and replay
/// frames on the main actor, integrates them on its own serial queue, and hands the main actor a
/// `Map3DSnapshot` at most `snapshotInterval` apart while the map changes.
///
/// Snapshots are read from a copy of the map on a second queue, one at a time, so integration
/// never waits for one. Timed once with a scratch test on an M4 Pro (not committed), a snapshot of
/// the LiDAR UI-test fixture's map took 27 ms with HouseScanKit built for release and 7 s built
/// for debug, 6.4 s of it fog and next view. Read on the integration queue, the debug app replaced
/// 45 of that replay's frames before integrating them, and its walk never saw a covered cell.
///
/// The AR delegate queue only converts ARKit objects (`Map3DFeed`) and drops the result into an
/// inbox, so a slow integration never holds ARKit's frames. The inbox holds one live depth or
/// feature frame: a newer one replaces an older one not yet integrated. Replay depth frames queue
/// instead, up to the replay's length (`ingest(_: SourceFrame)`). Mesh chunks and planes are kept
/// per anchor id, newest first, so the inbox is bounded by the anchors ARKit has.
///
/// Mesh chunks go into the map as they arrive and are not kept: a copy of every chunk would grow
/// with the walk. Only chunks that arrive while there is no map (before the meter is placed, or
/// after a reset) wait, newest per anchor, for the next `start`, which integrates those that reach
/// the map's bounds and drops them all. So a map rebuilt because the ground moved, or started
/// again after `reset(forgetAnchors: false)`, lacks the mesh ARKit sent to the map before: it has
/// only the chunks ARKit updates afterwards, and a stretch ARKit no longer refines stays without
/// mesh. Planes are small and kept whole across both. `reset(forgetAnchors: true)` drops the
/// waiting chunks and the planes too, for a session restarted with its anchors removed.
final class Map3DSession: Sendable {
    /// Two snapshots a second: the rate the fog overlay and the coverage strip were planned
    /// around. Each snapshot reads coverage and fog over the whole region of interest; no
    /// measurement of that cost on a phone exists yet.
    static let snapshotInterval: Double = 0.5

    /// How far the walk's ground may move from the map's before the map is rebuilt, meters. The
    /// voxels are laid out around the map's ground and reach `Map3DConfig.groundBelow` (0.5 m)
    /// under it, so within half of that the true ground stays well inside the grid; beyond it the
    /// map is rebuilt and loses the rays integrated so far. A guess, not measured: the chest-height
    /// ground guess the live walk starts with is ±0.3 m (`ScanEngine.estimatedGroundError`).
    static let groundTolerance: Float = 0.25

    private let queue = DispatchQueue(label: "dev.housescanning.housescan.map3d", qos: .utility)
    private let snapshotQueue = DispatchQueue(label: "dev.housescanning.housescan.map3d-snapshot", qos: .utility)
    /// Written by every caller; each lock is held only to add or take inputs.
    private let inbox = Mutex(Inbox())
    /// The map and what it is read along. Only the queue and `finalSnapshot()` lock it, and each
    /// takes the inbox inside that lock, so batches are applied in the order they were taken.
    private let core = Mutex(Core())
    private let onSnapshot: @MainActor @Sendable (Map3DSnapshot) -> Void

    init(onSnapshot: @escaping @MainActor @Sendable (Map3DSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    // MARK: Main actor

    /// Starts a new map at the meter: `MapFrame(wall:)`. Anything integrated before is dropped.
    func start(wall: WallFrame) {
        inbox.withLock { inbox in
            inbox.generation += 1
            inbox.active = true
            inbox.frame = nil
            inbox.estimated = []
            inbox.replay = []
            inbox.command = .start(wall)
            schedule(&inbox)
        }
    }

    /// The walk's wall changed. A moved meter moves the map with it (`MapFrame.following`,
    /// keeping its ground); a ground moved more than `groundTolerance` rebuilds it; corners only
    /// change the wall that coverage, fog and the next view are read along. Ignored before
    /// `start`.
    func update(wall: WallFrame) {
        inbox.withLock { inbox in
            guard inbox.active else { return }
            switch inbox.command {
            case .start?:
                // Nothing is integrated yet, so the map may as well start at the newer wall.
                inbox.command = .start(wall)
            case .update?, nil:
                inbox.command = .update(wall)
            }
            schedule(&inbox)
        }
    }

    /// Drops the map and its wall; nothing is integrated until the next `start`. With
    /// `forgetAnchors`, also the planes and waiting mesh chunks: pass it when the AR session
    /// restarts with its anchors removed. The mesh already in the map is lost either way (see the
    /// type's comment).
    func reset(forgetAnchors: Bool) {
        inbox.withLock { inbox in
            inbox.generation += 1
            inbox.active = false
            inbox.frame = nil
            inbox.estimated = []
            inbox.replay = []
            inbox.command = nil
            inbox.reset = .some((inbox.reset ?? false) || forgetAnchors)
            if forgetAnchors {
                inbox.planes = [:]
                inbox.chunks = [:]
            }
            schedule(&inbox)
        }
    }

    /// A replay frame. Only its LiDAR depth adds to the map: a replay carries no feature points,
    /// and frames without normal tracking, shown for review or carrying only a pose add nothing.
    /// Unlike live frames, none is dropped: `ReplayPlanning` plans the autopilot's gap with every
    /// depth frame, so the map must see the same ones. They queue, at most `replayLength` of them.
    @MainActor
    func ingest(_ frame: SourceFrame) {
        guard frame.tracking == .normal, !frame.isReview, !frame.isPoseOnly, let depth = frame.depth else { return }
        let camera = frame.camera
        inbox.withLock { inbox in
            guard inbox.active else { return }
            inbox.replay.append((depth, camera))
            if inbox.replay.count > max(1, inbox.replayLength) {
                inbox.replay.removeFirst()
                inbox.dropped += 1
            }
            schedule(&inbox)
        }
    }

    /// How many frames the replay being played has: the most its queue holds.
    func expectReplay(frames count: Int) {
        inbox.withLock { $0.replayLength = count }
    }

    // MARK: AR delegate queue

    /// A sampled ARKit frame: its LiDAR depth when it has some, else its feature points with the
    /// planes ARKit has at that frame. Only frames with normal tracking count: a limited pose can
    /// put rays half a meter off.
    func ingest(_ frame: ARFrame, trackingNormal: Bool) {
        guard trackingNormal, inbox.withLock({ $0.active }) else { return }
        let input: FrameInput = if let depth = Map3DFeed.depthFrame(frame) {
            .depth(depth)
        } else {
            .features(Map3DFeed.featureFrame(frame), planes: Map3DFeed.planes(frame))
        }
        inbox.withLock { inbox in
            guard inbox.active else { return }
            if inbox.frame != nil { inbox.dropped += 1 }
            inbox.frame = input
            schedule(&inbox)
        }
    }

    // MARK: Depth model queue

    /// An estimated depth frame (`DepthEstimator`) of a kept keyframe. Held apart from the
    /// sampled frame, which replaces itself ten times a second: an estimate comes once per kept
    /// keyframe and is not replaced by the next feature frame. At most `waitingEstimates` wait.
    func ingest(estimated depth: DepthFrame) {
        inbox.withLock { inbox in
            guard inbox.active else { return }
            inbox.estimated.append(depth)
            if inbox.estimated.count > Self.waitingEstimates {
                inbox.dropped += inbox.estimated.count - Self.waitingEstimates
                inbox.estimated.removeFirst(inbox.estimated.count - Self.waitingEstimates)
            }
            schedule(&inbox)
        }
    }

    /// Estimates waiting to be integrated, newest kept. One integrates in a few milliseconds and
    /// keyframes are kept at most about three a second, so more than a few waiting means the
    /// queue is stuck behind something else. A guess, not measured.
    private static let waitingEstimates = 4

    /// Anchors ARKit added or updated: mesh chunks and planes. Other anchors are ignored.
    func ingest(updated anchors: [ARAnchor]) {
        var planes: [UUID: PlaneObservation] = [:]
        var chunks: [UUID: MeshChunk] = [:]
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
                chunks[mesh.identifier] = Map3DFeed.meshChunk(mesh)
            } else if let plane = anchor as? ARPlaneAnchor {
                planes[plane.identifier] = Map3DFeed.plane(plane)
            }
        }
        guard !planes.isEmpty || !chunks.isEmpty else { return }
        inbox.withLock { inbox in
            for (id, plane) in planes { inbox.planes[id] = .some(plane) }
            for (id, chunk) in chunks { inbox.chunks[id] = .some(chunk) }
            schedule(&inbox)
        }
    }

    func ingest(removed anchors: [ARAnchor]) {
        let planes = anchors.filter { $0 is ARPlaneAnchor }.map(\.identifier)
        let chunks = anchors.filter { $0 is ARMeshAnchor }.map(\.identifier)
        guard !planes.isEmpty || !chunks.isEmpty else { return }
        inbox.withLock { inbox in
            for id in planes { inbox.planes[id] = .some(nil) }
            for id in chunks { inbox.chunks[id] = .some(nil) }
            schedule(&inbox)
        }
    }

    /// True while inputs wait to be integrated or a change to the map has not yet reached the
    /// main actor as a snapshot. The autopilot waits for it before acting on coverage; a person
    /// never needs to. Blocks while an integration runs.
    var isCatchingUp: Bool {
        if inbox.withLock({ $0.drainScheduled || $0.frame != nil || !$0.estimated.isEmpty || !$0.replay.isEmpty || $0.command != nil || $0.reset != nil }) { return true }
        return core.withLock { core in
            core.map != nil && (core.revision != core.publishedRevision || core.snapshotRunning || core.publishScheduled)
        }
    }

    // MARK: Export

    /// A snapshot of everything received so far, with `measured` filled, computed on the calling
    /// thread. Nil before `start`. It waits for an integration already running and can take a
    /// while itself, so call it off the main actor.
    func finalSnapshot() -> Map3DSnapshot? {
        core.withLock { core in
            drainInbox(into: &core)
            guard let map = core.map, let wall = core.wall else { return nil }
            var snapshot = Self.snapshot(map, wall: wall, revision: core.revision)
            snapshot.integratedDepth = core.integratedDepth
            if let chain = snapshot.chain, let measuredWall = chain.wallFrame(meter: wall.meter, groundY: wall.groundY, frame: map.frame) {
                snapshot.measured = (measuredWall, map.coverage(along: measuredWall))
            }
            return snapshot
        }
    }

    // MARK: Queue

    private enum FrameInput: Sendable {
        case depth(DepthFrame)
        case features(FeatureFrame, planes: [PlaneObservation])
    }

    private enum WallCommand: Sendable {
        case start(WallFrame)
        case update(WallFrame)
    }

    private struct Inbox: Sendable {
        /// Bumped by `start` and `reset`, so a snapshot of an older map is never delivered.
        var generation = 0
        /// A wall is set: frames are taken.
        var active = false
        var frame: FrameInput?
        var estimated: [DepthFrame] = []
        /// Replay depth frames in play order, converted on the queue, off the main actor.
        var replay: [(depth: DepthImage, camera: CameraFrame)] = []
        var replayLength = 0
        /// Frames replaced before they were integrated; logged with the next snapshot.
        var dropped = 0
        /// Applied before `command`. The value says whether to forget the anchors too.
        var reset: Bool?
        var command: WallCommand?
        /// Nil removes the anchor.
        var planes: [UUID: PlaneObservation?] = [:]
        var chunks: [UUID: MeshChunk?] = [:]
        var drainScheduled = false
    }

    private struct Core: Sendable {
        var map: Map3D?
        var wall: WallFrame?
        var generation = 0
        var planes: [UUID: PlaneObservation] = [:]
        /// Chunks that arrived while there was no map, for the next `start`.
        var waitingChunks: [UUID: MeshChunk] = [:]
        /// A measured depth frame (LiDAR or a replay's) went into the map since `start`
        /// (`Map3DSnapshot.integratedDepth`). Estimated depth doesn't count: it never certifies
        /// coverage, so a map with only estimated depth can't decide it. A rebuild after the
        /// ground moved keeps it: the phone still gives depth.
        var integratedDepth = false
        var revision = 0
        var publishedRevision = -1
        /// `ProcessInfo.systemUptime` at which the last snapshot was started.
        var lastPublish: Double?
        var publishScheduled = false
        var snapshotRunning = false
        var dropped = 0
    }

    /// Call with the inbox locked.
    private func schedule(_ inbox: inout Inbox) {
        guard !inbox.drainScheduled else { return }
        inbox.drainScheduled = true
        queue.async { [self] in
            core.withLock { drainInbox(into: &$0) }
            publishIfDue()
        }
    }

    /// Call with the core locked: takes everything in the inbox and applies it.
    private func drainInbox(into core: inout Core) {
        let taken = inbox.withLock { inbox -> Inbox in
            let taken = inbox
            inbox.frame = nil
            inbox.estimated = []
            inbox.replay = []
            inbox.dropped = 0
            inbox.reset = nil
            inbox.command = nil
            inbox.planes = [:]
            inbox.chunks = [:]
            inbox.drainScheduled = false
            return taken
        }
        core.generation = taken.generation
        core.dropped += taken.dropped
        var changed = false

        if let forgetAnchors = taken.reset {
            core.map = nil
            core.wall = nil
            if forgetAnchors {
                core.planes = [:]
                core.waitingChunks = [:]
            }
            core.integratedDepth = false
            changed = true
        }
        for (id, plane) in taken.planes {
            core.planes[id] = plane
            if let plane { core.map?.update(plane) } else { core.map?.removePlane(id: id) }
        }
        for (id, chunk) in taken.chunks {
            if core.map == nil {
                core.waitingChunks[id] = chunk
            } else if let chunk {
                core.map?.update(chunk)
            } else {
                core.map?.removeMeshChunk(id: id)
            }
        }
        if core.map != nil, !taken.planes.isEmpty || !taken.chunks.isEmpty { changed = true }
        switch taken.command {
        case .start(let wall)?:
            var map = Self.newMap(at: wall, planes: core.planes)
            var outside = 0
            for chunk in core.waitingChunks.values {
                if Self.reaches(chunk, map) { map.update(chunk) } else { outside += 1 }
            }
            let waiting = core.waitingChunks.count
            if waiting > 0 {
                RuntimeLog.engine.info("3D map started with \(waiting - outside) waiting mesh chunks; \(outside) wholly outside its bounds dropped")
            }
            core.waitingChunks = [:]
            core.integratedDepth = false
            core.map = map
            core.wall = wall
            changed = true
        case .update(let wall)?:
            if follow(wall, in: &core) { changed = true }
        case nil:
            break
        }
        // A frame taken after a reset but before the next start has no map to go into.
        if var map = core.map, let frame = taken.frame {
            // Moved out of `core` so the grid is integrated in place instead of copied.
            core.map = nil
            switch frame {
            case .depth(let depth):
                map.integrate(depth)
                core.integratedDepth = true
            case .features(let features, let planes):
                // The frame's planes are every plane ARKit had then: any other one is gone.
                let current = Set(planes.map(\.id))
                for id in core.planes.keys where !current.contains(id) {
                    core.planes[id] = nil
                    map.removePlane(id: id)
                }
                for plane in planes {
                    core.planes[plane.id] = plane
                    map.update(plane)
                }
                map.integrate(features)
            }
            core.map = map
            changed = true
        }
        if var map = core.map, !taken.estimated.isEmpty {
            core.map = nil
            for depth in taken.estimated { map.integrate(depth) }
            core.map = map
            changed = true
        }
        if var map = core.map, !taken.replay.isEmpty {
            core.map = nil
            for item in taken.replay { map.integrate(DepthFrame(image: item.depth, pose: item.camera)) }
            core.integratedDepth = true
            core.map = map
            changed = true
        }
        if changed { core.revision += 1 }
    }

    /// Applies a changed wall to the map: the map follows the meter, or is rebuilt when the ground
    /// moved beyond `groundTolerance`. Returns whether anything changed.
    private func follow(_ wall: WallFrame, in core: inout Core) -> Bool {
        guard var map = core.map, let old = core.wall, wall != old else { return false }
        core.wall = wall
        let ground = wall.groundY - wall.meter.y
        guard abs(ground - map.frame.groundY) <= Self.groundTolerance else {
            RuntimeLog.engine.info("3D map rebuilt without its rays and mesh: the ground moved from \(map.frame.groundY) to \(ground) m below the meter")
            core.map = Self.newMap(at: wall, planes: core.planes)
            return true
        }
        guard wall.meter != old.meter else { return true }
        core.map = nil
        map.reanchor(map.frame.following(anchorMovedFrom: Self.translation(old.meter), to: Self.translation(wall.meter)))
        core.map = map
        return true
    }

    private static func newMap(at wall: WallFrame, planes: [UUID: PlaneObservation]) -> Map3D {
        var map = Map3D(frame: MapFrame(wall: wall))
        for plane in planes.values { map.update(plane) }
        return map
    }

    /// Whether the box around a chunk's vertices, in the map's frame, meets the map's bounds.
    private static func reaches(_ chunk: MeshChunk, _ map: Map3D) -> Bool {
        let mapFromChunk = map.frame.mapFromWorld * chunk.worldFromChunk
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for v in chunk.vertices {
            let p = mapFromChunk * SIMD4(v, 1)
            let q = SIMD3(p.x, p.y, p.z)
            low = simd_min(low, q)
            high = simd_max(high, q)
        }
        return all(high .>= map.bounds.min) && all(low .< map.bounds.max)
    }

    private static func translation(_ p: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(p, 1)
        return m
    }

    private static func snapshot(_ map: Map3D, wall: WallFrame, revision: Int) -> Map3DSnapshot {
        Map3DSnapshot(
            revision: revision, frame: map.frame, wall: wall, coverage: map.coverage(along: wall),
            chain: map.measuredWalls(), fog: map.fogOfWar(along: wall), nextView: map.nextBestView(along: wall), measured: nil)
    }

    /// On the queue: when the map changed, no snapshot is being read and the last one started at
    /// least `snapshotInterval` ago, starts reading one from a copy of the map on the snapshot
    /// queue; too soon, schedules itself for when it will be due. A finished snapshot checks again,
    /// for changes made while it was read.
    private func publishIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        let job = core.withLock { core -> (map: Map3D, wall: WallFrame, revision: Int, generation: Int, dropped: Int)? in
            guard let map = core.map, let wall = core.wall, core.revision != core.publishedRevision, !core.snapshotRunning else { return nil }
            if let last = core.lastPublish, now - last < Self.snapshotInterval {
                guard !core.publishScheduled else { return nil }
                core.publishScheduled = true
                queue.asyncAfter(deadline: .now() + (Self.snapshotInterval - (now - last))) { [self] in
                    self.core.withLock { $0.publishScheduled = false }
                    publishIfDue()
                }
                return nil
            }
            core.publishedRevision = core.revision
            core.lastPublish = now
            core.snapshotRunning = true
            let dropped = core.dropped
            core.dropped = 0
            return (map, wall, core.revision, core.generation, dropped)
        }
        guard let job else { return }
        if job.dropped > 0 {
            RuntimeLog.engine.info("3D map: \(job.dropped) frames replaced before they were integrated")
        }
        let onSnapshot = onSnapshot
        snapshotQueue.async { [self] in
            let snapshot = Self.snapshot(job.map, wall: job.wall, revision: job.revision)
            Task { @MainActor [self] in
                // A snapshot of a map dropped since (a reset or a new start) must not reach the UI.
                if inbox.withLock({ $0.generation }) == job.generation { onSnapshot(snapshot) }
                // Only now, so `isCatchingUp` stays true until the snapshot is applied.
                core.withLock { $0.snapshotRunning = false }
                queue.async { [self] in publishIfDue() }
            }
        }
    }
}
