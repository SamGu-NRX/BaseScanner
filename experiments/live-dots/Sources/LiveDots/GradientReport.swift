import Foundation
import LiveDotsCore
import simd

/// Evidence for `Tuning.gradientThreshold`. Wall voxels of the synthetic fixture are split by
/// what the scene generator painted there: on an outline of the meter, gas meter, door or window
/// (within 2.5 cm), or plain brick at least 10 cm from any outline. For each, the per-voxel
/// gradient is computed two ways, a Sobel on the full-size JPEG and the voxel-scale pyramid the
/// field uses, and the report prints percentiles and the share above each candidate threshold.
enum GradientReport {
    /// Painted rectangles from ios/Tools/make-synthetic-replay.swift on t3/ios-mvf, as
    /// (minX, minY, maxX, maxY). The door's bottom is the ground, so it is left out.
    static let outlines: [SIMD4<Float>] = [
        SIMD4(-0.15, 1.3, 0.15, 1.7), SIMD4(-1.35, 0.3, -1.05, 0.8),
        SIMD4(-3.4, 0, -2.5, 2.05), SIMD4(2.0, 0.9, 3.0, 2.0),
    ]

    static func distanceToOutline(_ x: Float, _ y: Float) -> Float {
        var best = Float.infinity
        for r in outlines {
            let insideX = x >= r.x && x <= r.z, insideY = y >= r.y && y <= r.w
            if insideY { best = min(best, abs(x - r.x), abs(x - r.z)) }
            if insideX { best = min(best, abs(y - r.w)) }
            if insideX, r.y > 0 { best = min(best, abs(y - r.y)) }
            if !insideX, !insideY {
                let dx = min(abs(x - r.x), abs(x - r.z)), dy = min(abs(y - r.y), abs(y - r.w))
                best = min(best, (dx * dx + dy * dy).squareRoot())
            }
        }
        return best
    }

    static func insidePainted(_ x: Float, _ y: Float) -> Bool {
        outlines.contains { x > $0.x && x < $0.z && y > $0.y && y < $0.w }
    }

    static func run(fixture: String?) throws {
        let replay = try Replay.load(folder: FixtureLocator.folder(fixture))
        // key -> (max over keyframes of the keyframe mean) for both methods
        var full: [VoxelKey: Float] = [:], scaled: [VoxelKey: Float] = [:]
        let size = Tuning.voxelSize
        for keyframe in replay.keyframes {
            let depth = try replay.depth(for: keyframe)
            let pyramid = GradientPyramid(image: try replay.image(for: keyframe))
            let scale = Float(keyframe.width) / Float(depth.width)
            var sums: [VoxelKey: SIMD3<Float>] = [:]
            for j in 0..<depth.height {
                for i in 0..<depth.width {
                    let d = depth.meters[j * depth.width + i]
                    guard depth.confidence[j * depth.width + i] >= Tuning.minimumConfidence, Tuning.depthRange.contains(d) else { continue }
                    let u = Float(i) + 0.5, v = Float(j) + 0.5
                    let p = CameraMath.transform(keyframe.cameraToWorld, CameraMath.unproject(u: u, v: v, depth: d, intrinsics: depth.intrinsics))
                    guard abs(p.z) < size / 2 else { continue }
                    let key = VoxelKey((p / size).rounded(.toNearestOrAwayFromZero))
                    let level = GradientPyramid.level(depth: d, focal: keyframe.intrinsics.x)
                    sums[key, default: .zero] += SIMD3(
                        pyramid.magnitude(u: u * scale, v: v * scale, level: 0),
                        pyramid.magnitude(u: u * scale, v: v * scale, level: level), 1)
                }
            }
            for (key, s) in sums {
                full[key] = max(full[key] ?? 0, s.x / s.z)
                scaled[key] = max(scaled[key] ?? 0, s.y / s.z)
            }
        }
        var outline: [VoxelKey] = [], brick: [VoxelKey] = []
        for key in full.keys {
            let x = Float(key.x) * size, y = Float(key.y) * size
            let behindBin = x > 1.1 && x < 1.9 && y < 1.2
            guard y > 0.12, y < 2.9, abs(x) < 5.9, !behindBin else { continue }
            let distance = distanceToOutline(x, y)
            if distance <= size / 2 { outline.append(key) }
            else if distance >= 0.1, !insidePainted(x, y) { brick.append(key) }
        }
        print("wall voxels: \(outline.count) on painted outlines, \(brick.count) plain brick")
        for (name, values) in [("full-size Sobel", full), ("voxel-scale pyramid", scaled)] {
            print("\n\(name)")
            for (label, keys) in [("outline", outline), ("brick", brick)] {
                let sorted = keys.compactMap { values[$0] }.sorted()
                guard !sorted.isEmpty else { continue }
                func p(_ q: Double) -> String { String(format: "%.3f", sorted[min(Int(Double(sorted.count) * q), sorted.count - 1)]) }
                let shares = [0.1, 0.15, 0.2, 0.25, 0.3].map { t in
                    String(format: "%.2f: %3.0f%%", t, 100 * Double(sorted.count { $0 >= Float(t) }) / Double(sorted.count))
                }
                print("  \(label.padding(toLength: 8, withPad: " ", startingAt: 0)) p10 \(p(0.1)) p50 \(p(0.5)) p90 \(p(0.9)) p99 \(p(0.99)) | above " + shares.joined(separator: ", "))
            }
        }
    }
}
