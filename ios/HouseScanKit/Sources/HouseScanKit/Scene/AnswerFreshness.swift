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

/// What a step that would present an accepted answer as current does: the spot check's end, the
/// result, the AR view. The answer was current when it arrived (`AnswerFreshness.of`), but the
/// geometry can move while the homeowner answers the spot check or looks at the result (a ground
/// plane revoked or refined, an anchor correction), and the answer then describes a wall the
/// phone no longer has.
public enum AcceptedAnswerStep: Equatable, Sendable {
    /// The step itself changes the scan (an answer withdrew an area, or adds a ground patch): it
    /// is sent again from a fresh snapshot anyway, and the new answer is checked when it arrives.
    case upload
    /// The geometry is as sent: show the answer.
    case show
    /// It changed: drop the answer and send the scan again from a fresh snapshot.
    case sendAgain
    /// It changed again after that: drop the answer and show the stale-answer failure.
    case stillChanging
}

extension AnswerFreshness {
    /// The step for an answer to a scene sent at revision `sent`, when the revision is now `now`
    /// and a stale accepted answer has already been sent again `resends` times. The same limit
    /// as at the POST (`resendLimit`).
    public static func step(changesScan: Bool, sent: Int, now: Int, resends: Int) -> AcceptedAnswerStep {
        if changesScan { return .upload }
        switch of(sent: sent, now: now, resends: resends) {
        case .current: return .show
        case .sendAgain: return .sendAgain
        case .stillChanging: return .stillChanging
        }
    }
}
