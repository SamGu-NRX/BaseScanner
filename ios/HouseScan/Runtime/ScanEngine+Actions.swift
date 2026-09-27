import CoreGraphics
import Foundation
import HouseScanKit
import OSLog
import simd
import SwiftUI

extension ScanEngine: ScanActions {
    func finishOnboarding() {
        guard state.phase == .onboarding else { return }
        go(.findMeter)
    }

    func markMeter(at point: CGPoint?, viewSize: CGSize) {
        guard state.phase == .findMeter else { return }
        if let replay {
            // A replay has no live surfaces to raycast; its wall comes from the recording (or is
            // assumed from the trajectory, see ReplayPlayer.wallDescription).
            let wall = replay.wall
            meterTapCamera = nil
            guard setWall(meter: wall.meter, outward: wall.outward, groundY: wall.groundY, groundMeasured: replay.groundMeasured) else { return }
            markTimes[MarkKey.meter] = captureClock
            go(.meterCloseUp)
            return
        }
        guard let live = liveCapture, let frame = currentFrame else { return }
        guard frame.tracking == .normal else {
            state.guidance = .aimAtWallForMeter
            return
        }
        let viewPoint = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        // A detected vertical plane's own geometry first; failing that, ARKit's estimated vertical
        // plane, whose wider error the export records. Never an infinite plane, which extends a
        // fence or another wall past its edges.
        guard let hit = live.raycastVerticalPlane(from: viewPoint) else {
            state.guidance = .aimAtWallForMeter
            RuntimeLog.engine.info("meter tap refused: no vertical plane")
            return
        }
        // An estimated plane can put the wall far from the real one (#69): one out of reach,
        // turned from the phone, or behind a detected plane is refused, and the homeowner is asked
        // to let ARKit find the wall first.
        if let refusal = MeterTap.refusal(
            hit: hit.position, normal: hit.normal, source: hit.source, camera: frame.camera, planes: detectedWallPlanes
        ) {
            state.guidance = .aimAtWallForMeter
            RuntimeLog.engine.info("meter tap refused: \(refusal.description, privacy: .public)")
            return
        }
        meterPlaneSource = hit.source
        meterTapCamera = frame.camera.position
        var outward = SIMD3(hit.normal.x, 0, hit.normal.z)
        if simd_dot(outward, frame.camera.position - hit.position) < 0 { outward = -outward }
        // Until a horizontal plane shows up below the wall, the ground is a guess: a phone held at
        // chest height, 1.4 m above it. `SpatialUpdate` replaces the guess as planes arrive.
        let ground = groundBelow(hit.position, along: simd_normalize(simd_cross(-outward, SIMD3(0, 1, 0))), current: nil)
        guard setWall(meter: hit.position, outward: outward, groundY: ground?.plane.y ?? frame.camera.position.y - 1.4, groundMeasured: ground != nil) else {
            state.guidance = .aimAtWallForMeter
            return
        }
        let groundNote = ground.map(Self.describe) ?? "a guess"
        RuntimeLog.engine.info("meter marked on \(hit.source == .estimatedPlane ? "an estimated" : "a detected", privacy: .public) plane; ground from \(groundNote, privacy: .public)")
        // The map carries the line's source: the export writes it and the walked clearance
        // takes the server's error for it.
        updateCoverage { $0.setWallLineSource(meterLineSource) }
        setMeterAnchor(live.addMeterAnchor(at: hit.transform), pose: hit.transform)
        markTimes[MarkKey.meter] = captureClock
        go(.meterCloseUp)
        // A wall plane ARKit already knows may disagree with an estimated hit; waiting for the
        // planes to change would leave the close-up, and maybe the walk, on the estimated wall.
        refitWallToDetectedPlane()
    }

    /// The ground at the wall of the meter at `meter`, running along `along`: a detected plane
    /// the meter is a plausible height above, that reaches the wall's foot by the meter and isn't
    /// furniture, floor-classified first, then the one under where the phone stood to mark the
    /// meter, then the lowest (`GroundPlaneChoice`). With `current`, the ground already measured,
    /// it is never raised more than `GroundPlaneChoice.maximumRaise`. Nil when no plane qualifies;
    /// the ground stays as it is.
    func groundBelow(_ meter: SIMD3<Float>, along: SIMD3<Float>, current: Float?) -> GroundPlaneChoice.Choice? {
        GroundPlaneChoice.choose(meter: meter, along: along, phone: meterTapCamera, current: current, planes: detectedGroundPlanes)
    }

    func skipCloseUp() {
        guard state.phase == .meterCloseUp else { return }
        state.closeUp = .skipped
        state.meterNumber = .skipped
        RuntimeLog.engine.info("close-up skipped after \(self.state.closeUpFailedAttempts) failed attempts")
        observeCloseUpView()
        go(.wallWalk)
    }

    /// The homeowner's pick of the meter number. The number stays on the phone, in
    /// `state.meterNumber`: scene.json has no field for it and its schema allows no extra
    /// properties, so the server never receives it.
    func chooseMeterNumber(_ candidate: MeterNumberCandidate?) {
        guard state.phase == .meterCloseUp, case .choose(let candidates) = state.meterNumber else { return }
        guard let candidate else {
            // "None of these": small characters mean the phone was too far for a clear read.
            retakeCloseUp(currentMeterReadout?.numberTooSmall == true ? .numberTooSmall : .noNumber)
            return
        }
        guard let chosen = candidates.first(where: { $0.id == candidate.id }) else { return }
        state.meterNumber = .confirmed(chosen.text)
        RuntimeLog.engine.info("meter number confirmed (\(chosen.barcodeConfirmed ? "barcode-confirmed" : "text only", privacy: .public)), brand \(self.state.meterBrand == nil ? "none" : "kept", privacy: .public)")
        observeCloseUpView()
        finishCloseUp()
    }

    func rejectMeterBrand() {
        guard state.phase == .meterCloseUp, case .choose = state.meterNumber else { return }
        state.meterBrand = nil
        RuntimeLog.engine.info("meter brand rejected")
    }

    /// Puts the close-up photo's view into coverage, under the same rules as a walk keyframe: a
    /// cell counts once seen from two positions at least 0.25 m apart, and the view is replayed
    /// with the kept keyframes whenever the wall moves (`CoverageMap.observedCameras`).
    ///
    /// Only when the close-up step ends (number confirmed, or skipped), because the photo on disk
    /// is final then, and only the view `closeUpCredit` holds: the shot whose photo is on disk,
    /// after the reader found it decodable and in focus. A skip after a photo the reader
    /// rejected as blurry, or while a retake's photo is still saving or being read, adds nothing.
    /// A photo in focus where only the number couldn't be read still counts. The map always
    /// exists here: the close-up follows the meter mark, which sets the wall (`setWall`). No time
    /// is passed, so the pose never joins the walked path: nothing is kept between the close-up
    /// and the walk's first frame.
    private func observeCloseUpView() {
        guard let view = closeUpCredit.take() else { return }
        // Corrected for anchor moves made while the photo was saved and read.
        let camera = view.time.map { correctedPose(view.camera.cameraToWorld, capturedAt: $0) }
            .map { CameraFrame(cameraToWorld: $0, intrinsics: view.camera.intrinsics, imageSize: view.camera.imageSize) } ?? view.camera
        var delta: CoverageMap.Delta?
        updateCoverage { delta = $0.observe(camera, trackingNormal: true, depth: view.depth) }
        RuntimeLog.capture.info("close-up view in coverage: \(delta?.newlySeen ?? 0) cells newly seen, \(delta?.newlyCovered ?? 0) newly covered")
    }

    /// Marks a wall end during the walk, or, during a server past_end request, marks that
    /// request's end again at wherever the wall is now seen to stop.
    func markWallEnd(at point: CGPoint?, viewSize: CGSize) {
        guard state.phase == .wallWalk || (state.phase == .gapRequest && pastEndSide != nil),
              let wall = coverage?.wall, let frame = currentFrame else { return }
        guard let hit = wallHit(point, viewSize: viewSize, frame: frame, wall: wall) else { return }
        let side: WallSide = hit.s < 0 ? .left : .right
        if state.phase == .gapRequest, side != pastEndSide { return }
        // Unexplored until the homeowner says something blocks the wall there: an unanswered
        // question must not tell the server the usable wall stops at this point.
        state.endQuestion = side
        setEnd(side, at: hit.s, kind: .unexplored)
    }

    func answerWallEnd(turnsCorner: Bool) {
        guard let side = state.endQuestion else { return }
        state.endQuestion = nil
        if wallEndKinds[side] != nil { setEndKind(side, turnsCorner ? .unexplored : .limit) }
        // During the walk a corner is followed: the next wall is marked, and the walk goes on
        // along it. Until then the end stays marked, as an unexplored corner.
        if turnsCorner, state.phase == .wallWalk, wallEndKinds[side] != nil {
            nextWallSide = side
            nextWallRefusal = nil
        }
        if state.phase == .gapRequest, side == pastEndSide { settlePastEnd() }
        if state.phase == .wallWalk, let frame = currentFrame {
            resetGuidanceAfterSkip(camera: frame.camera, time: frame.timestamp)
        }
    }

    /// The wall round the corner: a raycast on a vertical plane under `point`, the same one the
    /// meter tap uses. Where its line meets the current wall's line on the ground is the corner;
    /// the wall chain turns there, the end on that side opens again and the walk goes on.
    func markNextWall(at point: CGPoint?, viewSize: CGSize) {
        guard state.phase == .wallWalk, let side = nextWallSide, coverage != nil, let frame = currentFrame else { return }
        func refuse(_ refusal: NextWallRefusal, _ reason: String) {
            nextWallRefusal = refusal
            state.guidance = .markNextWall(side: side, refusal: refusal)
            RuntimeLog.engine.info("next wall refused: \(reason, privacy: .public)")
        }
        guard frame.tracking == .normal else { return refuse(.trackingNotReady, "tracking not normal") }
        // A replay has no live surfaces to raycast, so it can't mark the next wall.
        let viewPoint = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        guard let hit = liveCapture?.raycastVerticalPlane(from: viewPoint) else { return refuse(.noSurface, "no vertical plane") }
        var outward = SIMD3(hit.normal.x, 0, hit.normal.z)
        if simd_dot(outward, frame.camera.position - hit.position) < 0 { outward = -outward }
        var turned: Result<WallCorner, CornerRefusal> = .failure(.notAWall)
        // The new piece's line runs through the hit point facing the hit plane's normal, as the
        // meter's does, so its source follows the same rule (`meterLineSource`).
        let source = Self.lineSource(of: hit.source)
        updateCoverage { map in
            turned = Result { () throws(CornerRefusal) in
                try map.turnCorner(side == .left ? .left : .right, meeting: hit.position, outward: outward, source: source)
            }
        }
        let corner: WallCorner
        switch turned {
        case .success(let turn): corner = turn
        case .failure(.nearlyParallel): return refuse(.sameWall, "nearly parallel to the current wall")
        case .failure(.notAWall): return refuse(.noSurface, "not a wall")
        case .failure(.implausible(let s)): return refuse(.notAtCorner, "the walls meet at s=\(s)")
        }
        // The end moves on with the walk; `clearEnd` also publishes the chain for the overlays.
        clearEnd(side)
        nextWallSide = nil
        nextWallRefusal = nil
        RuntimeLog.engine.info("corner followed on the \(side.rawValue, privacy: .public) at s=\(corner.s) (\(hit.source == .detectedPlane ? "detected" : "estimated", privacy: .public) plane)")
        // Features tapped past the corner were placed on the old wall's line.
        reprojectFeatures()
        resetGuidanceAfterSkip(camera: frame.camera, time: frame.timestamp)
    }

    /// The export sends a type as patches over the ground the coverage saw, and "Not sure" as no
    /// patch (`sceneJSON`). Every upload reads the latest answer.
    func answerGround(_ answer: GroundAnswer) {
        guard state.phase == .markFeatures else { return }
        state.groundAnswer = answer
        RuntimeLog.engine.info("ground answered: \(String(describing: answer), privacy: .public)")
    }

    /// "Open sky or nothing overhead" records the tilt-up view for the export; "A roof edge,
    /// porch or stairs" records nothing, so the server treats the stretch as unseen. During an
    /// overhead gap request the answer settles the request either way (`settleOverheadGap`).
    func answerOverhead(clear: Bool) {
        guard state.overheadQuestion else { return }
        switch state.phase {
        case .wallWalk:
            // Something overhead is an answer, not a view: the stretch goes to review unseen.
            resolveGuidance(clear ? .met : .skipped)
            settleTiltUp(clear: clear)
            if let frame = currentFrame {
                resetGuidanceAfterSkip(camera: frame.camera, time: frame.timestamp)
            }
        case .gapRequest:
            settleOverheadGap(clear: clear)
        default:
            return
        }
    }

    func beginMarking(_ kind: FeatureKind) {
        guard state.phase == .wallWalk || state.phase == .markFeatures else { return }
        // A mark is a tap into the world frame. The review hides "Add something" while the phone
        // has lost its place; this holds if a tap races the change.
        guard state.phase != .markFeatures || !state.tracking.hasLostItsPlace else { return }
        state.marking = MarkingState(kind: kind, step: 0, refusal: nil)
        pendingTaps = []
    }

    func markFeaturePoint(at point: CGPoint?, viewSize: CGSize) {
        guard var marking = state.marking, let wall = coverage?.wall, let frame = currentFrame else { return }
        guard frame.tracking == .normal else {
            marking.refusal = .trackingNotReady
            state.marking = marking
            return
        }
        let onGround = marking.kind == .driveway || marking.kind == .fence
        let pixel = frame.projection.imagePixel(forViewPoint: point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), in: viewSize)
        let ray = frame.camera.ray(throughPixel: pixel)
        if wall.wallPoint(frame.camera.position).out <= 0 {
            marking.refusal = .wrongSide
            state.marking = marking
            return
        }
        let hit = onGround ? wall.intersectGround(ray) : wall.intersectWall(ray)
        guard let hit else {
            marking.refusal = .noSurface
            state.marking = marking
            return
        }
        // Past 8 m out a ground tap is not about this wall any more.
        if onGround, hit.out > 8 || hit.out < 0 {
            marking.refusal = .tooFarFromWall
            state.marking = marking
            return
        }
        pendingTaps.append(hit)
        marking.refusal = nil
        marking.step += 1
        if marking.step < marking.kind.tapCount {
            state.marking = marking
            return
        }
        let marked = feature(marking.kind, taps: pendingTaps, wall: wall)
        markTimes[MarkKey.feature(marked.id)] = captureClock
        state.features.append(marked)
        publishFeaturesPastEnds()
        state.marking = nil
        pendingTaps = []
    }

    private func feature(_ kind: FeatureKind, taps: [WallPoint], wall: WallFrame) -> MarkedFeature {
        var marked = MarkedFeature(id: UUID(), kind: kind, span: 0...0, bottom: nil, top: nil, out: nil, points: taps.map { wall.world($0) }, opens: nil)
        Self.project(&marked, onto: wall)
        return marked
    }

    /// Sets a feature's wall coordinates from its tapped world points. Run again whenever the
    /// wall frame moves (meter anchor refined, ground measured), since only the world points
    /// are what was tapped.
    static func project(_ feature: inout MarkedFeature, onto wall: WallFrame) {
        let taps = feature.points.map { wall.wallPoint($0) }
        let ss = taps.map(\.s)
        let span = (ss.min() ?? 0)...(ss.max() ?? 0)
        switch feature.kind {
        case .door, .window:
            let heights = taps.map(\.height)
            feature.span = span
            feature.bottom = max(0, heights.min() ?? 0)
            feature.top = heights.max()
        case .gasMeter, .acUnit:
            // One tap marks the object's middle; 0.3 m is a nominal width, not a measurement.
            let s = ss.first ?? 0
            feature.span = (s - 0.15)...(s + 0.15)
        case .driveway, .fence:
            feature.span = span
            // The nearer tap, as the export uses: the narrow end must not be overstated.
            feature.out = taps.map(\.out).min() ?? 0
        }
    }

    func cancelMarking() {
        state.marking = nil
        pendingTaps = []
    }

    func deleteFeature(_ id: UUID) {
        state.features.removeAll { $0.id == id }
    }

    func setWindowOpens(_ id: UUID, opens: Bool) {
        guard let index = state.features.firstIndex(where: { $0.id == id }) else { return }
        state.features[index].opens = opens
    }

    func finishWalk() {
        guard state.phase == .wallWalk, bothEndsMarked else { return }
        if let map = coverage, map.endsTooClose, let left = map.leftEnd, let right = map.rightEnd {
            // Ends closer than a battery is wide (`WallFrame.minWallLength`): both sides ended
            // without walking, as "Wall ends here" or "Can't get there" at the meter does.
            // Nothing between them to scan, and an end can't be moved, so both go and the walk
            // goes on; the card says why.
            RuntimeLog.engine.info("finish refused: ends at s=\(left) and s=\(right) are closer than \(WallFrame.minWallLength) m")
            clearEnd(.left)
            clearEnd(.right)
            state.wallTooShort = true
            if let frame = currentFrame { resetGuidanceAfterSkip(camera: frame.camera, time: frame.timestamp) }
            return
        }
        // Done while a request is still up passes it by.
        resolveGuidance(.superseded)
        state.marking = nil
        nextWallSide = nil
        nextWallRefusal = nil
        // Leaving with the overhead question unanswered records nothing.
        if !tiltUpSettled { settleTiltUp(clear: false) }
        go(.markFeatures)
    }

    func confirmFeatures() {
        guard state.phase == .markFeatures else { return }
        runGapCheck()
    }

    func skipGap() {
        guard state.phase == .gapRequest else { return }
        skipCurrentGap()
    }

    func cannotAccessArea() {
        switch state.phase {
        case .gapRequest:
            skipCurrentGap()
        case .wallWalk:
            guard coverage != nil else { return }
            let task = ScanEngine.name(state.guidance)
            switch state.guidance {
            case .aimAtGround, .aimAtWall, .seeBehind, .walk, .markEnd, .tiltUp, .markNextWall:
                resolveGuidance(.cannotReach)
            default:
                return
            }
            switch state.guidance {
            case .aimAtGround(let s):
                updateCoverage { $0.markSkipped(.ground, (s - 0.5)...(s + 0.5)) }
            case .aimAtWall(let s):
                updateCoverage { $0.markSkipped(.wall, (s - 0.5)...(s + 0.5)) }
            case .seeBehind(let s):
                // Whatever is in the way can't be seen past: its hidden cells go to review. Only
                // those: open cells beside them can still be seen and stay asked for.
                updateCoverage { map in
                    for band in seeBehindBands {
                        for index in ScanEngine.hiddenCells(map, band: band, around: s) { map.markSkipped(band, map.cellRange(index)) }
                    }
                }
            case .walk(let side, _), .markEnd(let side):
                // The walk can't continue this way: stop the wall where the phone is, as an
                // unexplored end (`WalkedEnd`), where the strip's preview showed it.
                endWalkCannotGoOn(side)
            case .tiltUp:
                settleTiltUp(clear: false)
            case .markNextWall:
                // Not following the corner: the end stays marked, as an unexplored corner.
                nextWallSide = nil
                nextWallRefusal = nil
            default:
                return
            }
            RuntimeLog.engine.info("cannot access area during \(task, privacy: .public)")
            if let frame = currentFrame {
                resetGuidanceAfterSkip(camera: frame.camera, time: frame.timestamp)
            }
        default:
            return
        }
    }

    func retryUpload() {
        guard state.phase == .uploading else { return }
        if case .failed = state.upload { startUpload() }
    }

    /// Back to the feature review after a rejected upload. The scan (wall, coverage, keyframes,
    /// features) stays; confirming the review runs the gap check and the upload again.
    func backToReview() {
        guard state.phase == .uploading, case .rejected = state.upload else { return }
        state.upload = .idle
        go(.markFeatures)
    }

    func captureMissing(_ id: String) {
        // A stopped camera can't take the view: the answer stays, the request goes to review.
        guard mayCapture, state.phase == .result || state.phase == .gapRequest || state.phase == .uploading,
              let missing = placement?.missingEvidence,
              let index = Int(id.replacingOccurrences(of: "missing-", with: "")),
              missing.indices.contains(index) else { return }
        let item = missing[index]
        guard let map = coverage, let plan = gapPlanner.plan(for: item, leftEnd: map.leftEnd, rightEnd: map.rightEnd, limitEnds: map.limitEnds) else { return }
        beginServerGap(item, plan: plan)
    }

    func showAR() {
        guard state.phase == .result, state.spatialResultAvailable else { return }
        go(.resultAR)
    }

    func closeAR() {
        guard state.phase == .resultAR else { return }
        go(.result)
    }

    func startOver() {
        releaseFailedSource()
        resetAll()
    }

    func liveCameraView() -> AnyView {
        guard let live = liveCapture else { return AnyView(Color.black) }
        return AnyView(LiveCameraView(arView: live.arView))
    }

    // MARK: Helpers

    /// Where a tap lands on the wall plane, in wall coordinates.
    func wallHit(_ point: CGPoint?, viewSize: CGSize, frame: SourceFrame, wall: WallFrame) -> WallPoint? {
        let pixel = frame.projection.imagePixel(forViewPoint: point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), in: viewSize)
        return nearbyWallHit(frame.camera.ray(throughPixel: pixel), camera: frame.camera, wall: wall)
    }

    /// Where `ray` meets the wall, or nil when that is farther along the wall from the camera than
    /// the coverage map lets a camera see (`maxDistance`). A ray nearly parallel to the wall meets
    /// its line hundreds of meters away; an end placed there, or drawn on the strip, would be
    /// nothing the homeowner pointed at.
    func nearbyWallHit(_ ray: Ray, camera: CameraFrame, wall: WallFrame) -> WallPoint? {
        guard let hit = wall.intersectWall(ray) else { return nil }
        let reach = coverage?.config.maxDistance ?? CoverageConfig().maxDistance
        return abs(hit.s - wall.wallPoint(camera.position).s) <= reach ? hit : nil
    }
}
