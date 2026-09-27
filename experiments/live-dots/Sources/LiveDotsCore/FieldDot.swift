import simd

public enum DotKind: UInt8, Sendable {
    /// A LiDAR voxel on a flat surface; one per 2 x 2 x 2 group is drawn.
    case flat
    /// A LiDAR voxel on a crease, an occupancy boundary or an image edge; every one is drawn.
    case edge
    /// A simulated ARKit raw feature point (no-LiDAR mode).
    case feature
    /// A simulated plane-detection dot on the wall (no-LiDAR mode).
    case plane
}

/// A dot a field wants drawn at the current keyframe, before timing and occlusion.
public struct FieldDot: Sendable, Equatable {
    /// Stable for the life of the dot, so the timeline can tell a birth from a survivor.
    public let id: UInt64
    public let position: SIMD3<Float>
    public let kind: DotKind
    /// Distinct view directions so far; sets the opacity.
    public let views: Int
    /// On the thing standing in front of the wall (the bin), drawn in Hidden violet.
    public let onOccluder: Bool
    /// Some view saw it within 30 degrees of face-on. Only edge dots are ever false.
    public let faceOn: Bool
    /// Unit surface normal, zero when unknown (feature points).
    public let normal: SIMD3<Float>
    /// The last keyframe that observed it, for the ember scheme's cooling.
    public let lastSeenFrame: Int

    public init(
        id: UInt64, position: SIMD3<Float>, kind: DotKind, views: Int, onOccluder: Bool, faceOn: Bool = true,
        normal: SIMD3<Float> = .zero, lastSeenFrame: Int = 0
    ) {
        self.id = id
        self.position = position
        self.kind = kind
        self.views = views
        self.onOccluder = onOccluder
        self.faceOn = faceOn
        self.normal = normal
        self.lastSeenFrame = lastSeenFrame
    }

    public var opacity: Float {
        Evidence.opacity(views: views, faceOn: faceOn)
    }

    /// The brief's occluder test, plus a ground band so the lawn in front of the wall stays
    /// Hologram: in front of the wall by more than 0.25 m and above the ground voxel layer.
    public static func isOnOccluder(_ p: SIMD3<Float>) -> Bool {
        p.z > Tuning.occluderMinZ && p.y > Tuning.groundBand
    }
}
