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
}

extension CoverageMap {
    /// Where the kept views were taken from (`observedCameras`).
    public var walkedPositions: [SIMD3<Float>] { observedCameras.map(\.position) }

    /// How far the walk went on `side` (`WalkedEnd.farthest`).
    public func walkedFarthest(_ side: WalkSide) -> Float {
        WalkedEnd.farthest(side, walked: walkedPositions, wall: wall)
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
