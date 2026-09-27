import simd
import Testing
@testable import LiveDotsCore

struct SchemeTests {
    func sprite(_ x: Float, kind: DotKind = .edge, normal: SIMD3<Float> = SIMD3(0, 0, 1), y: Float = 1) -> DotSprite {
        DotSprite(
            id: UInt64(x * 1000), position: SIMD3(x, y, 0), kind: kind, onOccluder: false, birthTime: 0,
            fromOpacity: 0.45, toOpacity: 0.45, opacityTime: 0, edgeSince: kind == .edge ? -.infinity : .infinity,
            deathTime: .infinity, normal: normal)
    }

    @Test func `constellation draws no flat or plane dots`() {
        #expect(DotKind.allKinds.filter(DotScheme.constellation.draws) == [.edge, .feature])
        #expect(DotKind.allKinds.allSatisfy(DotScheme.hologram.draws))
        #expect(DotKind.allKinds.allSatisfy(DotScheme.ember.draws))
    }

    @Test func `constellation links follow an outline and skip other surfaces and flat dots`() {
        let sprites = [
            sprite(0), sprite(0.05), sprite(0.10), sprite(0.15), sprite(0.20),  // an outline, 5 cm apart
            sprite(0.05, normal: SIMD3(0, 1, 0), y: 1.04),                      // 4 cm away, 90 degrees off
            sprite(0.10, kind: .flat, y: 1.03),                                 // flat, never linked
        ]
        let links = EdgeLinks.links(among: sprites)
        #expect(links == [SIMD2(0, 1), SIMD2(1, 2), SIMD2(2, 3), SIMD2(3, 4)])
    }

    @Test func `an ember dot re-warms when observed again`() throws {
        var field = VoxelField()
        let key = VoxelKey(0, 30, 0)
        let camera = SIMD3<Float>(0, 1.5, 2.6)
        field.observe(key, normal: SIMD3(0, 0, 1), gradient: 1, samples: 4, camera: camera, frame: 0)
        field.classify(frame: 0)
        let first = try #require(field.dots().first).lastSeenFrame
        #expect(first == 0)
        // Keyframe 30 is 7.5 s of playback later: a dot last seen at 0 has fully cooled.
        let later = Float(30) / Tuning.keyframesPerSecond
        #expect(DotScheme.warmth(at: later, lastSeen: 0) == 0)

        field.observe(key, normal: SIMD3(0, 0, 1), gradient: 1, samples: 4, camera: camera, frame: 30)
        let rewarmed = try #require(field.dots().first).lastSeenFrame
        #expect(rewarmed == 30)
        let lastSeen = Float(rewarmed) / Tuning.keyframesPerSecond
        #expect(DotScheme.warmth(at: later, lastSeen: lastSeen) == 1)
        #expect(abs(DotScheme.warmth(at: later + 3, lastSeen: lastSeen) - 0.5) < 1e-6)
        #expect(DotScheme.warmth(at: later + 6, lastSeen: lastSeen) == 0)
    }
}

extension DotKind {
    static let allKinds: [DotKind] = [.flat, .edge, .feature, .plane]
}
