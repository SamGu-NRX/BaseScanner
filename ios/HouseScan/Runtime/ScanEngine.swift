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
    /// The close-up view coverage may take when the close-up step ends (`observeCloseUpView`):
    /// that of the photo on disk, once the reader's image checks passed it.
    var closeUpCredit = CloseUpCredit()
    /// Keyframe writes still in flight, by the `generation` they started in; the bundle waits
    /// for its own generation's. Keyed so a write finishing after a reset can't count against
    /// the new scan (a plain counter went negative when `resetAll` zeroed it mid-write).
    private var pendingSaves: [Int: Int] = [:]
    /// Bumped whenever the world frame or the whole scan is thrown away, so work that finishes
    /// afterwards (a keyframe write, an upload) can tell it belongs to a scan that no longer exists.
    private var generation = 0

    // Wall geometry inputs
    private var meterAnchorID: UUID?
    /// The meter anchor's pose the wall and everything captured agree with, and the corrections
    /// still to apply to them as ARKit refines it (`refreshMeterFromAnchor`). Nil on a replay.
    private var meterTracking: MeterAnchorTracking?
    /// Whether a frame source may start, and what a failure and Start over do to it.
    private var sourceState = CaptureSourceState()
    /// Counts changes to the captured geometry: every anchor correction, ground refinement or
    /// revocation, new wall and followed corner. An upload's snapshot records it; an answer to a
    /// scan whose count has moved on since is stale (`upload`).
    var spatialRevision = 0
    /// An upload waiting for a frame with its mesh (`takeUploadSnapshot`), and its number.
    var pendingSnapshot: CheckedContinuation<UploadSnapshot?, Never>?
    var snapshotRequest = 0
    /// The snapshot the last upload sent, which the spot check's repackaging writes again.
    private(set) var lastUploadSnapshot: UploadSnapshot?
    /// Detected horizontal planes, with their classes and outlines.
    private var groundPlanes: [GroundPlaneEvidence] = []
    private var lastFrame: SourceFrame?
    /// Whether `WallFrame.groundY` comes from a detected plane (or a recording's wall taps) rather
    /// than the chest-height guess, and the guess's error. The export widens position errors
    /// while it is a guess.
    private var groundEvidence = GroundEvidence(measured: false, guessError: ScanEngine.estimatedGroundError)
    private(set) var groundMeasured: Bool {
        get { groundEvidence.measured }
        set { groundEvidence = GroundEvidence(measured: newValue, guessError: Self.estimatedGroundError) }
    }
    private var endKinds: [WallSide: EndKind] = [:]
    /// The side whose end turns a corner the walk is to follow, while it waits for the next wall
    /// to be marked (`GuidanceStep.markNextWall`), and why the last mark was refused.
    var nextWallSide: WallSide?
    var nextWallRefusal: NextWallRefusal?

    // Gap loop
    private(set) var gapPlan: GapPlan?
    private var gapCounter = 0
    /// Keyframes stored when the current gap request began: a request is closed only by new views.
    private var keyframesAtGapStart = 0
    /// Tilt-up views kept when the current gap request began: an overhead request is closed by a
    /// new one (`keepOverheadView`); counting keyframes would not do, since the walk keeps them too.
    private var overheadViewsAtGapStart = 0
    /// Requests the homeowner skipped or answered with something overhead: they go to installer
    /// review, and the result doesn't offer them as captures again.
    private(set) var skippedGaps: [GapPlan] = []
    /// The side of a server past_end request being captured: that end was cleared, and marking
    /// it again settles the request (see `markWallEnd`).
    var pastEndSide: WallSide?
    /// The end the past_end request cleared: where it was, its kind and when it was marked, put
    /// back or moved on when the request ends without it marked again (`settleClearedEnd`).
    private var clearedEnd: (s: Float, kind: EndKind, t: Double?)?
    /// Server requests raised without a tap since the review was confirmed (`nextAutomaticGap`),
    /// oldest first. Each is raised once; the result still offers it as a capture.
    private var automaticGaps: [GapPlan] = []
    /// Set when the homeowner says they can't get to a server request's view: after the upload
    /// that follows, the result shows instead of the next request.
    private var automaticGapsStopped = false
    /// At most this many server requests are raised without a tap per confirmed review, so a
    /// server that keeps finding new gaps can't hold the homeowner in the loop. A guess, not
    /// measured: an answer usually lists one to three capturable items, and each round is a
    /// capture and an upload.
    static let maxAutomaticGaps = 5
    /// How long the upload screen shows "One more view to finish" before a request raised from
    /// the answer opens the camera: 1.5 s, about the time to read four words and see the new
    /// step appear, and what the UI lane asked for. Not measured with homeowners.
    static let followUpHold: Double = 1.5

    // LiDAR
    /// The bands the see-behind step is about, while `state.guidance` is `.seeBehind`: those with
    /// hidden cells near its s (`hiddenCells(_:band:around:)`).
    private(set) var seeBehindBands: [SurfaceBand] = []

    // Tilt-up step and overhead requests
    /// Set once the tilt-up step is answered or skipped: the walk asks it once per scan.
    var tiltUpSettled = false
    /// The tilted-up view the overhead question is about, with the walked-path segment it was
    /// captured in. "Open sky or nothing overhead" keeps it as a keyframe and in the coverage map
    /// (`keepOverheadView`), which the export sends as the overhead band; "A roof edge, porch or
    /// stairs" keeps nothing, so the server treats that stretch as unseen.
    private var pendingOverhead: (frame: SourceFrame, segment: Int?)?

    // Tracking recovery
    private var relocalizingSince: Double?

    // AR result
    /// Watches whether the AR scene draws the result (`watchResultInCamera`) while "See it on
    /// your wall" is up on the live camera.
    private var resultWatch: Task<Void, Never>?
    /// Which layer draws the result, and the wall the model in the AR scene was built for
    /// (`showResultInCamera`, `watchResultInCamera`).
    private var resultPolicy = ResultOverlayPolicy()

    // Upload
    let resultClient: any ResultClient
    private var uploadTask: Task<Void, Never>?
    private(set) var placement: PlacementResult?
    /// The latest scan-bundle write (`saveBundle`), and a count of writes started, so only the
    /// latest one offers its bundle.
    private var bundleTask: Task<Void, Never>?
    private var bundleSerial = 0

    // Packet
    /// The packet's sensor streams for the current world frame.
    private(set) var recorder: CaptureRecorder
    private let motion = MotionSource()
    /// Every request the homeowner was shown, for the packet.
    var guidanceLog = GuidanceLog()
    /// The spot check (`ScanEngine+Confirm.swift`).
    var spotConfirm = SpotConfirmState()
    /// When each mark was made, on the capture clock (`MarkKey`).
    var markTimes: [String: Double] = [:]
    /// The packet's clock for guidance and marks: the latest frame's time, ARFrame.timestamp
    /// live. A replay plays parts of its recording more than once, so its clock is the latest
    /// frame time seen and never runs back. Nil until the first frame.
    private(set) var captureClock: Double?

    private var lastGuidanceLog = ""
    private var lastGateLog = ""
    /// Taps of the feature being marked, in wall coordinates.
    /// Tapped world points of the feature being marked.
    var pendingTaps: [SIMD3<Float>] = []

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
        recorder = Self.makeRecorder(store)
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
        _ = sourceState.sourceFailed(failure == .arUnsupported ? .unsupported : .recoverable, afterCapture: false)
        state.failure = failure
        go(.unsupported)
    }

    private func loadReplay(_ folder: URL) async {
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try ReplayPlayer.load(folder: folder) }.value
            let source = sourceState.sourceStarted()
            let player = ReplayPlayer(folder: folder, loaded: loaded) { [weak self] frame in self?.ingest(frame, from: source) }
            replay = player
            state.spatialResultAvailable = true
            let withDepth = player.frames.filter { $0.depth != nil }.count
            state.depthAvailable = withDepth > 0
            player.show(index: 0)
            RuntimeLog.engine.info("replay \(player.session.id, privacy: .public): \(player.frames.count) frames, \(withDepth) with depth, wall \(player.wallDescription, privacy: .public)")
        } catch {
            RuntimeLog.engine.error("replay unreadable: \(String(describing: error), privacy: .public)")
            fail(.replayUnreadable(String(describing: error)))
        }
    }

    // MARK: Phases

    func go(_ phase: ScanPhase) {
        guard state.phase != phase else { return }
        if state.phase == .wallWalk || state.phase == .gapRequest {
            breakWalkedPath(because: "the walk paused (\(state.phase.rawValue) -> \(phase.rawValue))")
        }
        if state.phase == .resultAR { hideResultInCamera() }
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
            closeUpCredit = CloseUpCredit()
            state.meterNumber = nil
            state.closeUpFailedAttempts = 0
            live?.setMode(.closeUp)
            if let replay { replay.play(range: 0..<replay.frames.count, speed: replaySpeed) }
        case .wallWalk:
            live?.setMode(.walk)
            planner.reset()
            if let replay, let map = coverage {
                // The recording's closing tilt-up frames wait for the tilt-up step.
                let walkEnd = Self.tiltUpFrames(in: replay, map: map).lowerBound
                replay.play(range: 0..<walkEnd, excluding: replay.heldBack?.frames, speed: replaySpeed)
            }
        case .gapRequest:
            live?.setMode(.walk)
            if let replay {
                autoCapture.reset()
                // An overhead request, or one for the wall above what the walk saw, is answered
                // by tilting up, which the tilt-up frames show; other requests by the frames held
                // back from the walk.
                if gapPlan?.asksAboveTheWalk == true, let map = coverage, !Self.tiltUpFrames(in: replay, map: map).isEmpty {
                    replay.play(range: Self.tiltUpFrames(in: replay, map: map), speed: replaySpeed)
                } else {
                    let range = replay.heldBack.map { ReplayPlanning.gapReplayRange($0.frames) } ?? 0..<replay.frames.count
                    replay.play(range: range, speed: replaySpeed)
                }
            }
        case .markFeatures, .uploading, .spotConfirm, .result:
            live?.setMode(.idle)
            replay?.stop()
        case .resultAR:
            live?.setMode(.idle)
            if let replay, let index = bestFrameForResult() { replay.show(index: index) }
            showResultInCamera(rising: true)
        case .onboarding, .unsupported:
            break
        }
        updateRecording()
        noteGuidance()
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
        // A replay is its own source (`loadReplay`); a failed source waits for Start over.
        guard replay == nil, options.replayFolder == nil, live == nil, sourceState.mayStartSource else { return }
        // Each callback carries this source's number; one from a retired source is refused.
        let source = sourceState.sourceStarted()
        state.spatialResultAvailable = true
        let capture = LiveCapture(
            onFrame: { [weak self] frame in self?.ingest(frame, from: source) },
            onEvent: { [weak self] event in self?.handle(event, from: source) }
        )
        live = capture
        state.feed = .live
        state.depthAvailable = LiveCapture.supportsDepth
        capture.setRecorder(recorder)
        capture.start()
        updateRecording()
    }

    private static func makeRecorder(_ store: KeyframeStore) -> CaptureRecorder {
        CaptureRecorder(directory: store.directory.appending(path: "streams-raw", directoryHint: .isDirectory))
    }

    /// Streams record while a capture is under way, from the meter search through the upload that
    /// sends it. They stop on the result, and when an upload fails or is refused, since the phone
    /// may then sit idle for minutes; a request raised from the result, going back to the review
    /// or sending again starts them again. Depth frames record only where the camera is meant to
    /// be on the wall (the close-up, the walk, a gap request), so the meter search and the review
    /// don't spend `DepthFrameBudget`. Core Motion runs only with the live camera: a replay's
    /// frames were recorded by another phone at another time.
    private func updateRecording() {
        let capturing = switch state.phase {
        case .findMeter, .meterCloseUp, .wallWalk, .markFeatures, .gapRequest: true
        case .uploading:
            switch state.upload {
            case .failed, .rejected: false
            case .idle, .packaging, .uploading, .analyzing, .done: true
            }
        case .onboarding, .spotConfirm, .result, .resultAR, .unsupported: false
        }
        let depthFrames = switch state.phase {
        case .meterCloseUp, .wallWalk, .gapRequest: true
        case .onboarding, .findMeter, .markFeatures, .uploading, .spotConfirm, .result, .resultAR, .unsupported: false
        }
        recorder.setRecording(capturing, depthFrames: depthFrames)
        guard live != nil else { return }
        if capturing { motion.start(into: recorder) } else { motion.stop() }
    }

    var motionRunsLive: Bool { live != nil }
    var motionAvailable: Set<CaptureRecorder.Stream> { motion.available }

    // MARK: Frames

    /// A frame from the source started as `source`. One from a source that failed or was
    /// replaced is dropped: a frame it queued before failing would set tracking back to normal.
    func ingest(_ frame: SourceFrame, from source: Int) {
        guard sourceState.accepts(source) else { return }
        captureClock = max(captureClock ?? frame.timestamp, frame.timestamp)
        if !frame.isPoseOnly { lastFrame = frame }
        if let still = frame.still { state.feed = .still(still) }
        state.projection = frame.projection
        if state.tracking != frame.tracking {
            RuntimeLog.capture.info("tracking \(Self.name(self.state.tracking), privacy: .public) -> \(Self.name(frame.tracking), privacy: .public)")
            if state.tracking == .normal { breakWalkedPath(because: "tracking left normal") }
            state.tracking = frame.tracking
            // The model stays see-through until the next look hands it the result
            // (`setResultInCamera`), so enabling it here never shows it over the screen's drawing.
            live?.setResultVisible(frame.tracking == .normal)
        }
        if let planes = frame.groundPlanes { groundPlanes = planes }
        applySpatialUpdate(frame)
        // After the frame's corrections, so a snapshot taken on it agrees with its mesh.
        completeUploadSnapshot(with: frame)
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

    /// ARKit's correction to the meter's anchor, then the ground from the planes this frame
    /// reports, in that order (`SpatialUpdate`): the correction moves everything captured (the
    /// wall and corners, the kept cameras, and here the tapped marks) as one body into the frame
    /// ARKit reports now, and the ground is then read in that same frame. A plane that stops
    /// supporting the ground (reclassified, removed) puts it back to a guess.
    private func applySpatialUpdate(_ frame: SourceFrame) {
        guard var map = coverage else { return }
        let before = (y: map.wall.groundY, measured: groundEvidence.measured)
        let outcome = SpatialUpdate.apply(
            anchor: frame.meterAnchor, planes: frame.groundPlanes, time: frame.timestamp,
            map: &map, tracking: &meterTracking, ground: &groundEvidence)
        guard outcome.changed else { return }
        spatialRevision += 1
        coverage = map
        if let correction = outcome.correction {
            var features = state.features
            for index in features.indices { features[index].points = features[index].points.map(correction.point) }
            if features != state.features { state.features = features }
            // The first tap of a mark still being made was in the old frame too.
            pendingTaps = pendingTaps.map(correction.point)
        }
        if outcome.groundChanged {
            RuntimeLog.engine.info("ground \(self.groundEvidence.measured ? "measured" : "a guess again", privacy: .public) at y=\(map.wall.groundY) (was \(before.y), \(before.measured ? "measured" : "estimated", privacy: .public))")
        }
        publishWall()
        publishCoverage()
        reprojectFeatures()
    }

    /// A raw pose ARKit reported at `time`, in the frame the wall agrees with now. The same raw
    /// pose without an anchor (a replay).
    func correctedPose(_ raw: simd_float4x4, capturedAt time: Double) -> simd_float4x4 {
        meterTracking?.correctedPose(raw, capturedAt: time) ?? raw
    }

    /// The anchor corrections, for the packet writer off the main actor.
    var poseCorrections: PoseCorrections { PoseCorrections(meterTracking) }

    /// A frame's camera in the frame the wall agrees with now: a frame kept before a correction
    /// and stored after it (its photo saving, the close-up being read, the overhead question
    /// waiting) was captured in the old frame.
    func correctedCamera(_ frame: SourceFrame) -> CameraFrame {
        meterTracking?.correctedCamera(frame.camera, capturedAt: frame.timestamp) ?? frame.camera
    }

    /// Door and window heights, spans and fence distances follow the wall frame; the tapped world
    /// points stay put.
    func reprojectFeatures() {
        guard let wall = coverage?.wall, !state.features.isEmpty else { return }
        var features = state.features
        for index in features.indices { Self.project(&features[index], onto: wall) }
        if features != state.features { state.features = features }
        publishFeaturesPastEnds()
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
        if let issue = status.issue {
            logGate("close-up held back: \(issue)")
        } else if status.fire || closeUpPending, !frame.jpeg.isAvailable {
            logGate("close-up waiting: no photo on this frame")
        } else if !status.fire, !closeUpPending {
            logGate("close-up holding")
        }
        if status.fire || closeUpPending, status.issue == nil, frame.jpeg.isAvailable {
            logGate("close-up taken from \(frame.id)", always: true)
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
        // This shot's save replaces the photo on disk: the last one's view no longer counts.
        closeUpCredit.shotStarted()
        let view = frame.tracking == .normal ? CloseUpView(camera: frame.camera, depth: frame.depth, time: frame.timestamp) : nil
        let scan = generation
        let store = store
        Task {
            // The task can start after a reset or after the flow left the close-up.
            guard scan == generation, state.phase == .meterCloseUp else { return }
            let saved = await store.saveStill(frame, name: "meter_close.jpg")
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
            await readMeterNumber(scan: scan, view: view)
        }
    }

    /// Reads the meter number from the saved close-up, off the main actor, then offers the
    /// candidates for the homeowner to pick from (never filling one in) or asks for a retake.
    /// `view` is the shot's, which coverage may take once the reader has passed its photo.
    private func readMeterNumber(scan: Int, view: CloseUpView?) async {
        state.meterNumber = .reading
        let reader = MeterNumberReaders.make()
        let photo = store.directory.appending(path: "meter_close.jpg")
        let readout = await Task.detached(priority: .userInitiated) { () -> MeterReadout? in
            guard let jpeg = try? Data(contentsOf: photo) else { return nil }
            return await reader.read(jpeg: jpeg)
        }.value
        guard scan == generation, state.phase == .meterCloseUp, state.meterNumber == .reading else { return }
        closeUpCredit.photoChecked(view, passed: readout?.photoPassedChecks == true)
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
        state.meterBrand = readout.brand
        state.meterNumber = .choose(readout.candidates)
    }

    private func walk(_ frame: SourceFrame) {
        guard let map = coverage else { return }
        let sample = FrameSample(timestamp: frame.timestamp, camera: frame.camera, tracking: frame.captureTracking, quality: frame.quality)
        let decision = autoCapture.evaluate(sample, newlySeenCells: map.newlySeenCount(from: frame.camera))
        // Past an end it can't see back from, a photo adds nothing: it is refused and the screen says so.
        let pastEnd = map.unexploredEndPassed(by: frame.camera)
        var skip: CaptureDecision.SkipReason?
        switch decision {
        case .skip(let reason):
            skip = reason
            logGate("skipped: \(reason)")
        case .keep where pastEnd != nil:
            logGate("refused: past the \(pastEnd?.rawValue ?? "") end, nothing between the ends in view")
        // The gate judges sharpness and exposure from this frame's own quality when it has one,
        // else from the last measured frame's. A kept photo must have been judged itself.
        case .keep where frame.quality == nil:
            logGate("refused: no quality measured on this frame")
        case .keep where !frame.jpeg.isAvailable:
            logGate("refused: no photo on this frame")
        case .keep where keptSourceIDs.contains(frame.id):
            logGate("refused: frame already kept")
        case .keep(let reason):
            logGate("kept \(frame.id) (\(reason))", always: true)
            autoCapture.didKeep(sample)
            keptSourceIDs.insert(frame.id)
            keep(frame)
        }
        state.coaching = walkCoaching(tracking: frame.tracking, skip: skip, pastEnd: pastEnd != nil, time: frame.timestamp)
        afterCoverageChange(camera: frame.camera, time: frame.timestamp)
        askOverheadIfTiltedUp(frame)
    }

    /// Tracking problems show at once. A problem the capture gate reports (moving, blurry, too
    /// dark) shows only once it has lasted `showAfter` seconds and clears after `clearAfter`
    /// seconds of frames without it: the gate judges every frame, and one fast frame at 30 fps
    /// would otherwise flash a prompt for a single frame. During the walk moving and blurry read
    /// as "Slow down", never "Hold steady", which would tell a walking homeowner to stop. Both
    /// durations are guesses to try on a phone, not measured. Standing past an end the phone
    /// can't see back from (`pastEnd`) is debounced the same way and comes before the gate's
    /// reasons: no photo is kept there whatever the gate says.
    private func walkCoaching(tracking: TrackingQuality, skip: CaptureDecision.SkipReason?, pastEnd: Bool, time: Double) -> Coaching? {
        let showAfter = 0.7
        let clearAfter = 0.5
        guard tracking == .normal else {
            gateProblem = nil
            gateClearSince = nil
            return coaching(for: tracking, skip: nil)
        }
        var candidate: Coaching? = switch skip {
        case .moving?, .blurry?: .slowDown
        case .tooDark?: .tooDark
        default: nil
        }
        if pastEnd { candidate = .pastWallEnd }
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
    /// so the strip never claims a view the bundle lacks. The photo, pose and tracking all come
    /// from the one `SourceFrame`, so what is credited is the pose of the stored image. With
    /// `overhead`, the stored view is also kept as a clear overhead view. `segment` is the
    /// walked-path segment the frame was captured in, when it was captured before now.
    private func keep(_ frame: SourceFrame, overhead: Bool = false, capturedIn segment: Int? = nil) {
        let kind: CaptureEvent.Kind = state.phase == .gapRequest ? .gap : .walk
        let index = store.nextKeyframeIndex()
        let scan = generation
        let store = store
        // The walked-path segment the frame was captured in: a break while its photo stores must
        // not join it to frames captured after the break.
        let segment = segment ?? coverage?.pathSegment
        pendingSaves[scan, default: 0] += 1
        Task {
            // Every exit drains this generation's count, so the upload never waits on a write
            // that was refused or failed.
            defer {
                let left = (pendingSaves[scan] ?? 1) - 1
                pendingSaves[scan] = left > 0 ? left : nil
            }
            // A frame queued before a reset must not be written into the new scan's store.
            guard scan == generation else { return }
            let saved = await store.saveKeyframe(frame, index: index)
            guard scan == generation else { return }
            guard saved.stored else {
                // Not stored, so not kept: a later pass over the same replay frame may keep it.
                keptSourceIDs.remove(frame.id)
                if overhead { RuntimeLog.engine.error("overhead: the view asked about was not stored; nothing recorded") }
                return
            }
            // Coverage only moves on kept frames with normal tracking (checklist R3).
            // The frame's own time lets the walked path join only poses kept close together in time.
            // With LiDAR depth, a cell counts only where depth confirms the camera saw it.
            // Corrected for anchor moves made while the photo was saving.
            let delta = coverage?.observe(correctedCamera(frame), trackingNormal: frame.tracking == .normal, time: frame.timestamp, depth: frame.depth, segment: segment)
            RuntimeLog.capture.info("stored \(frame.id, privacy: .public) as keyframe \(index)\(frame.depth == nil ? "" : " with depth", privacy: .public): \(delta?.newlySeen ?? 0) cells newly seen, \(delta?.newlyCovered ?? 0) newly covered, \(delta?.newlyHidden ?? 0) newly hidden")
            if overhead { recordOverhead(frame) }
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
        // A question is on screen: the next step waits for its answer.
        guard let map = coverage, state.endQuestion == nil, !state.overheadQuestion else { return }
        if let side = nextWallSide {
            state.guidance = .markNextWall(side: side, refusal: nextWallRefusal)
            state.target = nil
            state.path = []
            logGuidance()
            return
        }
        if let span = tiltUpSpanIfDue(map) {
            state.guidance = .tiltUp(span: span)
            state.target = map.wall.world(s: (span.lowerBound + span.upperBound) / 2, height: Self.tiltUpHeight(map))
            state.path = []
            logGuidance()
            return
        }
        let screenTime = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let output = planner.update(coverage: map, camera: camera, time: screenTime)
        if let hidden = hiddenBlock(output.task, map, camera: camera) {
            seeBehindBands = hidden.bands
            state.guidance = .seeBehind(s: hidden.s)
            state.target = hidden.bands.contains(.wall)
                ? map.wall.world(s: hidden.s, height: 1)
                : map.wall.world(s: hidden.s, height: 0, out: map.config.groundBandDepth / 2)
            // Where to stand for another angle depends on what is in the way, which the map
            // doesn't know; no path.
            state.path = []
        } else {
            seeBehindBands = []
            state.guidance = Self.step(output.task)
            state.target = output.target
            state.path = output.path
        }
        logGuidance()
    }

    // MARK: See-behind step (LiDAR)

    /// How far past a hidden stretch the camera must be before the walk asks to look behind it
    /// instead of walking on: 1 m, about two strides, so the stretch has had a chance to show from
    /// the angles the walk passes through. A guess to try on a phone, not measured.
    static let seeBehindPassed: Float = 1

    /// LiDAR phones: the stretch the walk's task is waiting on, when what keeps it open is hidden
    /// cells (the camera looked, and depth showed something nearer) rather than unseen ones.
    /// Walking up to it again gives the same view; another angle, or stepping round, can show it.
    ///
    /// An aim task's stretch counts as hidden when at least half of its cells still open (neither
    /// covered nor skipped) within 0.3 m of it are hidden: the planner's own window for the task
    /// (`GuidancePlanner.isSatisfied`), and "half" is a guess. A walk counts as blocked when the
    /// first open cell on its side, where the planner's reach stops, is hidden and the camera is
    /// `seeBehindPassed` beyond it: without this, a bush hiding the whole band leaves the walk
    /// saying "walk on" while its reach never moves.
    ///
    /// The planner raises `.seeBehind` itself when hidden cells lie near the camera; the step is
    /// then about the bands holding hidden cells near its s. Nil when there are none, which leaves
    /// no cell for "Can't see past it" to settle.
    private func hiddenBlock(_ task: GuidanceTask, _ map: CoverageMap, camera: CameraFrame) -> (s: Float, bands: [SurfaceBand])? {
        func open(_ band: SurfaceBand, _ index: Int) -> Bool {
            let level = map.level(band, index)
            return level != .covered && level != .skipped
        }
        func mostlyHidden(_ band: SurfaceBand, around s: Float) -> Bool {
            let cells = map.indices(overlapping: (s - 0.3)...(s + 0.3)).filter { map.isWithinEnds($0) && open(band, $0) }
            let hidden = cells.filter { map.level(band, $0) == .hidden }.count
            return hidden > 0 && hidden * 2 >= cells.count
        }
        switch task {
        case .seeBehind(let s):
            let bands = SurfaceBand.allCases.filter { !Self.hiddenCells(map, band: $0, around: s).isEmpty }
            return bands.isEmpty ? nil : (s, bands)
        case .aimAtGround(let s):
            return mostlyHidden(.ground, around: s) ? (s, [.ground]) : nil
        case .aimAtWall(let s):
            return mostlyHidden(.wall, around: s) ? (s, [.wall]) : nil
        case .walk(let side):
            let reach = planner.reach(side, coverage: map)
            let index = map.cellIndex(forS: side.sign * (reach + map.config.cellWidth / 2))
            let bands = SurfaceBand.allCases.filter { map.level($0, index) == .hidden }
            let beyond = side.sign * map.wall.wallPoint(camera.position).s - reach
            guard !bands.isEmpty, beyond >= Self.seeBehindPassed else { return nil }
            let cell = map.cellRange(index)
            return ((cell.lowerBound + cell.upperBound) / 2, bands)
        case .markEnd, .stepBack, .complete:
            return nil
        }
    }

    /// How far either side of a see-behind step's s its hidden cells are looked for: 1 m, the
    /// half-width of the window around the camera in which the planner looks for them
    /// (`GuidancePlanner.preferredTask`).
    static let seeBehindReach: Float = 1

    /// The hidden cells of `band` within `seeBehindReach` of `s`: what the see-behind step asks
    /// to see past, and what "Can't see past it" hands to review.
    static func hiddenCells(_ map: CoverageMap, band: SurfaceBand, around s: Float) -> [Int] {
        map.indices(overlapping: (s - seeBehindReach)...(s + seeBehindReach)).filter { map.level(band, $0) == .hidden }
    }

    /// A frame shown for review (not captured) keeps the current task but re-aims its target and
    /// path from the camera now on screen; otherwise the arrow points from where the walk last was.
    private func refreshCues(camera: CameraFrame) {
        guard state.phase == .wallWalk, state.endQuestion == nil, !state.overheadQuestion, nextWallSide == nil,
              let map = coverage, let task = planner.current else { return }
        if case .tiltUp = state.guidance { return }
        if case .seeBehind = state.guidance { return }
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

    // MARK: Tilt-up step

    /// Half the stretch the tilt-up step asks about: 1.5 m (about 5 ft) each side of the meter,
    /// inside the marked ends. The spots the server tries first sit beside the meter, where the
    /// cable run is shortest, and a 2.58 ft battery fits on either side within it. 3 m is also
    /// about what one upright view takes in from 3 m out. A judgment call, not measured: a spot
    /// farther along gets its own `.overhead` request from the server.
    static let tiltUpReach: Float = 1.5

    /// The stretch to ask about, once both ends are marked and answered and the step hasn't been
    /// answered or skipped; nil otherwise, and when the marked ends leave no stretch.
    private func tiltUpSpanIfDue(_ map: CoverageMap) -> ClosedRange<Float>? {
        guard !tiltUpSettled, let left = map.leftEnd, let right = map.rightEnd else { return nil }
        let low = max(left, -Self.tiltUpReach)
        let high = min(right, Self.tiltUpReach)
        return low < high ? low...high : nil
    }

    /// How far above the top wall row (`CoverageConfig.wallCaptureHeight`, 7.5 ft) a view must
    /// reach to count as tilted up: 0.7 m, so about 9.8 ft above the ground, past a one-storey
    /// eave, where the view shows whether one is there. It is a height, not a pitch: a
    /// level view from 2 m out reaches about 8.5 ft and does not count, one from 2.6 m out
    /// reaches about 10 ft and does, and it shows what is overhead as well as a tilted one. A
    /// guess to try on a phone, not measured.
    static let tiltUpAbove: Float = 0.7

    /// The height the tilt-up step and an overhead request aim at, meters above the ground.
    static func tiltUpHeight(_ map: CoverageMap) -> Float { map.config.wallCaptureHeight + tiltUpAbove }

    /// The stretches a view shows at least `tiltUpHeight` up the wall (`CoverageMap.overheadReach`):
    /// empty unless the camera is tilted up at the wall.
    static func tiltedUp(_ camera: CameraFrame, _ map: CoverageMap) -> [ClosedRange<Float>] {
        let height = tiltUpHeight(map)
        return map.overheadReach(from: camera).filter { $0.out >= height }.map(\.span)
    }

    /// Raises the overhead question when a frame with normal tracking is tilted up where the scan
    /// needs it: over any of the tilt-up step's stretch during the walk, or, for an overhead gap
    /// request, over enough of the requested span that recording it settles the request
    /// (`GapPlanner.overheadViewSettles`), so "nothing overhead" always closes it. Only the
    /// homeowner can say whether what is above is open sky or an eave. Any frame with a photo
    /// counts, not only frames auto-capture kept: "nothing overhead" stores that photo as a
    /// keyframe, and the view counts only once it is stored (`keepOverheadView`).
    private func askOverheadIfTiltedUp(_ frame: SourceFrame) {
        guard !state.overheadQuestion, frame.tracking == .normal, frame.jpeg.isAvailable, let map = coverage else { return }
        let wanted: ClosedRange<Float>
        switch state.phase {
        case .wallWalk:
            guard case .tiltUp(let span) = state.guidance else { return }
            wanted = span
        case .gapRequest:
            guard let plan = gapPlan, case .overhead = plan.need, state.gap?.isSatisfied == false else { return }
            wanted = plan.span
        default:
            return
        }
        let seen = Self.tiltedUp(frame.camera, map)
        guard seen.contains(where: { $0.overlaps(wanted) }) else { return }
        if state.phase == .gapRequest, let plan = gapPlan, !gapPlanner.overheadViewSettles(plan, map, camera: frame.camera) { return }
        // The segment now: the answer can come after a tracking break.
        pendingOverhead = (frame, coverage?.pathSegment)
        state.overheadQuestion = true
        RuntimeLog.engine.info("tilt-up view over s \(seen.first?.lowerBound ?? 0)...\(seen.last?.upperBound ?? 0): asking what is overhead")
    }

    /// Ends the tilt-up step. `clear` is the homeowner's "Open sky or nothing overhead", which
    /// keeps the view the question was about; false for "A roof edge, porch or stairs", "Can't
    /// get there" or leaving the walk, which keep nothing.
    func settleTiltUp(clear: Bool) {
        let pending = pendingOverhead
        pendingOverhead = nil
        state.overheadQuestion = false
        tiltUpSettled = true
        // After settling, so the guidance recomputed once it is stored moves past the tilt-up step.
        let storing = clear && pending.map { keepOverheadView($0.frame, capturedIn: $0.segment) } == true
        RuntimeLog.engine.info("tilt-up step settled: \(storing ? "storing the clear overhead view" : "nothing recorded", privacy: .public)")
    }

    /// The answer to the overhead question during an overhead gap request. "Nothing overhead"
    /// keeps the view, which was checked to settle the request when the question was raised, so
    /// the request closes through `updateGap`. Something overhead means no view can settle it:
    /// the request goes to installer review and the gap loop moves on to the upload.
    func settleOverheadGap(clear: Bool) {
        let pending = pendingOverhead
        pendingOverhead = nil
        state.overheadQuestion = false
        guard clear else {
            skipCurrentGap(because: "something is overhead", refused: false)
            return
        }
        if pending.map({ keepOverheadView($0.frame, capturedIn: $0.segment) }) != true {
            RuntimeLog.engine.error("overhead answer: the view asked about could not be kept")
        }
    }

    /// The replay's closing run of tilted-up frames (`tiltedUp`): the walk leaves them out, and
    /// the tilt-up step and overhead gap requests play them (`playReplayTiltUp`). Empty at the end
    /// when the recording has none.
    static func tiltUpFrames(in replay: ReplayPlayer, map: CoverageMap) -> Range<Int> {
        var start = replay.frames.count
        while start > 0, !tiltedUp(replay.camera(at: start - 1), map).isEmpty { start -= 1 }
        return start..<replay.frames.count
    }

    /// Plays the replay's tilt-up frames, as a homeowner tilting up would show them. False when
    /// the recording has none.
    func playReplayTiltUp() -> Bool {
        guard let replay, let map = coverage else { return false }
        let frames = Self.tiltUpFrames(in: replay, map: map)
        guard !frames.isEmpty else { return false }
        replay.play(range: frames, speed: replaySpeed)
        return true
    }

    private func updateGap(camera: CameraFrame?) {
        guard let map = coverage, let plan = gapPlan, var request = state.gap else { return }
        request.progress = gapPlanner.progress(of: plan, map)
        let fresh = if case .overhead = plan.need {
            map.overheadCameras.count > overheadViewsAtGapStart
        } else {
            store.keyframes.count > keyframesAtGapStart
        }
        let satisfied = gapPlanner.isSatisfied(plan, map) && fresh
        state.guidance = .gap
        let center = (plan.span.lowerBound + plan.span.upperBound) / 2
        let cue = gapCue(plan, map, center: center)
        state.target = cue.target
        if let camera {
            let from = map.wall.wallPoint(camera.position).s
            // Every request but an overhead one needs its whole span seen or walked, and the
            // server's can run 20 ft or more (ground out to a pool's clearance), so the line runs
            // on to the span's far end. One tilted-up view from the middle covers an overhead one.
            let farEnd = abs(plan.span.lowerBound - from) > abs(plan.span.upperBound - from) ? plan.span.lowerBound : plan.span.upperBound
            let to = if case .overhead = plan.need { center } else { farEnd }
            state.path = [from, to].map { map.wall.world(s: $0, height: 0, out: cue.standOut) }
        }
        logGuidance()
        if satisfied, !request.isSatisfied {
            resolveGuidance(.met)
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
            // The walk has to pass `out` plus the wall's position error at the span's end where it
            // is larger (farther from the meter, or on a piece with a larger default); 0.3 m more
            // leaves room for drifting toward the wall. The 0.3 m is a guess.
            let error = max(map.positionError(atS: plan.span.lowerBound), map.positionError(atS: plan.span.upperBound))
            return (map.wall.world(s: center, height: 1.2), max(standOff, out + error + 0.3))
        case .overhead(let height):
            // Aim where a tilted-up view reaches, or at the height asked for when that is higher.
            let aim = max(Self.tiltUpHeight(map), height ?? 0)
            return (map.wall.world(s: center, height: aim), standOff)
        case .wallUp(let height):
            // At the height the view must pass, walked along the whole span like a cell request:
            // each stretch needs it from two places.
            return (map.wall.world(s: center, height: height), standOff)
        }
    }

    private func logGuidance() {
        noteGuidance()
        let name = Self.name(state.guidance)
        guard name != lastGuidanceLog else { return }
        lastGuidanceLog = name
        RuntimeLog.guidance.info("GUIDANCE=\(name, privacy: .public)")
    }

    /// Logs a capture-gate decision. The gate judges about ten frames a second, so a reason is
    /// logged when it differs from the last one logged; `always` logs every time (a kept frame,
    /// a shot taken). `decision` holds only enum reasons and frame ids, never image content.
    private func logGate(_ decision: String, always: Bool = false) {
        guard always || decision != lastGateLog else { return }
        lastGateLog = decision
        RuntimeLog.capture.info("gate \(decision, privacy: .public)")
    }

    /// The homeowner's path is not continuous across this point (tracking left normal, the
    /// session was interrupted, or the walk paused), so walked-path evidence must not join the
    /// poses on either side.
    private func breakWalkedPath(because reason: String) {
        guard coverage != nil else { return }
        coverage?.breakWalkedPath()
        RuntimeLog.capture.info("walked path broken: \(reason, privacy: .public)")
    }

    // MARK: Tracking recovery

    private func trackRelocalization(_ frame: SourceFrame) {
        guard live != nil else { return }
        guard case .limited(.relocalizing) = frame.tracking else {
            if let since = relocalizingSince {
                RuntimeLog.capture.info("relocalization ended after \(frame.timestamp - since, format: .fixed(precision: 1)) s: tracking \(Self.name(frame.tracking), privacy: .public)")
            }
            relocalizingSince = nil
            return
        }
        if relocalizingSince == nil {
            RuntimeLog.capture.info("relocalization started (phase \(self.state.phase.rawValue, privacy: .public))")
        }
        let since = relocalizingSince ?? frame.timestamp
        relocalizingSince = since
        // After 20 s ARKit is unlikely to relocalize; the old world frame is gone (checklist R5).
        guard frame.timestamp - since > 20 else { return }
        switch state.phase {
        case .findMeter, .meterCloseUp, .wallWalk:
            // The walk still needs the world frame: start again from the meter.
            RuntimeLog.capture.info("relocalization timed out after 20 s: resetting to the meter")
            resetSpatialState(reason: "relocalization timed out")
        case .gapRequest:
            // The scan so far is whole; only this request needs the lost frame. It goes to installer
            // review as if the homeowner couldn't get there, and the upload that follows keeps the
            // scan (and, for a request raised from the result, replaces the result with the new
            // answer). The clock restarts, so a later request gets its own 20 s.
            relocalizingSince = nil
            // A request already met is on its way to the upload (`afterGapResolved`).
            guard state.gap?.isSatisfied != true else { return }
            RuntimeLog.capture.info("relocalization timed out after 20 s: leaving the gap for installer review")
            skipCurrentGap(because: "the phone lost its place for 20 s")
        case .markFeatures:
            // The review needs no live frame: "Looks complete" uploads the scan as it is, and
            // "Add something", which taps into the world frame, waits for tracking to return
            // (`beginMarking`). Nothing is thrown away.
            break
        case .uploading, .spotConfirm, .result, .resultAR, .onboarding, .unsupported:
            // The bundle is already packed and the server's answer does not depend on the live
            // world frame, so the scan and the result stay. The AR result hides its overlay while
            // tracking is not normal and shows it again if ARKit does relocalize.
            relocalizingSince = nil
        }
    }

    private func handle(_ event: LiveEvent, from source: Int) {
        // An event from a source that failed or was replaced says nothing about the running one.
        guard sourceState.accepts(source) else { return }
        switch event {
        case .interrupted(let lastFrameTime):
            // The phase, captures and strip stay as they are; ARKit relocalizes into the same
            // world frame when the session resumes (checklist R4). The break is placed after the
            // last frame the session delivered, which may still be on its way here.
            RuntimeLog.capture.info("session interrupted")
            if let lastFrameTime { coverage?.breakWalkedPath(at: lastFrameTime) }
            breakWalkedPath(because: "session interrupted")
            state.coaching = .relocalizing
        case .interruptionEnded:
            RuntimeLog.capture.info("session interruption ended")
            state.coaching = .relocalizing
        case .cameraDenied:
            fail(.cameraDenied)
        case .failed(let message):
            // Once the scan is sent, the upload and its result no longer need the camera: keep
            // them on screen. So does the spot check, which shows a stored photo; with tracking
            // gone, unmarked equipment can't be marked there and its area is left out. Only the AR
            // view needs the camera, and it already hides the battery while it isn't tracking.
            switch state.phase {
            case .uploading, .spotConfirm, .result, .resultAR:
                RuntimeLog.engine.error("camera session failed after capture: \(message, privacy: .public)")
                _ = sourceState.sourceFailed(.recoverable, afterCapture: true)
                loseSpatialResult()
            case .markFeatures where spotConfirmIsMarking:
                // Marking unmarked equipment from the spot check: back to its photo, where the
                // thing can't be marked now and its area is left out.
                RuntimeLog.engine.error("camera session failed while marking for the spot check: \(message, privacy: .public)")
                _ = sourceState.sourceFailed(.recoverable, afterCapture: true)
                loseSpatialResult()
                cancelMarking()
            default:
                // The screen shows plain words, so the camera's own error is only recorded here.
                RuntimeLog.engine.error("camera session failed: \(message, privacy: .public)")
                fail(.sessionFailed(message))
            }
        }
    }

    /// Forgets everything tied to the old world frame and asks for the meter again, the spot
    /// check's answers with it: even the ground answer is about a footprint in that frame. The
    /// close-up's own state (gate, readout, view) is reset when the close-up starts again
    /// (`go(.meterCloseUp)`).
    func resetSpatialState(reason: String) {
        RuntimeLog.engine.info("spatial reset: \(reason, privacy: .public)")
        generation += 1
        spatialRevision += 1
        cancelPendingSnapshot()
        lastUploadSnapshot = nil
        // A new world frame is a new packet session: what was recorded is in the old frame.
        recorder.restart()
        resetPacketLog()
        relocalizingSince = nil
        groundPlanes = []
        groundMeasured = false
        lastFrame = nil
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
        // A mark half placed holds taps in the old frame's wall coordinates.
        state.marking = nil
        pendingTaps = []
        state.gap = nil
        gapPlan = nil
        pastEndSide = nil
        clearedEnd = nil
        // Skipped requests name spans along the old wall.
        skippedGaps = []
        automaticGaps = []
        automaticGapsStopped = false
        seeBehindBands = []
        endKinds = [:]
        state.endQuestion = nil
        state.wallTooShort = false
        nextWallSide = nil
        nextWallRefusal = nil
        resetTiltUp()
        resetSpotChecks()
        // An answer describes a scan that no longer exists; the next upload brings a new one.
        uploadTask?.cancel()
        placement = nil
        state.result = nil
        state.upload = .idle
        // The keyframes and stills, the meter close-up included, were taken in the old frame.
        store.discardKeyframes()
        // A bundle packed before this holds keyframes of the world frame just discarded.
        state.shareableScan = nil
        keptSourceIDs = []
        state.captureCount = 0
        state.lastCapture = nil
        gateProblem = nil
        gateClearSince = nil
        autoCapture.reset()
        planner.reset()
        go(.findMeter)
    }

    // MARK: Wall

    /// Sets the wall from a meter point and the wall's outward normal, and starts coverage.
    func setWall(meter: SIMD3<Float>, outward: SIMD3<Float>, groundY: Float, groundMeasured: Bool) -> Bool {
        guard let frame = WallFrame(meter: meter, outward: outward, groundY: groundY) else { return false }
        spatialRevision += 1
        coverage = CoverageMap(wall: frame)
        coverage?.heightError = groundMeasured ? 0 : Self.estimatedGroundError
        self.groundMeasured = groundMeasured
        endKinds = [:]
        state.endQuestion = nil
        state.wallTooShort = false
        nextWallSide = nil
        nextWallRefusal = nil
        resetTiltUp()
        publishWall()
        publishCoverage()
        return true
    }

    func publishWall() {
        guard let map = coverage else { state.wall = nil; return }
        let wall = map.wall
        state.wall = WallGeometry(
            meter: wall.meter, along: wall.along, outward: wall.outward, groundY: wall.groundY,
            leftEnd: map.leftEnd, rightEnd: map.rightEnd,
            cornerSegments: wall.segments.indices.filter { $0 != wall.meterSegmentIndex }.map { index in
                let piece = wall.segments[index]
                return WallGeometry.Segment(span: piece.span, along: piece.along, outward: piece.outward, anchor: piece.anchor, anchorS: piece.anchorS)
            }
        )
        if state.phase == .resultAR { showResultInCamera(rising: false) }
        publishFeaturesPastEnds()
        refreshSpotPhoto()
    }

    /// "See it on your wall" on the live camera. The screen draws the result over the camera
    /// itself (`BatteryOverlay`) unless the AR scene is seen drawing it (`watchResultInCamera`).
    /// Build 4.1 trusted the AR scene as soon as it had the model and showed no battery at all
    /// (#67). Only a phone with LiDAR tries the AR scene, where the mesh can hide the result
    /// behind things in front of it; without LiDAR the screen draws it, as build 3.1 did. A
    /// replay, or a meter without an anchor, leaves it to the screen too.
    private func showResultInCamera(rising: Bool) {
        guard LiveCapture.supportsMesh, let live, let wall = state.wall, let result = state.result,
              let pose = meterTracking?.pose, state.spatialResultAvailable else { return }
        if rising || resultWatch == nil { watchResultInCamera() }
        // Each rebuild takes the model out of the scene and puts a new one in, so a wall that
        // moved by a centimeter or two keeps the one it has. A new model starts on the screen's
        // drawing and has to be seen drawn again (`ResultOverlayPolicy.needsModel`, review of
        // #100); it goes in see-through (`LiveCapture.showResult`), so only one layer shows.
        guard resultPolicy.needsModel(for: Self.modelShape(wall), rising: rising) else { return }
        setResultInCamera(resultPolicy.usesRealityKit)
        let model = ResultARModel.build(wall: wall, result: result)
        // The battery's middle, or the meter without a spot, in the model's coordinates.
        let focus = (result.spotCenter(on: wall) ?? wall.meter) - wall.meter
        guard live.showResult(model, builtFor: pose, focus: focus) else {
            resultPolicy.modelRemoved()
            return
        }
        live.setResultVisible(state.tracking == .normal)
        if rising { ResultARModel.rise(model) }
    }

    /// What the AR result's model is built from, for `ResultOverlayPolicy.needsModel`: the
    /// meter, the ground, the ends and each piece of wall.
    private static func modelShape(_ wall: WallGeometry) -> ResultModelShape {
        var shape = ResultModelShape(
            points: [wall.meter], values: [wall.groundY, wall.leftEnd, wall.rightEnd],
            directions: [wall.along, wall.outward]
        )
        for piece in wall.cornerSegments {
            shape.points.append(piece.anchor)
            shape.values += [piece.span.lowerBound, piece.span.upperBound, piece.anchorS]
            shape.directions += [piece.along, piece.outward]
        }
        return shape
    }

    /// Looks at the AR scene about ten times a second while "See it on your wall" is up, and
    /// lets the screen's drawing step aside once the scene is seen drawing the result, for as
    /// long as the scene holds it (`ResultOverlayPolicy`). On its own clock, not in `ingest`: it
    /// has to notice a scene that stopped holding it whether frames arrive or not.
    private func watchResultInCamera() {
        resultWatch?.cancel()
        resultWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.state.phase == .resultAR, let live = self.live else {
                    // Nothing left to watch: the screen draws the result (review of #100).
                    self.setResultInCamera(false)
                    return
                }
                let look = live.resultIsDrawn()
                self.setResultInCamera(self.resultPolicy.update(drawn: look.drawn, held: look.held, time: self.screenTime))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Which layer draws the result: the AR scene (true) or the screen's overlay (false). The
    /// AR scene's model shows only while it owns the result (`LiveCapture.setResultOwned`), and
    /// both change here together, so the two layers are never both on screen: not while a new
    /// model waits to be seen, and not while tracking comes back and `ingest` enables the model
    /// before the next look (review of #100).
    private func setResultInCamera(_ usesRealityKit: Bool) {
        live?.setResultOwned(usesRealityKit)
        guard state.resultInCamera != usesRealityKit else { return }
        RuntimeLog.engine.info("AR result drawn by \(usesRealityKit ? "the AR scene" : "the screen overlay", privacy: .public)")
        state.resultInCamera = usesRealityKit
    }

    private func hideResultInCamera() {
        resultWatch?.cancel()
        resultWatch = nil
        resultPolicy = ResultOverlayPolicy()
        live?.hideResult()
        state.resultInCamera = false
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
            // The band the walk asks for; heights above it are still reported when seen.
            wallBandHeight: map.config.wallWalkHeight,
            groundBandDepth: map.config.groundBandDepth,
            visibleRange: range,
            revision: map.revision
        )
    }

    func setEnd(_ side: WallSide, at s: Float, kind: EndKind) {
        guard var map = coverage else { return }
        markTimes[MarkKey.end(side)] = captureClock
        map.setEnd(side == .left ? .left : .right, at: s)
        // Ground past a limit end still counts toward clearances (server contract, "Ends and
        // corners"); past an unexplored end it doesn't.
        map.setEndIsLimit(side == .left ? .left : .right, kind == .limit)
        coverage = map
        endKinds[side] = kind
        state.wallTooShort = false
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
        updateCoverage { $0.setEndIsLimit(side == .left ? .left : .right, kind == .limit) }
        RuntimeLog.engine.info("end \(side.rawValue, privacy: .public) is \(kind == .limit ? "limit" : "unexplored", privacy: .public)")
    }

    func clearEnd(_ side: WallSide) {
        markTimes[MarkKey.end(side)] = nil
        updateCoverage { $0.clearEnd(side == .left ? .left : .right) }
        endKinds[side] = nil
        if state.endQuestion == side { state.endQuestion = nil }
        publishWall()
    }

    var bothEndsMarked: Bool { coverage?.leftEnd != nil && coverage?.rightEnd != nil }

    // MARK: Gap loop

    /// After the review: ask for the planner's gap, or upload. Confirming the review starts a new
    /// pass of server requests raised without a tap.
    func runGapCheck() {
        automaticGaps = []
        automaticGapsStopped = false
        // A request needs the camera in the scan's world frame; while the phone has lost its
        // place, the scan goes as it is and the server's answer lists what is still unseen.
        guard !state.tracking.hasLostItsPlace else {
            RuntimeLog.engine.info("gap check skipped: the phone has lost its place; uploading the scan as it is")
            startUpload()
            return
        }
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
        // The server's own words name the height ("seen at least 6 ft 6 in up the wall").
        case .wallUp: reason
        }
        gapCounter += 1
        gapPlan = plan
        keyframesAtGapStart = store.keyframes.count
        overheadViewsAtGapStart = coverage?.overheadCameras.count ?? 0
        let progress = coverage.map { gapPlanner.progress(of: plan, $0) } ?? 0
        state.gap = GapRequest(id: gapCounter, origin: origin, reason: reason, band: plan.band == .ground ? .ground : .wall, span: plan.span, progress: progress, isSatisfied: false)
        state.guidance = .gap
        go(.gapRequest)
        updateGap(camera: lastFrame?.camera)
    }

    /// A closed or skipped gap goes straight to the upload, which re-runs the server's checks
    /// with the new evidence (the closed loop: gap, instruction, capture, updated result). The
    /// answer then leads to the next capturable request or to the result (`upload`).
    private func afterGapResolved() {
        settleClearedEnd()
        gapPlan = nil
        pastEndSide = nil
        pendingOverhead = nil
        state.overheadQuestion = false
        state.gap = nil
        startUpload()
    }

    /// The past_end request's end was marked again and its question answered: the request is
    /// settled, so the scan goes to the upload like a closed gap.
    func settlePastEnd() {
        guard state.phase == .gapRequest, var request = state.gap, !request.isSatisfied else { return }
        resolveGuidance(.met)
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

    /// Keeps the tilted-up view the overhead question was about as overhead evidence. Call it
    /// only once the homeowner answered that nothing is overhead (`answerOverhead(clear: true)`):
    /// the camera can't tell open sky from an eave. The view's photo is stored as a keyframe
    /// first, and it counts as overhead evidence only once stored (`recordOverhead`), like every
    /// other view. Returns false when it can't be kept: no photo, tracking not normal, or the
    /// view doesn't show the wall from the top of the sampled rows (7.5 ft, `wallCaptureHeight`) upward.
    /// `segment` is the walked-path segment the view was captured in.
    func keepOverheadView(_ frame: SourceFrame, capturedIn segment: Int?) -> Bool {
        guard let map = coverage, frame.jpeg.isAvailable, frame.tracking == .normal,
              !map.overheadReach(from: correctedCamera(frame)).isEmpty else { return false }
        keep(frame, overhead: true, capturedIn: segment)
        return true
    }

    /// Records a stored tilted-up view in the coverage map; the export then sends each stretch it
    /// reached as an overhead entry with the height seen.
    private func recordOverhead(_ frame: SourceFrame) {
        guard var map = coverage else { return }
        let reach = map.recordOverhead(correctedCamera(frame), trackingNormal: frame.tracking == .normal)
        guard !reach.isEmpty else {
            RuntimeLog.engine.error("overhead: the stored view no longer reaches above the wall band; nothing recorded")
            return
        }
        coverage = map
        RuntimeLog.engine.info("overhead: kept a view reaching \(reach.map(\.out).min() ?? 0) m over s=\(reach.first?.span.lowerBound ?? 0)...\(reach.last?.span.upperBound ?? 0)")
    }

    /// Ends the current request without the view it asked for ("I can't get there", or something
    /// overhead): recorded for installer review, then on to the upload. "I can't get there" on a
    /// server request also ends the requests raised without a tap: after that upload the result
    /// shows. Something overhead is an answer, not a refusal, so the loop goes on.
    func skipCurrentGap(because reason: String = "the homeowner can't get there", refused: Bool = true) {
        guard let plan = gapPlan else { return }
        // Something overhead is an answer: the request goes to review without its view.
        resolveGuidance(refused ? .cannotReach : .skipped)
        if refused, state.gap?.origin == .server { automaticGapsStopped = true }
        // Only a cell request marks cells: skipping a deeper, walked or overhead view says
        // nothing about the band the strip draws.
        if plan.need == .cells { coverage?.markSkipped(plan.band, plan.span) }
        skippedGaps.append(plan)
        publishCoverage()
        RuntimeLog.engine.info("gap \(self.gapCounter) left for installer review: \(reason, privacy: .public)")
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
        // Sending again from a failed upload stays on this phase, so `go` doesn't restart them.
        updateRecording()
        // Keyframe writes still in flight belong in the scene's keyframe list.
        for _ in 0..<200 where (pendingSaves[scan] ?? 0) > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard scan == generation else { return }
        var resends = 0
        while true {
            // Everything this attempt sends is built from one snapshot of one frame
            // (`UploadSnapshot`): scene.json, the mesh's measurements and the packet.
            guard let snapshot = await takeUploadSnapshot() else {
                guard scan == generation, !Task.isCancelled else { return }
                RuntimeLog.engine.error("scene.json export failed: no wall")
                state.upload = UploadFailure.packaging(ExportError.noWall)
                updateRecording()
                return
            }
            guard scan == generation, !Task.isCancelled else { return }
            // LiDAR phones: the frame's mesh, measured for what faces the wall and what is
            // overhead against the snapshot's wall, off the main actor since ray casts over a
            // whole mesh take a while. Nothing the measurement or the export reads can move
            // meanwhile: both read the snapshot.
            var measured = MeshMeasurements()
            if let mesh = snapshot.mesh?.mesh {
                let wall = snapshot.map.wall
                let span = Self.exportSpan(snapshot.map)
                measured = await Task.detached(priority: .userInitiated) { Self.measure(mesh, wall: wall, over: span) }.value
                guard scan == generation, !Task.isCancelled else { return }
                RuntimeLog.engine.info("mesh: \(mesh.vertices.count) vertices, \(mesh.indices.count / 3) triangles; \(measured.facing.count) facing and \(measured.overheads.count) overhead measurements")
            }
            let scene: Data
            do {
                scene = try sceneJSON(snapshot, mesh: measured)
            } catch {
                RuntimeLog.engine.error("scene.json export failed: \(String(describing: error), privacy: .public)")
                state.upload = UploadFailure.packaging(error)
                updateRecording()
                return
            }
            writeScanStamp(answer: placement)
            saveBundle(scene: scene, snapshot: snapshot)
            guard !Task.isCancelled else { return }
            state.upload = .uploading(fraction: 0)
            let result: PlacementResult
            let data: Data
            do {
                data = try await resultClient.submit(scene: scene) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, scan == self.generation, case .uploading = self.state.upload else { return }
                        self.state.upload = fraction >= 1 ? .analyzing : .uploading(fraction: fraction)
                    }
                }
                guard scan == generation else { return }
                state.upload = .analyzing
                result = try PlacementResult.decode(data)
            } catch is CancellationError {
                return
            } catch {
                guard scan == generation else { return }
                RuntimeLog.engine.error("upload failed: \(String(describing: error), privacy: .public)")
                state.upload = UploadFailure.state(for: error)
                updateRecording()
                return
            }
            // An answer about geometry the phone has since corrected would be drawn on the
            // wrong wall (`AnswerFreshness`).
            switch AnswerFreshness.of(sent: snapshot.revision, now: spatialRevision, resends: resends) {
            case .current:
                break
            case .sendAgain:
                resends += 1
                RuntimeLog.engine.info("answer is stale (sent at revision \(snapshot.revision), now \(self.spatialRevision)): sending again")
                state.upload = .packaging
                continue
            case .stillChanging:
                RuntimeLog.engine.error("answer is stale again (sent at revision \(snapshot.revision), now \(self.spatialRevision)): not shown")
                state.upload = UploadFailure.stillChanging
                updateRecording()
                return
            }
            placement = result
            lastUploadSnapshot = snapshot
            noteExchange(scene: scene, answer: data)
            break
        }
        guard let result = placement else { return }
        writeScanStamp(answer: result)
        state.result = presentation(of: result, isSample: resultClient.isSample)
        state.upload = .done
        await waitForGate(.uploading)
        guard scan == generation else { return }
        if let next = nextAutomaticGap(result) {
            // The upload screen says "One more view to finish" once the answer is in
            // (`state.result` set, upload `.done`, both kept through the request): long
            // enough to read before the camera takes over.
            guard (try? await Task.sleep(for: .seconds(Self.followUpHold))) != nil,
                  scan == generation, state.phase == .uploading else { return }
            automaticGaps.append(next.plan)
            RuntimeLog.engine.info("answer lists capturable evidence: asking for it (\(self.automaticGaps.count) of at most \(Self.maxAutomaticGaps))")
            beginServerGap(next.item, plan: next.plan)
            return
        }
        // The result appears only after the server answered (checklist R6), and after the
        // homeowner checked its spot (`presentAnswer`).
        presentAnswer()
    }

    /// The first item of the answer's missing evidence a capture can settle (the result's
    /// "capturable"), not skipped and not yet raised in this pass; nil once the homeowner said
    /// they can't get to one, or after `maxAutomaticGaps` requests.
    private func nextAutomaticGap(_ result: PlacementResult) -> (item: PlacementMissingEvidence, plan: GapPlan)? {
        // A request raised while the phone has lost its place could only time out: show the result.
        guard !automaticGapsStopped, automaticGaps.count < Self.maxAutomaticGaps, !state.tracking.hasLostItsPlace,
              sourceState.mayCapture, let map = coverage else { return nil }
        for item in result.missingEvidence {
            guard let plan = gapPlanner.plan(for: item, leftEnd: map.leftEnd, rightEnd: map.rightEnd, limitEnds: map.limitEnds),
                  !skippedGaps.contains(plan), !automaticGaps.contains(plan), captureCanSettle(plan) else { continue }
            return (item, plan)
        }
        return nil
    }

    /// Starts the capture for an item of the server's missing evidence, whether tapped on the
    /// result or raised after an upload.
    func beginServerGap(_ item: PlacementMissingEvidence, plan: GapPlan) {
        var pastEnd: WallSide?
        if item.kind == .pastEnd, let side = item.side {
            // The walk has to go past the end it stopped at; that end is no longer a limit. It
            // stays cleared until the homeowner marks it again (markWallEnd) or the request ends
            // (settleClearedEnd).
            let wallSide: WallSide = side == .left ? .left : .right
            pastEnd = wallSide
            let old = wallSide == .left ? coverage?.leftEnd : coverage?.rightEnd
            clearedEnd = old.map { (s: $0, kind: endKinds[wallSide] ?? EndKind.unexplored, t: markTimes[MarkKey.end(wallSide)]) }
            clearEnd(wallSide)
        }
        // Set first, so the guidance log records the request as a past-end one.
        pastEndSide = pastEnd
        beginGap(plan, origin: .server, reason: .server(detail: item.message))
    }

    /// A past_end request ending without its end marked again (the gap screen offers only "I
    /// can't get there") must not leave that side without an end: the export would run the wall
    /// out to whatever the fog saw, and the next past_end request would be planned from the
    /// meter (issue #35). Met, the end moves on past the ground the request showed, still
    /// unexplored (`GapPlanner.endAfterPastEnd`); skipped, the end it cleared comes back with its
    /// kind and mark time.
    private func settleClearedEnd() {
        guard let side = pastEndSide, let old = clearedEnd, let plan = gapPlan else { return }
        clearedEnd = nil
        guard (side == .left ? coverage?.leftEnd : coverage?.rightEnd) == nil else { return }
        if state.gap?.isSatisfied == true {
            setEnd(side, at: gapPlanner.endAfterPastEnd(plan, side: side == .left ? .left : .right, clearedAt: old.s), kind: .unexplored)
        } else {
            setEnd(side, at: old.s, kind: old.kind)
            markTimes[MarkKey.end(side)] = old.t
        }
    }

    /// Writes the capture packet (`ScanEngine+Packet.swift`) with this scene.json inside, zipped
    /// into the scan folder's `scan.zip`: the bundle "Share scan" offers (`state.shareableScan`)
    /// whatever the upload then does: it fails, is refused or answers. Nothing uploads the
    /// packet, and the upload never waits for it or fails because of it. The zip is rewritten in
    /// place, so it is not offered while a write is under way, and writes run one after another:
    /// a retry's write waits for the last one, and a write already superseded is skipped.
    func saveBundle(scene: Data, snapshot: UploadSnapshot) {
        state.shareableScan = nil
        bundleSerial += 1
        let serial = bundleSerial
        let scan = generation
        let previous = bundleTask
        guard let inputs = packetInputs(scene: scene, snapshot: snapshot) else {
            RuntimeLog.engine.error("scan bundle not written: no wall")
            return
        }
        bundleTask = Task {
            await previous?.value
            guard scan == generation, serial == bundleSerial else { return }
            do {
                let written = try await Task.detached(priority: .userInitiated) { try Self.writePacket(inputs) }.value
                RuntimeLog.engine.info("bundle \(written.url.path, privacy: .public): packet \(PacketManifest.version, privacy: .public) with \(written.summary, privacy: .public) (kept on the phone)")
                guard scan == generation, serial == bundleSerial else { return }
                state.shareableScan = written.url
            } catch {
                RuntimeLog.engine.error("scan bundle not written: \(String(describing: error), privacy: .public)")
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
        spatialRevision += 1
        uploadTask?.cancel()
        cancelPendingSnapshot()
        lastUploadSnapshot = nil
        replay?.stop()
        coverage = nil
        meterAnchorID.map { live?.removeAnchor($0) }
        meterAnchorID = nil
        meterPlaneSource = .detectedPlane
        store = KeyframeStore()
        recorder = Self.makeRecorder(store)
        live?.setRecorder(recorder)
        motion.stop()
        resetPacketLog()
        keptSourceIDs = []
        autoCapture.reset()
        planner.reset()
        closeUpGate = CloseUpGate()
        gapPlan = nil
        skippedGaps = []
        pastEndSide = nil
        clearedEnd = nil
        automaticGaps = []
        automaticGapsStopped = false
        seeBehindBands = []
        endKinds = [:]
        state.endQuestion = nil
        state.wallTooShort = false
        nextWallSide = nil
        nextWallRefusal = nil
        resetTiltUp()
        resetSpotChecks()
        placement = nil
        // The bundle belongs to the scan being thrown away; `generation` stops a write in flight
        // from offering it again.
        state.shareableScan = nil
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

    /// The overhead views belong to the world frame and the scan they were seen in.
    private func resetTiltUp() {
        tiltUpSettled = false
        pendingOverhead = nil
        state.overheadQuestion = false
    }

    // MARK: Internal accessors for marking and export

    var currentFrame: SourceFrame? { lastFrame }
    var liveCapture: LiveCapture? { live }
    var wallEndKinds: [WallSide: EndKind] { endKinds }

    /// The meter's anchor, and the pose the wall set with it agrees with.
    func setMeterAnchor(_ id: UUID?, pose: simd_float4x4?) {
        meterAnchorID = id
        meterTracking = pose.map(MeterAnchorTracking.init)
    }

    var detectedGroundPlanes: [GroundPlaneEvidence] { groundPlanes }

    /// The camera failed after the scan was sent: no frame will come to say tracking was lost, so
    /// the last one's "normal" would keep the AR result up and offered. The answer stays; the
    /// spatial result goes.
    private func loseSpatialResult() {
        state.tracking = .notAvailable
        state.spatialResultAvailable = false
        hideResultInCamera()
        if state.phase == .resultAR { go(.result) }
    }

    /// Whether a capture (a server request's view) can start: only with a running source.
    var mayCapture: Bool { sourceState.mayCapture }

    /// Start over after a failure: the failed source is let go and the failure cleared, so the
    /// next scan starts a new session (`startSourceIfNeeded`) or reads the replay again. A
    /// device that can't run world tracking stays failed.
    func releaseFailedSource() {
        let discard = sourceState.startOver()
        if sourceState.failure == nil { state.failure = nil }
        guard discard else { return }
        live?.pause()
        live = nil
        state.feed = .none
        // What the retired source saw is in its own world frame; the next source starts another.
        groundPlanes = []
        groundMeasured = false
        lastFrame = nil
        meterTracking = nil
        meterAnchorID = nil
        state.projection = nil
        state.tracking = .notAvailable
        if replay == nil, let folder = options.replayFolder { Task { await loadReplay(folder) } }
    }

    func updateCoverage(_ body: (inout CoverageMap) -> Void) {
        guard var map = coverage else { return }
        body(&map)
        coverage = map
        publishCoverage()
    }

    // MARK: Packet log

    /// Forgets the guidance log, the mark times and the clock: they belong to the packet session
    /// being thrown away.
    private func resetPacketLog() {
        guidanceLog = GuidanceLog()
        markTimes = [:]
        captureClock = nil
    }

    /// Records what request is on screen now in the guidance log.
    func noteGuidance() {
        publishEndPreview()
        guard let t = captureClock else { return }
        guidanceLog.show(guidanceRequest(), at: t) { old, next in closingOutcome(old, next: next) }
    }

    /// Closes the open request with an outcome an action settled.
    func resolveGuidance(_ outcome: GuidanceLog.Outcome) {
        guard let t = captureClock else { return }
        guidanceLog.resolve(outcome, at: t)
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
        case .hidden: .hidden
        }
    }

    static func step(_ task: GuidanceTask) -> GuidanceStep {
        switch task {
        case .walk(let side): .walk(side: side == .left ? .left : .right, remaining: nil)
        case .markEnd(let side): .markEnd(side: side == .left ? .left : .right)
        case .aimAtGround(let s): .aimAtGround(s: s)
        case .aimAtWall(let s): .aimAtWall(s: s)
        case .stepBack: .stepBack
        case .seeBehind(let s): .seeBehind(s: s)
        case .complete: .walkComplete
        }
    }

    static func name(_ tracking: TrackingQuality) -> String {
        switch tracking {
        case .notAvailable: "notAvailable"
        case .normal: "normal"
        case .limited(let reason): "limited.\(reason)"
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
        case .markNextWall(let side, _): "markNextWall.\(side.rawValue)"
        case .gap: "gap"
        case .seeBehind: "seeBehind"
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
