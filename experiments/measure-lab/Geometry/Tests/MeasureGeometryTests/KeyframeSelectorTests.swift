import Testing
@testable import MeasureGeometry

struct KeyframeSelectorTests {
    @Test func `first pose is always a keyframe`() {
        #expect(KeyframeSelector().wantsKeyframe(at: identityPose))
    }

    @Test(arguments: [
        (SIMD3<Double>(0.49, 0, 0), 0.0, false),
        (SIMD3<Double>(0.3, 0.4, 0), 0.0, true),
        (SIMD3<Double>(0, 0, 0.6), 0.0, true),
        (SIMD3<Double>.zero, 14.0, false),
        (SIMD3<Double>.zero, 15.5, true),
        (SIMD3<Double>(0.2, 0, 0), -20.0, true),
    ])
    func `spacing by distance or turn`(position: SIMD3<Double>, turn: Double, expected: Bool) {
        var selector = KeyframeSelector()
        selector.didSave(at: identityPose)
        #expect(selector.wantsKeyframe(at: poseTurned(turn, at: position)) == expected)
    }

    @Test func `spacing restarts at the last saved pose`() {
        var selector = KeyframeSelector()
        selector.didSave(at: identityPose)
        let tapPose = poseTurned(0, at: SIMD3(0.4, 0, 0))
        selector.didSave(at: tapPose)
        // 0.8 m from the first keyframe but only 0.4 m from the tap keyframe.
        #expect(!selector.wantsKeyframe(at: poseTurned(0, at: SIMD3(0.8, 0, 0))))
        selector.reset()
        #expect(selector.wantsKeyframe(at: tapPose))
    }
}
