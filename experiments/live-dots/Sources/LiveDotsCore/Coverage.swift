/// The ring's fraction: how much of the requirement zone around the meter (x from -3 to 3 m on
/// the wall) has 30 cm columns holding at least one dot seen from two or more directions.
public enum Coverage {
    public static var columnCount: Int {
        Int(((Tuning.coverageZone.upperBound - Tuning.coverageZone.lowerBound) / Tuning.coverageColumn).rounded())
    }

    /// Dots count when they sit on the wall plane (within 10 cm of z = 0) and are not on the bin.
    public static func fraction(of dots: [FieldDot]) -> Float {
        var covered = Set<Int>()
        for dot in dots where dot.views >= Tuning.coverageMinViews && abs(dot.position.z) <= 0.1 && !dot.onOccluder {
            let offset = dot.position.x - Tuning.coverageZone.lowerBound
            guard offset >= 0 else { continue }
            let column = Int((offset / Tuning.coverageColumn).rounded(.down))
            if column < columnCount { covered.insert(column) }
        }
        return Float(covered.count) / Float(columnCount)
    }
}
