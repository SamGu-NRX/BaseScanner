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

    @Test func `an ember dot cools from its birth and seeing it again never re-warms it`() throws {
        // A 32 x 32 grey image and an empty depth map: nothing occludes, and only the timeline matters.
        let image = RGBImage(width: 32, height: 32, rgba: [UInt8](repeating: 128, count: 32 * 32 * 4))
        let depth = DepthMap(
            meters: [Float](repeating: 0, count: 12), confidence: [UInt8](repeating: 2, count: 12),
            width: 4, height: 3, intrinsics: SIMD4(500 * 4 / 640, 500 * 3 / 480, 2, 1.5))
        func frame(_ index: Int) -> FrameInput {
            FrameInput(index: index, keyframe: .fixtureStyle(x: 0, pitch: 0), depth: depth, gradient: GradientPyramid(image: image))
        }
        let position = SIMD3<Float>(0, 1.5, 0)
        var builder = DotTimeline.Builder()
        builder.append(frame(0), dots: [FieldDot(id: 1, position: position, kind: .flat, views: 1, onOccluder: false)], seen: [], instruction: .walkLeft)
        // Keyframe 30, 7.5 s later: dot 1 is observed again, from a new direction, and has become
        // an edge; dot 2 is new.
        builder.append(frame(30), dots: [
            FieldDot(id: 1, position: position, kind: .edge, views: 2, onOccluder: false),
            FieldDot(id: 2, position: position + SIMD3(0.1, 0, 0), kind: .flat, views: 1, onOccluder: false),
        ], seen: [], instruction: .walkLeft)
        let sprites = try #require(builder.states.last).sprites
        let old = try #require(sprites.first { $0.id == 1 }), new = try #require(sprites.first { $0.id == 2 })
        let now = Float(30) / Tuning.keyframesPerSecond
        #expect(old.birthTime == 0)
        #expect(DotScheme.warmth(at: now, birth: old.birthTime) == 0)
        #expect(DotScheme.warmth(at: now, birth: new.birthTime) == 1)
        #expect(abs(DotScheme.warmth(at: now + 3, birth: new.birthTime) - 0.5) < 1e-6)
    }
}

extension DotKind {
    static let allKinds: [DotKind] = [.flat, .edge, .feature, .plane]
}
