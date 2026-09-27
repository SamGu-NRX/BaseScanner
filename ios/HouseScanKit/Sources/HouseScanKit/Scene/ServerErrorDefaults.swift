import Foundation

/// The server's default position errors, mirrored from `errors` in server/rules.yaml on
/// t3/server and converted to meters. The phone needs them where it reports a distance the
/// server takes as exact after the error (a walked path's clearance) or adds to one it sends
/// (the meter's, a tapped object's). `ServerErrorDefaultsTests` compares every value in
/// `mirrored` with the server's current rules.yaml and fails when one differs or is missing.
public enum ServerErrorDefaults {
    private static let metersPerFoot: Float = 0.3048

    /// Each mirrored value with its key under `errors:` in rules.yaml, in the file's unit (feet,
    /// or feet per foot for the drift). The constants below read from here.
    public static let mirrored: [(key: String, value: Double)] = [
        ("tap_ft", 0.3),
        ("mesh_ft", 0.5),
        ("plane_ft", 0.75),
        ("wall_ft", 0.3),
        ("meter_ft", 0.3),
        ("drift_per_ft", 0.16),
    ]

    private static func value(_ key: String) -> Float {
        guard let entry = mirrored.first(where: { $0.key == key }) else { fatalError("no mirrored rules.yaml value \(key)") }
        return Float(entry.value)
    }

    /// `errors.meter_ft` (rules.yaml): the meter's position, with no drift.
    public static let meter: Float = value("meter_ft") * metersPerFoot
    /// `errors.tap_ft` (rules.yaml): an object placed by AR taps, before its drift.
    public static let tap: Float = value("tap_ft") * metersPerFoot

    /// The default error of a wall line found by `source`: `errors.wall_ft` for taps,
    /// `errors.mesh_ft` and `errors.plane_ft` (rules.yaml).
    public static func wall(_ source: WallLineSource) -> Float {
        switch source {
        case .tap: value("wall_ft") * metersPerFoot
        case .mesh: value("mesh_ft") * metersPerFoot
        case .plane: value("plane_ft") * metersPerFoot
        }
    }

    /// `errors.drift_per_ft` (rules.yaml), per foot walked along the walls from the meter: a
    /// ratio, so also meters per meter.
    public static let driftPerLength: Float = value("drift_per_ft")

    /// The server's error for a wall line found by `source`, `s` meters along the walls from the
    /// meter: its default plus the drift (server/scene.py `Piece.error_at`).
    public static func wall(_ source: WallLineSource, atS s: Float) -> Float {
        wall(source) + driftPerLength * abs(s)
    }

    /// The server's error for an object placed by taps whose span reaches `farthest` meters
    /// along the walls from the meter: `tap_ft` plus the drift (server/scene.py `parse_scene`,
    /// objects without `plus_minus_ft`).
    public static func tapObject(farthest: Float) -> Float {
        tap + driftPerLength * abs(farthest)
    }
}
