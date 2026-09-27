import Foundation
import LiveDotsCore
import QuartzCore

/// Frame cost with exactly 6,000 dots, every one mid-birth and mid-evidence-rise so the shader
/// runs its full easing path, at the export size and at the app's Retina size.
enum Benchmark {
    static func run(fixture: String?) throws {
        let data = try ReplayData.loadNow(folder: FixtureLocator.folder(fixture))
        let renderer = try DotRenderer(data: data)
        guard let fullest = data.lidar.states.max(by: { $0.sprites.count < $1.sprites.count }) else { return }
        let time = fullest.time + 0.1
        var sprites: [DotSprite] = []
        var copy = 0
        while sprites.count < Tuning.dotCap {
            for s in fullest.sprites where sprites.count < Tuning.dotCap {
                // Later copies shift 1 cm per pass so they don't stack on the same pixel.
                sprites.append(DotSprite(
                    id: s.id &+ UInt64(copy) << 56, position: s.position + SIMD3(0.01 * Float(copy), 0, 0), kind: s.kind,
                    onOccluder: s.onOccluder, birthTime: time - 0.1, fromOpacity: 0.45, toOpacity: 0.9,
                    opacityTime: time - 0.1, edgeSince: s.edgeSince, deathTime: .infinity))
            }
            copy += 1
        }
        renderer.spriteOverride = sprites
        let edges = sprites.count { $0.edgeSince < .infinity }
        print("keyframe \(fullest.index + 1): \(sprites.count) dots (\(edges) edges), each with a halo: \(2 * sprites.count) point sprites")

        for (label, scale) in [("1170 x 2532 (export, 3x)", Float(3)), ("780 x 1688 (app window, 2x)", Float(2))] {
            let target = try OffscreenTarget(renderer: renderer, scale: scale)
            let request = FrameRequest(mode: .lidar, keyframe: fullest.index, time: time, reduceMotion: false, fog: .on)
            for _ in 0..<30 { try target.render(request, readBack: false) }
            var gpu: [Double] = [], wall: [Double] = []
            for _ in 0..<300 {
                let start = CACurrentMediaTime()
                gpu.append(try target.render(request, readBack: false) * 1000)
                wall.append((CACurrentMediaTime() - start) * 1000)
            }
            gpu.sort()
            wall.sort()
            func line(_ name: String, _ values: [Double]) -> String {
                let mean = values.reduce(0, +) / Double(values.count)
                return "\(name) mean \(String(format: "%.2f", mean)) ms, p95 \(String(format: "%.2f", values[values.count * 95 / 100])) ms"
            }
            print("\(label): \(line("GPU", gpu)); \(line("encode+submit+wait", wall))")
        }
    }
}
