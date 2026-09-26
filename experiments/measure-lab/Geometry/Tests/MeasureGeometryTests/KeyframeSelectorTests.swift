import Testing
@testable import MeasureGeometry

struct KeyframeSelectorTests {
    /// A selector whose last saved keyframe is the identity pose.
    func savedAtOrigin() -> KeyframeSelector {
        var selector = KeyframeSelector()
        selector.commit(selector.reserve(at: identityPose))
        return selector
    }

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
        #expect(savedAtOrigin().wantsKeyframe(at: poseTurned(turn, at: position)) == expected)
    }

    @Test func `spacing restarts at the last saved pose`() {
        var selector = savedAtOrigin()
        selector.commit(selector.reserve(at: poseTurned(0, at: SIMD3(0.4, 0, 0))))
        // 0.8 m from the first keyframe but only 0.4 m from the tap keyframe.
        #expect(!selector.wantsKeyframe(at: poseTurned(0, at: SIMD3(0.8, 0, 0))))
        selector.reset()
        #expect(selector.wantsKeyframe(at: identityPose))
    }

    // Regression for review defect 4: a failed write used to move the checkpoint anyway, so frames
    // until about x = 1 m were suppressed after a failure at x = 0.5 m.
    @Test func `a cancelled write leaves spacing at the last success`() {
        var selector = savedAtOrigin()
        let failed = selector.reserve(at: poseTurned(0, at: SIMD3(0.5, 0, 0)))
        selector.cancel(failed)
        #expect(selector.lastSaved == identityPose)
        #expect(selector.wantsKeyframe(at: poseTurned(0, at: SIMD3(0.51, 0, 0))))
    }

    @Test func `a write in progress holds off duplicates until it finishes`() {
        var selector = savedAtOrigin()
        let inFlight = selector.reserve(at: poseTurned(0, at: SIMD3(0.5, 0, 0)))
        // Measured from the pending pose, so a frame 2 cm on is not another keyframe.
        #expect(!selector.wantsKeyframe(at: poseTurned(0, at: SIMD3(0.52, 0, 0))))
        #expect(selector.lastSaved == identityPose)
        selector.commit(inFlight)
        #expect(selector.lastSaved == poseTurned(0, at: SIMD3(0.5, 0, 0)))
    }

    @Test func `an older write finishing late does not move the checkpoint back`() {
        var selector = KeyframeSelector()
        let older = selector.reserve(at: identityPose)
        let newer = selector.reserve(at: poseTurned(0, at: SIMD3(2, 0, 0)))
        selector.commit(newer)
        selector.commit(older)
        #expect(selector.lastSaved == poseTurned(0, at: SIMD3(2, 0, 0)))
    }

    @Test func `a reservation from before a reset is ignored`() {
        var selector = savedAtOrigin()
        let stale = selector.reserve(at: poseTurned(0, at: SIMD3(5, 0, 0)))
        selector.reset()
        selector.commit(stale)
        #expect(selector.lastSaved == nil)
        #expect(selector.wantsKeyframe(at: identityPose))
    }
}
