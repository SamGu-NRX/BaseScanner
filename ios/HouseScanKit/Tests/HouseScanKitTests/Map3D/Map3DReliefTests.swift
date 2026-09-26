import Foundation
import HouseScanKit
import simd
import Testing

// A facade with pilasters 0.36 m proud (ETH3D electro's), walked with up to 2 cm of depth error.
// The wall behind a pilaster can't be seen from anywhere and nothing can be mounted there: the
// pilaster's own face covers it. A freestanding hedge with a gap behind it does not.
@Suite struct Map3DReliefTests {
    static let wall = standardWall()
    static let scene = pilasterScene()
    static let map: Map3D = {
        var map = Map3D(frame: sceneFrame())
        for (index, camera) in pilasterWalk().enumerated() { map.integrate(scene.depthFrame(from: camera, noise: 0.02, seed: UInt64(index))) }
        return map
    }()

    static func covers(_ map: Map3D, _ spans: [ClosedRange<Float>], _ index: Int) -> Bool {
        let middle = (map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2
        return spans.contains { $0.contains(middle) }
    }

    /// Every cell between the first and last pilaster is seen, those behind pilasters included:
    /// no view can exist of the wall behind them, so a request for one could never be met.
    @Test func wallBehindPilastersIsCoveredByTheirFaces() {
        let coverage = Self.map.coverage(along: Self.wall)
        let cells = Self.map.cellIndices.filter { Self.map.cellRange($0).lowerBound >= -4.25 && Self.map.cellRange($0).upperBound <= 5.75 }
        let unseen = cells.filter { !Self.covers(Self.map, coverage.wall, $0) }
        #expect(unseen.isEmpty, "unseen cells \(unseen.map { Self.map.cellRange($0) })")
    }

    /// Every claimed wall sample has a truly visible facade surface, wall face or pilaster face,
    /// straight out from it (within a voxel).
    @Test func everyClaimedSampleHasAVisibleFacadeFace() {
        let coverage = Self.map.coverage(along: Self.wall)
        let cameras = pilasterWalk()
        for index in Self.map.cellIndices where Self.covers(Self.map, coverage.wall, index) {
            let range = Self.map.cellRange(index)
            for s in [range.lowerBound + 0.03, range.upperBound - 0.03] {
                for height: Float in [0.3, 1.0, 1.9] {
                    let visible = [Float(0), 0.36].contains { out in
                        [Float(-0.1), 0, 0.1].contains { ds in
                            let p = SIMD3(s + ds, height, out + 1e-3)
                            return Self.scene.intersect(origin: p + SIMD3(0, 0, 0.01), direction: SIMD3(0, 0, -1)).map { $0.t < 0.02 } == true
                                && cameras.contains { Self.scene.isVisible(p, normal: SIMD3(0, 0, 1), from: $0) }
                        }
                    }
                    #expect(visible, "cell \(index) s \(s) h \(height) claimed without a visible face")
                }
            }
        }
    }

    /// The wall's line runs along the face, not between face and pilasters: within 0.5 degrees
    /// and 3 cm at the meter, with an error bar that covers that and is not wildly larger.
    @Test func wallLineFollowsTheFaceNotThePilasters() throws {
        let chain = try #require(Self.map.measuredWalls())
        let piece = chain.walls[chain.meterIndex]
        let angle = abs(atan2(piece.along.y, piece.along.x)) * 180 / .pi
        #expect(angle < 0.5, "angle \(angle) degrees")
        let offset = simd_dot(SIMD2<Float>.zero - piece.start, piece.outward)
        #expect(abs(offset) < 0.03, "line \(offset) m off the face at the meter")
        #expect(piece.plusMinus >= abs(offset) && piece.plusMinus <= 0.2, "plus or minus \(piece.plusMinus)")
        #expect(abs(piece.length - 12) < 0.3, "length \(piece.length)")
    }

    /// A hedge 2.5 m tall standing 0.25 to 0.45 m out, with the gap behind it seen from the side:
    /// it is not part of the facade, so the wall behind it is not seen.
    @Test func aFreestandingHedgeWithAGapIsNotRelief() {
        let hedge = SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(7, 0))],
            boxes: [SyntheticScene.Box(min: SIMD3(1, 0, 0.25), max: SIMD3(2, 2.5, 0.45))])
        var map = Map3D(frame: sceneFrame())
        let side = [SIMD3<Float>(3.2, 1.2, 0.35), SIMD3(-0.2, 1.2, 0.35)].map { lidarCamera(at: $0, lookingAt: SIMD3(1.5, 1.0, 0.1)) }
        for (index, camera) in (pilasterWalk() + side).enumerated() { map.integrate(hedge.depthFrame(from: camera, seed: UInt64(index))) }
        let coverage = map.coverage(along: Self.wall)
        for index in map.cellIndices where map.cellRange(index).lowerBound >= 1.2 && map.cellRange(index).upperBound <= 1.8 {
            #expect(!Self.covers(map, coverage.wall, index), "cell \(index) behind the hedge claimed seen")
        }
    }

    /// Stone cladding 12 cm proud and 1.3 m tall along the right two thirds of a 9.4 m wall
    /// (30.8 ft, electro's length): the line still runs on the wall's face. A least-squares
    /// line through face and cladding tilts toward the cladding's end.
    @Test func claddingAlongPartOfTheWallDoesNotTiltItsLine() throws {
        let scene = SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-3, 0), b: SIMD2(6.4, 0))],
            boxes: [SyntheticScene.Box(min: SIMD3(0.4, 0, 0), max: SIMD3(6.4, 1.3, 0.12))])
        var map = Map3D(frame: sceneFrame())
        let cameras = Swift.stride(from: Float(-2.5), through: 6, by: 0.3).flatMap { x in
            [Float(0), -1.4, 1.4].map { dx in lidarCamera(at: SIMD3(x, 1.4, 2.5), lookingAt: SIMD3(x + dx, 1.0, 0)) }
        }
        for (index, camera) in cameras.enumerated() { map.integrate(scene.depthFrame(from: camera, noise: 0.02, seed: UInt64(index))) }
        let chain = try #require(map.measuredWalls())
        let piece = chain.walls[chain.meterIndex]
        let angle = abs(atan2(piece.along.y, piece.along.x)) * 180 / .pi
        let offset = simd_dot(SIMD2<Float>.zero - piece.start, piece.outward)
        #expect(angle < 0.3, "angle \(angle) degrees")
        #expect(abs(offset) < 0.03, "line \(offset) m off the face at the meter")
    }

    /// A box 0.3 m proud mounted on the wall from 1.0 to 1.5 m up: the wall is seen up to just
    /// below it, and the rest of the wall up to the top of the map. Pilasters' faces carry the
    /// height on up.
    @Test func wallHeightStopsBelowABoxOnTheWall() {
        let scene = SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(7, 0))],
            boxes: [SyntheticScene.Box(min: SIMD3(1, 1.0, 0), max: SIMD3(2, 1.5, 0.3))])
        var map = Map3D(frame: sceneFrame())
        for (index, camera) in pilasterWalk().enumerated() { map.integrate(scene.depthFrame(from: camera, noise: 0.02, seed: UInt64(index))) }
        for index in map.cellIndices {
            let range = map.cellRange(index)
            let height = map.wallHeight(cell: index, along: Self.wall)
            if range.lowerBound >= 1.2, range.upperBound <= 1.8 {
                #expect(height.map { $0 >= 0.8 && $0 < 1.0 } == true, "cell \(index) seen to \(height ?? -1)")
            }
            if range.lowerBound >= -2, range.upperBound <= 0.6 {
                #expect((height ?? 0) >= 2.3, "cell \(index) seen to \(height ?? -1)")
            }
        }
        let behind = Self.map.cellIndices.filter { Self.map.cellRange($0).lowerBound >= -4.2 && Self.map.cellRange($0).upperBound <= -3.8 }
        #expect(behind.allSatisfy { (Self.map.wallHeight(cell: $0, along: Self.wall) ?? 0) >= 2.3 })
    }
}

