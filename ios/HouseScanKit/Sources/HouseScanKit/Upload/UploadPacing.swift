import Foundation

/// How long the upload screen still has to hold a step so the homeowner sees it (issue #31).
///
/// The server works out the spot inside the same request that carries the scene, so the answer
/// can arrive a moment after the last byte is sent. The engine then went from "Check clearances"
/// to the result in one turn of the main actor, and neither that step's spinner nor its tick was
/// ever drawn.
public enum UploadPacing {
    /// What is left of `minimum` since `start`, never below zero: all of it when the step hasn't
    /// started (`start` nil), none once `minimum` has passed.
    public static func remaining(since start: ContinuousClock.Instant?, minimum: Duration, now: ContinuousClock.Instant) -> Duration {
        guard let start else { return minimum }
        let left = minimum - (now - start)
        return left > .zero ? left : .zero
    }
}
