import ARKit
import CoreGraphics
import Foundation
import HouseScanKit
import OSLog
import simd
import SwiftUI

/// The capture engine: the only writer of `ScanViewState`, and the implementation of the
/// homeowner's intents. Frames arrive from `LiveCapture` (ARKit) or `ReplayPlayer` (a recorded
/// session) and take the same path through auto-capture, coverage and guidance.
@MainActor
final class ScanEngine {
    let state = ScanViewState()
    let options: LaunchOptions

    // Sources
    private(set) var replay: ReplayPlayer?
    /// Which kind of plane the meter tap hit; an estimated plane widens the meter's error in the
    /// export. A replay's wall comes from the recording, so it counts as detected.
    var meterPlaneSource: MeterPlaneSource = .detectedPlane
    private var live: LiveCapture?

    // Capture logic (HouseScanKit)
    private(set) var coverage: CoverageMap?
    private var autoCapture = AutoCapture()
    private var closeUpGate = CloseUpGate()
    private var planner = GuidancePlanner()
    let gapPlanner = GapPlanner()

    // Stored evidence
    private(set) var store: KeyframeStore
    private var keptSourceIDs: Set<String> = []
    /// Debounces coaching that comes from the capture gate (see `gateCoaching`).
    private var gateProblem: (coaching: Coaching, since: Double)?
    private var gateClearSince: Double?
    private var closeUpPending = false
    /// Why the last close-up has to be retaken (from the meter-number reader, or "None of
    /// these"), and when that was said, in screen seconds. Shown until the next shot fires.
    private var closeUpRetake: (problem: CloseUpProblem, since: Double)?
    /// The reader's answer for the close-up on screen, for the advice after "None of these".
    private var meterReadout: MeterReadout?
    /// Keyframe writes still in flight, by the `generation` they started in; the bundle waits
    /// for its own generation's. Keyed so a write finishing after a reset can't count against
    /// the new scan (a plain counter went negative when `resetAll` zeroed it mid-write).
    private var pendingSaves: [Int: Int] = [:]
    /// Bumped whenever the world frame or the whole scan is thrown away, so work that finishes
    /// afterwards (a keyframe write, an upload) can tell it belongs to a scan that no longer exists.
    private var generation = 0

    // Wall geometry inputs
    private var meterAnchorID: UUID?
    /// Detected horizontal planes as (center x, y, center z, radius), world meters.
    private var groundPlanes: [SIMD4<Float>] = []
    private var lastFrame: SourceFrame?
    /// Whether `WallFrame.groundY` comes from a detected plane (or a recording's wall taps) rather
    /// than the chest-height guess. The export widens position errors while it is a guess.
    private(set) var groundMeasured = false
    private var endKinds: [WallSide: EndKind] = [:]

    // Gap loop
    private var gapPlan: GapPlan?
    private var gapCounter = 0
    /// Keyframes stored when the current gap request began: a request is closed only by new views.
    private var keyframesAtGapStart = 0
    private var skippedGaps: [GapPlan] = []
    /// The side of a server past_end request being captured: that end was cleared, and marking
    /// it again settles the request (see `markWallEnd`).
    var pastEndSide: WallSide?

    // Tracking recovery
    private var relocalizingSince: Double?

    // Upload
    let resultClient: any ResultClient
    private var uploadTask: Task<Void, Never>?
    private(set) var placement: PlacementResult?

    private var lastGuidanceLog = ""
    /// Taps of the feature being marked, in wall coordinates.
    var pendingTaps: [WallPoint] = []

    enum EndKind {
        /// The homeowner marked the end and said something blocks the wall there (a fence, gate
        /// or property line).
        case limit
        /// The wall may go on past this end: it turns a corner, the walk stopped there ("I can't
        /// get there"), or the homeowner has not said what is there yet.
        case unexplored
    }

    init(options: LaunchOptions) {
        self.options = options
        store = KeyframeStore()
        if let url = options.serverURL, !options.sampleResult {
            resultClient = HTTPResultClient(serverURL: url)
        } else {
            resultClient = SampleResultClient(pace: options.autopilot ? options.autopilotHold : 1.2)
        }
        state.isAutopilot = options.autopilot
        state.isReplay = options.replayFolder != nil
        state.usesSampleResult = resultClient.isSample
    }

    // MARK: Start

    func start() {
        RuntimeLog.state.info("STATE=\(self.state.phase.rawValue, privacy: .public)")
        if let folder = options.replayFolder {
            Task { await loadReplay(folder) }
        } else if !ARWorldTrackingConfiguration.isSupported {
            fail(.arUnsupported)
        }
    }

    /// Every failure the homeowner has to act on (no AR, camera denied, a failed session, an
    /// unreadable replay) ends on the failure screen, which reads `state.failure` for its words.
    /// Setting the failure alone left the flow on whatever screen was up.
    private func fail(_ failure: ScanFailure) {
        state.failure = failure
        go(.unsupported)
    }

    private func loadReplay(_ folder: URL) async {
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try ReplayPlayer.load(folder: folder) }.value
            let player = ReplayPlayer(folder: folder, loaded: loaded) { [weak self] frame in self?.ingest(frame) }
            replay = player
            player.show(index: 0)
            RuntimeLog.engine.info("replay \(player.session.id, privacy: .public): \(player.frames.count) frames, wall \(player.wallDescription, privacy: .public)")
        } catch {
            RuntimeLog.engine.error("replay unreadable: \(String(describing: error), privacy: .public)")
            fail(.replayUnreadable(String(describing: error)))
        }
    }

    // MARK: Phases

    func go(_ phase: ScanPhase) {
        guard state.phase != phase else { return }
        state.phase = phase
        RuntimeLog.state.info("STATE=\(phase.rawValue, privacy: .public)")
        switch phase {
        case .findMeter:
            state.guidance = .findMeter
            startSourceIfNeeded()
            live?.setMode(.idle)
        case .meterCloseUp:
            state.guidance = .holdOnMeter
            state.closeUp = .aiming(hold: 0, problem: nil)
            closeUpGate = CloseUpGate()
            closeUpPending = false
            closeUpRetake = nil
            meterReadout = nil
            state.meterNumber = nil
            state.closeUpFailedAttempts = 0
            live?.setMode(.closeUp)
            if let replay { replay.play(range: 0..<replay.frames.count, speed: replaySpeed) }
        case .wallWalk:
            live?.setMode(.walk)
            planner.reset()
            if let replay {
                replay.play(range: 0..<replay.frames.count, excluding: replay.heldBack?.frames, speed: replaySpeed)
            }
        case .gapRequest:
            live?.setMode(.walk)
            if let replay {
                let range = replay.heldBack.map { ReplayPlanning.gapReplayRange($0.frames) } ?? 0..<replay.frames.count
                autoCapture.reset()
                replay.play(range: range, speed: replaySpeed)
            }
        case .markFeatures, .uploading, .result:
            live?.setMode(.idle)
            replay?.stop()
        case .resultAR:
            live?.setMode(.idle)
            if let replay, let index = bestFrameForResult() { replay.show(index: index) }
        case .onboarding, .unsupported:
            break
        }
    }

    private var replaySpeed: Double { options.autopilot ? 3 : 1 }

    /// How long a finished step (close-up taken, gap closed) stays on screen before the next.
    private var autoAdvanceDelay: Double { options.autopilot ? max(1.2, options.autopilotHold) : 1.2 }

    /// With `-autopilotGate`, waits until the UI test has finished with `phase` (its file exists),
    /// for at most two minutes so a lost gate file can't hang the app.
    func waitForGate(_ phase: ScanPhase) async {
        guard options.autopilot, let gate = options.autopilotGate else { return }
        let file = gate.appending(path: phase.rawValue)
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline, !FileManager.default.fileExists(atPath: file.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func startSourceIfNeeded() {
        guard replay == nil, live == nil, state.failure == nil else { return }
        let capture = LiveCapture(
            onFrame: { [weak self] frame in self?.ingest(frame) },
            onEvent: { [weak self] event in self?.handle(event) }
        )
        live = capture
        state.feed = .live
        capture.start()
    }

    // MARK: Frames

    func ingest(_ frame: SourceFrame) {
        if !frame.isPoseOnly { lastFrame = frame }
        if let still = frame.still { state.feed = .still(still) }
        state.projection = frame.projection
        if state.tracking != frame.tracking { state.tracking = frame.tracking }
        if !frame.groundPlanes.isEmpty, frame.groundPlanes != groundPlanes {
            groundPlanes = frame.groundPlanes
            refineGround()
        }
        refreshMeterFromAnchor(frame)
        guard !frame.isPoseOnly else { return }
        trackRelocalization(frame)
        guard !frame.isReview else {
            refreshCues(camera: frame.camera)
            return
        }

        switch state.phase {
        case .meterCloseUp:
            closeUp(frame)
        case .wallWalk, .gapRequest:
            walk(frame)
        case .findMeter:
            state.coaching = coaching(for: frame.tracking, skip: nil)
        default:
            break
        }
    }

    /// Re-runs the ground lookup as ARKit adds or grows horizontal planes, so a plane below the
    /// wall always replaces the guess, and a better plane replaces an earlier one.
    private func refineGround() {
        guard var wall = coverage?.wall, let y = groundBelow(wall.meter) else { return }
        // 1 cm: far under tap error, and it keeps plane jitter from republishing every frame.
        guard !groundMeasured || abs(y - wall.groundY) > 0.01 else { return }
        RuntimeLog.engine.info("ground at y=\(y) from a detected plane (was \(wall.groundY), \(self.groundMeasured ? "measured" : "estimated", privacy: .public))")
        wall.groundY = y
        groundMeasured = true
        // Rebuilds coverage from the kept cameras: the rows now sit at other heights.
        coverage?.updateWall(wall)
        publishWall()
        publishCoverage()
        reprojectFeatures()
    }

    /// Door and window heights, spans and fence distances follow the wall frame; the tapped world
    /// points stay put.
    private func reprojectFeatures() {
        guard let wall = coverage?.wall, !state.features.isEmpty else { return }
        var features = state.features
        for index in features.indices { Self.project(&features[index], onto: wall) }
        if features != state.features { state.features = features }
    }

    private func refreshMeterFromAnchor(_ frame: SourceFrame) {
        guard let anchor = frame.meterAnchor, var wall = coverage?.wall else { return }
        let meter = SIMD3(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
        // A wall-frame change replays every kept camera through the coverage map on the main
        // actor, and ARKit nudges the anchor by millimetres most frames. 2 cm is far below the
        // 6 in cell and doesn't show in the overlays; 2 mm would rebuild nearly every frame.
        guard simd_distance(meter, wall.meter) > 0.02 else { return }
        wall.meter = meter
        coverage?.updateWall(wall)
        publishWall()
        publishCoverage()
        reprojectFeatures()
    }

    private func closeUp(_ frame: SourceFrame) {
        guard let wall = coverage?.wall else { return }
        if case .captured = state.closeUp { return }
        if case .skipped = state.closeUp { return }
        state.coaching = coaching(for: frame.tracking, skip: nil)
        // After a retake request the shutter waits long enough for the reason to be read (and,
        // for "move closer", acted on) before the hold can start again.
        if let retake = closeUpRetake, screenTime - retake.since < Self.retakeNotice {
            state.closeUp = .aiming(hold: 0, problem: retake.problem)
            return
        }
        let sample = FrameSample(timestamp: frame.timestamp, camera: frame.camera, tracking: frame.captureTracking, quality: frame.quality)
        let status = closeUpGate.evaluate(sample, meter: wall.meter)
        state.closeUpFailedAttempts = status.failedAttempts
        if status.fire || closeUpPending, status.issue == nil, frame.jpeg.isAvailable {
            closeUpPending = false
            closeUpRetake = nil
            captureCloseUp(frame)
        } else {
            // A hold that finished on a frame without a photo waits for the next photo, but only
            // while the gates keep passing; any problem restarts the hold.
            closeUpPending = status.issue == nil && (closeUpPending || status.fire)
            state.closeUp = .aiming(hold: status.hold, problem: status.issue.map(Self.problem) ?? closeUpRetake?.problem)
        }
    }

    /// Seconds a retake reason stays up before the next close-up can be taken. A guess to try
    /// on a phone, not measured: long enough to read one short line.
    private static let retakeNotice: Double = 2

    private var screenTime: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    /// Back to aiming because the close-up photo was not usable (not saved, no number read, or
    /// "None of these"). Counts as a failed attempt, so "Can't get a clear shot" appears from
    /// the second one on.
    func retakeCloseUp(_ problem: CloseUpProblem) {
        guard state.phase == .meterCloseUp else { return }
        RuntimeLog.engine.info("close-up retake: \(String(describing: problem), privacy: .public)")
        closeUpGate.photoRejected()
        state.closeUpFailedAttempts = closeUpGate.failedAttempts
        closeUpPending = false
        closeUpRetake = (problem, screenTime)
        meterReadout = nil
        state.meterNumber = nil
        state.closeUp = .aiming(hold: 0, problem: problem)
    }

    /// The meter number was confirmed: on to the walk once the confirmation has been seen.
    func finishCloseUp() {
        let scan = generation
        Task {
            try? await Task.sleep(for: .seconds(autoAdvanceDelay))
            await waitForGate(.meterCloseUp)
            if scan == generation, state.phase == .meterCloseUp { go(.wallWalk) }
        }
    }

    /// The reader's answer for the close-up on screen, or nil while none is showing.
    var currentMeterReadout: MeterReadout? { meterReadout }

    private func captureCloseUp(_ frame: SourceFrame) {
        state.closeUp = .captured(nil)
        let scan = generation
        let store = store
        Task {
            let saved = await store.saveStill(frame.jpeg, name: "meter_close.jpg")
            guard scan == generation, state.phase == .meterCloseUp else { return }
            if !saved {
                retakeCloseUp(.blurry)
                return
            }
            let thumbnail = await store.thumbnail(ofStill: "meter_close.jpg")
            guard scan == generation, state.phase == .meterCloseUp else { return }
            state.closeUp = .captured(thumbnail)
            state.captureCount += 1
            state.lastCapture = CaptureEvent(id: state.captureCount, kind: .closeUp, thumbnail: thumbnail)
            await readMeterNumber(scan: scan)
        }
    }

    /// Reads the meter number from the saved close-up, off the main actor, then offers the
    /// candidates for the homeowner to pick from (never filling one in) or asks for a retake.
    private func readMeterNumber(scan: Int) async {
        state.meterNumber = .reading
        let reader = MeterNumberReaders.make()
        let photo = store.directory.appending(path: "meter_close.jpg")
        let readout = await Task.detached(priority: .userInitiated) { () -> MeterReadout? in
            guard let jpeg = try? Data(contentsOf: photo) else { return nil }
            return await reader.read(jpeg: jpeg)
        }.value
        guard scan == generation, state.phase == .meterCloseUp, state.meterNumber == .reading else { return }
        guard let readout else {
            RuntimeLog.engine.error("close-up photo could not be read back for the meter number")
            retakeCloseUp(.noNumber)
            return
        }
        guard !readout.candidates.isEmpty else {
            retakeCloseUp(readout.retake ?? .noNumber)
            return
        }
        RuntimeLog.engine.info("meter number: \(readout.candidates.count) candidates to choose from")
        meterReadout = readout
        state.meterNumber = .choose(readout.candidates)
    }

    private func walk(_ frame: SourceFrame) {
        guard let map = coverage else { return }
        let sample = FrameSample(timestamp: frame.timestamp, camera: frame.camera, tracking: frame.captureTracking, quality: frame.quality)
        let decision = autoCapture.evaluate(sample, newlySeenCells: map.newlySeenCount(from: frame.camera))
        var skip: CaptureDecision.SkipReason?
        if case .skip(let reason) = decision { skip = reason }
        if decision.isKeep, frame.jpeg.isAvailable, !keptSourceIDs.contains(frame.id) {
            autoCapture.didKeep(sample)
            keptSourceIDs.insert(frame.id)
            keep(frame)
        }
        state.coaching = walkCoaching(tracking: frame.tracking, skip: skip, time: frame.timestamp)
        afterCoverageChange(camera: frame.camera, time: frame.timestamp)
    }

    /// Tracking problems show at once. A problem the capture gate reports (moving, blurry, too
    /// dark) shows only once it has lasted `showAfter` seconds and clears after `clearAfter`
    /// seconds of frames without it: the gate judges every frame, and one fast frame at 30 fps
    /// would otherwise flash a prompt for a single frame. During the walk moving and blurry read
    /// as "Slow down", never "Hold steady", which would tell a walking homeowner to stop. Both
    /// durations are guesses to try on a phone, not measured.
    private func walkCoaching(tracking: TrackingQuality, skip: CaptureDecision.SkipReason?, time: Double) -> Coaching? {
        let showAfter = 0.7
        let clearAfter = 0.5
        guard tracking == .normal else {
            gateProblem = nil
            gateClearSince = nil
            return coaching(for: tracking, skip: nil)
        }
        let candidate: Coaching? = switch skip {
        case .moving?, .blurry?: .slowDown
        case .tooDark?: .tooDark
        default: nil
        }
        if let problem = gateProblem, time < problem.since { gateProblem = nil }  // replay restarted
        if let candidate {
            gateClearSince = nil
            if gateProblem?.coaching != candidate {
                gateProblem = (candidate, time)
            }
        } else if let problem = gateProblem {
            let clearSince = gateClearSince ?? time
            gateClearSince = clearSince
            if time - clearSince >= clearAfter || time - problem.since < showAfter {
                gateProblem = nil
                gateClearSince = nil
            }
        }
        guard let problem = gateProblem, time - problem.since >= showAfter else { return nil }
        return problem.coaching
    }

    private func afterCoverageChange(camera: CameraFrame?, time: Double) {
        publishCoverage()
        if state.phase == .wallWalk, let camera {
            updateGuidance(camera: camera, time: time)
        } else if state.phase == .gapRequest {
            updateGap(camera: camera)
        }
    }

    /// Stores a kept frame; coverage and the capture count move only once its photo is on disk,
    /// so the strip never claims a view the bundle lacks.
    private func keep(_ frame: SourceFrame) {
        let kind: CaptureEvent.Kind = state.phase == .gapRequest ? .gap : .walk
        let index = store.nextKeyframeIndex()
        let scan = generation
        let store = store
        pendingSaves[scan, default: 0] += 1
        Task {
            let saved = await store.saveKeyframe(frame.jpeg, index: index, camera: frame.camera)
            let left = (pendingSaves[scan] ?? 1) - 1
            pendingSaves[scan] = left > 0 ? left : nil
            guard scan == generation, saved.stored else { return }
            // Coverage only moves on kept frames with normal tracking (checklist R3).
            coverage?.observe(frame.camera, trackingNormal: frame.tracking == .normal)
            state.captureCount += 1
            state.lastCapture = CaptureEvent(id: state.captureCount, kind: kind, thumbnail: saved.thumbnail)
            afterCoverageChange(camera: lastFrame?.camera, time: lastFrame?.timestamp ?? frame.timestamp)
        }
    }

    // MARK: Guidance

    /// The planner's dwell runs on the screen's clock, not on `time` (the frame's timestamp).
    /// "Don't change the instruction for 3 s" is about what the person looking at the screen
    /// reads. Live, the two clocks agree; a replay at 3x speed on frame time changed the card
    /// every second or so, which the verify lane's wall-clock check (I6) and the accessibility
    /// audit both caught.
    private func updateGuidance(camera: CameraFrame, time _: Double) {
        // The end question is on screen: the next step waits for its answer.
        guard let map = coverage, state.endQuestion == nil else { return }
        let screenTime = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let output = planner.update(coverage: map, camera: camera, time: screenTime)
        state.guidance = Self.step(output.task)
        state.target = output.target
        state.path = output.path
        logGuidance()
    }

    /// A frame shown for review (not captured) keeps the current task but re-aims its target and
    /// path from the camera now on screen; otherwise the arrow points from where the walk last was.
    private func refreshCues(camera: CameraFrame) {
        guard state.phase == .wallWalk, state.endQuestion == nil, let map = coverage, let task = planner.current else { return }
        let output = planner.cues(for: task, coverage: map, camera: camera)
        state.target = output.target
        state.path = output.path
    }

    /// "I can't get there" or an answered end question settled the current task: choose the next
    /// one now.
    func resetGuidanceAfterSkip(camera: CameraFrame, time: Double) {
        planner.reset()
        updateGuidance(camera: camera, time: time)
    }

    private func updateGap(camera: CameraFrame?) {
        guard let map = coverage, let plan = gapPlan, var request = state.gap else { return }
        request.progress = gapPlanner.progress(of: plan, map)
        let satisfied = gapPlanner.isSatisfied(plan, map) && store.keyframes.count > keyframesAtGapStart
        state.guidance = .gap
        let center = (plan.span.lowerBound + plan.span.upperBound) / 2
        let cue = gapCue(plan, map, center: center)
        state.target = cue.target
        if let camera {
            let from = map.wall.wallPoint(camera.position).s
            state.path = [from, center].map { map.wall.world(s: $0, height: 0, out: cue.standOut) }
        }
        logGuidance()
        if satisfied, !request.isSatisfied {
            request.isSatisfied = true
            request.progress = max(request.progress, gapPlanner.config.satisfiedFraction)
            state.gap = request
            RuntimeLog.engine.info("gap \(request.id) satisfied")
            let id = request.id
            Task {
                try? await Task.sleep(for: .seconds(autoAdvanceDelay))
                await waitForGate(.gapRequest)
                // Only if this same request is still showing (not skipped or replaced meanwhile).
                guard state.phase == .gapRequest, state.gap?.id == id else { return }
                afterGapResolved()
            }
        } else if !request.isSatisfied {
            state.gap = request
        }
    }

    /// Where a gap request points the camera, and how far out from the wall to walk for it.
    private func gapCue(_ plan: GapPlan, _ map: CoverageMap, center: Float) -> (target: SIMD3<Float>, standOut: Float) {
        let standOff = planner.config.standOff
        switch plan.need {
        case .cells:
            let target = plan.band == .ground
                ? map.wall.world(s: center, height: 0, out: map.config.groundBandDepth / 2)
                : map.wall.world(s: center, height: 1.2)
            return (target, standOff)
        case .groundOut(let out):
            // 1 m beyond the requested depth: a phone at chest height (about 1.4 m) tilted down
            // there sees the ground from about 2 m nearer the wall out to that depth, within the
            // 65 degree view limit. Geometry only; not tried on a device.
            return (map.wall.world(s: center, height: 0, out: out), max(standOff, out + 1))
        case .walkOut(let out):
            // The walk has to pass `out` plus the position error at the span's far edge; 0.3 m
            // more leaves room for drifting toward the wall. The 0.3 m is a guess.
            let farEdge = max(abs(plan.span.lowerBound), abs(plan.span.upperBound))
            return (map.wall.world(s: center, height: 1.2), max(standOff, out + CoverageMap.positionError(atS: farEdge) + 0.3))
        case .overhead(let height):
            // Aim above the wall band, at the height asked for when there is one.
            let aim = max(map.config.overheadFrom + 1, height ?? 0)
            return (map.wall.world(s: center, height: aim), standOff)
        }
    }

    private func logGuidance() {
        let name = Self.name(state.guidance)
        guard name != lastGuidanceLog else { return }
        lastGuidanceLog = name
        RuntimeLog.guidance.info("GUIDANCE=\(name, privacy: .public)")
    }

    // MARK: Tracking recovery

    private func trackRelocalization(_ frame: SourceFrame) {
        guard live != nil else { return }
        guard case .limited(.relocalizing) = frame.tracking else {
            relocalizingSince = nil
            return
        }
        let since = relocalizingSince ?? frame.timestamp
        relocalizingSince = since
        // After 20 s ARKit is unlikely to relocalize; the old world frame is gone (checklist R5).
        guard frame.timestamp - since > 20 else { return }
        switch state.phase {
        case .findMeter, .meterCloseUp, .wallWalk, .markFeatures, .gapRequest:
            // Capture still needs the world frame: start again from the meter.
            resetSpatialState(reason: "relocalization timed out")
        case .uploading, .result, .resultAR, .onboarding, .unsupported:
            // The bundle is already packed and the server's answer does not depend on the live
            // world frame, so the scan and the result stay. The AR result hides its overlay while
            // tracking is not normal and shows it again if ARKit does relocalize.
            relocalizingSince = nil
        }
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case .interrupted:
            // The phase, captures and strip stay as they are; ARKit relocalizes into the same
            // world frame when the session resumes (checklist R4).
            state.coaching = .relocalizing
        case .interruptionEnded:
            state.coaching = .relocalizing
        case .cameraDenied:
            fail(.cameraDenied)
        case .failed(let message):
            // Once the scan is sent, the upload and its result no longer need the camera: keep
            // them on screen. Only the AR view needs it, and it already hides the battery while
            // the camera isn't tracking.
            switch state.phase {
            case .uploading, .result, .resultAR:
                RuntimeLog.engine.error("camera session failed after capture: \(message, privacy: .public)")
            default:
                // The screen shows plain words, so the camera's own error is only recorded here.
                RuntimeLog.engine.error("camera session failed: \(message, privacy: .public)")
                fail(.sessionFailed(message))
            }
        }
    }

    /// Forgets everything tied to the old world frame and asks for the meter again.
    func resetSpatialState(reason: String) {
        RuntimeLog.engine.info("spatial reset: \(reason, privacy: .public)")
        generation += 1
        relocalizingSince = nil
        groundPlanes = []
        // A fresh map: the old world frame is gone, so its anchors and planes are meaningless.
        live?.restart()
        coverage = nil
        meterAnchorID.map { live?.removeAnchor($0) }
        meterAnchorID = nil
        meterPlaneSource = .detectedPlane
        state.wall = nil
        state.coverage = .empty
        state.target = nil
        state.path = []
        state.features = []
        state.gap = nil
        gapPlan = nil
        pastEndSide = nil
        endKinds = [:]
        state.endQuestion = nil
        store.discardKeyframes()
        keptSourceIDs = []
        state.captureCount = 0
        autoCapture.reset()
        planner.reset()
        go(.findMeter)
    }

    // MARK: Wall

    /// Sets the wall from a meter point and the wall's outward normal, and starts coverage.
    func setWall(meter: SIMD3<Float>, outward: SIMD3<Float>, groundY: Float, groundMeasured: Bool) -> Bool {
        guard let frame = WallFrame(meter: meter, outward: outward, groundY: groundY) else { return false }
        coverage = CoverageMap(wall: frame)
        self.groundMeasured = groundMeasured
        endKinds = [:]
        state.endQuestion = nil
        publishWall()
        publishCoverage()
        return true
    }

    func publishWall() {
        guard let map = coverage else { state.wall = nil; return }
        let wall = map.wall
        state.wall = WallGeometry(
            meter: wall.meter, along: wall.along, outward: wall.outward, groundY: wall.groundY,
            leftEnd: map.leftEnd, rightEnd: map.rightEnd
        )
    }

    func publishCoverage() {
        guard let map = coverage else { return }
        guard map.revision != state.coverage.revision || state.coverage.wall.isEmpty else { return }
        let range = map.visibleRange
        let indices = map.indices(overlapping: range)
        state.coverage = CoverageStrip(
            cellWidth: map.config.cellWidth,
            firstCellS: map.cellRange(indices.lowerBound).lowerBound,
            wall: indices.map { Self.cell(map.level(.wall, $0)) },
            ground: indices.map { Self.cell(map.level(.ground, $0)) },
            wallBandHeight: map.config.wallBandHeight,
            groundBandDepth: map.config.groundBandDepth,
            visibleRange: range,
            revision: map.revision
        )
    }

    func setEnd(_ side: WallSide, at s: Float, kind: EndKind) {
        guard var map = coverage else { return }
        map.setEnd(side == .left ? .left : .right, at: s)
        coverage = map
        endKinds[side] = kind
        publishWall()
        publishCoverage()
        RuntimeLog.engine.info("end \(side.rawValue, privacy: .public) at s=\(s) (\(kind == .limit ? "limit" : "unexplored", privacy: .public))")
        if let camera = lastFrame?.camera, state.phase == .wallWalk {
            updateGuidance(camera: camera, time: lastFrame?.timestamp ?? 0)
        }
    }

    /// What the homeowner said is at an already marked end.
    func setEndKind(_ side: WallSide, _ kind: EndKind) {
        endKinds[side] = kind
        RuntimeLog.engine.info("end \(side.rawValue, privacy: .public) is \(kind == .limit ? "limit" : "unexplored", privacy: .public)")
    }

    func clearEnd(_ side: WallSide) {
        updateCoverage { $0.clearEnd(side == .left ? .left : .right) }
        endKinds[side] = nil
        if state.endQuestion == side { state.endQuestion = nil }
        publishWall()
    }

    var bothEndsMarked: Bool { coverage?.leftEnd != nil && coverage?.rightEnd != nil }

    // MARK: Gap loop

    /// After the review: ask for the planner's gap, or upload.
    func runGapCheck() {
        guard let map = coverage, let plan = gapPlanner.plan(map), !skippedGaps.contains(plan) else {
            startUpload()
            return
        }
        beginGap(plan, origin: .phone, reason: plan.band == .ground ? .groundNearCandidate : .wallAboveCandidate)
    }

    func beginGap(_ plan: GapPlan, origin: GapRequest.Origin, reason: GapRequest.Reason) {
        // A request with a reach says what to do in its own terms, whatever the caller passed.
        let reason: GapRequest.Reason = switch plan.need {
        case .cells: reason
        case .groundOut(let out): .groundOut(out: out)
        case .walkOut(let out): .walkOut(out: out)
        case .overhead: .overhead
        }
        gapCounter += 1
        gapPlan = plan
        keyframesAtGapStart = store.keyframes.count
        let progress = coverage.map { gapPlanner.progress(of: plan, $0) } ?? 0
        state.gap = GapRequest(id: gapCounter, origin: origin, reason: reason, band: plan.band == .ground ? .ground : .wall, span: plan.span, progress: progress, isSatisfied: false)
        state.guidance = .gap
        go(.gapRequest)
        updateGap(camera: lastFrame?.camera)
    }

    /// A closed or skipped gap goes straight to the upload, which re-runs the server's checks
    /// with the new evidence (the closed loop: gap, instruction, capture, updated result).
    private func afterGapResolved() {
        gapPlan = nil
        pastEndSide = nil
        state.gap = nil
        startUpload()
    }

    /// The past_end request's end was marked again and its question answered: the request is
    /// settled, so the scan goes to the upload like a closed gap.
    func settlePastEnd() {
        guard state.phase == .gapRequest, var request = state.gap, !request.isSatisfied else { return }
        request.isSatisfied = true
        request.progress = 1
        state.gap = request
        RuntimeLog.engine.info("gap \(request.id) settled by marking the end again")
        let id = request.id
        Task {
            try? await Task.sleep(for: .seconds(autoAdvanceDelay))
            await waitForGate(.gapRequest)
            guard state.phase == .gapRequest, state.gap?.id == id else { return }
            afterGapResolved()
        }
    }

    /// Keeps the tilt-up view as overhead evidence (`CoverageMap.recordOverhead`). Call it only
    /// once the homeowner answered that nothing is overhead (`answerOverhead(clear: true)`): the
    /// camera can't tell open sky from an eave. `frame` is the view that was tilted up; nil uses
    /// the latest frame. Returns false when nothing was kept: tracking was not normal, or the
    /// view did not show the wall from the top of the wall band (6.5 ft) upward. The export then
    /// sends each stretch the view reached as an overhead entry with the height seen.
    @discardableResult
    func recordOverheadClear(from frame: SourceFrame? = nil) -> Bool {
        guard var map = coverage, let frame = frame ?? lastFrame else { return false }
        let reach = map.recordOverhead(frame.camera, trackingNormal: frame.tracking == .normal)
        guard !reach.isEmpty else { return false }
        coverage = map
        RuntimeLog.engine.info("overhead: kept a view reaching \(reach.map(\.out).min() ?? 0) m over s=\(reach.first?.span.lowerBound ?? 0)...\(reach.last?.span.upperBound ?? 0)")
        afterCoverageChange(camera: frame.camera, time: frame.timestamp)
        return true
    }

    func skipCurrentGap() {
        guard let plan = gapPlan else { return }
        // Only a cell request marks cells: skipping a deeper, walked or overhead view says
        // nothing about the band the strip draws.
        if plan.need == .cells { coverage?.markSkipped(plan.band, plan.span) }
        skippedGaps.append(plan)
        publishCoverage()
        RuntimeLog.engine.info("gap \(self.gapCounter) skipped")
        afterGapResolved()
    }

    // MARK: Upload

    func startUpload() {
        go(.uploading)
        uploadTask?.cancel()
        uploadTask = Task { await upload() }
    }

    private func upload() async {
        let scan = generation
        state.upload = .packaging
        // Keyframe writes still in flight belong in the scene's keyframe list.
        for _ in 0..<200 where (pendingSaves[scan] ?? 0) > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard scan == generation else { return }
        let scene: Data
        do {
            scene = try sceneJSON()
        } catch {
            RuntimeLog.engine.error("scene.json export failed: \(String(describing: error), privacy: .public)")
            state.upload = UploadFailure.packaging
            return
        }
        saveReplayBundle(scene: scene)
        guard !Task.isCancelled else { return }
        state.upload = .uploading(fraction: 0)
        do {
            let data = try await resultClient.submit(scene: scene) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, scan == self.generation, case .uploading = self.state.upload else { return }
                    self.state.upload = fraction >= 1 ? .analyzing : .uploading(fraction: fraction)
                }
            }
            guard scan == generation else { return }
            state.upload = .analyzing
            let result = try PlacementResult.decode(data)
            placement = result
            state.result = presentation(of: result, isSample: resultClient.isSample)
            state.upload = .done
            await waitForGate(.uploading)
            guard scan == generation else { return }
            // The result appears only after the server answered (checklist R6).
            go(.result)
        } catch is CancellationError {
            return
        } catch {
            guard scan == generation else { return }
            RuntimeLog.engine.error("upload failed: \(String(describing: error), privacy: .public)")
            state.upload = UploadFailure.state(for: error)
        }
    }

    /// Writes scene.json with the keyframes and stills into the scan folder's `scan.zip`, for
    /// replay and debugging only: nothing uploads it, and the upload never waits for it or fails
    /// because of it.
    private func saveReplayBundle(scene: Data) {
        let store = store
        Task {
            do {
                let bundle = try await store.writeBundle(sceneJSON: scene)
                RuntimeLog.engine.info("bundle \(bundle.path, privacy: .public) with \(store.keyframes.count) keyframes (kept on the phone)")
            } catch {
                RuntimeLog.engine.error("replay bundle not written: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Result for AR

    /// The replay frame that sees the chosen spot best, for the AR result on a replay.
    private func bestFrameForResult() -> Int? {
        guard let replay, let wall = coverage?.wall else { return nil }
        let spot = state.result?.spot
        let s = spot.map { ($0.span.lowerBound + $0.span.upperBound) / 2 } ?? 0
        let point = wall.world(s: s, height: 0.5, out: 0.3)
        return replay.bestFrame(showing: point)
    }

    // MARK: Start over

    func resetAll() {
        generation += 1
        uploadTask?.cancel()
        replay?.stop()
        coverage = nil
        meterAnchorID.map { live?.removeAnchor($0) }
        meterAnchorID = nil
        meterPlaneSource = .detectedPlane
        store = KeyframeStore()
        keptSourceIDs = []
        autoCapture.reset()
        planner.reset()
        closeUpGate = CloseUpGate()
        gapPlan = nil
        skippedGaps = []
        pastEndSide = nil
        endKinds = [:]
        state.endQuestion = nil
        placement = nil
        state.wall = nil
        state.coverage = .empty
        state.features = []
        state.marking = nil
        state.gap = nil
        state.result = nil
        state.upload = .idle
        state.captureCount = 0
        state.lastCapture = nil
        state.target = nil
        state.path = []
        state.coaching = nil
        state.guidance = .findMeter
        state.closeUp = .aiming(hold: 0, problem: nil)
        state.closeUpFailedAttempts = 0
        state.meterNumber = nil
        closeUpRetake = nil
        meterReadout = nil
        go(.onboarding)
        replay?.show(index: 0)
    }

    // MARK: Internal accessors for marking and export

    var currentFrame: SourceFrame? { lastFrame }
    var liveCapture: LiveCapture? { live }
    var wallEndKinds: [WallSide: EndKind] { endKinds }

    func setMeterAnchor(_ id: UUID?) { meterAnchorID = id }
    var detectedGroundPlanes: [SIMD4<Float>] { groundPlanes }

    func updateCoverage(_ body: (inout CoverageMap) -> Void) {
        guard var map = coverage else { return }
        body(&map)
        coverage = map
        publishCoverage()
    }
}

// MARK: - Mapping to contract values

extension ScanEngine {
    static func cell(_ level: CoverageLevel) -> CellState {
        switch level {
        case .unseen: .unseen
        case .seen: .seen
        case .covered: .covered
        case .skipped: .skipped
        }
    }

    static func step(_ task: GuidanceTask) -> GuidanceStep {
        switch task {
        case .walk(let side): .walk(side: side == .left ? .left : .right, remaining: nil)
        case .markEnd(let side): .markEnd(side: side == .left ? .left : .right)
        case .aimAtGround(let s): .aimAtGround(s: s)
        case .aimAtWall(let s): .aimAtWall(s: s)
        case .stepBack: .stepBack
        case .complete: .walkComplete
        }
    }

    static func name(_ step: GuidanceStep) -> String {
        switch step {
        case .findMeter: "findMeter"
        case .aimAtWallForMeter: "aimAtWallForMeter"
        case .holdOnMeter: "holdOnMeter"
        case .walk(let side, _): "walk.\(side.rawValue)"
        case .markEnd(let side): "markEnd.\(side.rawValue)"
        case .aimAtGround: "aimAtGround"
        case .aimAtWall: "aimAtWall"
        case .stepBack: "stepBack"
        case .walkComplete: "walkComplete"
        case .tiltUp: "tiltUp"
        case .gap: "gap"
        }
    }

    static func problem(_ issue: CloseUpIssue) -> CloseUpProblem {
        switch issue {
        case .blurry: .blurry
        case .tooDark: .tooDark
        case .tooBright: .tooBright
        case .notCentered: .meterNotCentered
        case .tooFar: .tooFar
        case .tracking: .tracking
        }
    }

    /// Tracking problems first (they block everything), then the capture gate's reason.
    func coaching(for tracking: TrackingQuality, skip: CaptureDecision.SkipReason?) -> Coaching? {
        switch tracking {
        case .notAvailable: return .trackingLost
        case .limited(.initializing): return .initializing
        case .limited(.excessiveMotion): return .slowDown
        case .limited(.insufficientFeatures): return .needsTexture
        case .limited(.relocalizing): return .relocalizing
        case .limited(.unknown): return .trackingLost
        case .normal:
            switch skip {
            case .moving?, .blurry?: return .holdSteady
            case .tooDark?: return .tooDark
            default: return nil
            }
        }
    }
}
