/// Why a point or measurement should count as an abstention rather than an accepted value.
///
/// A result inherits the warnings of every observation it depends on, so a flaw in one ground
/// contact follows the wall it defines into every point on that wall and every measurement that
/// uses them. The observations themselves keep only their own warnings, so analysis can still
/// tell where a warning started.
public enum MeasurementWarning: String, Sendable, Codable, CaseIterable, Comparable {
    /// A ground hit on ARKit's estimated surface rather than a found plane.
    case estimatedPlane
    /// A ground hit on a found plane's extension, past its detected edge.
    case extendedPlane
    /// A ground ray looking down less than the minimum angle.
    case shallowLookDown
    /// A wall point beyond the wall's two contacts, where the plane is extrapolated.
    case outsideWallContacts
    /// One of the wall's ground contacts has a warning of its own.
    case wallContactWarning
    /// The wall has no validation contact yet.
    case wallNotValidated
    /// A validation contact lay farther from the wall plane than the tolerance.
    case wallValidationFailed
    /// A height above ground came out negative: the point is below the wall's ground line.
    case belowGround

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// The qualification of a wall, from its contacts' warnings and its validation contacts.
public struct WallStatus: Sendable, Equatable {
    /// Own warnings of each ground contact that defines the wall.
    public var contactWarnings: [[MeasurementWarning]]
    /// Whether each validation contact passed, in order.
    public var validations: [Bool]

    public init(contactWarnings: [[MeasurementWarning]], validations: [Bool]) {
        self.contactWarnings = contactWarnings
        self.validations = validations
    }

    /// A single failed validation disqualifies the wall even if another one passed.
    public var warnings: [MeasurementWarning] {
        var result: [MeasurementWarning] = []
        if contactWarnings.contains(where: { !$0.isEmpty }) { result.append(.wallContactWarning) }
        if validations.isEmpty {
            result.append(.wallNotValidated)
        } else if validations.contains(false) {
            result.append(.wallValidationFailed)
        }
        return result
    }
}

/// A point's own warnings plus, for a point located on a wall plane, that wall's status.
public struct PointEvidence: Sendable, Equatable {
    public var own: [MeasurementWarning]
    /// Set only when the point's position came from intersecting a wall plane.
    public var wall: WallStatus?

    public init(own: [MeasurementWarning], wall: WallStatus? = nil) {
        self.own = own
        self.wall = wall
    }

    /// Everything that should stop the point counting as accepted.
    public var warnings: [MeasurementWarning] {
        normalized(own + (wall?.warnings ?? []))
    }
}

/// Warnings for one measurement value.
///
/// It inherits both points' warnings (including the walls that located them), the target wall's
/// status for point-to-wall quantities, and the reference wall's status only when the compared
/// quantity is along-wall distance. A negative height above ground adds `belowGround`.
public func measurementWarnings(
    from: PointEvidence,
    to: PointEvidence?,
    targetWall: WallStatus?,
    referenceWall: WallStatus?,
    compared: MeasuredQuantity,
    value: Double
) -> [MeasurementWarning] {
    var result = from.warnings + (to?.warnings ?? []) + (targetWall?.warnings ?? [])
    if compared == .alongWall, let referenceWall {
        result += referenceWall.warnings
    }
    if compared == .heightAboveGround, value < 0 {
        result.append(.belowGround)
    }
    return normalized(result)
}

/// Sorted and without repeats, so equal sets compare and encode the same way.
func normalized(_ warnings: [MeasurementWarning]) -> [MeasurementWarning] {
    Array(Set(warnings)).sorted()
}
