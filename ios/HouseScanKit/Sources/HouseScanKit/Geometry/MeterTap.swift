import Foundation
import simd

/// Checks on the meter tap's raycast hit, and the re-fit of the wall to a detected wall plane
/// before the walk (#69).
///
/// A hit on a plane ARKit detected is taken as it is. A hit on a plane ARKit only estimated from
/// feature points around the tap can be far off: in a field run one sat 1.1 m behind the real wall
/// and turned 46 degrees from it, and the whole scan was built on a wall that isn't there. So an
/// estimated hit is refused when it is out of reach, turned away from the phone, or behind a
/// detected plane the phone looks through to reach it. Every threshold is a guess, not measured;
/// a field test counts refusals of good taps to tune them.
public enum MeterTap {
    /// How far from the phone the meter may be, meters, for an estimated hit to be taken, and for
    /// a detected wall plane to count as the one the phone was looking at. The app asks for the
    /// meter from close by; the close-up is taken from about 0.5 m. A guess.
    public static let maximumReach: Float = 2
    /// The most an estimated plane may be turned from facing the phone, radians: the horizontal
    /// angle between its normal and the phone's view, reversed. Someone marking a meter faces it
    /// roughly square-on. 30 degrees is a guess; the field run's bad hit was 46 degrees off.
    public static let maximumFacingAngle: Float = 30 * .pi / 180
    /// Below this horizontal length of the phone's unit view direction (pitched more than 60
    /// degrees up or down) the view says too little about which way the wall faces, and the facing
    /// check is skipped.
    public static let minimumLevelView: Float = 0.5
    /// How far behind a detected plane an estimated hit may lie, meters, where the phone looks
    /// through that plane to reach it. A meter stands proud of its wall by a few inches, so a hit in
    /// front of a plane is never refused; one this far behind the surface the phone sees first is
    /// not on it. A guess.
    public static let behindTolerance: Float = 0.1
    /// How far beyond a detected plane's outline its surface is still taken to be there, meters.
    /// ARKit's outlines stop short of a surface's real edge. A guess.
    public static let coverMargin: Float = 0.25
    /// A detected wall plane moves the wall to it once the meter would move more than this,
    /// meters, or the wall would turn more than `refitAngle`. Under both, the tap agrees with it
    /// well enough. Guesses: 0.2 m and 10 degrees are what the field analysis proposed.
    public static let refitOffset: Float = 0.2
    public static let refitAngle: Float = 10 * .pi / 180

    /// Why an estimated hit was refused, for the log.
    public enum Refusal: Sendable, Equatable, CustomStringConvertible {
        /// The hit is this many meters from the phone.
        case tooFar(meters: Float)
        /// The hit plane is turned this many degrees from facing the phone.
        case turnedFromPhone(degrees: Float)
        /// The hit lies this many meters behind the detected plane with id `planeID`, which the
        /// phone's line of sight crosses first.
        case behindDetectedPlane(planeID: String, meters: Float)

        public var description: String {
            switch self {
            case .tooFar(let meters):
                "estimated plane \(MeterTap.format(meters)) m from the phone (over \(MeterTap.format(MeterTap.maximumReach)) m)"
            case .turnedFromPhone(let degrees):
                "estimated plane turned \(MeterTap.format(degrees)) degrees from the phone's view"
            case .behindDetectedPlane(let planeID, let meters):
                "estimated plane \(MeterTap.format(meters)) m behind detected plane \(planeID)"
            }
        }
    }

    /// Why the tap's hit at `hit`, on a plane with normal `normal`, can't be the meter, or nil when
    /// it can. A hit on a detected plane always can. `camera` is the frame the tap was made on;
    /// `planes` are the vertical planes ARKit has detected. Only planes classified wall or not
    /// classified can refuse a hit: a door or a window may stand in front of a wall.
    public static func refusal(
        hit: SIMD3<Float>, normal: SIMD3<Float>, source: MeterPlaneSource, camera: CameraFrame, planes: [WallPlaneEvidence]
    ) -> Refusal? {
        switch source {
        case .detectedPlane: return nil
        case .estimatedPlane: break
        }
        let reach = simd_distance(hit, camera.position)
        if reach > maximumReach { return .tooFar(meters: reach) }
        let view = camera.forward
        let towardPhone = SIMD3(-view.x, 0, -view.z)
        let flatNormal = SIMD3(normal.x, 0, normal.z)
        if simd_length(towardPhone) >= minimumLevelView, simd_length(flatNormal) > 1e-3 {
            let cosine = abs(simd_dot(simd_normalize(towardPhone), simd_normalize(flatNormal)))
            let angle = acos(min(1, cosine))
            if angle > maximumFacingAngle { return .turnedFromPhone(degrees: angle * 180 / .pi) }
        }
        for plane in planes where plane.kind != .other {
            guard let crossing = sightCrossing(from: camera.position, through: hit, plane: plane),
                  crossing.depthBehind > behindTolerance, plane.covers(crossing.point, margin: coverMargin) else { continue }
            return .behindDetectedPlane(planeID: plane.id, meters: crossing.depthBehind)
        }
        return nil
    }

    /// Where a detected wall plane puts the meter and the wall, when it disagrees with a tap on an
    /// estimated plane.
    public struct Refit: Sendable, Equatable {
        /// Where the tap's line of sight meets the plane.
        public var meter: SIMD3<Float>
        /// The plane's horizontal normal, facing the side the tap was made from.
        public var outward: SIMD3<Float>
        public var planeID: String
        /// How far the meter moves, meters.
        public var moved: Float
        /// How far the wall turns, radians.
        public var turned: Float

        public init(meter: SIMD3<Float>, outward: SIMD3<Float>, planeID: String, moved: Float, turned: Float) {
            self.meter = meter
            self.outward = outward
            self.planeID = planeID
            self.moved = moved
            self.turned = turned
        }
    }

    /// The wall a detected wall plane gives, for a meter marked at `meter` on an estimated plane
    /// facing `outward`, from a phone at `tapCamera`; nil when no detected wall plane disagrees
    /// with the tap. The meter was on the tap's line of sight, wherever the estimated plane put it
    /// along it, so the plane that line crosses first, within `maximumReach` of the phone and
    /// within the plane's outline, is the surface the homeowner aimed at. It disagrees when the
    /// meter would move more than `refitOffset` to it or the wall would turn more than
    /// `refitAngle`. Only planes classified wall count: an unclassified one near a meter may be
    /// the meter's own board, or a fence.
    public static func refit(meter: SIMD3<Float>, outward: SIMD3<Float>, tapCamera: SIMD3<Float>, planes: [WallPlaneEvidence]) -> Refit? {
        let flat = SIMD3(outward.x, 0, outward.z)
        guard simd_length(flat) > 1e-3 else { return nil }
        var nearest: (plane: WallPlaneEvidence, crossing: SightCrossing)?
        for plane in planes where plane.kind == .wall {
            guard let crossing = sightCrossing(from: tapCamera, through: meter, plane: plane),
                  simd_distance(crossing.point, tapCamera) <= maximumReach,
                  plane.covers(crossing.point, margin: coverMargin) else { continue }
            if let best = nearest, best.crossing.fraction <= crossing.fraction { continue }
            nearest = (plane: plane, crossing: crossing)
        }
        guard let nearest else { return nil }
        let turned = acos(min(1, abs(simd_dot(simd_normalize(flat), nearest.crossing.normal))))
        let moved = simd_distance(nearest.crossing.point, meter)
        guard moved > refitOffset || turned > refitAngle else { return nil }
        return Refit(meter: nearest.crossing.point, outward: nearest.crossing.normal, planeID: nearest.plane.id, moved: moved, turned: turned)
    }

    /// Where the line of sight from `eye` through `target` meets a vertical plane.
    struct SightCrossing {
        var point: SIMD3<Float>
        /// The plane's horizontal normal, turned toward the eye.
        var normal: SIMD3<Float>
        /// How far along from the eye to the target the crossing is: under 1 before the target.
        var fraction: Float
        /// How far the target lies behind the plane as the eye sees it, meters; negative in front.
        var depthBehind: Float
    }

    /// Nil when the plane isn't vertical, the eye is on it, or the line of sight runs along it or
    /// away from it.
    static func sightCrossing(from eye: SIMD3<Float>, through target: SIMD3<Float>, plane: WallPlaneEvidence) -> SightCrossing? {
        guard var normal = plane.horizontalNormal else { return nil }
        var eyeSide = simd_dot(eye - plane.center, normal)
        if eyeSide < 0 {
            normal = -normal
            eyeSide = -eyeSide
        }
        let targetSide = simd_dot(target - plane.center, normal)
        let closing = eyeSide - targetSide
        guard eyeSide > 1e-3, closing > 1e-4 else { return nil }
        let fraction = eyeSide / closing
        return SightCrossing(point: eye + (target - eye) * fraction, normal: normal, fraction: fraction, depthBehind: -targetSide)
    }

    static func format(_ value: Float) -> String {
        String(format: "%.2f", Double(value))
    }
}
