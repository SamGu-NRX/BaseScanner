/// A point located from two taps on the same feature in two frames taken from different places.
///
/// Two tap rays rarely meet exactly, so the point is the midpoint of their closest approach. With
/// w = o1 − o2, a = d1·d1, b = d1·d2, c = d2·d2, d = d1·w, e = d2·w:
///
///     t1 = (b·e − c·d) / (a·c − b²)     t2 = (a·e − b·d) / (a·c − b²)
///
/// Depth error grows as the rays approach parallel, so small ray angles are refused. Two taps on
/// different physical points can still pass every gate when their rays happen to nearly meet.
public struct Triangulation: Sendable, Equatable {
    public let point: SIMD3<Double>
    /// Closest point on each ray to the other.
    public let closest1: SIMD3<Double>
    public let closest2: SIMD3<Double>
    public let t1: Double
    public let t2: Double
    /// Distance between the closest points, in meters: how far the two rays miss each other.
    public let gap: Double
    /// Angle between the two ray lines in degrees, from 0 (parallel) to 90.
    public let rayAngle: Double
    /// Distance between the two camera positions, in meters.
    public let baseline: Double

    public init(_ ray1: Ray, _ ray2: Ray, gates: TriangulationGates = TriangulationGates()) throws(TriangulationError) {
        let d1 = ray1.direction
        let d2 = ray2.direction
        let angle = acosDegrees(abs(d1.dot(d2)))
        guard angle >= gates.minimumRayAngle else {
            throw .rayAngleTooSmall(angle: angle, minimum: gates.minimumRayAngle)
        }
        let w = ray1.origin - ray2.origin
        let a = d1.dot(d1)
        let b = d1.dot(d2)
        let c = d2.dot(d2)
        let d = d1.dot(w)
        let e = d2.dot(w)
        // Nonzero: the angle gate keeps the rays at least 15° from parallel.
        let denominator = a * c - b * b
        let t1 = (b * e - c * d) / denominator
        let t2 = (a * e - b * d) / denominator
        guard t1 > 0, t2 > 0 else {
            throw .behindCamera(t1: t1, t2: t2)
        }
        let closest1 = ray1.point(at: t1)
        let closest2 = ray2.point(at: t2)
        let gap = (closest1 - closest2).length
        guard gap <= gates.maximumGap else {
            throw .raysMiss(gap: gap, maximum: gates.maximumGap)
        }
        point = (closest1 + closest2) / 2
        self.closest1 = closest1
        self.closest2 = closest2
        self.t1 = t1
        self.t2 = t2
        self.gap = gap
        rayAngle = angle
        baseline = w.length
    }
}

/// Thresholds from the research note's triangulation gates. Hypotheses, not calibrated values.
public struct TriangulationGates: Sendable, Equatable {
    /// Smallest accepted angle between the rays, in degrees.
    public var minimumRayAngle: Double = 15
    /// Largest accepted miss distance between the rays: 2 in, in meters.
    public var maximumGap: Double = 2 * Length.metersPerInch

    public init() {}
}

public enum TriangulationError: Error, Sendable, Equatable {
    case rayAngleTooSmall(angle: Double, minimum: Double)
    /// The closest approach lies behind at least one camera.
    case behindCamera(t1: Double, t2: Double)
    case raysMiss(gap: Double, maximum: Double)
}
