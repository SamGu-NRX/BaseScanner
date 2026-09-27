import Foundation
import HouseScanKit
import simd
import Testing

// The 2D coverage map and the 3D map fed the same whole replay walk, read along the declared
// wall, and printed side by side as REPLAY_COMPARE lines. On the synthetic fixtures each claim
// is judged against exact ray casting of the scene the fixture was rendered from
// (ios/Tools/make-synthetic-replay.swift, header), from the same camera poses. Only the 3D map
// is asserted on; the 2D map's numbers are printed for comparison.
@Suite struct Map3DReplayComparisonTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Map3D
        .deletingLastPathComponent() // HouseScanKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // HouseScanKit
        .deletingLastPathComponent() // ios
        .appendingPathComponent("HouseScanUITests/Fixtures", isDirectory: true)

    static let advioFolder = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["HOUSESCAN_ADVIO_REPLAY"] ?? "/Users/samgu/house-scanning-data/replays/advio-20-0040-0075",
        isDirectory: true)
    static var advioPresent: Bool { FileManager.default.fileExists(atPath: advioFolder.appendingPathComponent("session.json").path) }

    /// The generator's scene: the wall on z = 0 facing +z, x in [-6, 6], 3 m tall, the ground at
    /// y = 0, and with --lidar the bin. The meters, door and window are painted flush on the wall
    /// and hide nothing, so they are left out.
    static func scene(bin: Bool) -> SyntheticScene {
        SyntheticScene(
            walls: [SyntheticScene.Wall(a: SIMD2(-6, 0), b: SIMD2(6, 0), height: 3)],
            boxes: bin ? [SyntheticScene.Box(min: SIMD3(1.2, 0, 0.5), max: SIMD3(1.8, 1.1, 1.1))] : [])
    }

    @Test func syntheticLidarWalk() throws {
        let walk = try Walk(folder: Self.fixtures.appendingPathComponent("synthetic-wall-lidar"))
        let truth = Truth(scene: Self.scene(bin: true), cameras: walk.frames.map(\.photo), wallExtent: -6...6, wall: walk.wall)
        let models = walk.feed()
        let rows = report("synthetic-wall-lidar", walk: walk, models: models, truth: truth)

        #expect(rows.map3DWall.falseLength == 0, "Map3D claims \(rows.map3DWall.falseLength) m of wall no camera saw")
        #expect(rows.map3DGround.falseLength == 0, "Map3D claims \(rows.map3DGround.falseLength) m of ground past what any camera saw")
        // Behind the bin means cells whose middle lies in s 1.3..1.7, as Map3DOcclusionTests.covers
        // judges a cell. Any overlap would be too strict: the cell from 1.676 to 1.829 is truly
        // seen at every height (1 to 7 cameras at s 1.65 and 1.75 by exact ray casting), and
        // overlaps the stretch by 2.4 cm.
        let width = Map3DConfig().cellWidth
        let behindBin = (0..<20).map { (Float($0) + 0.5) * width }.filter { (1.3...1.7).contains($0) }
        let claimedBehindBin = behindBin.filter { middle in models.map.wall.contains { $0.contains(middle) } }
        let gridOverlap = Truth.grid.filter { s in (1.3...1.7).contains(s) && models.map.wall.contains { $0.contains(s) } }
        print(String(
            format: "REPLAY_COMPARE fixture=synthetic-wall-lidar model=Map3D note=behind the bin: %d of %d cells with middles in s 1.3..1.7 claimed; claimed 2 cm samples in 1.3..1.7: %@",
            claimedBehindBin.count, behindBin.count, gridOverlap.map { String(format: "%.2f", $0) }.joined(separator: ",")))
        #expect(!behindBin.isEmpty)
        #expect(claimedBehindBin.isEmpty, "Map3D claims the wall behind the bin at cell middles \(claimedBehindBin)")
    }

    @Test func syntheticPhotoWalk() throws {
        let walk = try Walk(folder: Self.fixtures.appendingPathComponent("synthetic-wall"))
        let truth = Truth(scene: Self.scene(bin: false), cameras: walk.frames.map(\.photo), wallExtent: -6...6, wall: walk.wall)
        report("synthetic-wall", walk: walk, models: walk.feed(), truth: truth)
    }

    @Test(.enabled(if: advioPresent, "no ADVIO replay at HOUSESCAN_ADVIO_REPLAY (default /Users/samgu/house-scanning-data/replays/advio-20-0040-0075); skipped"))
    func advioWalk() throws {
        let walk = try Walk(folder: Self.advioFolder)
        report("advio-20-0040-0075", walk: walk, models: walk.feed(), truth: nil)
    }

    // MARK: Feeding

    struct Walk {
        struct Frame {
            var photo: CameraFrame
            var depth: DepthImage?
            var time: Double
            var trackingNormal: Bool
        }

        var frames: [Frame]
        var wall: WallFrame
        var wallSource: String

        init(folder: URL) throws {
            let session = try ReplaySession.load(folder: folder)
            frames = try session.frames.map { frame in
                Frame(
                    photo: CameraFrame(cameraToWorld: frame.cameraToWorld, intrinsics: frame.intrinsics, imageSize: SIMD2(Float(frame.width), Float(frame.height))),
                    depth: try ReplaySession.loadDepth(for: frame, folder: folder), time: frame.timestamp, trackingNormal: frame.trackingNormal)
            }
            if let declared = session.declaredWall {
                wall = try #require(WallFrame(meter: declared.meter, outward: declared.outward, groundY: declared.groundY))
                wallSource = "declared"
            } else {
                // No wall was tapped (ADVIO): the wall the app's replay player assumes from the trajectory.
                let planned = frames.map { PlannedFrame(camera: $0.photo, timestamp: $0.time, trackingNormal: $0.trackingNormal) }
                let assumed = try #require(ReplayPlanning.assumedWall(frames: planned), "no wall can be assumed from \(folder.path)")
                wall = assumed.wall
                wallSource = String(format: "assumed by ReplayPlanning.assumedWall, %.2f m from the walk's centroid", assumed.offset)
            }
        }

        struct Models {
            var flat: CoverageMap
            var map: Map3DCoverage
            var flatOverheadFrames: Int
            var map3DDepthFrames: Int
        }

        /// Every frame, as ScanEngine keeps them: the 2D map observes each with its tracking state
        /// (limited tracking only breaks the walked path) and its depth; the 3D map integrates the
        /// depth of each frame with normal tracking. The 2D map's overhead band holds only views
        /// the homeowner confirmed clear; frames tilted more than 15 degrees up stand in for them.
        func feed() -> Models {
            var flat = CoverageMap(wall: wall)
            var map = Map3D(frame: MapFrame(wall: wall))
            var overheadFrames = 0
            var depthFrames = 0
            for frame in frames {
                flat.observe(frame.photo, trackingNormal: frame.trackingNormal, time: frame.time, depth: frame.depth)
                if frame.trackingNormal, frame.photo.forward.y > sin(15 * Float.pi / 180),
                   !flat.recordOverhead(frame.photo, trackingNormal: true).isEmpty {
                    overheadFrames += 1
                }
                if frame.trackingNormal, let depth = frame.depth {
                    map.integrate(Self.depthFrame(depth, pose: frame.photo))
                    depthFrames += 1
                }
            }
            return Models(flat: flat, map: map.coverage(along: wall), flatOverheadFrames: overheadFrames, map3DDepthFrames: depthFrames)
        }

        /// Mirrors Map3DFeed.depthFrame(_:pose:) in the app target (HouseScan/Runtime/Map3DFeed.swift).
        static func depthFrame(_ image: DepthImage, pose: CameraFrame) -> DepthFrame {
            let camera = CameraFrame(
                cameraToWorld: pose.cameraToWorld, intrinsics: image.intrinsics,
                imageSize: SIMD2(Float(image.width), Float(image.height)))
            return DepthFrame(
                camera: camera, width: image.width, height: image.height,
                depth: image.millimeters.map { Float($0) / 1000 }, kind: .lidar(confidence: image.confidence))
        }
    }

    // MARK: Truth

    /// What the cameras truly saw of a synthetic scene. A point counts as seen when, within a
    /// voxel (0.1 m) along the surface, some camera has it in view within 5 m and 65 degrees of
    /// its normal with nothing in between (SyntheticScene.isVisible), as
    /// Map3DOcclusionTests.nearlyVisible judges it. Different heights may be seen by different
    /// cameras, as the 3D map accumulates them.
    struct Truth {
        /// s samples every 2 cm, at their centers, over the 3D map's whole extent.
        static let step: Float = 0.02
        static let grid: [Float] = (0..<800).map { -8 + step * (Float($0) + 0.5) }
        static let wallHeights = Array(Swift.stride(from: Float(0.1), to: 1.9812, by: 0.2)) + [1.9812]
        static let groundStep: Float = 0.1524
        static let groundOuts = Array(Swift.stride(from: Float(0.1), through: 5.2, by: groundStep))

        var scene: SyntheticScene
        var cameras: [CameraFrame]
        var wallExtent: ClosedRange<Float>
        var wall: WallFrame

        func nearlyVisible(_ point: SIMD3<Float>, normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) -> Bool {
            for du: Float in [-0.1, 0, 0.1] {
                for dv: Float in [-0.1, 0, 0.1] {
                    let p = point + u * du + v * dv + normal * 1e-3
                    if cameras.contains(where: { scene.isVisible(p, normal: normal, from: $0) }) { return true }
                }
            }
            return false
        }

        /// Seen at every sampled height of the wall band. Past the wall's ends there is no wall.
        func wallSeen(_ s: Float) -> Bool {
            guard wallExtent.contains(s) else { return false }
            return Self.wallHeights.allSatisfy { height in
                nearlyVisible(wall.world(s: s, height: height), normal: wall.outward, u: wall.along, v: WallFrame.up)
            }
        }

        /// The farthest ground sample out from the wall with every sample up to it seen; nil when
        /// the first is not.
        func groundReach(_ s: Float) -> Float? {
            var reach: Float?
            for out in Self.groundOuts {
                guard nearlyVisible(wall.world(s: s, height: 0, out: out), normal: WallFrame.up, u: wall.along, v: wall.outward) else { break }
                reach = out
            }
            return reach
        }
    }

    // MARK: Report

    struct Row {
        var claimedLength: Float
        var falseLength: Float?
        var missedLength: Float?
    }

    struct Rows {
        var map3DWall: Row
        var map3DGround: Row
    }

    @discardableResult
    func report(_ fixture: String, walk: Walk, models: Walk.Models, truth: Truth?) -> Rows {
        let grid = Truth.grid
        let step = Truth.step
        let trueWall = truth.map { t in grid.map(t.wallSeen) }
        let trueGround = truth.map { t in grid.map(t.groundReach) }

        func length(_ count: Int) -> Float { Float(count) * step }
        func meters(_ value: Float?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.2fm(%.1fft)", value, value / 0.3048)
        }
        func reach(_ outs: [Float]) -> String {
            guard !outs.isEmpty else { return "reach=none" }
            let sorted = outs.sorted()
            return String(format: "reach(min/median/max)=%.2f/%.2f/%.2fm", sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1])
        }
        func line(_ model: String, _ band: String, _ row: Row, _ extra: String = "") {
            print("REPLAY_COMPARE fixture=\(fixture) model=\(model) band=\(band) claimed=\(meters(row.claimedLength)) false=\(meters(row.falseLength)) missed=\(meters(row.missedLength))\(extra.isEmpty ? "" : " " + extra)")
        }

        func wallRow(_ intervals: [ClosedRange<Float>]) -> Row {
            let claimed = grid.map { s in intervals.contains { $0.contains(s) } }
            return Row(
                claimedLength: length(claimed.filter { $0 }.count),
                falseLength: trueWall.map { seen in length(grid.indices.filter { claimed[$0] && !seen[$0] }.count) },
                missedLength: trueWall.map { seen in length(grid.indices.filter { !claimed[$0] && seen[$0] }.count) })
        }
        func outs(_ spans: [ObservedSpan]) -> [Float?] {
            grid.map { s in spans.filter { $0.span.contains(s) }.map(\.out).max() }
        }
        /// Ground is claimed falsely where the claim reaches more than one sample step past the
        /// last truly seen sample, or where nothing at the wall's foot was seen.
        func groundRow(_ spans: [ObservedSpan]) -> (Row, [Float]) {
            let claimed = outs(spans)
            let row = Row(
                claimedLength: length(claimed.compactMap { $0 }.count),
                falseLength: trueGround.map { t in
                    length(grid.indices.filter { i in claimed[i].map { out in t[i].map { out > $0 + Truth.groundStep } ?? true } ?? false }.count)
                },
                missedLength: trueGround.map { t in length(grid.indices.filter { claimed[$0] == nil && t[$0] != nil }.count) })
            return (row, claimed.compactMap { $0 })
        }
        func untruthedRow(_ spans: [ObservedSpan]) -> (Row, [Float]) {
            let claimed = outs(spans).compactMap { $0 }
            return (Row(claimedLength: length(claimed.count)), claimed)
        }

        print("REPLAY_COMPARE fixture=\(fixture) note=\(walk.frames.count) frames (\(walk.frames.filter(\.trackingNormal).count) normal), \(walk.frames.filter { $0.depth != nil }.count) with depth; wall \(walk.wallSource); lengths on a \(Int(step * 100)) cm s grid over [-8, 8] m; no ends marked")

        if let trueWall, let trueGround {
            line("truth", "wall", Row(claimedLength: length(trueWall.filter { $0 }.count)))
            line("truth", "ground", Row(claimedLength: length(trueGround.compactMap { $0 }.count)), reach(trueGround.compactMap { $0 }))
        }

        let flatWall = wallRow(models.flat.coveredIntervals(.wall))
        let (flatGround, flatGroundOuts) = groundRow(models.flat.groundDepthSpans())
        let (flatFacing, flatFacingOuts) = untruthedRow(models.flat.facingSpans())
        let (flatOverhead, flatOverheadOuts) = untruthedRow(models.flat.overheadSpans())
        line("CoverageMap", "wall", flatWall)
        line("CoverageMap", "ground", flatGround, reach(flatGroundOuts))
        line("CoverageMap", "facing", flatFacing, reach(flatFacingOuts))
        line("CoverageMap", "overhead", flatOverhead, reach(flatOverheadOuts) + " (\(models.flatOverheadFrames) tilted-up frames recorded as confirmed clear)")

        let mapWall = wallRow(models.map.wall)
        let (mapGround, mapGroundOuts) = groundRow(models.map.ground)
        let (mapFacing, mapFacingOuts) = untruthedRow(models.map.facing)
        let (mapOverhead, mapOverheadOuts) = untruthedRow(models.map.overhead)
        line("Map3D", "wall", mapWall)
        line("Map3D", "ground", mapGround, reach(mapGroundOuts))
        line("Map3D", "facing", mapFacing, reach(mapFacingOuts))
        line("Map3D", "overhead", mapOverhead, reach(mapOverheadOuts))
        if models.map3DDepthFrames == 0 {
            print("REPLAY_COMPARE fixture=\(fixture) model=Map3D note=no depth and no feature points in this replay, so Map3D integrated nothing and is expected to claim nothing")
        }
        return Rows(map3DWall: mapWall, map3DGround: mapGround)
    }
}
