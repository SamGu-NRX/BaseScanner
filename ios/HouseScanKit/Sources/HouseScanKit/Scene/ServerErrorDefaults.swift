import Foundation

/// The server's default position errors, mirrored from `errors` in server/rules.yaml on t3/server
/// at 930e8e5 and converted to meters. The phone needs them where it reports a distance the
/// server takes as exact after the error (a walked path's clearance) or adds to one it sends
/// (the meter's). If the rules change, these go stale.
public enum ServerErrorDefaults {
    private static let metersPerFoot: Float = 0.3048

    /// `errors.meter_ft`, 0.3 ft: the meter's position, with no drift.
    public static let meter: Float = 0.3 * metersPerFoot

    /// The default error of a wall line found by `source`: `errors.wall_ft` for taps (0.3 ft),
    /// `mesh_ft` (0.5 ft) and `plane_ft` (0.75 ft).
    public static func wall(_ source: WallLineSource) -> Float {
        switch source {
        case .tap: 0.3 * metersPerFoot
        case .mesh: 0.5 * metersPerFoot
        case .plane: 0.75 * metersPerFoot
        }
    }

    /// `errors.drift_per_ft`, 0.16 ft per foot walked along the walls from the meter: a ratio, so
    /// also meters per meter.
    public static let driftPerLength: Float = 0.16

    /// The server's error for a wall line found by `source`, `s` meters along the walls from the
    /// meter: its default plus the drift (server/scene.py `Piece.error_at`).
    public static func wall(_ source: WallLineSource, atS s: Float) -> Float {
        wall(source) + driftPerLength * abs(s)
    }
}
