import Testing
@testable import MeasureGeometry

struct FrameResetGateTests {
    @Test func waitsForTrackingCycleAndRejectsOldFrames() {
        var gate = FrameResetGate(resetUptime: 100)
        #expect(!gate.accepts(frameTimestamp: 101))
        gate.trackingChanged(isNormal: true, at: 101)
        #expect(!gate.accepts(frameTimestamp: 101))
        gate.trackingChanged(isNormal: false, at: 99)
        #expect(!gate.accepts(frameTimestamp: 101))
        gate.trackingChanged(isNormal: false, at: 102)
        #expect(!gate.accepts(frameTimestamp: 103))
        gate.trackingChanged(isNormal: true, at: 104)
        #expect(!gate.accepts(frameTimestamp: 100))
        #expect(!gate.accepts(frameTimestamp: 99.9))
        #expect(gate.accepts(frameTimestamp: 104))
    }

    @Test func trackingLossClosesGateUntilNormalReturns() {
        var gate = FrameResetGate(resetUptime: 100)
        gate.trackingChanged(isNormal: false, at: 101)
        gate.trackingChanged(isNormal: true, at: 102)
        #expect(gate.accepts(frameTimestamp: 103))
        gate.trackingChanged(isNormal: false, at: 104)
        #expect(!gate.accepts(frameTimestamp: 105))
        gate.trackingChanged(isNormal: true, at: 106)
        #expect(gate.accepts(frameTimestamp: 107))
    }
}
