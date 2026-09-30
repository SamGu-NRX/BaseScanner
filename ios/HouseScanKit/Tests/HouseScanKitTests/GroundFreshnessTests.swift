import HouseScanKit
import Testing

/// A ground refine after the answer takes it down and sends the scan once more; an anchor
/// correction keeps it (`GroundFreshness`).
@Suite struct GroundFreshnessTests {
    private static let answerScreens: [GroundFreshness.Screen] = [.spotCheck, .result, .resultInCamera]

    /// A rule that has already taken one answer down for a ground change.
    private static func afterOneWithdrawal() -> GroundFreshness {
        var rule = GroundFreshness()
        _ = rule.after(.ground, on: .result)
        return rule
    }

    @Test(arguments: answerScreens)
    func aGroundChangeUnderAnAnswerSendsTheScanAgain(screen: GroundFreshness.Screen) {
        var rule = GroundFreshness()
        #expect(rule.after(.ground, on: screen) == .sendAgain)
        #expect(rule.awaitingNewAnswer)
    }

    @Test(arguments: answerScreens + [.sending])
    func aSecondGroundChangeBeforeANewAnswerFails(screen: GroundFreshness.Screen) {
        var rule = Self.afterOneWithdrawal()
        #expect(rule.after(.ground, on: screen) == .fail)
        // Still waiting: "Try again" sends a scan that is itself protected.
        #expect(rule.awaitingNewAnswer)
    }

    @Test(arguments: GroundFreshness.Screen.allCases)
    func anAnchorCorrectionKeepsTheAnswer(screen: GroundFreshness.Screen) {
        var fresh = GroundFreshness()
        #expect(fresh.after(.anchorCorrection, on: screen) == .keep)
        #expect(fresh == GroundFreshness())

        // Nor does it count as the second change while a resend is out.
        var resending = Self.afterOneWithdrawal()
        #expect(resending.after(.anchorCorrection, on: screen) == .keep)
        #expect(resending == Self.afterOneWithdrawal())
    }

    @Test func aGroundChangeWhileCapturingKeepsGoing() {
        var fresh = GroundFreshness()
        #expect(fresh.after(.ground, on: .noAnswer) == .keep)
        #expect(!fresh.awaitingNewAnswer)

        // A gap request or the review after a withdrawal: the next upload is built afresh.
        var resending = Self.afterOneWithdrawal()
        #expect(resending.after(.ground, on: .noAnswer) == .keep)
        #expect(resending.awaitingNewAnswer)
    }

    @Test func aGroundChangeDuringAFirstUploadKeepsIt() {
        var rule = GroundFreshness()
        #expect(rule.after(.ground, on: .sending) == .keep)
        #expect(!rule.awaitingNewAnswer)
    }

    @Test(arguments: GroundFreshness.Screen.allCases, [false, true])
    func packagingAndAwaitingMatrix(screen: GroundFreshness.Screen, packaged: Bool) {
        for awaiting in [false, true] {
            for change in GroundFreshness.Change.allCases {
                var rule = awaiting ? Self.afterOneWithdrawal() : GroundFreshness()
                let expected: GroundFreshness.Action
                if change == .anchorCorrection || screen == .noAnswer {
                    expected = .keep
                } else if awaiting {
                    expected = .fail
                } else if screen == .sending && !packaged {
                    expected = .keep
                } else {
                    expected = .sendAgain
                }
                #expect(rule.after(change, on: screen, scenePackaged: packaged) == expected)
                #expect(rule.awaitingNewAnswer == (awaiting || expected == .sendAgain))
            }
        }
    }

    @Test func aPackagedFirstUploadUsesOneResendUntilAnAnswerIsShown() {
        var rule = GroundFreshness()
        #expect(rule.after(.ground, on: .sending, scenePackaged: true) == .sendAgain)
        #expect(rule.awaitingNewAnswer)
        #expect(rule.after(.ground, on: .sending, scenePackaged: false) == .fail)
        #expect(rule.awaitingNewAnswer)
        rule.answerShown()
        #expect(rule.after(.ground, on: .sending, scenePackaged: true) == .sendAgain)
    }

    @Test(arguments: answerScreens)
    func anAnswerShownStartsANewResend(screen: GroundFreshness.Screen) {
        var rule = Self.afterOneWithdrawal()
        rule.answerShown()
        #expect(!rule.awaitingNewAnswer)
        #expect(rule.after(.ground, on: screen) == .sendAgain)
    }
}
