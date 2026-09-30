import HouseScanKit
import simd
import Testing

// How the engine keeps the far surface current (`ScanEngine.ingest` and `noteFarSurface`, review
// of #168): the planes a frame carries (`PlaneSnapshot`) and the stretch they are measured over
// (`FarSurfaceTracker`). `step` below runs one sampled frame's part of that, as the engine does.
@Suite struct FarSurfaceTrackerTests {
    static let floor = GroundPlaneEvidence(y: 0, kind: .floor, boundary: [[-1, 0], [1, 0], [1, 2], [-1, 2]], id: "floor")

    /// A frame without planes (nil: pose-only, replay, review) keeps what is held. A live
    /// snapshot replaces it, and an empty one clears it. Only the lists that differ count as
    /// changed.
    @Test func onlyAFrameThatCarriesPlanesChangesThem() {
        let far = FarSurfaceTests.plane(at: 2.0)
        var held = PlaneSnapshot()
        func take(_ frame: PlaneSnapshot?) -> [Bool] {
            let changed = held.update(from: frame)
            return [changed.ground, changed.walls]
        }
        #expect(take(PlaneSnapshot(ground: [Self.floor], walls: [far])) == [true, true])
        #expect(take(nil) == [false, false])
        #expect(held == PlaneSnapshot(ground: [Self.floor], walls: [far]))
        #expect(take(PlaneSnapshot(ground: [Self.floor], walls: [far])) == [false, false])
        #expect(take(PlaneSnapshot(ground: [Self.floor])) == [false, true])
        #expect(held.walls.isEmpty)
        #expect(take(PlaneSnapshot()) == [true, false])
        #expect(held == PlaneSnapshot())
    }

    /// One sampled frame's far-surface update, as `ScanEngine.noteFarSurface` makes it.
    static func step(_ map: inout CoverageMap, _ tracker: inout FarSurfaceTracker, _ planes: PlaneSnapshot) {
        if let spans = tracker.spans(for: map, planes: planes.walls, excluding: []) { map.setFarSurface(spans) }
    }

    /// The corridor of `aFarWallFoundAfterTheDepthFramesReclassifiesThem`, as live frames report
    /// it. ARKit finds the far wall, loses it (an empty snapshot), and pose-only or replay frames
    /// in between carry nothing. The rows behind the wall are the end of the space while the
    /// plane is tracked. Frames without planes leave that alone. Once the plane is gone they are
    /// hidden again, exactly as on a map that never knew it. Before, the engine ignored the empty
    /// snapshot and kept the lost wall as the end of the space.
    @Test func aPlaneARKitStopsTrackingStopsEndingTheSpace() {
        let scene = standardScene(boxes: [FarSurfaceTests.farWall(at: 2.0)])
        var plain = CoverageMap(wall: standardWall())
        var map = CoverageMap(wall: standardWall())
        for camera in FarSurfaceTests.corridorCameras {
            let depth = renderDepth(scene, from: camera)
            plain.observe(camera, trackingNormal: true, depth: depth)
            map.observe(camera, trackingNormal: true, depth: depth)
        }
        var tracker = FarSurfaceTracker()
        var held = PlaneSnapshot()

        held.update(from: PlaneSnapshot(walls: [FarSurfaceTests.plane(at: 2.0)]))
        Self.step(&map, &tracker, held)
        #expect(!map.farSurface.isEmpty)
        #expect((-2...1).allSatisfy { map.groundDepthHiddenRows(at: $0).isEmpty })

        let revision = map.revision
        for _ in 0..<3 {
            held.update(from: nil)
            Self.step(&map, &tracker, held)
        }
        #expect(map.revision == revision)
        #expect(!map.farSurface.isEmpty)

        held.update(from: PlaneSnapshot())
        Self.step(&map, &tracker, held)
        #expect(map.farSurface.isEmpty)
        #expect(FarSurfaceTests.Readout(map) == FarSurfaceTests.Readout(plain))
    }

    /// The reviewer's case (review of #168): the only view is from beyond a far wall 20 m along
    /// the wall, at (20, 1.4, 3.0), with the wall's plane 1.6 m out over s 10 to 30. Once the
    /// far surface is set, nothing the view sampled counts as seen or hidden, so the stretch seen
    /// is empty. Measured over the stretch seen, the next frame measured around the meter, found
    /// no far wall, and the rebuild hid the cells again. The frame after that found the wall once
    /// more, and so on, on alternate frames. Measured over where the kept frame looks, the first
    /// frame sets it and later frames change nothing.
    @Test func theFarSurfaceDoesNotAlternateWithWhatARebuildDecides() {
        let scene = standardScene(boxes: [(SIMD3(10, 0, 1.6), SIMD3(30, 2.5, 1.7))])
        let camera = portraitCamera(at: SIMD3(20, 1.4, 3.0), lookingAt: SIMD3(20, 0.6, 0))
        let plane = FarSurfaceTests.plane(at: 1.6, from: 10, to: 30)
        let cell = Int((20 / CoverageConfig().cellWidth).rounded(.down))
        var start = CoverageMap(wall: standardWall())
        start.observe(camera, trackingNormal: true, depth: renderDepth(scene, from: camera))
        #expect(start.level(.wall, cell) == .hidden)

        // The old stretch, the one seen, as a control: the map flips on every frame.
        var old = start
        var levels: [CoverageLevel] = []
        for _ in 0..<4 {
            let around = old.seenExtent ?? -1...1
            let reach = old.config.maxDistance
            old.setFarSurface(FarSurface.spans(planes: [plane], wall: old.wall, over: (around.lowerBound - reach)...(around.upperBound + reach)))
            levels.append(old.level(.wall, cell))
        }
        #expect(levels.map { $0 == .hidden } == [false, true, false, true])

        var map = start
        var tracker = FarSurfaceTracker()
        let held = PlaneSnapshot(walls: [plane])
        Self.step(&map, &tracker, held)
        #expect(map.level(.wall, cell) != .hidden)
        let revision = map.revision
        for _ in 0..<3 {
            Self.step(&map, &tracker, held)
            #expect(tracker.spans(for: map, planes: held.walls, excluding: []) == nil)
        }
        #expect(map.revision == revision)
        #expect(map.level(.wall, cell) != .hidden)
    }

    /// The stretch is where kept cameras stand along the wall, `maxDistance` (6 m) either way,
    /// rounded out to whole meters. Before any frame is kept, it is 7 m either side of the
    /// meter. Cameras at s = 0.3 and 2.4 give -5.7 to 8.4, so -6 to 9. A camera 0.5 m farther
    /// on stays inside 9 m and changes nothing; one at 3.2 reaches 9.2, so the stretch grows to
    /// 10.
    @Test func theStretchIsWhereKeptFramesLookInWholeMeters() {
        var map = CoverageMap(wall: standardWall())
        #expect(FarSurfaceTracker.range(for: map) == -7...7)
        map.observe(wallCamera(s: 0.3), trackingNormal: true)
        map.observe(wallCamera(s: 2.4), trackingNormal: true)
        #expect(FarSurfaceTracker.range(for: map) == -6...9)
        map.observe(wallCamera(s: 2.9), trackingNormal: true)
        #expect(FarSurfaceTracker.range(for: map) == -6...9)
        map.observe(wallCamera(s: 3.2), trackingNormal: true)
        #expect(FarSurfaceTracker.range(for: map) == -6...10)
    }
}
