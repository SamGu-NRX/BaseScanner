import Foundation
import simd

/// Where a wall end goes when the homeowner ends the walk on a side without pointing at the end:
/// "Can't get there" while the walk asks them to walk that way, or "Wall ends here" during the
/// walk.
///
/// The end goes where the phone is, along the wall chain (`WallFrame.wallPoint`, so s runs on
/// round a corner the walk followed), kept within the stretch walked on that side: never past the
/// farthest kept view there, and never across the meter. It used to go where coverage ran
/// unbroken from the meter over both bands (`GuidancePlanner.reach`). On device run 1
/// (2026-09-26) the ground in front of the meter had not been seen from two places when the
/// homeowner tapped, so both ends landed within 4 in of the meter and the scan left out the
/// 19 ft it had walked and photographed. Stretches between the meter and the end that nothing
/// saw stay in the scan as unseen, and the server asks for them.
public enum WalkedEnd {
    /// How far the walk went on `side`, meters from the meter along the chain: the farthest
    /// position a kept view was taken from on that side, 0 when none was.
    public static func farthest(_ side: WalkSide, walked: [SIMD3<Float>], wall: WallFrame) -> Float {
        walked.reduce(0) { max($0, side.sign * wall.wallPoint($1).s) }
    }

    /// s of the end on `side`. `walked` holds the positions of the kept views; `phone` is where
    /// the phone is now, nil when it has lost its place.
    ///
    /// - Phone on that side of the meter: its s, but no farther out than `farthest`.
    /// - Phone across the meter, or its place unknown: `farthest`. The phone's position then says
    ///   nothing about how far this side goes, and the walked stretch is the only measurement of
    ///   it; an end at the meter would drop everything walked there, which is how run 1 lost its
    ///   wall.
    /// - Nothing walked on that side: the meter.
    public static func end(_ side: WalkSide, phone: SIMD3<Float>?, walked: [SIMD3<Float>], wall: WallFrame) -> Float {
        let reach = farthest(side, walked: walked, wall: wall)
        guard let phone else { return side.sign * reach }
        let along = side.sign * wall.wallPoint(phone).s
        return side.sign * (along < 0 ? reach : min(along, reach))
    }

    /// The side "Wall ends here" ends while the walk asks about the wall in front of the phone
    /// (tilt down, tilt up, step back) instead of asking to walk a side: the side of the meter the
    /// phone is on, by its s along the chain as `end` measures it, when that side has no end yet.
    /// The planner does the left side first, so the first side without an end can be the one
    /// behind the homeowner: after walking right with the left end unmarked, the button ended the
    /// left side at its farthest walked point, far from the phone (review of #24). With the
    /// phone's place unknown, the phone at the meter, or its side already ended: the first side
    /// without an end, as before. Nil when both ends are marked.
    public static func side(phone: SIMD3<Float>?, wall: WallFrame, leftEnd: Float?, rightEnd: Float?) -> WalkSide? {
        let open = WalkSide.allCases.filter { ($0 == .left ? leftEnd : rightEnd) == nil }
        if let phone {
            let s = wall.wallPoint(phone).s
            if let side = open.first(where: { $0.sign * s > 0 }) { return side }
        }
        return open.first
    }
}

extension CoverageMap {
    /// Where the kept views were taken from (`observedCameras`).
    public var walkedPositions: [SIMD3<Float>] { observedCameras.map(\.position) }

    /// How far the walk went on `side` (`WalkedEnd.farthest`).
    public func walkedFarthest(_ side: WalkSide) -> Float {
        WalkedEnd.farthest(side, walked: walkedPositions, wall: wall)
    }

    /// True when both ends are marked closer together along the chain than
    /// `WallFrame.minWallLength`: too short a wall to finish the walk with.
    public var endsTooClose: Bool {
        guard let leftEnd, let rightEnd else { return false }
        return rightEnd - leftEnd < WallFrame.minWallLength
    }

    /// The unexplored end the camera stands beyond while its view shows nothing between the marked
    /// ends, or nil. A photo taken there adds nothing: cells past an end are never observed
    /// (`isWithinEnds`). Past a limit end it is nil, since the ground seen there still counts
    /// (`groundDepthPastLimit`).
    public func unexploredEndPassed(by camera: CameraFrame) -> WalkSide? {
        let s = wall.wallPoint(camera.position).s
        let side: WalkSide
        if let leftEnd, s < leftEnd {
            side = .left
        } else if let rightEnd, s > rightEnd {
            side = .right
        } else {
            return nil
        }
        guard !limitEnds.contains(side) else { return nil }
        // Only cells between the ends are candidates, so any sighting is one the scan keeps.
        return visibleCells(from: camera).isEmpty ? side : nil
    }
}

extension WalkedEnd {
    /// Meters of the walk on `side` past an end at `s`: how far the farthest kept view there
    /// (`farthest`) is beyond it, which the scan leaves out if the wall ends at `s`. Nil when that
    /// is less than `minimum`, by default one keyframe's spacing: that close to the farthest view
    /// is still the front of the walk.
    public static func walkedPast(
        _ side: WalkSide, s: Float, walked: [SIMD3<Float>], wall: WallFrame,
        minimum: Float = AutoCaptureConfig().spacingMeters
    ) -> Float? {
        let past = farthest(side, walked: walked, wall: wall) - side.sign * s
        return past >= minimum ? past : nil
    }

    /// Whether the strip may say what an end leaves out during `task`: only while the walk asks
    /// to walk a side or mark its end (issue #66). During a tilt or step-back request, or a
    /// request about something in front of the wall, the homeowner isn't ending the wall, and the
    /// line read as a warning that something went wrong. Nil `task`: the walk is on a step the
    /// planner didn't set (the meter, a corner, a gap, the overhead), so no.
    public static func saysWhatAnEndLeavesOut(during task: GuidanceTask?) -> Bool {
        switch task {
        case .walk, .markEnd:
            return true
        case .aimAtGround, .aimAtWall, .stepBack, .seeBehind, .complete, nil:
            return false
        }
    }

    /// What the wall strip says an end at `s` would leave out of the walk (`walkedPast`), before
    /// anything is pressed. Nil unless the walk asks to walk `side` or to mark its end
    /// (`saysWhatAnEndLeavesOut(during: task)`). Nil too when the phone stands more than twice
    /// `GuidanceConfig.standOff` out from the wall, where its place along the wall, and so `s`,
    /// says little: walking out into the yard counted up to 11 ft on device run 3. `phoneOut` is
    /// the phone's distance out from the wall (`WallPoint.out`) when `s` is the phone's place,
    /// nil when it isn't (the reticle's end) or the phone has lost its place.
    public static func leavesOut(
        side: WalkSide, s: Float, walked: [SIMD3<Float>], wall: WallFrame,
        phoneOut: Float?, task: GuidanceTask?, config: GuidanceConfig = GuidanceConfig()
    ) -> Float? {
        guard saysWhatAnEndLeavesOut(during: task) else { return nil }
        if let phoneOut, abs(phoneOut) > 2 * config.standOff { return nil }
        return walkedPast(side, s: s, walked: walked, wall: wall)
    }

    /// Whether a mark's span (meters of s) lies wholly past a marked end. The scan doesn't cover
    /// it there: the wall may turn or stop at that end, so the review says so (issue #42). A mark
    /// reaching an end, or with any of it between the ends, is on the scanned wall.
    public static func liesPastAnEnd(_ span: ClosedRange<Float>, leftEnd: Float?, rightEnd: Float?) -> Bool {
        if let leftEnd, span.upperBound < leftEnd { return true }
        if let rightEnd, span.lowerBound > rightEnd { return true }
        return false
    }
}
