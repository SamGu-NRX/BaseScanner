import Foundation
import HouseScanKit
import simd
import Testing

// The bush scene (SyntheticScene.swift): a straight wall with a bush 0.9 m tall standing 0.4 to
// 1.0 m in front of it between s = 1 and 2, walked every 0.3 m at 2.5 m out, depth off by up to
// 2 cm. Every coverage claim is checked against exact ray casting of the scene from the same
// cameras.
@Suite struct Map3DOcclusionTests {
    static let scene = bushScene()
    static let cameras = bushWalk()
    static let map: Map3D = {
        var map = Map3D(frame: sceneFrame())
        for (index, camera) in cameras.enumerated() {
            map.integrate(scene.depthFrame(from: camera, noise: 0.02, seed: UInt64(index)))
        }
        return map
    }()
    static let wall = standardWall()
    static let coverage = map.coverage(along: wall)

    /// Whether any point within a voxel (0.1 m) of `point` along the two directions `u` and `v`
    /// on its surface is truly visible from some camera: the resolution coverage is judged at.
    static func nearlyVisible(_ point: SIMD3<Float>, normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) -> Bool {
        for du: Float in [-0.1, 0, 0.1] {
            for dv: Float in [-0.1, 0, 0.1] {
                let p = point + u * du + v * dv + normal * 1e-3
                if cameras.contains(where: { scene.isVisible(p, normal: normal, from: $0) }) { return true }
            }
        }
        return false
    }

    static func wallSamples(_ index: Int) -> [SIMD3<Float>] {
        let range = map.cellRange(index)
        let width = range.upperBound - range.lowerBound
        let heights = Array(Swift.stride(from: Float(0.1), to: 1.9812, by: 0.2)) + [1.9812]
        return [0.25, 0.75].flatMap { f in heights.map { SIMD3(range.lowerBound + f * width, $0, 0) } }
    }

    static func covers(_ spans: [ClosedRange<Float>], _ index: Int) -> Bool {
        let middle = (map.cellRange(index).lowerBound + map.cellRange(index).upperBound) / 2
        return spans.contains { $0.contains(middle) }
    }

    @Test func everySeenWallCellWasTrulyVisible() {
        var checked = 0
        for index in Self.map.cellIndices where Self.covers(Self.coverage.wall, index) {
            checked += 1
            for sample in Self.wallSamples(index) {
                #expect(Self.nearlyVisible(sample, normal: SIMD3(0, 0, 1), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0)), "cell \(index) sample \(sample)")
            }
        }
        #expect(checked >= 40, "only \(checked) wall cells seen")
    }

    @Test func wallHiddenBehindTheBushIsNeverSeen() {
        // Cells with some sample no camera saw even within a voxel: the band must be seen from
        // the ground to headroom, so each of these is unseen.
        let hidden = Self.map.cellIndices.filter { index in
            Self.wallSamples(index).contains { !Self.nearlyVisible($0, normal: SIMD3(0, 0, 1), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0)) }
        }
        let behindBush = hidden.filter { abs(Self.map.cellRange($0).lowerBound - 1.5) < 1 }
        #expect(behindBush.count >= 3, "cells hidden behind the bush: \(behindBush)")
        for index in hidden {
            #expect(!Self.covers(Self.coverage.wall, index), "cell \(index) has hidden wall but was claimed seen")
        }
    }

    @Test func wallAwayFromTheBushIsSeen() {
        for index in Self.map.cellIndices {
            let range = Self.map.cellRange(index)
            guard (range.lowerBound >= -2 && range.upperBound <= 0.6) || (range.lowerBound >= 2.6 && range.upperBound <= 4) else { continue }
            #expect(Self.covers(Self.coverage.wall, index), "cell \(index) (\(range)) not seen")
        }
    }

    @Test func groundReachNeverPassesGroundNobodySaw() {
        var checked = 0
        for span in Self.coverage.ground {
            for index in Self.map.cellIndices where span.span.contains((Self.map.cellRange(index).lowerBound + Self.map.cellRange(index).upperBound) / 2) {
                let range = Self.map.cellRange(index)
                for out in Swift.stride(from: Float(0.1), through: span.out, by: 0.1524) {
                    for f: Float in [0.25, 0.75] {
                        let point = SIMD3(range.lowerBound + f * (range.upperBound - range.lowerBound), 0, out)
                        #expect(Self.nearlyVisible(point, normal: SIMD3(0, 1, 0), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1)), "ground \(point) claimed seen")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 500)
    }

    @Test func groundBehindTheBushIsNotSeenAndGroundElsewhereIs() {
        for index in Self.map.cellIndices {
            let range = Self.map.cellRange(index)
            let reach = Self.map.groundReach(cell: index, along: Self.wall)
            if range.lowerBound >= 1.1, range.upperBound <= 1.9 {
                #expect(reach == nil, "ground behind the bush at cell \(index) reaches \(reach ?? -1)")
            }
            if range.lowerBound >= -2, range.upperBound <= 0.6 {
                #expect((reach ?? 0) >= 1.5, "ground at cell \(index) reaches only \(reach ?? -1)")
            }
        }
    }

    @Test func facingAndOverheadNeverClaimSpaceTheBushFills() {
        let bush = Self.scene.boxes[0]
        for index in Self.map.cellIndices {
            let range = Self.map.cellRange(index)
            let overlapsBush = range.upperBound > bush.min.x && range.lowerBound < bush.max.x
            let facing = Self.map.facingReach(cell: index, along: Self.wall)
            let overhead = Self.map.overheadReach(cell: index, along: Self.wall)
            if overlapsBush {
                // The bush fills out 0.4 to 1.0 from 0 to 0.9 m up: a clear reach past 0.4 m out
                // (facing) or anything from 0.3 m up over the battery's 0.56 m depth (overhead)
                // would claim space it fills.
                #expect((facing ?? 0) < bush.min.z, "facing at cell \(index): \(facing ?? -1)")
                #expect(overhead == nil, "overhead at cell \(index): \(overhead ?? -1)")
            }
            if range.lowerBound >= -2, range.upperBound <= 0.6 {
                #expect((facing ?? 0) >= 1.0, "facing at cell \(index): \(facing ?? -1)")
                #expect((overhead ?? 0) > Self.map.config.headroom, "overhead at cell \(index): \(overhead ?? -1)")
            }
        }
    }

    @Test func coverageFeedsSceneExport() throws {
        let scene = SceneCoverage(Self.coverage, leftEndMarked: false, rightEndMarked: false)
        #expect(!scene.wall.isEmpty && !scene.ground.isEmpty && !scene.facing.isEmpty && !scene.overhead.isEmpty)
        let data = try SceneExport.jsonData(SceneInput(wall: SceneWall(meter: Self.wall.meter, outward: Self.wall.outward, groundY: 0), baselineS: -5...6, coverage: scene))
        #expect(!data.isEmpty)
    }

    /// The 2D coverage map counts what the camera pointed at, so it claims the wall behind the
    /// bush; the 3D map does not.
    @Test func theTwoDimensionalMapClaimsWhatTheBushHides() {
        var flat = CoverageMap(wall: Self.wall)
        for camera in Self.cameras { flat.observe(camera, trackingNormal: true) }
        let hidden = Self.map.cellIndices.filter { index in
            let range = Self.map.cellRange(index)
            return range.lowerBound >= 1.1 && range.upperBound <= 1.9
        }
        let claimedFlat = hidden.filter { Self.covers(flat.coveredIntervals(.wall), $0) }
        let claimed3D = hidden.filter { Self.covers(Self.coverage.wall, $0) }
        #expect(claimedFlat.count == hidden.count, "2D map claims \(claimedFlat.count) of \(hidden.count)")
        #expect(claimed3D.isEmpty)
    }
}
