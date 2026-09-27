/// Routes each finished keyframe write to the session that reserved it.
///
/// Writes finish on another thread and report back later, possibly after one or more session
/// switches. A closed session stays routable until every write it reserved has reported back,
/// success or failure, however many sessions open in between.
public struct KeyframeRouter<Session: Hashable & Sendable>: Sendable {
    public enum Route: Sendable, Equatable {
        /// The session still open for new keyframes.
        case current
        /// A closed session still waiting for this write; append it to that session's manifest.
        case closed
        /// A session this router never opened, or one already drained.
        case unknown
    }

    private var current: Session?
    private var reported: [Session: Int] = [:]
    /// Reservation totals of closed sessions that still wait for writes.
    private var closing: [Session: Int] = [:]

    public init() {}

    public mutating func open(_ session: Session) {
        current = session
        reported[session] = 0
    }

    /// Closes the current session, which made `reserved` reservations in total. Returns true when
    /// some of them have not reported back yet, so the caller must keep the session's manifest.
    @discardableResult
    public mutating func closeCurrent(reserved: Int) -> Bool {
        guard let session = current else { return false }
        current = nil
        if reported[session, default: 0] >= reserved {
            reported[session] = nil
            return false
        }
        closing[session] = reserved
        return true
    }

    /// Records one write reporting back. `drained` is true when that was the last write a closed
    /// session was waiting for; the caller can then release the session.
    public mutating func report(for session: Session) -> (route: Route, drained: Bool) {
        if session == current {
            reported[session, default: 0] += 1
            return (.current, false)
        }
        guard let expected = closing[session] else { return (.unknown, false) }
        let count = reported[session, default: 0] + 1
        guard count >= expected else {
            reported[session] = count
            return (.closed, false)
        }
        closing[session] = nil
        reported[session] = nil
        return (.closed, true)
    }
}
