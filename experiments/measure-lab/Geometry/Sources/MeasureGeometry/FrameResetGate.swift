/// Refuses frames from the previous AR world until the reset reports a fresh tracking cycle.
/// ARFrame timestamps and ProcessInfo.systemUptime use the same clock.
public struct FrameResetGate: Sendable, Equatable {
    public let resetUptime: Double
    private var sawTrackingReset = false
    private var ready = false

    public init(resetUptime: Double) {
        self.resetUptime = resetUptime
    }

    /// A callback after the cutoff must report limited or unavailable tracking before a later
    /// normal callback opens the gate. A normal callback alone cannot open the new world.
    public mutating func trackingChanged(isNormal: Bool, at uptime: Double) {
        guard uptime > resetUptime else { return }
        if !isNormal {
            sawTrackingReset = true
            ready = false
        } else if sawTrackingReset {
            ready = true
        }
    }

    public func accepts(frameTimestamp: Double) -> Bool {
        ready && frameTimestamp > resetUptime
    }
}
