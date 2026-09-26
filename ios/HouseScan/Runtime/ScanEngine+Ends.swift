import Foundation
import HouseScanKit
import OSLog
import simd

/// Ending the wall during the walk without pointing at the end ("Can't get there", "Wall ends
/// here"), and the preview of where an end would land.
extension ScanEngine {
    /// The side ending the wall applies to now, and whether the end lands at the reticle. The
    /// walk's own side while it asks to walk or to mark the end; during a request about the wall
    /// in front of the homeowner (tilt down, tilt up, step back), the side the walk is on, which
    /// is the first without an end, as the planner orders them. Nil when both ends are marked or
    /// the walk is doing something else.
    private var endOnOffer: (side: WallSide, atReticle: Bool)? {
        guard state.phase == .wallWalk, state.marking == nil, state.endQuestion == nil, !state.overheadQuestion,
              nextWallSide == nil, let map = coverage else { return nil }
        switch state.guidance {
        case .walk(let side, _):
            return (side, false)
        case .markEnd(let side):
            return (side, true)
        case .aimAtGround, .aimAtWall, .stepBack:
            if map.leftEnd == nil { return (.left, false) }
            if map.rightEnd == nil { return (.right, false) }
            return nil
        case .findMeter, .aimAtWallForMeter, .holdOnMeter, .walkComplete, .tiltUp, .markNextWall, .gap, .seeBehind:
            return nil
        }
    }

    /// Where ending the walk on `side` puts the end now (`WalkedEnd`): the phone's place along the
    /// wall, kept to what was walked on that side. The phone's place doesn't count while it has
    /// lost it.
    func walkedEnd(_ side: WallSide) -> Float? {
        guard let map = coverage else { return nil }
        let phone = currentFrame.flatMap { $0.tracking.hasLostItsPlace ? nil : $0.camera.position }
        return WalkedEnd.end(side.walk, phone: phone, walked: map.walkedPositions, wall: map.wall)
    }

    /// The end preview for this moment (`ScanViewState.endPreview`).
    func currentEndPreview() -> EndPreview? {
        guard let offer = endOnOffer, let map = coverage, let frame = currentFrame else { return nil }
        let side: WallSide
        let s: Float
        if offer.atReticle {
            // `markWallEnd` with no point: the middle of the view, which is the sensor image's
            // middle whatever the view's size.
            guard frame.tracking == .normal,
                  let hit = nearbyWallHit(frame.camera.ray(throughPixel: frame.camera.imageSize / 2), camera: frame.camera, wall: map.wall) else { return nil }
            side = hit.s < 0 ? .left : .right
            s = hit.s
        } else {
            guard let end = walkedEnd(offer.side) else { return nil }
            side = offer.side
            s = end
        }
        // Less than one keyframe's spacing short of the farthest view is still the front of the walk.
        let walkedPast = map.walkedFarthest(side.walk) - side.walk.sign * s
        let leavesOut = walkedPast >= AutoCaptureConfig().spacingMeters ? walkedPast : nil
        return EndPreview(side: side, s: s, atReticle: offer.atReticle, leavesOutWalked: leavesOut)
    }

    /// Republishes the end preview; called with every guidance update, since the phone moves.
    func publishEndPreview() {
        let preview = currentEndPreview()
        if preview != state.endPreview { state.endPreview = preview }
    }

    func endWallHere() {
        guard let preview = currentEndPreview(), !preview.atReticle else { return }
        // The walk toward that side is met: the homeowner got to its end.
        if case .walk(let side, _) = state.guidance, side == preview.side { resolveGuidance(.met) }
        logEnd("wall ends here", side: preview.side, at: preview.s)
        // Unexplored until the homeowner says something blocks the wall there, as for a marked end.
        state.endQuestion = preview.side
        setEnd(preview.side, at: preview.s, kind: .unexplored)
    }

    /// "Can't get there" while the walk asks to walk `side` or to mark its end: the end goes where
    /// the preview showed, as an unexplored end.
    func endWalkCannotGoOn(_ side: WallSide) {
        guard let s = walkedEnd(side) else { return }
        logEnd("can't get there", side: side, at: s)
        setEnd(side, at: s, kind: .unexplored)
    }

    /// Where the end went and what the old rule, the unbroken covered reach, would have said.
    private func logEnd(_ action: String, side: WallSide, at s: Float) {
        guard let map = coverage else { return }
        let phone = currentFrame.map { map.wall.wallPoint($0.camera.position).s } ?? .nan
        let walked = map.walkedFarthest(side.walk)
        let covered = GuidancePlanner().reach(side.walk, coverage: map)
        RuntimeLog.engine.info("\(action, privacy: .public) on the \(side.rawValue, privacy: .public): end at s=\(s) (phone at s=\(phone), walked \(walked) m, covered reach \(covered) m)")
    }

    /// `ScanViewState.featuresPastEnds`, refreshed when the ends move (`publishWall`), the spans
    /// follow the wall (`reprojectFeatures`) and a mark is added.
    func publishFeaturesPastEnds() {
        let left = coverage?.leftEnd
        let right = coverage?.rightEnd
        let past = Set(state.features.filter { WalkedEnd.liesPastAnEnd($0.span, leftEnd: left, rightEnd: right) }.map(\.id))
        if past != state.featuresPastEnds { state.featuresPastEnds = past }
    }
}

extension WallSide {
    var walk: WalkSide { self == .left ? .left : .right }
}
