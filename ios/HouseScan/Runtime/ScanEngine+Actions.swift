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
            guard setWall(meter: wall.meter, outward: wall.outward, groundY: wall.groundY, groundMeasured: replay.groundMeasured) else { return }
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
        meterPlaneSource = hit.source
        var outward = SIMD3(hit.normal.x, 0, hit.normal.z)
        if simd_dot(outward, frame.camera.position - hit.position) < 0 { outward = -outward }
        // Until a horizontal plane shows up below the wall, the ground is a guess: a phone held at
        // chest height, 1.4 m above it. `refineGround` replaces the guess as planes arrive.
        let measured = groundBelow(hit.position)
        guard setWall(meter: hit.position, outward: outward, groundY: measured ?? frame.camera.position.y - 1.4, groundMeasured: measured != nil) else {
            state.guidance = .aimAtWallForMeter
            return
        }
        setMeterAnchor(live.addMeterAnchor(at: hit.transform))
        go(.meterCloseUp)
    }

    /// The ground at the meter: the highest detected horizontal plane at least 0.3 m below it whose
    /// extent comes within 2 m of it (so a porch or a neighbour's lawn elsewhere doesn't count), or
    /// nil when no such plane has been detected.
    func groundBelow(_ meter: SIMD3<Float>) -> Float? {
        let near = detectedGroundPlanes.filter { plane in
            let horizontal = simd_distance(SIMD2(plane.x, plane.z), SIMD2(meter.x, meter.z))
            return plane.y < meter.y - 0.3 && horizontal - plane.w <= 2
        }
        return near.map(\.y).max()
    }

    func skipCloseUp() {
        guard state.phase == .meterCloseUp else { return }
        state.closeUp = .skipped
        state.meterNumber = .skipped
        RuntimeLog.engine.info("close-up skipped after \(self.state.closeUpFailedAttempts) failed attempts")
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
        RuntimeLog.engine.info("meter number confirmed (\(chosen.barcodeConfirmed ? "barcode-confirmed" : "text only", privacy: .public))")
        finishCloseUp()
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
        if state.phase == .gapRequest, side == pastEndSide { settlePastEnd() }
        if state.phase == .wallWalk, let frame = currentFrame {
            resetGuidanceAfterSkip(camera: frame.camera, time: frame.timestamp)
        }
    }

    /// "Open sky or nothing overhead" records the tilt-up view for the export; "A roof edge,
    /// porch or stairs" records nothing, so the server treats the stretch as unseen. During an
    /// overhead gap request the answer settles the request either way (`settleOverheadGap`).
    func answerOverhead(clear: Bool) {
        guard state.overheadQuestion else { return }
        switch state.phase {
        case .wallWalk:
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
        state.features.append(feature(marking.kind, taps: pendingTaps, wall: wall))
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
        state.marking = nil
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
            guard let map = coverage else { return }
            let task = ScanEngine.name(state.guidance)
            switch state.guidance {
            case .aimAtGround(let s):
                updateCoverage { $0.markSkipped(.ground, (s - 0.5)...(s + 0.5)) }
            case .aimAtWall(let s):
                updateCoverage { $0.markSkipped(.wall, (s - 0.5)...(s + 0.5)) }
            case .walk(let side, _), .markEnd(let side):
                // The walk can't continue this way: stop the wall here, as an unexplored end.
                let reach = GuidancePlanner().reach(side == .left ? .left : .right, coverage: map)
                let s = side == .left ? -reach : reach
                setEnd(side, at: s, kind: .unexplored)
            case .tiltUp:
                settleTiltUp(clear: false)
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
        guard state.phase == .result || state.phase == .gapRequest || state.phase == .uploading,
              let missing = placement?.missingEvidence,
              let index = Int(id.replacingOccurrences(of: "missing-", with: "")),
              missing.indices.contains(index) else { return }
        let item = missing[index]
        guard let map = coverage, let plan = gapPlanner.plan(for: item, leftEnd: map.leftEnd, rightEnd: map.rightEnd) else { return }
        var pastEnd: WallSide?
        if item.kind == .pastEnd, let side = item.side {
            // The walk has to go past the end it stopped at; that end is no longer a limit. It
            // exports as unexplored unless the homeowner marks it again (markWallEnd).
            pastEnd = side == .left ? .left : .right
            clearEnd(side == .left ? .left : .right)
        }
        beginGap(plan, origin: .server, reason: .server(detail: item.message))
        pastEndSide = pastEnd
    }

    func showAR() {
        guard state.phase == .result else { return }
        go(.resultAR)
    }

    func closeAR() {
        guard state.phase == .resultAR else { return }
        go(.result)
    }

    func startOver() {
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
        return wall.intersectWall(frame.camera.ray(throughPixel: pixel))
    }
}
