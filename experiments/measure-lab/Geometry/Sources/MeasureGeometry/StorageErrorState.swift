/// The one storage error the app shows, and which closed session's manifest write caused it, if
/// any. A later successful retry of that write clears the error. It never clears an error from
/// anything else, such as a failed save of the current session.
public struct StorageErrorState<Session: Hashable & Sendable>: Sendable, Equatable {
    public private(set) var message: String?
    private var closedSession: Session?

    public init() {}

    /// An error that no retry clears.
    public mutating func report(_ message: String) {
        self.message = message
        closedSession = nil
    }

    /// A failed write of a closed session's manifest, which a later retry can clear.
    public mutating func report(_ message: String, closedSession session: Session) {
        // A retriable manifest failure must not hide an unrelated error that its retry cannot fix.
        guard self.message == nil || closedSession != nil else { return }
        self.message = message
        closedSession = session
    }

    /// The closed session's manifest is on disk now.
    public mutating func closedSessionSaved(_ session: Session) {
        guard closedSession == session else { return }
        message = nil
        closedSession = nil
    }

    public mutating func clear() {
        message = nil
        closedSession = nil
    }
}
