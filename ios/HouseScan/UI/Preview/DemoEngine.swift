import SwiftUI

/// A fake engine for the UI demo: implements `ScanActions` by scripting `ScanViewState` over
/// the made-up wall in `DemoScene`. It mimics the real engine's phases and timing closely enough
/// to exercise every screen; it measures nothing.
@MainActor
final class DemoEngine: ScanActions {
    let state = ScanViewState()

    private let freeze: Bool
    private let noFeed: Bool
    private let offline: Bool
    private let passResult: Bool
    private var script: Task<Void, Never>?
    private var nextCaptureID = 1
    /// How far the walk has seen to each side of the meter, meters.
    private var reachedLeft: Float = 0.3
    private var reachedRight: Float = 0.3
    private var skippedSpan: ClosedRange<Float>?
    private var returnToReview = false
    private var failedUploads = 0

    private static let cellWidth: Float = 0.1524
    private static let leftEnd: Float = -2.9
    private static let rightEnd: Float = 4.3

    init(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        freeze = arguments.contains("-uiDemoFreeze")
        noFeed = arguments.contains("-uiDemoNoFeed")
        offline = arguments.contains("-uiDemoOffline")
        passResult = arguments.contains("-uiDemoPass")
        state.feed = DemoScene.image.map(CameraFeed.still) ?? .none
        state.isReplay = true
        state.tracking = .normal

        if let failure = value("-uiDemoFailure") {
            state.failure = failure == "cameraDenied" ? .cameraDenied : .arUnsupported
            state.phase = .unsupported
            return
        }
        let phase = value("-uiDemoPhase").flatMap(ScanPhase.init(rawValue:)) ?? .onboarding
        jump(to: phase)
        if let raw = value("-uiDemoMarking"), let kind = FeatureKind(rawValue: raw) {
            state.marking = MarkingState(kind: kind, step: 0, refusal: arguments.contains("-uiDemoRefusal") ? .noSurface : nil)
        }
        if let raw = value("-uiDemoCoaching") {
            state.coaching = Self.coaching(raw)
            // The real engine reports these two only while the phone has lost its place, which
            // also hides the overlays drawn from its position.
            switch state.coaching {
            case .relocalizing: state.tracking = .limited(.relocalizing)
            case .trackingLost: state.tracking = .notAvailable
            default: break
            }
        }
        if arguments.contains("-uiDemoEndQuestion") {
            state.endQuestion = .left
        }
        if arguments.contains("-uiDemoSample") {
            state.usesSampleResult = true
        }
        if arguments.contains("-uiDemoNoFeed") {
            state.feed = .none
        }
        if arguments.contains("-uiDemoCloseUpFailed") {
            state.closeUpFailedAttempts = 2
            state.closeUp = .aiming(hold: 0.2, problem: .tooBright)
        }
    }

    // MARK: Phase set-up

    /// Puts the state where the real engine would be on arriving at `phase`.
    private func jump(to phase: ScanPhase) {
        switch phase {
        case .onboarding:
            state.phase = .onboarding
        case .findMeter:
            enterFindMeter()
        case .meterCloseUp:
            enterCloseUp()
        case .wallWalk:
            placeMeter()
            reachedLeft = 0.6
            reachedRight = 0.9
            enterWalk()
        case .markFeatures:
            placeMeter()
            finishedWalkState()
            state.phase = .markFeatures
        case .gapRequest:
            placeMeter()
            finishedWalkState()
            enterGap()
        case .uploading:
            placeMeter()
            finishedWalkState()
            enterUpload()
        case .result:
            placeMeter()
            finishedWalkState()
            showResult()
        case .resultAR:
            placeMeter()
            finishedWalkState()
            showResult()
            state.phase = .resultAR
        case .unsupported:
            state.failure = .arUnsupported
            state.phase = .unsupported
        }
    }

    private func enterFindMeter() {
        state.phase = .findMeter
        state.guidance = .findMeter
        state.feed = noFeed ? .none : DemoScene.meterImage.map(CameraFeed.still) ?? .none
        state.projection = DemoScene.meterProjection
        state.wall = nil
        state.coverage = .empty
    }

    private func placeMeter() {
        state.feed = noFeed ? .none : DemoScene.image.map(CameraFeed.still) ?? .none
        state.projection = DemoScene.projection
        state.wall = DemoScene.wall
        state.captureCount = max(state.captureCount, 1)
    }

    private func enterCloseUp() {
        placeMeter()
        state.feed = noFeed ? .none : DemoScene.closeUpImage.map(CameraFeed.still) ?? .none
        state.projection = DemoScene.closeUpProjection
        state.phase = .meterCloseUp
        state.guidance = .holdOnMeter
        state.closeUp = .aiming(hold: 0, problem: nil)
        run { engine in await engine.closeUpScript() }
    }

    private func enterWalk() {
        state.phase = .wallWalk
        state.closeUp = .captured(DemoScene.meterThumbnail)
        state.captureCount = max(state.captureCount, 6)
        refreshCoverage()
        refreshGuidance()
        run { engine in await engine.walkScript() }
    }

    private func finishedWalkState() {
        reachedLeft = -Self.leftEnd
        reachedRight = Self.rightEnd
        state.wall?.leftEnd = Self.leftEnd
        state.wall?.rightEnd = Self.rightEnd
        state.captureCount = max(state.captureCount, 42)
        if state.features.isEmpty {
            state.features = [Self.demoFeature(.gasMeter), Self.demoFeature(.window)]
        }
        refreshCoverage()
        state.guidance = .walkComplete
        state.path = []
        state.target = nil
    }

    private func enterGap() {
        // Leave a hole in the ground right of the likely spot, as the phone's planner would find.
        state.phase = .gapRequest
        state.guidance = .gap
        let span: ClosedRange<Float> = 1.3...2.1
        setGround(span, to: .seen)
        state.gap = GapRequest(id: 1, origin: .phone, reason: .groundNearCandidate, band: .ground, span: span, progress: 0, isSatisfied: false)
        state.target = DemoScene.wall.world(s: 1.7, height: 0, out: 0.5)
        state.path = DemoScene.path(toward: 1.7)
        run { engine in await engine.gapScript(span: span) }
    }

    private func enterUpload() {
        state.phase = .uploading
        state.gap = nil
        state.path = []
        state.target = nil
        state.upload = .packaging
        run { engine in await engine.uploadScript() }
    }

    private func showResult() {
        state.upload = .done
        state.result = passResult ? Self.passSample : Self.reviewSample
        state.phase = .result
    }

    // MARK: Scripts

    /// Runs a timed script unless frozen; a new script replaces the old one.
    private func run(_ body: @escaping @MainActor (DemoEngine) async -> Void) {
        script?.cancel()
        guard !freeze else { return }
        script = Task { [weak self] in
            guard let self else { return }
            await body(self)
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private func closeUpScript() async {
        guard await pause(0.6) else { return }
        for step in 1...6 {
            state.closeUp = .aiming(hold: Double(step) * 0.09, problem: nil)
            guard await pause(0.12) else { return }
        }
        state.closeUp = .aiming(hold: 0.54, problem: .blurry)
        guard await pause(1.4) else { return }
        for step in 6...11 {
            state.closeUp = .aiming(hold: Double(step) * 0.09, problem: nil)
            guard await pause(0.12) else { return }
        }
        capture(.closeUp, thumbnail: DemoScene.meterThumbnail)
        state.closeUp = .captured(DemoScene.meterThumbnail)
        guard await pause(1.5) else { return }
        reachedLeft = 0.3
        reachedRight = 0.3
        enterWalk()
    }

    private func walkScript() async {
        while !Task.isCancelled {
            guard await pause(0.45) else { return }
            guard state.marking == nil else { continue }
            if case .walk(let side, _) = state.guidance {
                if side == .right {
                    reachedRight = min(reachedRight + 0.3, Self.rightEnd)
                } else {
                    reachedLeft = min(reachedLeft + 0.3, -Self.leftEnd)
                }
                capture(.walk)
                refreshCoverage()
                refreshGuidance()
            }
        }
    }

    private func gapScript(span: ClosedRange<Float>) async {
        guard await pause(1.2) else { return }
        let cells = Int(((span.upperBound - span.lowerBound) / Self.cellWidth).rounded(.up))
        for step in 1...cells {
            let covered = span.lowerBound...(span.lowerBound + Float(step) * Self.cellWidth)
            setGround(covered, to: .covered)
            state.gap?.progress = Double(step) / Double(cells)
            capture(.gap)
            guard await pause(0.45) else { return }
        }
        state.gap?.isSatisfied = true
        guard await pause(1.6) else { return }
        enterUpload()
    }

    private func uploadScript() async {
        state.upload = .packaging
        guard await pause(1.0) else { return }
        for step in 0...10 {
            state.upload = .uploading(fraction: Double(step) / 10)
            guard await pause(0.22) else { return }
            if offline, failedUploads == 0, step == 4 {
                failedUploads += 1
                state.upload = .failed(message: "No internet connection.", offline: true)
                return
            }
        }
        state.upload = .analyzing
        guard await pause(1.8) else { return }
        showResult()
    }

    // MARK: Coverage

    private func refreshCoverage() {
        let wallRange = DemoScene.wallRange
        let count = Int(((wallRange.upperBound - wallRange.lowerBound) / Self.cellWidth).rounded(.up))
        var wallCells: [CellState] = []
        var groundCells: [CellState] = []
        for index in 0..<count {
            let center = wallRange.lowerBound + (Float(index) + 0.5) * Self.cellWidth
            wallCells.append(Self.state(at: center, left: reachedLeft, right: reachedRight, lag: 0))
            groundCells.append(Self.state(at: center, left: reachedLeft, right: reachedRight, lag: 0.35))
        }
        if let skippedSpan {
            for index in 0..<count {
                let center = wallRange.lowerBound + (Float(index) + 0.5) * Self.cellWidth
                if skippedSpan.contains(center), wallCells[index] != .covered { wallCells[index] = .skipped }
                if skippedSpan.contains(center), groundCells[index] != .covered { groundCells[index] = .skipped }
            }
        }
        let fogAhead: Float = 1.2
        var lower = max(-reachedLeft - fogAhead, wallRange.lowerBound)
        var upper = min(reachedRight + fogAhead, wallRange.upperBound)
        if let left = state.wall?.leftEnd { lower = max(lower, left) }
        if let right = state.wall?.rightEnd { upper = min(upper, right) }
        state.coverage = CoverageStrip(
            cellWidth: Self.cellWidth,
            firstCellS: wallRange.lowerBound,
            wall: wallCells,
            ground: groundCells,
            wallBandHeight: 2.4,
            groundBandDepth: 1.2,
            visibleRange: lower...upper,
            revision: state.coverage.revision + 1
        )
    }

    private static func state(at s: Float, left: Float, right: Float, lag: Float) -> CellState {
        let reach = s < 0 ? left - lag : right - lag
        let distance = abs(s)
        if distance <= reach - 0.3 { return .covered }
        if distance <= reach + 0.3 { return .seen }
        return .unseen
    }

    private func setGround(_ span: ClosedRange<Float>, to cell: CellState) {
        var coverage = state.coverage
        for index in coverage.ground.indices where span.contains(coverage.cellRange(index).lowerBound + Self.cellWidth / 2) {
            coverage.ground[index] = cell
        }
        coverage.revision += 1
        state.coverage = coverage
    }

    private func refreshGuidance() {
        guard let wall = state.wall else { return }
        if wall.rightEnd == nil {
            if reachedRight >= Self.rightEnd - 0.01 {
                state.guidance = .markEnd(side: .right)
                state.target = DemoScene.wall.world(s: Self.rightEnd, height: 1.0)
                state.path = []
            } else {
                state.guidance = .walk(side: .right, remaining: Self.rightEnd - reachedRight)
                state.target = DemoScene.wall.world(s: min(reachedRight + 0.9, Self.rightEnd), height: 0.2, out: 0.3)
                state.path = DemoScene.path(toward: min(reachedRight + 1.2, Self.rightEnd))
            }
        } else if wall.leftEnd == nil {
            if reachedLeft >= -Self.leftEnd - 0.01 {
                state.guidance = .markEnd(side: .left)
                state.target = DemoScene.wall.world(s: Self.leftEnd, height: 1.0)
                state.path = []
            } else {
                state.guidance = .walk(side: .left, remaining: -Self.leftEnd - reachedLeft)
                state.target = DemoScene.wall.world(s: max(-reachedLeft - 0.9, Self.leftEnd), height: 0.2, out: 0.3)
                state.path = DemoScene.path(toward: max(-reachedLeft - 1.2, Self.leftEnd))
            }
        } else {
            state.guidance = .walkComplete
            state.target = nil
            state.path = []
        }
    }

    private func capture(_ kind: CaptureEvent.Kind, thumbnail: CGImage? = nil) {
        state.captureCount += 1
        state.lastCapture = CaptureEvent(id: nextCaptureID, kind: kind, thumbnail: thumbnail)
        nextCaptureID += 1
    }

    // MARK: ScanActions

    func finishOnboarding() {
        enterFindMeter()
    }

    func markMeter(at point: CGPoint?, viewSize: CGSize) {
        // Taps near the top of the screen land on the eave, not the wall: ask to step closer,
        // the way the real engine refuses a tap with no vertical surface under it.
        if let point, point.y < viewSize.height * 0.18 {
            state.guidance = .aimAtWallForMeter
            return
        }
        capture(.closeUp)
        enterCloseUp()
    }

    func skipCloseUp() {
        state.closeUp = .skipped
        enterWalk()
    }

    func markWallEnd(at point: CGPoint?, viewSize: CGSize) {
        guard case .markEnd(let side) = state.guidance else { return }
        if side == .right {
            state.wall?.rightEnd = Self.rightEnd
        } else {
            state.wall?.leftEnd = Self.leftEnd
        }
        state.endQuestion = side
        refreshCoverage()
        refreshGuidance()
    }

    func answerWallEnd(turnsCorner: Bool) {
        state.endQuestion = nil
        refreshGuidance()
    }

    func beginMarking(_ kind: FeatureKind) {
        if state.phase == .markFeatures {
            returnToReview = true
            state.phase = .wallWalk
        }
        state.marking = MarkingState(kind: kind, step: 0, refusal: nil)
    }

    func markFeaturePoint(at point: CGPoint?, viewSize: CGSize) {
        guard var marking = state.marking else { return }
        if marking.step + 1 < marking.kind.tapCount {
            marking.step += 1
            marking.refusal = nil
            state.marking = marking
            return
        }
        state.features.append(Self.demoFeature(marking.kind))
        state.marking = nil
        if returnToReview {
            returnToReview = false
            state.phase = .markFeatures
        }
    }

    func cancelMarking() {
        state.marking = nil
        if returnToReview {
            returnToReview = false
            state.phase = .markFeatures
        }
    }

    func deleteFeature(_ id: UUID) {
        state.features.removeAll { $0.id == id }
    }

    func setWindowOpens(_ id: UUID, opens: Bool) {
        guard let index = state.features.firstIndex(where: { $0.id == id }) else { return }
        state.features[index].opens = opens
    }

    func finishWalk() {
        guard state.wall?.leftEnd != nil, state.wall?.rightEnd != nil else { return }
        script?.cancel()
        state.phase = .markFeatures
    }

    func confirmFeatures() {
        enterGap()
    }

    func skipGap() {
        if let gap = state.gap { setGround(gap.span, to: .skipped) }
        enterUpload()
    }

    func cannotAccessArea() {
        guard case .walk(let side, _) = state.guidance else { return }
        if side == .right {
            skippedSpan = (reachedRight + 0.1)...Self.rightEnd
            reachedRight = Self.rightEnd
        } else {
            skippedSpan = Self.leftEnd...(-reachedLeft - 0.1)
            reachedLeft = -Self.leftEnd
        }
        refreshCoverage()
        refreshGuidance()
    }

    func retryUpload() {
        enterUpload()
    }

    func captureMissing(_ id: String) {
        state.result = nil
        enterGap()
    }

    func showAR() {
        state.phase = .resultAR
    }

    func closeAR() {
        state.phase = .result
    }

    func startOver() {
        script?.cancel()
        state.phase = .onboarding
        state.features = []
        state.wall = nil
        state.coverage = .empty
        state.result = nil
        state.gap = nil
        state.captureCount = 0
        state.lastCapture = nil
        state.closeUpFailedAttempts = 0
        state.upload = .idle
        state.marking = nil
        reachedLeft = 0.3
        reachedRight = 0.3
        skippedSpan = nil
    }

    func liveCameraView() -> AnyView {
        AnyView(Color.black)
    }

    // MARK: Sample data

    private static func coaching(_ raw: String) -> Coaching? {
        switch raw {
        case "initializing": .initializing
        case "slowDown": .slowDown
        case "needsTexture": .needsTexture
        case "tooDark": .tooDark
        case "holdSteady": .holdSteady
        case "relocalizing": .relocalizing
        case "trackingLost": .trackingLost
        default: nil
        }
    }

    static func demoFeature(_ kind: FeatureKind) -> MarkedFeature {
        let wall = DemoScene.wall
        switch kind {
        case .gasMeter:
            return MarkedFeature(id: UUID(), kind: kind, span: DemoScene.gasMeterSpan, bottom: 0.35, top: 0.72, out: 0.15,
                                 points: [wall.world(s: -1.4, height: 0.55, out: 0.15)], opens: nil)
        case .window:
            return MarkedFeature(id: UUID(), kind: kind, span: DemoScene.windowSpan, bottom: DemoScene.windowHeights.lowerBound,
                                 top: DemoScene.windowHeights.upperBound, out: nil,
                                 points: [wall.world(s: 2.2, height: 0.95), wall.world(s: 3.0, height: 2.15)], opens: nil)
        case .door:
            return MarkedFeature(id: UUID(), kind: kind, span: -2.6 ... -1.8, bottom: 0, top: 2.03, out: nil,
                                 points: [wall.world(s: -2.6, height: 0), wall.world(s: -1.8, height: 2.03)], opens: nil)
        case .acUnit:
            return MarkedFeature(id: UUID(), kind: kind, span: DemoScene.acSpan, bottom: 0, top: 0.8, out: 0.25,
                                 points: [wall.world(s: 3.75, height: 0.8, out: 0.6)], opens: nil)
        case .driveway:
            return MarkedFeature(id: UUID(), kind: kind, span: -1.0...1.0, bottom: nil, top: nil, out: 2.4,
                                 points: [wall.world(s: -1.0, height: 0, out: 2.4), wall.world(s: 1.0, height: 0, out: 2.4)], opens: nil)
        case .fence:
            return MarkedFeature(id: UUID(), kind: kind, span: -2.0...2.0, bottom: 0, top: 1.2, out: 3.0,
                                 points: [wall.world(s: -2.0, height: 0, out: 3.0), wall.world(s: 2.0, height: 0, out: 3.0)], opens: nil)
        }
    }

    /// The offline sample result. Placeholder rules, so the decision is manual review.
    static let reviewSample = ResultPresentation(
        decision: .manualReview,
        summary: "A spot 3 ft right of your meter fits, but it's close to a window, so an installer will confirm it.",
        policyApproved: false,
        spot: BatterySpot(span: 0.55...1.34, depth: 0.56, height: 1.1, offsetFromWall: 0.03),
        cableRoute: [SIMD2(0.16, 1.45), SIMD2(0.95, 1.45), SIMD2(0.95, 1.1)],
        cableLength: 1.14,
        checks: [
            CheckRow(id: "wall", title: "Wall behind the spot", outcome: .pass,
                     reason: "Flat, solid wall behind the whole spot."),
            CheckRow(id: "gas", title: "Distance from the gas meter", outcome: .pass,
                     reason: "The gas meter is well to the left of the spot."),
            CheckRow(id: "window", title: "Distance from the window", outcome: .unsure,
                     reason: "The window is close to the spot's right edge.",
                     needsPerson: true, measured: 0.86, threshold: 0.91, plusMinus: 0.1),
            CheckRow(id: "ground", title: "Ground under the spot", outcome: .unsure,
                     reason: "Part of the ground was only seen from one place.", needsPerson: false),
            CheckRow(id: "ac", title: "Distance from the AC unit", outcome: .pass,
                     reason: "The AC unit is far enough to the right."),
        ],
        clearances: [
            ClearanceZone(id: "meter", label: "In front of the meter", outcome: .pass, span: -0.38...0.38, depth: 0.9),
            ClearanceZone(id: "window", label: "Window", outcome: .unsure, span: 1.3...2.2, depth: 0.9),
        ],
        missing: [
            MissingEvidence(id: "ground-right", text: "A second look at the ground just right of the spot.", capturable: true),
            MissingEvidence(id: "window-opens", text: "Whether the window next to the spot opens.", capturable: false),
        ],
        isSample: true
    )

    static let passSample: ResultPresentation = {
        var sample = reviewSample
        sample.decision = .pass
        sample.policyApproved = true
        sample.summary = "The spot fits every check we could measure."
        sample.checks = sample.checks.map { row in
            var row = row
            row.outcome = .pass
            return row
        }
        sample.missing = []
        sample.clearances = sample.clearances.map { zone in
            var zone = zone
            zone.outcome = .pass
            return zone
        }
        return sample
    }()
}
