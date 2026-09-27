import Foundation
@testable import HouseScanKit
import simd
import Testing

// The walk asks for the wall up to `CoverageConfig.wallWalkHeight` (4.5 ft); rows are sampled and
// heights reported up to `wallCaptureHeight` (7.5 ft), and a server that needs more asks for it.

@Suite struct WalkingHeightTests {
    /// The synthetic replay's frames up to its closing tilt-ups, as the app plays them in the walk:
    /// kept by auto-capture, observed, and the walk's guidance chosen after each.
    static func syntheticWalkTasks() throws -> (tasks: [GuidanceTask], map: CoverageMap) {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../HouseScanUITests/Fixtures/synthetic-wall")
            .standardizedFileURL
        let session = try ReplaySession.load(folder: folder)
        let declared = try #require(session.declaredWall)
        let wall = try #require(WallFrame(meter: declared.meter, outward: declared.outward, groundY: declared.groundY))
        var map = CoverageMap(wall: wall)
        var capture = AutoCapture()
        var planner = GuidancePlanner()
        var tasks: [GuidanceTask] = []
        // Up to the closing tilt-up run, frame 38 on, which the walk doesn't play.
        for frame in session.frames.prefix(38) {
            let camera = CameraFrame(cameraToWorld: frame.cameraToWorld, intrinsics: frame.intrinsics, imageSize: SIMD2(Float(frame.width), Float(frame.height)))
            let sample = FrameSample(timestamp: frame.timestamp, camera: camera, tracking: .normal, quality: nil)
            if capture.evaluate(sample, newlySeenCells: map.newlySeenCount(from: camera)).isKeep {
                capture.didKeep(sample)
                map.observe(camera, trackingNormal: true, time: frame.timestamp)
            }
            let task = planner.update(coverage: map, camera: camera, time: frame.timestamp).task
            if tasks.last != task { tasks.append(task) }
        }
        return (tasks, map)
    }

    /// Pitched 20 degrees down from 2.6 m, the walk sees the wall about 2.0 m up: past the walking
    /// height, so it is never asked to tilt up for the wall. (With the band at 7.5 ft it was.)
    @Test func theSyntheticWalkIssuesNoWallTiltUp() throws {
        let (tasks, map) = try Self.syntheticWalkTasks()
        let wallTasks = tasks.filter { if case .aimAtWall = $0 { true } else { false } }
        #expect(wallTasks.isEmpty, "\(tasks)")
        // The ground by the meter still comes first (the field run's ordering).
        #expect(tasks.first { if case .stepBack = $0 { false } else { true } } == .aimAtGround(s: 0), "\(tasks)")
        // The walked stretch is covered to the walking height, and reported to what was seen.
        #expect(map.coveredFraction(.wall, in: -4...4) == 1)
        #expect(map.wallSeenSpans().contains { $0.span.contains(0) && nearlyEqual($0.out, 1.9812) })
    }

    /// Views reaching 1.98 m cover the wall (the strip goes green) and report 6.5 ft, not 4.5.
    /// Views reaching only 1.22 m leave it seen and report 4 ft.
    @Test func theStripGoesGreenAtTheWalkingHeightAndOutFtIsWhatWasSeen() throws {
        var map = CoverageMap(wall: standardWall())
        for x: Float in [0, 0.3] { map.observe(CoverageMapTests.frontCamera(x: x), trackingNormal: true) }
        #expect(map.level(.wall, 0) == .covered)
        var low = CoverageMap(wall: standardWall())
        for x: Float in [0, 0.3] { low.observe(CoverageMapTests.frontCamera(x: x, pitch: 35), trackingNormal: true) }
        #expect(low.level(.wall, 0) == .seen)

        func wallOut(_ map: CoverageMap) throws -> Double? {
            let data = try SceneExport.jsonData(SceneInput(
                wall: SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY), baselineS: -2...2,
                coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: false)))
            #expect(try SceneSchemas.scene().validate(data) == [])
            let entries = try JSONSchemaValidator.Value.parse(data)["coverage"]?["observed"]?.array ?? []
            return entries.first { $0["band"]?.string == "wall" && ($0["span_ft"]?.numbers).map { $0[0] <= 0.25 && $0[1] >= 0.25 } == true }?["out_ft"]?.number
        }
        #expect(try wallOut(map) == 6.5)
        #expect(try wallOut(low) == 4)
    }

    /// The phone's own gap check asks only for the walking band; the server's wall request above it
    /// is still a `.wallUp` request that the walking band doesn't meet.
    @Test func aServerRequestAboveTheWalkingHeightStillRoutesToWallUp() throws {
        var map = CoverageMap(wall: standardWall())
        FacingTests.walk(&map, out: 2.6, from: -2, to: 2)
        for x in stride(from: Float(-2), through: 2, by: 0.3) { map.observe(CoverageMapTests.frontCamera(x: x), trackingNormal: true) }
        map.setEnd(.left, at: -1)
        map.setEnd(.right, at: 1)
        let planner = GapPlanner()
        #expect(planner.plan(map) == nil)

        let item = try JSONDecoder().decode(PlacementMissingEvidence.self, from: Data(
            #"{"kind":"band","band":"wall","span_ft":[-3,3],"out_ft":6.500001,"message":"m"}"#.utf8))
        let request = try #require(planner.plan(for: item, leftEnd: map.leftEnd, rightEnd: map.rightEnd))
        #expect(request.need == .wallUp(Float(6.500001) * 0.3048))
        #expect(map.coveredFraction(.wall, in: -0.9...0.9) == 1)
        #expect(!planner.isSatisfied(request, map))
        for x in stride(from: Float(-1.5), through: 1.5, by: 0.3) { map.observe(wallCamera(s: x), trackingNormal: true) }
        #expect(planner.isSatisfied(request, map))
    }
}
