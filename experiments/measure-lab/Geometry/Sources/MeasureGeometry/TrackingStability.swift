/// Decides when taps may count: tracking must have been normal, with the camera running, for
/// `requiredSeconds` without a break.
///
/// An interruption breaks the run even when the tracking state reads normal on both sides of
/// it, because ARKit need not report a tracking change across an interruption. Times are device
/// uptime, the clock of `ARFrame.timestamp`, stamped when ARKit called back. A caller's timer only
/// prompts a fresh `isStable(at:)`; it never decides stability itself.
///
/// Callbacks reach the main actor through posted tasks, so a report from the AR run before a
/// reset can arrive after it. `reset(at:)` sets a cutoff: reports stamped at or before it are
/// refused, and after it a normal report counts only once a limited or unavailable one has
/// arrived, the fresh tracking cycle a reset run starts with (as in `FrameResetGate`).
public struct TrackingStability: Sendable, Equatable {
    public let requiredSeconds: Double
    private var isNormal = false
    private var isInterrupted = false
    /// Reports stamped at or before this belong to the run before the last reset.
    private var resetUptime: Double?
    private var awaitingFreshCycle = false
    /// Start of the current run of normal, uninterrupted tracking.
    public private(set) var normalSince: Double?

    public init(requiredSeconds: Double) {
        self.requiredSeconds = requiredSeconds
    }

    /// Returns false, changing nothing, for a report from before the last reset. A repeated
    /// normal report keeps the run going; only a change into normal starts one.
    @discardableResult
    public mutating func trackingChanged(isNormal: Bool, at time: Double) -> Bool {
        guard isAfterReset(time) else { return false }
        if awaitingFreshCycle {
            if isNormal { return false }
            awaitingFreshCycle = false
        }
        let wasNormal = self.isNormal
        self.isNormal = isNormal
        if !isNormal {
            normalSince = nil
        } else if !wasNormal, !isInterrupted {
            normalSince = time
        }
        return true
    }

    /// Returns false, changing nothing, for a report from before the last reset. Ending an
    /// interruption starts a fresh run if tracking reads normal.
    @discardableResult
    public mutating func interruptionChanged(isInterrupted: Bool, at time: Double) -> Bool {
        guard isAfterReset(time) else { return false }
        let wasInterrupted = self.isInterrupted
        self.isInterrupted = isInterrupted
        if isInterrupted {
            normalSince = nil
        } else if wasInterrupted, isNormal {
            normalSince = time
        }
        return true
    }

    /// A new AR run started at `uptime`: tracking starts over from not available.
    public mutating func reset(at uptime: Double) {
        resetUptime = uptime
        awaitingFreshCycle = true
        isNormal = false
        normalSince = nil
    }

    /// When the current run becomes long enough, or nil when no run is under way.
    public var stableAt: Double? {
        normalSince.map { $0 + requiredSeconds }
    }

    public func isStable(at time: Double) -> Bool {
        stableAt.map { time >= $0 } ?? false
    }

    private func isAfterReset(_ time: Double) -> Bool {
        resetUptime.map { time > $0 } ?? true
    }
}
