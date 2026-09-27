import simd

/// Three looks for the same dot field, to compare on one replay before one goes into the app.
public enum DotScheme: String, Sendable, CaseIterable {
    /// White cores, blue halos, edge and flat dots, opacity from evidence.
    case hologram
    /// Edges only, joined by hairline links into a line drawing; the wall's surface shows nothing.
    case constellation
    /// As hologram, but a dot is born amber and cools to white over the 6 s after its birth, so
    /// the newest part of the map glows. Seeing a dot again never re-warms it: LiDAR re-measures
    /// everything in view every keyframe, which kept the whole screen amber.
    case ember

    /// Whether a dot of `kind` draws at all.
    public func draws(_ kind: DotKind) -> Bool {
        switch self {
        case .hologram, .ember: true
        case .constellation: kind == .edge || kind == .feature
        }
    }

    /// Links join each edge dot to its two nearest edge neighbours within 8 cm on the same
    /// surface (normals within 35 degrees).
    public static let linkRadius: Float = 0.08
    public static let linksPerDot = 2
    /// Seconds of playback for an ember dot to cool from amber to white.
    public static let emberCooling: Float = 6

    /// 1 at birth, falling linearly to 0 `emberCooling` seconds later.
    public static func warmth(at t: Float, birth: Float) -> Float {
        min(max(1 - (t - birth) / emberCooling, 0), 1)
    }
}
