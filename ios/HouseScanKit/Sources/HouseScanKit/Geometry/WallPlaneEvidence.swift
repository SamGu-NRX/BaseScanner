import Foundation
import simd

/// A vertical plane ARKit detected, as the meter tap's checks need it: what ARKit classified it
/// as, where it is, which way it faces and its outline. World meters.
public struct WallPlaneEvidence: Sendable, Equatable {
    /// ARKit's plane classifications that matter here (`ARPlaneAnchor.Classification`).
    public enum Kind: Sendable, Equatable {
        case wall
        /// `.none`: not classified, which is every plane on a phone without classification.
        case unclassified
        /// Anything else: a door, a window, or a class added after iOS 26.
        case other
    }

    /// ARKit's anchor identifier, for the log.
    public var id: String
    public var kind: Kind
    /// A point on the plane: its centre.
    public var center: SIMD3<Float>
    /// The plane's normal, either way round. A vertical plane's is horizontal.
    public var normal: SIMD3<Float>
    /// The plane's outline, in order around it.
    public var boundary: [SIMD3<Float>]

    public init(id: String, kind: Kind, center: SIMD3<Float>, normal: SIMD3<Float>, boundary: [SIMD3<Float>]) {
        self.id = id
        self.kind = kind
        self.center = center
        self.normal = normal
        self.boundary = boundary
    }

    /// The normal made horizontal and unit length, or nil when the plane isn't close to vertical
    /// (its normal is more than 60 degrees from horizontal).
    var horizontalNormal: SIMD3<Float>? {
        let flat = SIMD3(normal.x, 0, normal.z)
        let length = simd_length(normal)
        guard length > 0, simd_length(flat) > 0.5 * length else { return nil }
        return simd_normalize(flat)
    }

    /// Whether `point`, on or near the plane, lies within its outline or at most `margin` beyond
    /// it: along the plane horizontally, and in height. The outline is taken as the box around it
    /// in the plane, so a notch in it counts as covered.
    func covers(_ point: SIMD3<Float>, margin: Float) -> Bool {
        guard let normal = horizontalNormal, !boundary.isEmpty else { return false }
        let along = SIMD3(-normal.z, 0, normal.x)
        let offsets = boundary.map { simd_dot($0 - center, along) }
        let heights = boundary.map(\.y)
        guard let first = offsets.min(), let last = offsets.max(), let bottom = heights.min(), let top = heights.max() else { return false }
        let offset = simd_dot(point - center, along)
        return offset >= first - margin && offset <= last + margin && point.y >= bottom - margin && point.y <= top + margin
    }
}
