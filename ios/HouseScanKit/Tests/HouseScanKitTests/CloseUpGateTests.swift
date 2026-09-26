import HouseScanKit
import simd
import Testing

@Suite struct CloseUpGateTests {
    static let meter = SIMD3<Float>(0, 1.5, 0)
    static let quality = FrameQuality(sharpness: 100, meanLuma: 128, clippedFraction: 0)

    /// Standing `distance` in front of the meter at its height, looking at `target`.
    static func frame(_ t: Double, distance: Float = 1, lookingAt target: SIMD3<Float> = meter) -> FrameSample {
        let camera = portraitCamera(at: SIMD3(0, 1.5, distance), lookingAt: target)
        return FrameSample(timestamp: t, camera: camera, tracking: .normal, quality: quality)
    }

    /// Yawed 45 degrees right from 1 m out: f = (1, 0, -1)/sqrt 2, r = (1, 0, 1)/sqrt 2. The meter
    /// offset (0, 0, -1) has camera y = r . d = -0.707 at depth 0.707, so v = 240 + 500 = 740, far
    /// outside the central band 240 +- 120.
    static func offCenter(_ t: Double) -> FrameSample {
        frame(t, lookingAt: SIMD3(1, 1.5, 0))
    }

    @Test func centeredMeterFiresAfterTheHold() {
        var gate = CloseUpGate()
        // 1 m straight ahead projects on the principal point (320, 240). Hold = t / 0.6.
        let holds = [0, 0.2, 0.4, 0.6].map { gate.evaluate(Self.frame($0), meter: Self.meter) }
        #expect(holds.map(\.issue) == [nil, nil, nil, nil])
        #expect(abs(holds[0].hold - 0) < 1e-9)
        #expect(abs(holds[1].hold - 1.0 / 3) < 1e-9)
        #expect(abs(holds[2].hold - 2.0 / 3) < 1e-9)
        #expect(holds[3].hold == 1)
        #expect(holds.map(\.fire) == [false, false, false, true])
    }

    @Test func offCenterMeter() throws {
        let pixel = try #require(Self.offCenter(0).camera.pixel(of: Self.meter))
        #expect(nearlyEqual(pixel, SIMD2(320, 740)))
        var gate = CloseUpGate()
        let status = gate.evaluate(Self.offCenter(0), meter: Self.meter)
        #expect(status.issue == .notCentered)
        #expect(status.hold == 0 && !status.fire)
    }

    @Test func twoMetresIsTooFar() {
        var gate = CloseUpGate()
        // Centered, but 2 m > maxDistance 1.5.
        #expect(gate.evaluate(Self.frame(0, distance: 2), meter: Self.meter).issue == .tooFar)
    }

    @Test func problemLastingFourSecondsFailsTheAttempt() {
        var gate = CloseUpGate()
        for t in [0, 1, 2, 3, 3.9] {
            #expect(gate.evaluate(Self.offCenter(t), meter: Self.meter).failedAttempts == 0)
        }
        // 4.0 - 0 >= failAfter 4; the clock then restarts.
        #expect(gate.evaluate(Self.offCenter(4), meter: Self.meter).failedAttempts == 1)
        #expect(gate.evaluate(Self.offCenter(5), meter: Self.meter).failedAttempts == 1)
        #expect(gate.failedAttempts == 1)
    }

    /// B-04: two sharp frames then a blurry one, 10 frames a second. A 0.2 s run of sharp frames
    /// never finishes the 0.6 s hold, so no photo fires; every 4 s of that is a failed try. (A
    /// third of the frames blurry keeps the sharpness median at the sharp value, so each blurry
    /// frame stays under half of it.)
    @Test func alternatingGoodAndBlurryFramesFailEachFourSeconds() {
        var gate = CloseUpGate()
        let blurry = FrameQuality(sharpness: 10, meanLuma: 128, clippedFraction: 0)
        var fired = false
        var failedAt: [Int] = []
        for step in 0..<90 {
            var sample = Self.frame(Double(step) / 10)
            if step % 3 == 2 { sample.quality = blurry }
            let status = gate.evaluate(sample, meter: Self.meter)
            fired = fired || status.fire
            if status.failedAttempts > failedAt.count { failedAt.append(step) }
        }
        #expect(!fired)
        // The attempt starts at 0 s. The first blurry frame at or after 4.0 s is step 41 (4.1 s);
        // the next attempt starts there, and the first blurry frame from 8.1 s on is step 83.
        #expect(failedAt == [41, 83])
    }

    @Test func aPhotoRestartsTheAttemptClock() {
        var gate = CloseUpGate()
        _ = gate.evaluate(Self.offCenter(0), meter: Self.meter)
        for t in [3.0, 3.3, 3.6] { _ = gate.evaluate(Self.frame(t), meter: Self.meter) }
        // The shutter fired at 3.6, so the attempt after it starts at 3.7 and 4.5 is not late.
        _ = gate.evaluate(Self.offCenter(3.7), meter: Self.meter)
        #expect(gate.evaluate(Self.offCenter(4.5), meter: Self.meter).failedAttempts == 0)
        #expect(gate.evaluate(Self.offCenter(7.7), meter: Self.meter).failedAttempts == 1)
    }

    @Test func goodFramesWithoutAPhotoDoNotRestartTheClock() {
        var gate = CloseUpGate()
        _ = gate.evaluate(Self.offCenter(0), meter: Self.meter)
        _ = gate.evaluate(Self.frame(3), meter: Self.meter)
        _ = gate.evaluate(Self.offCenter(3.5), meter: Self.meter)
        #expect(gate.evaluate(Self.offCenter(4.0), meter: Self.meter).failedAttempts == 1)
    }

    @Test func rejectedPhotoCountsAndRestartsTheHold() {
        var gate = CloseUpGate()
        for t in [0, 0.3, 0.6] { _ = gate.evaluate(Self.frame(t), meter: Self.meter) }
        gate.photoRejected()
        #expect(gate.failedAttempts == 1)
        let next = gate.evaluate(Self.frame(0.8), meter: Self.meter)
        #expect(next.hold == 0)
        #expect(next.failedAttempts == 1)
    }

    @Test func limitedTrackingIsAnIssue() {
        var gate = CloseUpGate()
        var sample = Self.frame(0)
        sample.tracking = .limited
        #expect(gate.evaluate(sample, meter: Self.meter).issue == .tracking)
    }
}
