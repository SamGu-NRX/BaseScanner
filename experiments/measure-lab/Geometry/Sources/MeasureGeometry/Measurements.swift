/// Distances between two world points. World y is up, so "horizontal" ignores y.
public struct PointSeparation: Sendable, Equatable {
    /// Straight-line 3D distance, in meters.
    public let straight: Double
    /// Distance in the horizontal plane, in meters.
    public let horizontal: Double
    /// Height of `to` minus height of `from`, in meters.
    public let rise: Double

    public init(from a: SIMD3<Double>, to b: SIMD3<Double>) {
        let delta = b - a
        straight = delta.length
        horizontal = delta.horizontal.length
        rise = delta.y
    }
}

/// The quantity a tape reading is compared against.
public enum MeasuredQuantity: String, Sendable, CaseIterable, Codable {
    /// 3D distance between two points.
    case straight
    /// Horizontal distance between two points.
    case horizontal
    /// Absolute height difference between two points.
    case vertical
    /// Absolute along-wall distance between two points.
    case alongWall
    /// Perpendicular horizontal distance from a point to the wall line (facing gap).
    case gapToWall
    /// Height of a point above the wall's ground line.
    case heightAboveGround
}

/// A tape reading compared with the app's value for the same quantity.
public struct TapeComparison: Sendable, Equatable {
    /// App value, in meters.
    public let measured: Double
    /// Tape value, in meters.
    public let tape: Double

    public init(measured: Double, tape: Double) {
        self.measured = measured
        self.tape = tape
    }

    /// App minus tape, in meters. Positive means the app read long.
    public var error: Double {
        measured - tape
    }

    public var errorInches: Double {
        error / Length.metersPerInch
    }
}

/// What a measurement runs to: another point, or a wall.
public enum MeasurementTarget: Sendable {
    case point(SIMD3<Double>)
    case wall(Wall)
}

/// Every quantity that applies to a pair, in meters and non-negative.
///
/// Point to point gives straight, horizontal and vertical distance, plus along-wall distance when
/// a reference wall is given. Point to wall gives the facing gap and the point's height above the
/// wall's ground line.
public func measuredValues(
    from point: SIMD3<Double>,
    to target: MeasurementTarget,
    referenceWall: Wall? = nil
) -> [MeasuredQuantity: Double] {
    switch target {
    case .point(let other):
        let separation = PointSeparation(from: point, to: other)
        var values: [MeasuredQuantity: Double] = [
            .straight: separation.straight,
            .horizontal: separation.horizontal,
            .vertical: abs(separation.rise),
        ]
        if let referenceWall {
            values[.alongWall] = abs(referenceWall.alongDistance(from: point, to: other))
        }
        return values
    case .wall(let wall):
        return [
            .gapToWall: wall.gap(to: point),
            .heightAboveGround: abs(wall.heightAboveGround(point)),
        ]
    }
}
