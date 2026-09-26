import Foundation
import Testing
@testable import MeasureGeometry

struct WallTests {
    /// A 4 m wall along +x at ground height 0, seen from z = +3.
    let camera = SIMD3<Double>(2, 1.5, 3)
    var wall: Wall {
        get throws { try Wall(contact1: SIMD3(0, 0, 0), contact2: SIMD3(4, 0, 0), cameraPosition: camera) }
    }

    @Test func `direction and normal from two contacts`() throws {
        let wall = try wall
        #expect(wall.direction == SIMD3(1, 0, 0))
        // u × g = (1, 0, 0) × (0, 1, 0) = (0, 0, 1), which already points toward the camera.
        #expect(wall.normal == SIMD3(0, 0, 1))
        #expect(wall.length == 4)
    }

    @Test func `normal flips to face the camera`() throws {
        let wall = try Wall(contact1: SIMD3(0, 0, 0), contact2: SIMD3(4, 0, 0), cameraPosition: SIMD3(2, 1.5, -3))
        #expect(wall.normal == SIMD3(0, 0, -1))
        #expect(wall.direction == SIMD3(1, 0, 0))
    }

    @Test func `diagonal wall`() throws {
        // Horizontal run (3, 0, 4) has length 5, so u = (0.6, 0, 0.8) and
        // u × g = (−0.8, 0, 0.6); the camera at (0, 1.5, 5) gives n·o = 3 > 0.
        let wall = try Wall(contact1: SIMD3(0, 0, 0), contact2: SIMD3(3, 0, 4), cameraPosition: SIMD3(0, 1.5, 5))
        #expect(isClose(wall.direction, SIMD3(0.6, 0, 0.8)))
        #expect(isClose(wall.normal, SIMD3(-0.8, 0, 0.6)))
        #expect(isClose(wall.length, 5))
    }

    @Test func `contacts must be two meters apart horizontally`() {
        #expect(throws: WallError.contactsTooClose(separation: 1.5, minimum: 2)) {
            try Wall(contact1: .zero, contact2: SIMD3(1.5, 0, 0), cameraPosition: camera)
        }
        // The 3D distance is over 2 m, but the horizontal part is only about 1.91 m.
        let error = #expect(throws: WallError.self) {
            try Wall(contact1: .zero, contact2: SIMD3(1.9, 0.5, 0.2), cameraPosition: camera)
        }
        guard case .contactsTooClose(let separation, 2)? = error else {
            Issue.record("Expected contactsTooClose, got \(String(describing: error))")
            return
        }
        #expect(isClose(separation, (1.9 * 1.9 + 0.2 * 0.2).squareRoot()))
        // Vertically stacked contacts have no horizontal run at all.
        #expect(throws: WallError.contactsTooClose(separation: 0, minimum: 2)) {
            try Wall(contact1: .zero, contact2: SIMD3(0, 1, 0), cameraPosition: camera)
        }
        #expect(throws: Never.self) {
            try Wall(contact1: .zero, contact2: SIMD3(2, 0, 0), cameraPosition: camera)
        }
    }

    @Test func `camera standing in the wall plane is refused`() {
        #expect(throws: WallError.cameraInWallPlane(offset: 0.05, minimum: 0.1)) {
            try Wall(contact1: .zero, contact2: SIMD3(4, 0, 0), cameraPosition: SIMD3(6, 1.5, 0.05))
        }
    }

    @Test func `along-wall position, offset and gap`() throws {
        let wall = try wall
        #expect(wall.along(SIMD3(1, 5, 3)) == 1)
        #expect(wall.alongDistance(from: SIMD3(1, 5, 3), to: SIMD3(3.5, 0, -2)) == 2.5)
        #expect(wall.alongDistance(from: SIMD3(3.5, 0, -2), to: SIMD3(1, 5, 3)) == -2.5)
        #expect(wall.offset(of: SIMD3(2, 0, 1.5)) == 1.5)
        #expect(wall.offset(of: SIMD3(2, 0, -0.5)) == -0.5)
        #expect(wall.gap(to: SIMD3(2, 0, -0.5)) == 0.5)
        // The gap ignores height and position along the wall.
        #expect(wall.gap(to: SIMD3(-7, 9, 1.25)) == 1.25)
    }

    @Test func `facing gap from a diagonal wall`() throws {
        let wall = try Wall(contact1: SIMD3(0, 0, 0), contact2: SIMD3(3, 0, 4), cameraPosition: SIMD3(0, 1.5, 5))
        // n = (−0.8, 0, 0.6): the point (−0.8, 0.3, 0.6) + 0.5·u sits 1 m in front of the wall.
        let fencePost = SIMD3<Double>(-0.8, 0.3, 0.6) + SIMD3(0.6, 0, 0.8) * 0.5
        #expect(isClose(wall.gap(to: fencePost), 1))
        #expect(isClose(wall.along(fencePost), 0.5))
    }

    @Test func `height above a sloping ground line`() throws {
        // The ground rises 0.4 m over the 4 m wall.
        let wall = try Wall(contact1: SIMD3(0, 0, 0), contact2: SIMD3(4, 0.4, 0), cameraPosition: camera)
        #expect(isClose(wall.groundHeight(atAlong: 2), 0.2))
        #expect(isClose(wall.heightAboveGround(SIMD3(2, 1.2, 0)), 1.0))
        // Beyond the second contact the line is extended and flagged.
        #expect(isClose(wall.groundHeight(atAlong: 6), 0.6))
        #expect(wall.containsAlong(4))
        #expect(!wall.containsAlong(6))
        #expect(!wall.containsAlong(-0.01))
    }

    // A wall that is translated, rotated and on sloped ground, so dropping the ground line's
    // intercept or the plane's offset from the origin changes every answer below.
    // Contacts (1, 0.3, 2) and (4, 0.9, 6): horizontal run (3, 0, 4), length 5, u = (0.6, 0, 0.8),
    // n = u × g = (−0.8, 0, 0.6), ground rising 0.6 m over the wall. The camera stands 3 m out
    // along n and 1.5 m up from the first contact.
    let offsetWallStart = SIMD3<Double>(1, 0.3, 2)
    let offsetCamera = SIMD3<Double>(1, 0.3, 2) + SIMD3(-0.8, 0, 0.6) * 3 + SIMD3(0, 1.5, 0)
    var offsetWall: Wall {
        get throws { try Wall(contact1: offsetWallStart, contact2: SIMD3(4, 0.9, 6), cameraPosition: offsetCamera) }
    }

    @Test func `sloped ground line off the origin`() throws {
        let wall = try offsetWall
        #expect(isClose(wall.normal, SIMD3(-0.8, 0, 0.6)))
        #expect(isClose(wall.length, 5))
        // Halfway along, the ground is 0.3 + 0.6 · 2.5 / 5 = 0.6.
        #expect(isClose(wall.groundHeight(atAlong: 2.5), 0.6))
        #expect(isClose(wall.groundHeight(atAlong: 0), 0.3))
        #expect(isClose(wall.groundHeight(atAlong: 5), 0.9))
        // A point on the wall 2.5 m along at y = 1.9 is 1.3 m above the ground there.
        let point = offsetWallStart + SIMD3(0.6, 0, 0.8) * 2.5 + SIMD3(0, 1.6, 0)
        #expect(isClose(wall.along(point), 2.5))
        #expect(isClose(wall.offset(of: point), 0))
        #expect(isClose(wall.heightAboveGround(point), 1.3))
        #expect(isClose(wall.offset(of: offsetCamera), 3))
    }

    @Test func `ray meets a translated, rotated wall plane`() throws {
        let wall = try offsetWall
        // Aim at (2.5, 1.5, 4), which is 2.5 m along the wall: n·((2.5, 1.5, 4) − (1, 0.3, 2)) = 0.
        // From the camera at (−1.4, 1.8, 3.8) the direction is (3.9, −0.3, 0.2), with n·d = −3.
        let target = SIMD3<Double>(2.5, 1.5, 4)
        #expect(isClose(offsetCamera, SIMD3(-1.4, 1.8, 3.8)))
        let hit = try wall.intersect(try Ray(origin: offsetCamera, direction: SIMD3(3.9, -0.3, 0.2)))
        #expect(isClose(hit.point, target))
        #expect(isClose(hit.range, 15.34.squareRoot()))
        #expect(isClose(hit.angleFromNormal, acos(3 / 15.34.squareRoot()) * 180 / .pi))
        #expect(isClose(hit.along, 2.5))
        // Ground at 2.5 m along is 0.6, so the target is 0.9 m up.
        #expect(isClose(hit.heightAboveGround, 0.9))
        #expect(hit.withinContacts)
    }

    @Test func `third contact validates the plane within two inches`() throws {
        let wall = try wall
        let close = wall.validate(contact: SIMD3(3, 0, 0.04))
        #expect(isClose(close.residual, 0.04))
        #expect(close.tolerance == 0.0508)
        #expect(close.passes)
        let far = wall.validate(contact: SIMD3(3, 0, -0.06))
        #expect(isClose(far.residual, 0.06))
        #expect(!far.passes)
    }

    @Test func `ray meets the wall plane`() throws {
        let wall = try wall
        // From the camera toward (1, 1, 0): direction (−1, −0.5, −3), length √10.25.
        let ray = try Ray(origin: camera, direction: SIMD3(-1, -0.5, -3))
        let hit = try wall.intersect(ray)
        #expect(isClose(hit.point, SIMD3(1, 1, 0)))
        #expect(isClose(hit.range, 10.25.squareRoot()))
        // cos θ = 3 / √10.25.
        #expect(isClose(hit.angleFromNormal, acos(3 / 10.25.squareRoot()) * 180 / .pi))
        #expect(isClose(hit.along, 1))
        #expect(isClose(hit.heightAboveGround, 1))
        #expect(hit.withinContacts)
    }

    @Test func `hit beyond the contacts is flagged`() throws {
        let hit = try wall.intersect(try Ray(origin: camera, direction: SIMD3(3, 0, -3)))
        #expect(isClose(hit.point, SIMD3(5, 1.5, 0)))
        #expect(isClose(hit.along, 5))
        #expect(!hit.withinContacts)
    }

    @Test(arguments: [59.0, 45.0, 0.0])
    func `rays within sixty degrees of the normal are accepted`(angle: Double) throws {
        let r = angle * .pi / 180
        let hit = try wall.intersect(try Ray(origin: camera, direction: SIMD3(sin(r), 0, -cos(r))))
        #expect(isClose(hit.angleFromNormal, angle, within: 1e-7))
        #expect(isClose(hit.range, 3 / cos(r)))
    }

    @Test func `grazing rays are refused`() throws {
        // |n·d| = 0.5 / √1.25 ≈ 0.447, below cos 60° = 0.5: atan(2) ≈ 63.4° from the normal.
        let grazing = try Ray(origin: camera, direction: SIMD3(1, 0, -0.5))
        try expectGrazing(try wall, grazing, angle: atan(2) * 180 / .pi)
        let r = 61 * Double.pi / 180
        try expectGrazing(try wall, try Ray(origin: camera, direction: SIMD3(sin(r), 0, -cos(r))), angle: 61)
        // Parallel to the wall: 90° from the normal, refused before any division by n·d = 0.
        try expectGrazing(try wall, try Ray(origin: camera, direction: SIMD3(1, 0, 0)), angle: 90)
    }

    private func expectGrazing(_ wall: Wall, _ ray: Ray, angle expected: Double) throws {
        let error = #expect(throws: WallHitError.self) { try wall.intersect(ray) }
        guard case .grazing(let angle, let maximum)? = error else {
            Issue.record("Expected a grazing refusal, got \(String(describing: error))")
            return
        }
        #expect(isClose(angle, expected, within: 1e-7))
        #expect(maximum == 60)
    }

    @Test func `intersections behind the camera are refused`() throws {
        let away = try Ray(origin: camera, direction: SIMD3(0, 0, 1))
        #expect(throws: WallHitError.behindCamera(t: -3)) {
            try wall.intersect(away)
        }
    }
}
