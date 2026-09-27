import Foundation

/// The engine's decisions about its frame source (the live AR session or a replay), kept apart
/// from ARKit so they can be tested: when a source may start, what a failure does before and
/// after the scan is captured, and what Start over clears.
public struct CaptureSourceState: Sendable, Equatable {
    public enum Failure: Sendable, Equatable {
        /// The device can't run world tracking. Nothing a new session changes.
        case unsupported
        /// The camera was refused, the session failed, or a replay couldn't be read. A new
        /// attempt can succeed (permission granted meanwhile, a transient failure, a fixed file).
        case recoverable
    }

    public enum Source: Sendable, Equatable {
        case none
        case running
        /// It failed and delivers nothing more. Start over discards it for a new one.
        case failed
    }

    /// What the engine does about a failure.
    public enum Response: Sendable, Equatable {
        /// Show the failure screen.
        case showFailure
        /// The scan is already sent: keep the answer on screen, without anything spatial.
        case keepAnswer
    }

    public private(set) var source: Source = .none
    /// The failure the screen shows; nil after a failure that kept the answer.
    public private(set) var failure: Failure?
    /// Whether the camera's view of the world can be trusted for spatial content (the AR result,
    /// its offer). False from a session failure until a new source starts: no further frame will
    /// arrive to say tracking was lost, so the last frame's "normal" would stand.
    public private(set) var spatialAvailable = true

    public init() {}

    /// A source may start only when none exists and no failure is on screen.
    public var mayStartSource: Bool { source == .none && failure == nil }

    public mutating func sourceStarted() {
        source = .running
        spatialAvailable = true
    }

    /// The source failed. Before the scan is sent the flow can't go on, so the failure shows;
    /// after it, the answer doesn't need the camera and stays, but nothing spatial may.
    public mutating func sourceFailed(_ failure: Failure, afterCapture: Bool) -> Response {
        source = .failed
        spatialAvailable = false
        if afterCapture { return .keepAnswer }
        self.failure = failure
        return .showFailure
    }

    /// Start over. Returns true when the failed source has to be discarded, so the next scan
    /// starts a new one. A recoverable failure is cleared; an unsupported device stays failed.
    public mutating func startOver() -> Bool {
        if failure == .recoverable { failure = nil }
        guard source == .failed, failure == nil else { return false }
        source = .none
        return true
    }
}
