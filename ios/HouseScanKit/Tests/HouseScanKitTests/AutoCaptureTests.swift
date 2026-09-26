import HouseScanKit
import simd
import Testing

@Suite struct AutoCaptureTests {
    static func frame(_ t: Double, x: Float = 0, tracking: TrackingStatus = .normal, quality: FrameQuality? = nil) -> FrameSample {
        let camera = portraitCamera(at: SIMD3(x, 1.4, 2.6), forward: forwardFacingWall(pitchedDown: 20))
        return FrameSample(timestamp: t, camera: camera, tracking: tracking, quality: quality)
    }

    static func good(sharpness: Double = 100, meanLuma: Double = 128) -> FrameQuality {
        FrameQuality(sharpness: sharpness, meanLuma: meanLuma, clippedFraction: 0)
    }

    /// A gate that kept a still frame at t = 0.5 after tracking went normal at t = 0.
    static func afterFirstKeep() -> AutoCapture {
        var gate = AutoCapture()
        _ = gate.evaluate(frame(0), newlySeenCells: 0)
        let first = frame(0.5)
        _ = gate.evaluate(first, newlySeenCells: 0)
        gate.didKeep(first)
        return gate
    }

    @Test func waitsForHalfASecondOfNormalTracking() {
        var gate = AutoCapture()
        #expect(gate.evaluate(Self.frame(0), newlySeenCells: 10) == .skip(.trackingNotReady))
        #expect(gate.evaluate(Self.frame(0.4), newlySeenCells: 10) == .skip(.trackingNotReady))
        // 0.5 - 0 >= stableTracking 0.5, and nothing kept yet.
        #expect(gate.evaluate(Self.frame(0.5), newlySeenCells: 0) == .keep(.first))
    }

    @Test func limitedTrackingRestartsTheWait() {
        var gate = AutoCapture()
        _ = gate.evaluate(Self.frame(0), newlySeenCells: 0)
        _ = gate.evaluate(Self.frame(0.4), newlySeenCells: 0)
        #expect(gate.evaluate(Self.frame(0.45, tracking: .limited), newlySeenCells: 0) == .skip(.trackingNotReady))
        // Normal again from 0.5, so ready at 1.0 rather than at 0.5.
        #expect(gate.evaluate(Self.frame(0.5), newlySeenCells: 0) == .skip(.trackingNotReady))
        #expect(gate.evaluate(Self.frame(0.9), newlySeenCells: 0) == .skip(.trackingNotReady))
        #expect(gate.evaluate(Self.frame(1.0), newlySeenCells: 0) == .keep(.first))
    }

    @Test func tooSoonAfterAKeep() {
        var gate = Self.afterFirstKeep()
        // 0.6 - 0.5 = 0.1 < minInterval 0.33.
        #expect(gate.evaluate(Self.frame(0.6), newlySeenCells: 10) == .skip(.tooSoon))
    }

    @Test func fastWalkingIsMoving() {
        var gate = Self.afterFirstKeep()
        _ = gate.evaluate(Self.frame(0.6), newlySeenCells: 0)
        // 1 m since the frame at 0.6, in 0.4 s: 2.5 m/s > maxSpeed 1.5.
        #expect(gate.evaluate(Self.frame(1.0, x: 1), newlySeenCells: 10) == .skip(.moving))
    }

    @Test func keepsOnSpacing() {
        var gate = Self.afterFirstKeep()
        // 0.6 m in 0.5 s is 1.2 m/s, and 0.6 >= spacingMeters 0.5.
        #expect(gate.evaluate(Self.frame(1.0, x: 0.6), newlySeenCells: 0) == .keep(.spacing))
    }

    @Test func keepsOnNewCoverageBeforeTheSpacing() {
        var gate = Self.afterFirstKeep()
        // 0.2 m is under the spacing; 3 new cells reaches newCellsToKeep.
        #expect(gate.evaluate(Self.frame(1.0, x: 0.2), newlySeenCells: 3) == .keep(.newCoverage))
        var other = Self.afterFirstKeep()
        #expect(other.evaluate(Self.frame(1.0, x: 0.2), newlySeenCells: 2) == .skip(.redundant))
    }

    @Test func darkFramesAreSkipped() {
        var gate = AutoCapture()
        _ = gate.evaluate(Self.frame(0, quality: Self.good()), newlySeenCells: 0)
        #expect(gate.evaluate(Self.frame(0.5, quality: Self.good(meanLuma: 39)), newlySeenCells: 0) == .skip(.tooDark))
        #expect(gate.evaluate(Self.frame(0.6, quality: Self.good(meanLuma: 40)), newlySeenCells: 0) == .keep(.first))
    }

    @Test func blurryAgainstTheRecentMedian() {
        var gate = AutoCapture()
        for t in [0, 0.25, 0.5] { _ = gate.evaluate(Self.frame(t, quality: Self.good(sharpness: 100)), newlySeenCells: 0) }
        #expect(gate.medianSharpness == 100)
        // Median before this frame is 100; 49 < 100 * 0.5.
        #expect(gate.evaluate(Self.frame(0.75, quality: Self.good(sharpness: 49)), newlySeenCells: 0) == .skip(.blurry))
        // Median of [100, 100, 100, 49] (upper middle) is still 100; 50 is not below 50.
        #expect(gate.evaluate(Self.frame(1.0, quality: Self.good(sharpness: 50)), newlySeenCells: 0) == .keep(.first))
    }

    @Test func unmeasuredFramesReuseTheLastQuality() {
        var gate = AutoCapture()
        _ = gate.evaluate(Self.frame(0, quality: Self.good(meanLuma: 20)), newlySeenCells: 0)
        #expect(gate.evaluate(Self.frame(0.5), newlySeenCells: 0) == .skip(.tooDark))
    }
}
