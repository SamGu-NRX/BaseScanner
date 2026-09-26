import Testing
@testable import MeasureGeometry

struct WarningsTests {
    // Regression for review defect 1: a wall point took only its own flags, so a point on a wall
    // whose first contact looked down too shallowly was recorded as accepted.
    @Test func `a wall point inherits its wall's contact warnings`() {
        let wall = WallStatus(contactWarnings: [[.shallowLookDown], []], validations: [true])
        let point = PointEvidence(own: [], wall: wall)
        #expect(point.warnings == [.wallContactWarning])
    }

    @Test func `a failed validation reaches later wall points`() {
        let wall = WallStatus(contactWarnings: [[], []], validations: [false])
        #expect(PointEvidence(own: [], wall: wall).warnings == [.wallValidationFailed])
        // A second, passing check does not clear the failure.
        let rechecked = WallStatus(contactWarnings: [[], []], validations: [false, true])
        #expect(rechecked.warnings == [.wallValidationFailed])
    }

    @Test func `a wall status lists its own qualification`() {
        #expect(WallStatus(contactWarnings: [[], []], validations: [true]).warnings.isEmpty)
        #expect(WallStatus(contactWarnings: [[], []], validations: []).warnings == [.wallNotValidated])
        #expect(
            WallStatus(contactWarnings: [[.estimatedPlane], [.extendedPlane]], validations: [])
                .warnings == [.wallContactWarning, .wallNotValidated]
        )
    }

    @Test func `point warnings combine own and wall, sorted, without repeats`() {
        let wall = WallStatus(contactWarnings: [[.shallowLookDown], []], validations: [false])
        let point = PointEvidence(own: [.outsideWallContacts, .outsideWallContacts], wall: wall)
        #expect(point.warnings == [.outsideWallContacts, .wallContactWarning, .wallValidationFailed])
    }

    @Test func `a measurement inherits both points and the walls behind them`() {
        let flaggedWall = WallStatus(contactWarnings: [[.shallowLookDown], []], validations: [true])
        let warnings = measurementWarnings(
            from: PointEvidence(own: [], wall: flaggedWall),
            to: PointEvidence(own: [.estimatedPlane]),
            targetWall: nil,
            referenceWall: nil,
            compared: .horizontal,
            value: 1.2
        )
        #expect(warnings == [.estimatedPlane, .wallContactWarning])
    }

    @Test func `the reference wall matters only for along-wall distance`() {
        let unvalidated = WallStatus(contactWarnings: [[], []], validations: [])
        let clean = PointEvidence(own: [])
        #expect(measurementWarnings(
            from: clean, to: clean, targetWall: nil, referenceWall: unvalidated, compared: .horizontal, value: 2
        ).isEmpty)
        #expect(measurementWarnings(
            from: clean, to: clean, targetWall: nil, referenceWall: unvalidated, compared: .alongWall, value: 2
        ) == [.wallNotValidated])
    }

    @Test func `a point-to-wall measurement inherits the target wall`() {
        let failed = WallStatus(contactWarnings: [[], []], validations: [false])
        #expect(measurementWarnings(
            from: PointEvidence(own: []), to: nil, targetWall: failed, referenceWall: nil, compared: .gapToWall, value: 1
        ) == [.wallValidationFailed])
    }

    // Regression for review defect 3, second half: a negative height must not pass as accepted.
    @Test func `a negative height above ground is flagged`() {
        let good = WallStatus(contactWarnings: [[], []], validations: [true])
        let clean = PointEvidence(own: [])
        #expect(measurementWarnings(
            from: clean, to: nil, targetWall: good, referenceWall: nil, compared: .heightAboveGround, value: -1
        ) == [.belowGround])
        #expect(measurementWarnings(
            from: clean, to: nil, targetWall: good, referenceWall: nil, compared: .heightAboveGround, value: 1
        ).isEmpty)
    }
}
