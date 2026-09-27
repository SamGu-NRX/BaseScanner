import Darwin
import Foundation
import HouseScanKit
import simd
import Testing

// Timing and memory. Times are printed as MAP3D_PERF lines; the frame-time bound is only held in
// optimized builds (swift test -c release), since a debug build is many times slower.
@Suite(.serialized) struct Map3DPerformanceTests {
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static let optimized: Bool = {
        #if DEBUG
        false
        #else
        true
        #endif
    }()

    /// Median and fastest of `runs` calls.
    static func time(runs: Int, _ body: () -> Void) -> (median: Double, fastest: Double) {
        let clock = ContinuousClock()
        let times = (0..<runs).map { _ in milliseconds(clock.measure(body)) }.sorted()
        return (times[runs / 2], times[0])
    }

    /// One 256 x 192 LiDAR frame of the bush scene, 2.5 m from the wall, into a map that has
    /// already stored the bricks it touches. ARKit delivers depth at 60 frames a second
    /// (16.7 ms apart); the bound is half of that.
    @Test func oneLidarFrameIntegratesWellUnderAFrame() {
        let camera = lidarCamera(at: SIMD3(1.5, 1.4, 2.5), lookingAt: SIMD3(1.5, 1.0, 0))
        let frame = bushScene().depthFrame(from: camera, noise: 0.02)
        for stride in [2, 1] {
            var config = Map3DConfig()
            config.pixelStride = stride
            var map = Map3D(frame: sceneFrame(), config: config)
            map.integrate(frame)
            let result = Self.time(runs: Self.optimized ? 31 : 3) { map.integrate(frame) }
            print("MAP3D_PERF integrate one 256x192 depth frame, pixel stride \(stride): median \(String(format: "%.2f", result.median)) ms, fastest \(String(format: "%.2f", result.fastest)) ms")
            if Self.optimized, stride == Map3DConfig().pixelStride {
                #expect(result.median < 8.35, "median \(result.median) ms")
            }
        }
    }

    /// What the UI and the export would read from a walked map, timed for the record.
    @Test func readingTheMap() {
        var map = Map3D(frame: sceneFrame())
        for (index, camera) in bushWalk().enumerated() { map.integrate(bushScene().depthFrame(from: camera, noise: 0.02, seed: UInt64(index))) }
        let wall = standardWall()
        for (name, body) in [
            ("coverage", { _ = map.coverage(along: wall) }),
            ("measuredWalls", { _ = map.measuredWalls() }),
            ("fogOfWar", { _ = map.fogOfWar(along: wall) }),
            ("nextBestView", { _ = map.nextBestView(along: wall) }),
        ] as [(String, () -> Void)] {
            let result = Self.time(runs: Self.optimized ? 3 : 1, body)
            print("MAP3D_PERF \(name) after \(bushWalk().count) frames: median \(String(format: "%.1f", result.median)) ms")
        }
    }

    /// A 30 x 10 x 5 m region (x, z, y), filled by frames from all over it looking four ways:
    /// storage never passes the bounds' worst case, and integrating frames again stores
    /// nothing more.
    @Test func memoryIsBoundedForA30By10By5Region() {
        let bounds = MapBounds(min: SIMD3(-15, -1, -1), max: SIMD3(15, 4, 9))
        var map = Map3D(frame: sceneFrame(), bounds: bounds)
        let worst = map.worstCaseBytes
        #expect(worst <= 32 << 20, "worst case \(worst) bytes")
        let scene = SyntheticScene(
            walls: SyntheticScene.chain([SIMD2(-15, 9), SIMD2(-15, 0), SIMD2(15, 0), SIMD2(15, 9), SIMD2(-15, 9)]),
            boxes: [SyntheticScene.Box(min: SIMD3(-8, 0, 3), max: SIMD3(-6, 1.5, 5)), SyntheticScene.Box(min: SIMD3(5, 0, 6), max: SIMD3(7, 2, 7))])
        let cameras = Swift.stride(from: Float(-12), through: 12, by: 6).flatMap { x in
            [Float(2), 5, 8].flatMap { z in
                [SIMD3<Float>(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)].map { direction in
                    lidarCamera(at: SIMD3(x, 1.4, z), lookingAt: SIMD3(x, 1.0, z) + direction)
                }
            }
        }
        let frames = cameras.map { scene.depthFrame(from: $0) }
        for frame in frames { map.integrate(frame) }
        let first = map.allocatedBytes
        for frame in frames.prefix(12) { map.integrate(frame) }
        #expect(map.allocatedBytes == first)
        #expect(first <= worst)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        let footprint = status == KERN_SUCCESS ? "\(info.phys_footprint >> 20) MB" : "unknown"
        print("MAP3D_PERF 30x10x5 m region, \(frames.count) frames: map holds \(first >> 20) MB (\(first) bytes), worst case \(worst >> 20) MB (\(worst) bytes); test process footprint \(footprint)")
    }
}
