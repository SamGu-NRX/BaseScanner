import Foundation
import HouseScanKit
import Testing
import simd

// A wall chain on the standard wall (face z = 0, outward +z, meter at s = 0). Right of the meter
// the house ends at x = 3: the wall turns away from the homeowner (an outside corner) and runs on
// toward -z facing +x, so s = 3 + distance along it. Left of the meter it meets a wall at x = -2
// that faces +x and runs toward +z (an inside corner), so s = -2 - distance along it.

/// The standard wall with the right corner followed.
func rightCornerWall() throws -> WallFrame {
    var wall = standardWall()
    wall.turn(.right, at: try wall.corner(on: .right, meeting: SIMD3(3, 1.2, -2), outward: SIMD3(1, 0, 0)))
    return wall
}

@Suite struct WallChainTests {
    @Test func cornerIsWhereTheWallLinesMeet() throws {
        let wall = standardWall()
        let right = try wall.corner(on: .right, meeting: SIMD3(3, 1.2, -2), outward: SIMD3(1, 0, 0))
        #expect(nearlyEqual(right.s, 3) && right.outward == SIMD3(1, 0, 0))
        // The marked point's height and its distance from the corner don't move the corner.
        let far = try wall.corner(on: .right, meeting: SIMD3(3, 2.5, -4), outward: SIMD3(2, 0.3, 0))
        #expect(nearlyEqual(far.s, 3) && far.outward == SIMD3(1, 0, 0))
        let left = try wall.corner(on: .left, meeting: SIMD3(-2, 1, 1.5), outward: SIMD3(1, 0, 0))
        #expect(nearlyEqual(left.s, -2))
    }

    @Test func cornerRefusals() {
        let wall = standardWall()
        // 11 degrees off the wall: more likely the same wall than the next one.
        #expect(throws: CornerRefusal.nearlyParallel) { try wall.corner(on: .right, meeting: SIMD3(3, 1, 1), outward: SIMD3(0.2, 0, 1)) }
        // A floor.
        #expect(throws: CornerRefusal.notAWall) { try wall.corner(on: .right, meeting: SIMD3(3, 0, 1), outward: SIMD3(0, 1, 0)) }
        // The marked point lies in front of the corner, on the wrong side of it for the next wall.
        #expect(throws: CornerRefusal.implausible(s: 3)) { try wall.corner(on: .right, meeting: SIMD3(3, 1, 2), outward: SIMD3(1, 0, 0)) }
        // The lines meet left of the meter, so it can't be a right corner.
        #expect(throws: CornerRefusal.implausible(s: -1)) { try wall.corner(on: .right, meeting: SIMD3(-1, 1, -2), outward: SIMD3(1, 0, 0)) }
    }

    @Test func worldAndWallPointRoundTripAcrossTheChain() throws {
        var wall = try rightCornerWall()
        wall.turn(.left, at: try wall.corner(on: .left, meeting: SIMD3(-2, 1, 1.5), outward: SIMD3(1, 0, 0)))
        #expect(wall.segments.count == 3 && wall.meterSegmentIndex == 1)
        #expect(wall.segments.map(\.span.lowerBound) == [-.infinity, -2, 3])

        // (s, height, out) -> world, by hand from the layout above.
        let cases: [(WallPoint, SIMD3<Float>)] = [
            (WallPoint(s: 1, height: 0.5, out: 2), SIMD3(1, 0.5, 2)),
            (WallPoint(s: 4, height: 1, out: 0.5), SIMD3(3.5, 1, -1)),
            (WallPoint(s: 6, height: 0, out: 1), SIMD3(4, 0, -3)),
            (WallPoint(s: -3, height: 0, out: 0.5), SIMD3(-1.5, 0, 1)),
        ]
        for (point, world) in cases {
            #expect(nearlyEqual(wall.world(point), world), "\(point)")
            let back = wall.wallPoint(world)
            #expect(nearlyEqual(back.s, point.s) && nearlyEqual(back.height, point.height) && nearlyEqual(back.out, point.out), "\(point) -> \(back)")
        }
        // Continuous at each corner.
        #expect(nearlyEqual(wall.world(s: 3 - 1e-4, height: 0), wall.world(s: 3 + 1e-4, height: 0), 1e-3))
        #expect(nearlyEqual(wall.world(s: -2 - 1e-4, height: 0), wall.world(s: -2 + 1e-4, height: 0), 1e-3))
        // Outside the outer corner, in front of neither piece, a point maps to the corner.
        let outside = wall.wallPoint(SIMD3(4, 1, 1))
        #expect(nearlyEqual(outside.s, 3) && nearlyEqual(outside.out, 1))
    }

    @Test func aStraightWallIsOneUnboundedPiece() {
        let wall = standardWall()
        #expect(wall.segments.count == 1 && wall.meterSegmentIndex == 0)
        #expect(wall.segments[0].span == -Float.infinity...Float.infinity)
        #expect(wall.segments[0].along == wall.along && wall.segments[0].outward == wall.outward)
    }

    @Test func raysMeetThePieceTheyReach() throws {
        let wall = try rightCornerWall()
        // Round the corner, facing the second wall: (5, 1.2, -1) toward -x meets x = 3 at s = 4.
        let round = try #require(wall.intersectWall(Ray(origin: SIMD3(5, 1.2, -1), direction: SIMD3(-1, 0, 0))))
        #expect(nearlyEqual(round.s, 4) && nearlyEqual(round.height, 1.2) && nearlyEqual(round.out, 0))
        let front = try #require(wall.intersectWall(Ray(origin: SIMD3(1, 1, 2), direction: SIMD3(0, 0, -1))))
        #expect(nearlyEqual(front.s, 1))
        // The first wall's plane past the corner is air.
        #expect(wall.intersectWall(Ray(origin: SIMD3(4, 1, 2), direction: SIMD3(0, 0, -1))) == nil)
    }
}

@Suite struct CoverageAcrossCornersTests {
    /// Level cameras 2 m out from the second wall at s = c, facing it, their right along +s: the
    /// `wallCamera` view turned round the corner, so each sees wall samples with |s - c| <= 0.9024.
    func roundCornerCamera(s c: Float) -> CameraFrame {
        makeCamera(at: SIMD3(5, 1.2, 3 - c), forward: SIMD3(-1, 0, 0), right: SIMD3(0, 0, -1))
    }

    @Test func eachPieceIsCoveredFromInFrontOfIt() throws {
        var map = CoverageMap(wall: try rightCornerWall())
        for camera in [wallCamera(s: 2.0), wallCamera(s: 2.4), roundCornerCamera(s: 4.4), roundCornerCamera(s: 4.8)] {
            map.observe(camera, trackingNormal: true)
        }
        // wallCamera: a cell with lower edge L is covered when both cameras are within
        // [L - 0.7881, L + 0.9405], so L runs over cells 10...18 in front of the meter's wall and
        // 26...34 round the corner. The cell across the corner (19) has a sample on each wall.
        let covered = map.coveredIntervals(.wall)
        #expect(covered.count == 2)
        #expect(nearlyEqual(covered[0], 1.524...2.8956, 1e-3))
        #expect(nearlyEqual(covered[1], 3.9624...5.334, 1e-3))
        // Standing behind the first wall's plane, the round-corner cameras see none of a straight wall.
        var straight = CoverageMap(wall: standardWall())
        straight.observe(roundCornerCamera(s: 4.4), trackingNormal: true)
        straight.observe(roundCornerCamera(s: 4.8), trackingNormal: true)
        #expect(straight.coveredIntervals(.wall).isEmpty)
    }

    @Test func turningACornerReplaysTheWalkAgainstTheNewWall() throws {
        var map = CoverageMap(wall: standardWall())
        // The walk's view carried on past the corner along the first wall's plane, into the air.
        for s: Float in [2.0, 2.4, 3.6, 4.0] { map.observe(wallCamera(s: s), trackingNormal: true) }
        #expect(map.coveredIntervals(.wall).contains { $0.upperBound > 3.5 })
        map.setEnd(.right, at: 3.1)

        // A marked wall whose corner is 3.9 m from the marked end is some other wall.
        #expect(throws: CornerRefusal.implausible(s: 7)) { try map.turnCorner(.right, meeting: SIMD3(7, 1, -2), outward: SIMD3(1, 0, 0)) }
        #expect(map.rightEnd == 3.1 && map.wall.rightCorners.isEmpty)

        let corner = try map.turnCorner(.right, meeting: SIMD3(3, 1.2, -2), outward: SIMD3(1, 0, 0))
        #expect(nearlyEqual(corner.s, 3))
        #expect(map.rightEnd == nil && map.wall.rightCorners == [corner])
        // Past the corner the same views look along the new wall, not at it.
        #expect(map.coveredIntervals(.wall).allSatisfy { $0.upperBound <= 3.05 })
        #expect(!map.coveredIntervals(.wall).isEmpty)
    }

    @Test func movingTheMeterKeepsCornersInPlace() throws {
        var map = CoverageMap(wall: try rightCornerWall())
        var moved = map.wall
        moved.meter = SIMD3(0.5, 1.5, 0)
        map.updateWall(moved)
        // Like the ends, the corner's s moves by -0.5 so it stays at x = 3.
        #expect(nearlyEqual(map.wall.rightCorners[0].s, 2.5))
        #expect(nearlyEqual(map.wall.world(s: 2.5, height: 0), SIMD3(3, 0, 0)))
        #expect(nearlyEqual(map.wall.world(s: 3.5, height: 0), SIMD3(3, 0, -1)))
    }
}

@Suite struct ChainExportTests {
    typealias Value = JSONSchemaValidator.Value

    static let corners = (
        left: [WallCorner(s: -2, outward: SIMD3(1, 0, 0))],
        right: [WallCorner(s: 3, outward: SIMD3(1, 0, 0))]
    )

    static let wall = SceneWall(
        meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0,
        leftCorners: corners.left, rightCorners: corners.right)

    static func input() -> SceneInput {
        let w = wall
        return SceneInput(
            wall: w, baselineS: -4...6, wallHeight: 2.7,
            features: [
                .opening(kind: .window, span: 4...5, bottom: 0.9, top: 2.0, operable: false),
                .pointObject(kind: .gasMeter, tap: w.world(s: -3, height: 0.5, out: 0.25), bottom: nil, top: nil),
                .fence(foot: [w.world(s: 0.5, height: 0, out: 2), w.world(s: 1.5, height: 0, out: 2)]),
            ],
            coverage: SceneCoverage(
                leftEndMarked: false, rightEndMarked: true, wall: [-4...6],
                ground: [ObservedSpan(span: -4...6, out: 1.2)], facing: [ObservedSpan(span: 2...4, out: 1.5)]))
    }

    @Test func sceneWallMatchesTheWallFrame() throws {
        var frame = try rightCornerWall()
        frame.turn(.left, at: try frame.corner(on: .left, meeting: SIMD3(-2, 1, 1.5), outward: SIMD3(1, 0, 0)))
        let scene = SceneWall(meter: frame.meter, outward: frame.outward, groundY: frame.groundY, leftCorners: frame.leftCorners, rightCorners: frame.rightCorners)
        // Off the corners themselves, where a point off the wall is in front of both pieces or neither.
        for s: Float in [-3.5, -0.5, 0, 2.5, 4.5] {
            #expect(nearlyEqual(scene.world(s: s, height: 0.4, out: 0.7), frame.world(s: s, height: 0.4, out: 0.7)), "s = \(s)")
            let c = scene.wallCoordinates(of: frame.world(s: s, height: 0.4, out: 0.7))
            #expect(nearlyEqual(c.s, s) && nearlyEqual(c.out, 0.7), "s = \(s)")
        }
    }

    @Test func oneWallPerPieceContinuousAtEachCorner() throws {
        let data = try SceneExport.jsonData(Self.input())
        #expect(try SceneSchemas.scene().validate(data) == [])
        let v = try Value.parse(data)
        let walls = try #require(v["walls"]?.array)
        #expect(walls.map { $0["id"] } == [.string("wall-left-1"), .string("wall"), .string("wall-right-1")])
        let baselines = walls.map { $0["baseline"]?.array?.map { $0.numbers ?? [] } ?? [] }
        // s = -4 is (-2, 0, 2) m, the corners are (-2, 0, 0) and (3, 0, 0), s = 6 is (3, 0, -3).
        #expect(baselines == [
            [[-6.5617, 6.5617], [-6.5617, 0]],
            [[-6.5617, 0], [9.8425, 0]],
            [[9.8425, 0], [9.8425, -9.8425]],
        ])
        #expect(v["meter"]?["wall_id"] == .string("wall"))

        let objects = try #require(v["objects"]?.array)
        #expect(objects.map { $0["wall_id"] } == [.string("wall-right-1"), .string("wall-left-1")])
        // Spans keep s along the whole chain: 4...5 m and -3.15...-2.85 m.
        #expect(objects[0]["span_ft"]?.numbers == [13.1234, 16.4042])
        #expect(objects[1]["span_ft"]?.numbers == [-10.3346, -9.3504])
        #expect(v["facing"]?[0]?["wall_id"] == .string("wall"))
    }

    @Test func cornersMustRunOutwardFromTheMeter() {
        var input = Self.input()
        input.wall.rightCorners = [WallCorner(s: -1, outward: SIMD3(1, 0, 0))]
        #expect(throws: SceneExportError.cornersOutOfOrder([-2, -1])) { try SceneExport.jsonData(input) }
        input.wall.rightCorners = [WallCorner(s: 3, outward: SIMD3(2, 0, 0))]
        #expect(throws: SceneExportError.outwardNotUnitHorizontal(SIMD3(2, 0, 0))) { try SceneExport.jsonData(input) }
    }
}
