/// What to do with the server's answer when the scan's geometry may have changed while it was
/// sent. The app counts changes to the captured geometry (anchor corrections, ground refinements
/// and revocations, a new wall, a followed corner) and records the count with the scene it sends.
/// An answer to a scene whose count has moved on describes a wall the phone no longer has, and
/// drawing its spot on the current wall would put it in the wrong place.
public enum AnswerFreshness: Equatable, Sendable {
    /// The geometry is as sent: show the answer.
    case current
    /// It changed: drop the answer and send the scan again from a fresh snapshot.
    case sendAgain
    /// It changed again after the scan was sent again: drop the answer and let the homeowner try
    /// again once the phone has settled.
    case stillChanging

    /// How many times a stale answer's scan is sent again before giving up. One: a correction
    /// or ground refinement settles within a frame or two, so a second stale answer means the
    /// phone is still moving things, and a loop would only keep the homeowner waiting.
    public static let resendLimit = 1

    /// The decision for an answer to a scene sent at revision `sent`, when the revision is now
    /// `now` and the scan has already been sent again `resends` times.
    public static func of(sent: Int, now: Int, resends: Int) -> AnswerFreshness {
        if sent == now { return .current }
        return resends < resendLimit ? .sendAgain : .stillChanging
    }
}
