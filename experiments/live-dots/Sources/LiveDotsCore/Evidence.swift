import simd

public enum Evidence {
    /// Opacity for a dot seen from `views` distinct directions: 45% at one, rising linearly to
    /// 90% at four and holding there. Zero views draws nothing.
    /// With `faceOn` false (an edge no view has seen within 30 degrees of face-on) the result
    /// is capped at 60%.
    public static func opacity(views: Int, faceOn: Bool = true) -> Float {
        guard views > 0 else { return 0 }
        let level = min(0.45 + 0.15 * Float(views - 1), 0.9)
        return faceOn ? level : min(level, Tuning.obliqueEdgeOpacityCap)
    }
}

/// The distinct directions a point has been seen from. A direction is new only when it differs
/// from every stored one by more than `Tuning.viewSeparationDegrees`.
public struct ViewDirections: Sendable, Equatable {
    public private(set) var directions: [SIMD3<Float>] = []
    /// Opacity stops rising at four views and the ring needs two, so eight is plenty.
    public static let capacity = 8

    public init() {}

    public var count: Int { directions.count }

    /// Adds `direction` (any length) if it is new. Returns whether it was.
    @discardableResult
    public mutating func insert(_ direction: SIMD3<Float>) -> Bool {
        let length = simd_length(direction)
        guard length > 1e-6, directions.count < Self.capacity else { return false }
        let unit = direction / length
        let limit = cos(Tuning.viewSeparationDegrees * Float.pi / 180)
        for existing in directions where simd_dot(existing, unit) >= limit {
            return false
        }
        directions.append(unit)
        return true
    }
}
