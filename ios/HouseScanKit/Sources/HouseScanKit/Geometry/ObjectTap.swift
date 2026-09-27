import Foundation
import simd

/// Checks on where a tap marking a wall object (an AC unit, gas meter, door, window, box) meets the
/// wall (#140), and where a tap on an object standing on the ground lands instead (#163).
///
/// `WallFrame.intersectWall` never bounds a hit's height, and the outermost pieces of the wall run
/// on forever. A tap aimed down at the ground meets the wall's plane under the floor; grazing rays
/// can put objects far along the wall. A hit below the ground is refused. From a phone above the
/// ground, such a ray crosses the ground before reaching the wall. A hit farther along the wall
/// than the camera can see is also refused, using the same distance bound as wall-end taps.
///
/// An AC unit stands on the ground in front of the wall, so a ray aimed at it meets the ground
/// first and the wall's plane under the floor, deeper the steeper the aim or the farther out the
/// unit stands (#163). For such an object the tap lands where the ray meets the ground instead.
public enum ObjectTap {
    /// How far below the wall's ground a hit may lie, meters, on top of the ground's own error. A
    /// tap on something standing on the ground may land at its foot or a little below it. The
    /// 0.15 m allowance is an unmeasured guess.
    public static let belowGroundSlack: Float = 0.15

    /// How far out from the wall a ground tap may land, meters. Past 8 m out a ground tap (a fence,
    /// a driveway edge, an AC unit) is not about this wall any more. A sanity bound on the tap, not
    /// a placement rule.
    public static let maxGroundOut: Float = 8

    /// Why a tap can't be the object.
    public enum Refusal: Sendable, Equatable, CustomStringConvertible {
        /// The ray meets no wall, and for an object standing on the ground, no ground either.
        case noSurface
        /// The wall hit is this many meters below the ground.
        case belowGround(meters: Float)
        /// The hit is this many meters along the wall from the phone.
        case tooFarAlong(meters: Float)
        /// The ground hit is this many meters out from the wall: behind it when negative.
        case tooFarOut(meters: Float)

        public var description: String {
            switch self {
            case .noSurface: "ray meets no surface"
            case .belowGround(let meters): "wall hit \(ObjectTap.format(meters)) m below the ground"
            case .tooFarAlong(let meters): "hit \(ObjectTap.format(meters)) m along the wall from the phone"
            case .tooFarOut(let meters): "ground hit \(ObjectTap.format(meters)) m out from the wall"
            }
        }
    }

    /// Where a tap marking an object lands.
    public enum Placement: Sendable, Equatable {
        /// On the wall's face.
        case wall(WallPoint)
        /// On the ground in front of the wall: an object standing on the ground (#163).
        case ground(WallPoint)
        case refused(Refusal)
    }

    /// Why `hit`, where a tap's ray met `wall`, can't be the object, or nil when it can. `camera` is
    /// the phone's position when it tapped. `reach` is how far along the wall from the phone a hit
    /// may lie, meters: the coverage map's `maxDistance`, as for a wall-end tap. `groundError` is how
    /// far the real ground may lie below `wall.groundY` (`CoverageMap.heightError`): 0 once the
    /// ground is measured.
    public static func refusal(_ hit: WallPoint, camera: SIMD3<Float>, wall: WallFrame, reach: Float, groundError: Float) -> Refusal? {
        let floor = -(belowGroundSlack + max(0, groundError))
        if hit.height < floor { return .belowGround(meters: -hit.height) }
        return tooFarAlong(hit, camera: camera, wall: wall, reach: reach)
    }

    /// Where `ray`, a tap marking an object, lands on `wall`. The wall hit comes first, checked by
    /// `refusal`. When `standsOnGround` (an AC unit) and the ray meets the wall's plane below the
    /// ground, or meets no wall, the tap lands where the ray meets the ground instead: in front of
    /// the wall by at most `maxGroundOut`, and within `reach` along it from the phone (#163).
    /// Doors, windows and gas meters hang on the wall and keep the wall-only rule of #140.
    public static func place(_ ray: Ray, standsOnGround: Bool, camera: SIMD3<Float>, wall: WallFrame, reach: Float, groundError: Float) -> Placement {
        let wallRefusal: Refusal
        if let hit = wall.intersectWall(ray) {
            guard let refused = refusal(hit, camera: camera, wall: wall, reach: reach, groundError: groundError) else { return .wall(hit) }
            wallRefusal = refused
        } else {
            wallRefusal = .noSurface
        }
        guard standsOnGround else { return .refused(wallRefusal) }
        switch wallRefusal {
        case .noSurface, .belowGround:
            break
        case .tooFarAlong, .tooFarOut:
            // A wall hit at a plausible height but out of reach: the ray runs nearly along the
            // wall and doesn't come down to the ground before it.
            return .refused(wallRefusal)
        }
        guard let ground = wall.intersectGround(ray) else { return .refused(wallRefusal) }
        if ground.out < 0 || ground.out > maxGroundOut { return .refused(.tooFarOut(meters: ground.out)) }
        if let refused = tooFarAlong(ground, camera: camera, wall: wall, reach: reach) { return .refused(refused) }
        return .ground(ground)
    }

    private static func tooFarAlong(_ hit: WallPoint, camera: SIMD3<Float>, wall: WallFrame, reach: Float) -> Refusal? {
        let along = abs(hit.s - wall.wallPoint(camera).s)
        return along > reach ? .tooFarAlong(meters: along) : nil
    }

    static func format(_ value: Float) -> String {
        String(format: "%.2f", Double(value))
    }
}
