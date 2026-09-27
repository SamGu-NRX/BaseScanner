import Foundation
import simd

/// Checks on where a tap marking a wall object (an AC unit, gas meter, door, window, box) meets the
/// wall (#140).
///
/// `WallFrame.intersectWall` never bounds a hit's height, and the outermost pieces of the wall run
/// on forever. A tap aimed down at the ground meets the wall's plane under the floor; in a field
/// run two AC taps landed 28 m and 70 m below the floor, 105 ft and 276 ft along the wall, and were
/// exported. A hit is refused when it lies below the ground, which also covers a ray that meets the
/// ground before the wall (from a phone above the ground, the ray crosses the ground first exactly
/// when it meets the wall below it), or when it lies farther along the wall from the phone than a
/// camera can see (the same bound wall-end taps use).
public enum ObjectTap {
    /// How far below the wall's ground a hit may lie, meters, on top of the ground's own error. A
    /// tap on something standing on the ground lands at its foot or a little below it: in the
    /// field run a plausible AC tap landed 0.10 m below the ground. 0.15 m (about 6 in) is a guess,
    /// not measured.
    public static let belowGroundSlack: Float = 0.15

    /// Why a wall hit can't be the object tapped.
    public enum Refusal: Sendable, Equatable, CustomStringConvertible {
        /// The hit is this many meters below the ground.
        case belowGround(meters: Float)
        /// The hit is this many meters along the wall from the phone.
        case tooFarAlong(meters: Float)

        public var description: String {
            switch self {
            case .belowGround(let meters): "wall hit \(ObjectTap.format(meters)) m below the ground"
            case .tooFarAlong(let meters): "wall hit \(ObjectTap.format(meters)) m along the wall from the phone"
            }
        }
    }

    /// Why `hit`, where a tap's ray met `wall`, can't be the object, or nil when it can. `camera` is
    /// the phone's position when it tapped. `reach` is how far along the wall from the phone a hit
    /// may lie, meters: the coverage map's `maxDistance`, as for a wall-end tap. `groundError` is how
    /// far the real ground may lie below `wall.groundY` (`CoverageMap.heightError`): 0 once the
    /// ground is measured.
    public static func refusal(_ hit: WallPoint, camera: SIMD3<Float>, wall: WallFrame, reach: Float, groundError: Float) -> Refusal? {
        let floor = -(belowGroundSlack + max(0, groundError))
        if hit.height < floor { return .belowGround(meters: -hit.height) }
        let along = abs(hit.s - wall.wallPoint(camera).s)
        if along > reach { return .tooFarAlong(meters: along) }
        return nil
    }

    static func format(_ value: Float) -> String {
        String(format: "%.2f", Double(value))
    }
}
