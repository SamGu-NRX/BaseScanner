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
    private var closeUpPending = false

    // Wall geometry inputs
    private var meterAnchorID: UUID?
    private var groundPlaneY: Float?
    private var lastFrame: SourceFrame?
    private var endKinds: [WallSide: EndKind] = [:]

    // Gap loop
    private var gapPlan: GapPlan?
    private var gapCounter = 0
    private var skippedGaps: [GapPlan] = []
    private var serverMissingPending: [String] = []

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
        /// The homeowner marked where the wall ends.
        case limit
        /// The walk stopped there without reaching the wall's end ("I can't get there").
        case unexplored
    }

    init(options: LaunchOptions) {
        self.options = options
        store = KeyframeStore()
        if options.sampleResult || options.serverURL == nil {
            resultClient = SampleResultClient(pace: options.autopilot ? options.autopilotHold : 1.2)
        } else if let url = options.serverURL {
            resultClient = HTTPResultClient(serverURL: url)
        } else {
            resultClient = SampleResultClient(pace: 1.2)
        }
        state.isAutopilot = options.autopilot
        state.isReplay = options.replayFolder != nil
    }

    // MARK: Start

    func start() {
        RuntimeLog.state.info("STATE=\(self.state.phase.rawValue, privacy: .public)")
        if let folder = options.replayFolder {
            do {
                let player = try ReplayPlayer(folder: folder) { [weak self] frame in self?.ingest(frame) }
                replay = player
                player.show(index: 0)
                RuntimeLog.engine.info("replay \(player.session.id, privacy: .public): \(player.frames.count) frames, wall \(player.wallDescription, privacy: .public)")
            } catch {
                state.failure = .replayUnreadable(String(describing: error))
                RuntimeLog.engine.error("replay unreadable: \(String(describing: error), privacy: .public)")
            }
        } else if !ARWorldTrackingConfiguration.isSupported {
            state.failure = .arUnsupported
            go(.unsupported)
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
        lastFrame = frame
        if let still = frame.still { state.feed = .still(still) }
        state.projection = frame.projection
        if state.tracking != frame.tracking { state.tracking = frame.tracking }
        if let y = frame.groundPlaneY { groundPlaneY = y }
        refreshMeterFromAnchor(frame)
        trackRelocalization(frame)
        guard !frame.isReview else { return }

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

    private func refreshMeterFromAnchor(_ frame: SourceFrame) {
        guard let anchor = frame.meterAnchor, var wall = coverage?.wall else { return }
        let meter = SIMD3(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
        guard simd_distance(meter, wall.meter) > 0.002 else { return }
        wall.meter = meter
        coverage?.updateWall(wall)
        publishWall()
    }

    private func closeUp(_ frame: SourceFrame) {
        guard let wall = coverage?.wall else { return }
        if case .captured = state.closeUp { return }
        if case .skipped = state.closeUp { return }
        let sample = FrameSample(timestamp: frame.timestamp, camera: frame.camera, tracking: frame.captureTracking, quality: frame.quality)
        let status = closeUpGate.evaluate(sample, meter: wall.meter)
        state.closeUpFailedAttempts = status.failedAttempts
        state.coaching = coaching(for: frame.tracking, skip: nil)
        if status.fire || closeUpPending, status.issue == nil, frame.jpeg.isAvailable {
            closeUpPending = false
            captureCloseUp(frame)
        } else {
            if status.fire { closeUpPending = true }
            state.closeUp = .aiming(hold: status.hold, problem: status.issue.map(Self.problem))
        }
    }

    private func captureCloseUp(_ frame: SourceFrame) {
        state.closeUp = .captured(nil)
        Task {
            let saved = await store.saveStill(frame.jpeg, name: "meter_close.jpg")
            guard state.phase == .meterCloseUp else { return }
            if !saved {
                closeUpGate.photoRejected()
                state.closeUpFailedAttempts = closeUpGate.failedAttempts
                state.closeUp = .aiming(hold: 0, problem: .blurry)
                return
            }
            let thumbnail = await store.thumbnail(ofStill: "meter_close.jpg")
            state.closeUp = .captured(thumbnail)
            state.captureCount += 1
            state.lastCapture = CaptureEvent(id: state.captureCount, kind: .closeUp, thumbnail: thumbnail)
            try? await Task.sleep(for: .seconds(autoAdvanceDelay))
            if state.phase == .meterCloseUp { go(.wallWalk) }
        }
    }

    private func walk(_ frame: SourceFrame) {
        guard var map = coverage else { return }
        let sample = FrameSample(timestamp: frame.timestamp, camera: frame.camera, tracking: frame.captureTracking, quality: frame.quality)
        let decision = autoCapture.evaluate(sample, newlySeenCells: map.newlySeenCount(from: frame.camera))
        var skip: CaptureDecision.SkipReason?
        if case .skip(let reason) = decision { skip = reason }
        if decision.isKeep, frame.jpeg.isAvailable, !keptSourceIDs.contains(frame.id) {
            autoCapture.didKeep(sample)
            keptSourceIDs.insert(frame.id)
            // Coverage only moves on kept frames with normal tracking (checklist R3).
            map.observe(frame.camera, trackingNormal: frame.tracking == .normal)
            coverage = map
            keep(frame)
        }
        state.coaching = coaching(for: frame.tracking, skip: skip)
        publishCoverage()
        if state.phase == .wallWalk {
            updateGuidance(camera: frame.camera, time: frame.timestamp)
        } else {
            updateGap(camera: frame.camera)
        }
    }

    private func keep(_ frame: SourceFrame) {
        let kind: CaptureEvent.Kind = state.phase == .gapRequest ? .gap : .walk
        let index = store.nextKeyframeIndex()
        let camera = frame.camera
        state.captureCount += 1
        let eventID = state.captureCount
        Task {
            let thumbnail = await store.saveKeyframe(frame.jpeg, index: index, camera: camera)
            state.lastCapture = CaptureEvent(id: eventID, kind: kind, thumbnail: thumbnail)
        }
    }

    // MARK: Guidance

    private func updateGuidance(camera: CameraFrame, time: Double) {
        guard let map = coverage else { return }
        let output = planner.update(coverage: map, camera: camera, time: time)
        state.guidance = Self.step(output.task)
        state.target = output.target
        state.path = output.path
        logGuidance()
    }

    /// "I can't get there" satisfied the current task: choose the next one now.
    func resetGuidanceAfterSkip(camera: CameraFrame, time: Double) {
        planner.reset()
        updateGuidance(camera: camera, time: time)
    }

    private func updateGap(camera: CameraFrame?) {
        guard let map = coverage, let plan = gapPlan, var request = state.gap else { return }
        request.progress = gapPlanner.progress(of: plan, map)
        let satisfied = gapPlanner.isSatisfied(plan, map)
        state.guidance = .gap
        let center = (plan.span.lowerBound + plan.span.upperBound) / 2
        state.target = plan.band == .ground
            ? map.wall.world(s: center, height: 0, out: map.config.groundBandDepth / 2)
            : map.wall.world(s: center, height: 1.2)
        if let camera {
            let from = map.wall.wallPoint(camera.position).s
            state.path = [from, center].map { map.wall.world(s: $0, height: 0, out: 1.5) }
        }
        logGuidance()
        if satisfied, !request.isSatisfied {
            request.isSatisfied = true
            request.progress = max(request.progress, gapPlanner.config.satisfiedFraction)
            state.gap = request
            RuntimeLog.engine.info("gap \(request.id) satisfied")
            Task {
                try? await Task.sleep(for: .seconds(autoAdvanceDelay))
                guard state.phase == .gapRequest else { return }
                afterGapResolved()
            }
        } else if !request.isSatisfied {
            state.gap = request
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
        if case .limited(.relocalizing) = frame.tracking {
            let since = relocalizingSince ?? frame.timestamp
            relocalizingSince = since
            // After 20 s ARKit is unlikely to relocalize; the old world frame is gone
            // (checklist R5). Start again from the meter.
            if frame.timestamp - since > 20 { resetSpatialState(reason: "relocalization timed out") }
        } else {
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
            state.failure = .cameraDenied
        case .failed(let message):
            state.failure = .sessionFailed(message)
        }
    }

    /// Forgets everything tied to the old world frame and asks for the meter again.
    func resetSpatialState(reason: String) {
        RuntimeLog.engine.info("spatial reset: \(reason, privacy: .public)")
        relocalizingSince = nil
        coverage = nil
        meterAnchorID.map { live?.removeAnchor($0) }
        meterAnchorID = nil
        state.wall = nil
        state.coverage = .empty
        state.target = nil
        state.path = []
        state.features = []
        state.gap = nil
        gapPlan = nil
        endKinds = [:]
        store.discardKeyframes()
        keptSourceIDs = []
        state.captureCount = 0
        autoCapture.reset()
        planner.reset()
        go(.findMeter)
    }

    // MARK: Wall

    /// Sets the wall from a meter point and the wall's outward normal, and starts coverage.
    func setWall(meter: SIMD3<Float>, outward: SIMD3<Float>, groundY: Float) -> Bool {
        guard let frame = WallFrame(meter: meter, outward: outward, groundY: groundY) else { return false }
        coverage = CoverageMap(wall: frame)
        endKinds = [:]
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
        gapCounter += 1
        gapPlan = plan
        let progress = coverage.map { gapPlanner.progress(of: plan, $0) } ?? 0
        state.gap = GapRequest(id: gapCounter, origin: origin, reason: reason, band: plan.band == .ground ? .ground : .wall, span: plan.span, progress: progress, isSatisfied: false)
        state.guidance = .gap
        go(.gapRequest)
        updateGap(camera: lastFrame?.camera)
    }

    private func afterGapResolved() {
        gapPlan = nil
        state.gap = nil
        if let next = serverMissingPending.first {
            serverMissingPending.removeFirst()
            captureMissing(next)
            return
        }
        startUpload()
    }

    func skipCurrentGap() {
        guard let plan = gapPlan else { return }
        coverage?.markSkipped(plan.band, plan.span)
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
        state.upload = .packaging
        let bundle: URL
        do {
            bundle = try await store.writeBundle(sceneJSON: try sceneJSON())
            RuntimeLog.engine.info("bundle \(bundle.path, privacy: .public) with \(self.store.keyframes.count) keyframes")
        } catch {
            RuntimeLog.engine.error("packaging failed: \(String(describing: error), privacy: .public)")
            state.upload = .failed(message: String(describing: error), offline: false)
            return
        }
        state.upload = .uploading(fraction: 0)
        do {
            let data = try await resultClient.submit(bundle: bundle) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .uploading = self.state.upload else { return }
                    self.state.upload = fraction >= 1 ? .analyzing : .uploading(fraction: fraction)
                }
            }
            state.upload = .analyzing
            let result = try PlacementResult.decode(data)
            placement = result
            state.result = presentation(of: result, isSample: resultClient.isSample)
            state.upload = .done
            // The result appears only after the server answered (checklist R6).
            go(.result)
        } catch is CancellationError {
            return
        } catch {
            RuntimeLog.engine.error("upload failed: \(String(describing: error), privacy: .public)")
            state.upload = .failed(message: String(describing: error), offline: (error as? URLError) != nil)
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
        uploadTask?.cancel()
        replay?.stop()
        coverage = nil
        meterAnchorID.map { live?.removeAnchor($0) }
        meterAnchorID = nil
        store = KeyframeStore()
        keptSourceIDs = []
        autoCapture.reset()
        planner.reset()
        closeUpGate = CloseUpGate()
        gapPlan = nil
        skippedGaps = []
        serverMissingPending = []
        endKinds = [:]
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
        go(.onboarding)
        replay?.show(index: 0)
    }

    // MARK: Internal accessors for marking and export

    var currentFrame: SourceFrame? { lastFrame }
    var liveCapture: LiveCapture? { live }
    var wallEndKinds: [WallSide: EndKind] { endKinds }

    func setMeterAnchor(_ id: UUID?) { meterAnchorID = id }
    var detectedGroundY: Float? { groundPlaneY }

    func queueServerMissing(_ ids: [String]) { serverMissingPending = ids }

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
