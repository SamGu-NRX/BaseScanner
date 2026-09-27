import Foundation
import simd
import Testing
@testable import LiveDotsCore

struct FogAndGuidanceTests {
    @Test func `the reveal mask is smoothstepped from 0.12 to 0.55 after clamping to 1`() {
        #expect(FogMask.shape(0) == 0)
        #expect(FogMask.shape(0.12) == 0)
        #expect(abs(FogMask.shape(0.335) - 0.5) < 1e-5)
        #expect(FogMask.shape(0.55) == 1)
        #expect(FogMask.shape(3.7) == 1)
    }

    @Test func `the fog lifts with a 600 ms time constant and returns in 120 ms`() {
        let lifted = FogMask.lagStep(from: 0, toward: 1, dt: 0.6, reduceMotion: false)
        #expect(abs(lifted - (1 - exp(-1))) < 1e-5)
        let returned = FogMask.lagStep(from: 1, toward: 0, dt: 0.12, reduceMotion: false)
        #expect(abs(returned - exp(-1)) < 1e-5)
        // Stepping in frames lands in the same place as one long step.
        var stepped: Float = 0
        for _ in 0..<36 { stepped = FogMask.lagStep(from: stepped, toward: 1, dt: 1 / 60, reduceMotion: false) }
        #expect(abs(stepped - lifted) < 1e-4)
    }

    @Test func `under Reduce Motion the lift is a linear 400 ms fade`() {
        #expect(abs(FogMask.lagStep(from: 0, toward: 1, dt: 0.2, reduceMotion: true) - 0.5) < 1e-6)
        #expect(FogMask.lagStep(from: 0, toward: 1, dt: 0.5, reduceMotion: true) == 1)
    }

    @Test func `a box appears at 60 percent in view and settles when seen face-on with both sides in frame`() throws {
        let window = try #require(RecognisedBox.fixture.first { $0.caption == "Window" })
        var state = BoxState()
        func view(_ x: Float, _ t: Float) {
            state.update(window, projection: ScreenProjection(keyframe: .fixtureStyle(x: x), viewSize: SIMD2(390, 844)), at: t)
        }
        view(0.5, 1)  // the window is off to the right
        #expect(state == BoxState())
        view(1.9, 2)  // most of it in view, its right edge cut off: dashed
        #expect(state.appearedAt == 2 && state.solidAt == nil)
        view(2.5, 3)  // square on, both sides in frame: solid
        #expect(state.appearedAt == 2 && state.solidAt == 3)
        view(0.5, 4)  // walking away changes nothing
        #expect(state.appearedAt == 2 && state.solidAt == 3)
    }

    @Test func `an oblique view never settles a box`() throws {
        let window = try #require(RecognisedBox.fixture.first { $0.caption == "Window" })
        // 1.9 m to the side and 0.6 m out, turned to face it: 72 degrees off face-on.
        let camera = SIMD3<Float>(4.4, 1.5, 0.6)
        let forward = simd_normalize(SIMD3<Float>(2.5, 1.45, 0) - camera)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0))), up = simd_cross(right, forward)
        let keyframe = Keyframe(
            id: "k", imagePath: "k.jpg", width: 640, height: 480, intrinsics: SIMD4(500, 500, 320, 240),
            cameraToWorld: simd_float4x4(columns: (SIMD4(-up, 0), SIMD4(right, 0), SIMD4(-forward, 0), SIMD4(camera, 1))),
            timestamp: 0, depth: nil)
        var state = BoxState()
        state.update(window, projection: ScreenProjection(keyframe: keyframe, viewSize: SIMD2(390, 844)), at: 1)
        #expect(state.appearedAt == 1 && state.solidAt == nil)
    }

    @Test func `the meter box is solid from the first keyframe it is in view`() throws {
        let meter = try #require(RecognisedBox.fixture.first { $0.isMeter })
        var state = BoxState()
        state.update(meter, projection: ScreenProjection(keyframe: .fixtureStyle(x: 0, pitch: 0), viewSize: SIMD2(390, 844)), at: 0)
        #expect(state == BoxState(appearedAt: 0, solidAt: 0))
    }

    @Test func `guidance runs meter, hold, left, right, tilt, done`() {
        let xs: [Float] = [0, 0, 0, 0, -1, -2.6, -1, 0, 1, 0.2, 0.2, 0.2]
        let sequence = Instruction.sequence(for: xs.map { Keyframe.fixtureStyle(x: $0) })
        #expect(sequence == [
            .pointAtMeter, .pointAtMeter, .holdStill, .walkLeft, .walkLeft, .walkRight, .walkRight, .walkRight, .walkRight,
            .tiltDown, .tiltDown, .done,
        ])
    }

    @Test func `the hold keyframe stays on screen for the ring fill and the flash`() {
        let hold = Schedule.start(of: Schedule.holdIndex)
        #expect(abs(Schedule.start(of: Schedule.holdIndex + 1) - hold - Schedule.holdDuration - Schedule.flashDuration) < 1e-6)
        #expect(abs(Schedule.start(of: 5) - Schedule.start(of: 4) - 0.25) < 1e-6)
        #expect(Schedule.keyframe(at: hold + 1, count: 41) == Schedule.holdIndex)
        #expect(Schedule.keyframe(at: 1e5, count: 41) == 40)
    }
}
