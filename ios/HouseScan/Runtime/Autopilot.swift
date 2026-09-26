import CoreGraphics
import Foundation
import HouseScanKit
import OSLog
import simd

/// Drives the intents through the whole flow on a replay, for UI tests and demos (`-autopilot`).
///
/// It calls the same `ScanActions` a homeowner's taps call. Taps are simulated at view points
/// computed by projecting chosen wall points through the shown replay frame, so the engine
/// computes the geometry exactly as it does for a finger. Each state is held for about a second
/// so screenshots show it.
@MainActor
final class Autopilot {
    private let engine: ScanEngine
    /// A portrait iPhone screen in points. Any size works: view points and the engine's mapping
    /// back to pixels use the same size.
    private let viewSize = CGSize(width: 393, height: 852)
    private var hold: Double { engine.options.autopilotHold }

    init(engine: ScanEngine) {
        self.engine = engine
    }

    func run() async {
        guard let replay = engine.replay else {
            log("needs -replay; the live camera can't be driven")
            return
        }
        async let prepared: Void = replay.prepareHeldBack()
        await pause(hold)
        engine.finishOnboarding()
        await prepared
        if let window = replay.heldBack {
            log("holding back frames \(window.frames.lowerBound)..<\(window.frames.upperBound) for the gap loop; gap \(window.gap.band.rawValue) \(format(window.gap.span))")
        } else {
            log("no frames can be held back to make a closable gap on this replay; the gap step will be skipped")
        }
        await pause(hold)

        engine.markMeter(at: nil, viewSize: viewSize)
        guard await waitFor(.meterCloseUp, timeout: 5) else { return fail("meter was not marked") }
        if await !waitUntil(timeout: 4, { if case .captured = self.engine.state.closeUp { return true }; return false }) {
            log("close-up did not fire on this replay; skipping it as a homeowner would")
            engine.skipCloseUp()
        }
        guard await waitFor(.wallWalk, timeout: 5) else { return fail("walk did not start") }

        await pause(0.5)
        guard await waitUntil(timeout: 120, { !replay.isPlaying }) else { return fail("walk replay did not finish") }
        await pause(1.0)

        await markFeatures(replay)
        await markEnds(replay)
        await pause(1.0)
        engine.finishWalk()
        guard await waitFor(.markFeatures, timeout: 5) else { return fail("could not finish the walk (ends marked: \(engine.bothEndsMarked))") }
        await pause(hold)

        engine.confirmFeatures()
        await pause(0.3)
        if engine.state.phase == .gapRequest {
            if replay.heldBack == nil {
                await pause(hold)
                log("skipping the gap: no held-back frames to show it")
                engine.skipGap()
            } else if await !waitFor(.uploading, timeout: 30) {
                log("gap not satisfied by the held-back frames within 30 s; skipping it")
                engine.skipGap()
            }
        }
        guard await waitFor(.uploading, timeout: 5) else { return fail("upload did not start") }
        if await !waitFor(.result, timeout: 90) {
            if case .failed = engine.state.upload {
                log("upload failed; retrying once")
                engine.retryUpload()
                guard await waitFor(.result, timeout: 90) else { return fail("no result after retry") }
            } else {
                return fail("no result")
            }
        }
        await pause(hold)
        engine.showAR()
        guard await waitFor(.resultAR, timeout: 5) else { return fail("AR result did not open") }
        await pause(hold)
        engine.closeAR()
        _ = await waitFor(.result, timeout: 5)
        log("done")
    }

    // MARK: Steps

    /// A gas meter (one tap) and a window (two diagonal corners) on covered wall. The synthetic
    /// fixture paints them at s = -1.2 m and s = 2.0...3.0 m; on other replays the nearest covered
    /// wall stands in for them.
    private func markFeatures(_ replay: ReplayPlayer) async {
        guard let map = engine.coverage else { return }
        let covered = map.coveredIntervals(.wall)
        guard !covered.isEmpty else {
            log("no covered wall to mark features on")
            return
        }
        let gasS = nearestCovered(-1.2, in: covered)
        engine.beginMarking(.gasMeter)
        await tap(map.wall.world(s: gasS, height: 0.55), replay: replay) { point in
            self.engine.markFeaturePoint(at: point, viewSize: self.viewSize)
        }
        await pause(0.8)

        let windowS = nearestCovered(2.5, in: covered)
        engine.beginMarking(.window)
        // Near the corners of the fixture's window (0.9 to 2.0 m high), kept inside the band a
        // walking camera sees so a frame shows each tap.
        for corner in [map.wall.world(s: windowS - 0.45, height: 1.85), map.wall.world(s: windowS + 0.45, height: 0.95)] {
            let tapped = await tap(corner, replay: replay) { point in
                self.engine.markFeaturePoint(at: point, viewSize: self.viewSize)
            }
            if !tapped { log("no replay frame shows a window corner") }
            await pause(0.4)
        }
        if engine.state.marking != nil {
            log("window marking incomplete (\(String(describing: self.engine.state.marking?.refusal))); cancelling it")
            engine.cancelMarking()
        }
        if let window = engine.state.features.first(where: { $0.kind == .window }) {
            engine.setWindowOpens(window.id, opens: true)
        }
        log("marked \(engine.state.features.count) features")
    }

    /// Ends at the covered extremes (the held-back window's plan, or the walk's coverage).
    private func markEnds(_ replay: ReplayPlayer) async {
        guard let map = engine.coverage else { return }
        let intervals = map.coveredIntervals(.wall) + map.coveredIntervals(.ground)
        guard let low = intervals.map(\.lowerBound).min(), let high = intervals.map(\.upperBound).max() else {
            log("nothing covered; marking ends 1 m either side of the meter")
            engine.setEnd(.left, at: -1, kind: .limit)
            engine.setEnd(.right, at: 1, kind: .limit)
            return
        }
        for (side, s) in [(WallSide.left, min(low, -0.2)), (.right, max(high, 0.2))] {
            let point = map.wall.world(s: s, height: 0.5)
            let tapped = await tap(point, replay: replay) { viewPoint in
                self.engine.markWallEnd(at: viewPoint, viewSize: self.viewSize)
            }
            let marked = side == .left ? engine.coverage?.leftEnd : engine.coverage?.rightEnd
            if !tapped || marked == nil {
                log("no replay frame shows the \(side.rawValue) end; setting it directly at s=\(s)")
                engine.setEnd(side, at: s, kind: .limit)
            }
            await pause(0.6)
        }
    }

    // MARK: Helpers

    /// Shows the replay frame that best shows `point`, then taps where it appears on screen.
    @discardableResult
    private func tap(_ point: SIMD3<Float>, replay: ReplayPlayer, action: (CGPoint) -> Void) async -> Bool {
        guard let (index, viewPoint) = frameShowing(point, replay: replay) else { return false }
        replay.show(index: index)
        await replay.waitUntilShown(index)
        await pause(0.2)
        action(viewPoint)
        return true
    }

    private func frameShowing(_ point: SIMD3<Float>, replay: ReplayPlayer) -> (Int, CGPoint)? {
        let inset: CGFloat = 40
        var best: (Int, CGPoint, CGFloat)?
        for index in replay.frames.indices {
            let camera = replay.camera(at: index)
            let projection = CameraProjection(cameraToWorld: camera.cameraToWorld, intrinsics: camera.intrinsics, imageSize: camera.imageSize)
            guard let view = projection.viewPoint(for: point, in: viewSize),
                  view.x > inset, view.y > inset, view.x < viewSize.width - inset, view.y < viewSize.height - inset else { continue }
            let offCenter = hypot(view.x - viewSize.width / 2, view.y - viewSize.height / 2)
            if offCenter < best?.2 ?? .infinity { best = (index, view, offCenter) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func nearestCovered(_ s: Float, in intervals: [ClosedRange<Float>]) -> Float {
        if intervals.contains(where: { $0.contains(s) }) { return s }
        let candidates = intervals.map { interval -> Float in
            let inset = min(0.5, (interval.upperBound - interval.lowerBound) / 2)
            return min(max(s, interval.lowerBound + inset), interval.upperBound - inset)
        }
        return candidates.min { abs($0 - s) < abs($1 - s) } ?? s
    }

    private func waitFor(_ phase: ScanPhase, timeout: Double) async -> Bool {
        await waitUntil(timeout: timeout) { self.engine.state.phase == phase }
    }

    private func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func log(_ message: String) {
        RuntimeLog.autopilot.info("AUTOPILOT \(message, privacy: .public)")
    }

    private func fail(_ message: String) {
        RuntimeLog.autopilot.error("AUTOPILOT stopped: \(message, privacy: .public) (phase \(self.engine.state.phase.rawValue, privacy: .public))")
    }

    private func format(_ range: ClosedRange<Float>) -> String {
        String(format: "%.2f...%.2f m", range.lowerBound, range.upperBound)
    }
}
