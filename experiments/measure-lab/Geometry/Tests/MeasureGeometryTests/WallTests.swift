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
