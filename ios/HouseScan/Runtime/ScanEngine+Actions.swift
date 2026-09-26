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
            guard setWall(meter: wall.meter, outward: wall.outward, groundY: wall.groundY) else { return }
            go(.meterCloseUp)
            return
        }
        guard let live = liveCapture, let frame = currentFrame else { return }
        guard frame.tracking == .normal else {
            state.guidance = .aimAtWallForMeter
            return
        }
        let viewPoint = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        // Only real, detected vertical plane geometry sets the anchor (checklist I8): an
        // estimated plane would guess the depth.
        guard let hit = live.raycastExistingVerticalPlane(from: viewPoint) else {
            state.guidance = .aimAtWallForMeter
            RuntimeLog.engine.info("meter tap refused: no vertical plane")
            return
        }
        var outward = SIMD3(hit.normal.x, 0, hit.normal.z)
        if simd_dot(outward, frame.camera.position - hit.position) < 0 { outward = -outward }
        let groundY = groundBelow(hit.position.y, camera: frame.camera)
        guard setWall(meter: hit.position, outward: outward, groundY: groundY) else {
            state.guidance = .aimAtWallForMeter
            return
        }
        setMeterAnchor(live.addMeterAnchor(at: hit.transform))
        go(.meterCloseUp)
    }

    /// The detected ground plane below a height, or the camera height minus 1.4 m (a phone held
    /// at chest height) until one appears.
    private func groundBelow(_ y: Float, camera: CameraFrame) -> Float {
        if let plane = detectedGroundY, plane < y - 0.3 { return plane }
        return camera.position.y - 1.4
    }

    func skipCloseUp() {
        guard state.phase == .meterCloseUp else { return }
        state.closeUp = .skipped
        RuntimeLog.engine.info("close-up skipped after \(self.state.closeUpFailedAttempts) failed attempts")
        go(.wallWalk)
    }

    func markWallEnd(at point: CGPoint?, viewSize: CGSize) {
        guard state.phase == .wallWalk, let wall = coverage?.wall, let frame = currentFrame else { return }
        guard let hit = wallHit(point, viewSize: viewSize, frame: frame, wall: wall) else { return }
        setEnd(hit.s < 0 ? .left : .right, at: hit.s, kind: .limit)
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
        let points = taps.map { wall.world($0) }
        let ss = taps.map(\.s)
        let span = (ss.min() ?? 0)...(ss.max() ?? 0)
        switch kind {
        case .door, .window:
            let heights = taps.map(\.height)
            return MarkedFeature(id: UUID(), kind: kind, span: span, bottom: max(0, heights.min() ?? 0), top: heights.max(), out: nil, points: points, opens: nil)
        case .gasMeter, .acUnit:
            // One tap marks the object's middle; 0.3 m is a nominal width, not a measurement.
            let s = ss.first ?? 0
            return MarkedFeature(id: UUID(), kind: kind, span: (s - 0.15)...(s + 0.15), bottom: nil, top: nil, out: nil, points: points, opens: nil)
        case .driveway, .fence:
            let out = taps.map(\.out).reduce(0, +) / Float(max(1, taps.count))
            return MarkedFeature(id: UUID(), kind: kind, span: span, bottom: nil, top: nil, out: out, points: points, opens: nil)
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
            default:
                return
            }
            RuntimeLog.engine.info("cannot access area during \(ScanEngine.name(self.state.guidance), privacy: .public)")
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

    func captureMissing(_ id: String) {
        guard state.phase == .result || state.phase == .gapRequest || state.phase == .uploading,
              let missing = placement?.missingEvidence,
              let index = Int(id.replacingOccurrences(of: "missing-", with: "")),
              missing.indices.contains(index) else { return }
        let item = missing[index]
        let feetToMeters = Float(0.3048)
        switch item.kind {
        case .band:
            guard let span = item.spanFt else { return }
            let band: SurfaceBand = item.band == .ground ? .ground : .wall
            let plan = GapPlan(band: band, span: Float(span.x) * feetToMeters...Float(span.y) * feetToMeters, reason: .server)
            beginGap(plan, origin: .server, reason: .server(detail: item.message))
        case .pastEnd:
            guard let side = item.side, let map = coverage else { return }
            let end = side == .left ? (map.leftEnd ?? 0) : (map.rightEnd ?? 0)
            let beyond: ClosedRange<Float> = side == .left ? (end - 2)...end : end...(end + 2)
            let plan = GapPlan(band: .ground, span: beyond, reason: .server)
            beginGap(plan, origin: .server, reason: .server(detail: item.message))
        }
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
