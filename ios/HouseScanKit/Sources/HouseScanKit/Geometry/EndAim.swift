import Foundation
import simd

/// Whether "Wall ends here", pressed with the circle in the middle of the view, may put the end the
/// walk's card asks about where the circle's ray meets the wall (B-06). Before, the button marked
/// whatever side the hit fell on, did nothing for a hit it couldn't use, and said nothing either
/// way. The button and the tape's end preview both take this answer, so the tape never shows an
/// end the button would refuse.
///
/// A hit below the ground is refused with the rule object taps use (`ObjectTap.refusal`). Aimed
/// at the ground, the ray passes the ground and meets the wall's plane under the floor, past the
/// column the circle shows. A hit above the wall is kept: aimed at the sky over the wall, the ray
/// meets the plane in the column under the circle, which is where the end goes.
public enum EndAim {
    public enum Verdict: Sendable, Equatable {
        /// The end goes here.
        case end(WallPoint)
        /// The phone doesn't know where it is yet: no hit can be trusted.
        case lostPlace
        /// The ray meets no wall, meets it below the ground, or farther along it than a view
        /// counts for.
        case offWall
        /// The hit is on the other side of the meter from the end asked about.
        case otherSide
    }

    /// The verdict for `hit`, where the circle's ray meets `wall` (nil when it doesn't), with the
    /// phone at `camera`. `askedLeft` is true when the card asks about the left end (negative s).
    /// `reach` and `groundError` are as for `ObjectTap.refusal`. `lostPlace` wins over everything:
    /// a hit from a phone that has lost its place is somewhere else in the world.
    public static func verdict(
        hit: WallPoint?, camera: SIMD3<Float>, wall: WallFrame, reach: Float, groundError: Float,
        askedLeft: Bool, lostPlace: Bool
    ) -> Verdict {
        if lostPlace { return .lostPlace }
        guard let hit, ObjectTap.refusal(hit, camera: camera, wall: wall, reach: reach, groundError: groundError) == nil else {
            return .offWall
        }
        return (hit.s < 0) == askedLeft ? .end(hit) : .otherSide
    }
}
