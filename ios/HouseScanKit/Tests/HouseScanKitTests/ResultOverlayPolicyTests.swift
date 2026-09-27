import HouseScanKit
import Testing

/// #67: "See it on your wall" keeps the Canvas drawing until the AR scene has been seen drawing
/// the result for half a second, and falls back to it the moment the AR scene stops holding it.
/// Review of #100: exactly one layer draws it, so the battery leaving the view doesn't bring the
/// Canvas back over RealityKit's copy, and a rebuilt model is confirmed afresh.
@Suite struct ResultOverlayPolicyTests {
    /// One look at the AR scene: `drawn` (held, with the battery's middle in view), `held`
    /// (anchored and enabled) and the time.
    private typealias Look = (drawn: Bool, held: Bool, time: Double)

    /// Feeds `looks` to `policy` in order and returns each answer (true: the AR scene draws the
    /// result, false: the Canvas does).
    private static func answers(_ looks: [Look], to policy: inout ResultOverlayPolicy) -> [Bool] {
        looks.map { policy.update(drawn: $0.drawn, held: $0.held, time: $0.time) }
    }

    private static func answers(_ looks: [Look]) -> [Bool] {
        var policy = ResultOverlayPolicy()
        return answers(looks, to: &policy)
    }

    /// Looks every 0.1 s from `start`, `count` times, as the engine does.
    private static func polled(drawn: Bool, held: Bool, from start: Double, count: Int) -> [Look] {
        (0..<count).map { (drawn: drawn, held: held, time: start + Double($0) * 0.1) }
    }

    /// Seen drawing from 0.0 to 0.6 s: confirmed at 0.5 s.
    private static let confirming = polled(drawn: true, held: true, from: 0, count: 7)

    @Test func startsOnTheCanvas() {
        let policy = ResultOverlayPolicy()
        #expect(!policy.usesRealityKit)
    }

    @Test func neverDrawnKeepsTheCanvas() {
        let answers = Self.answers(Self.polled(drawn: false, held: false, from: 0, count: 50))
        #expect(answers.allSatisfy { !$0 })
    }

    @Test func heldButNeverInViewKeepsTheCanvas() {
        // Anchored and enabled with the battery out of view: nothing shows the AR scene draws it.
        let answers = Self.answers(Self.polled(drawn: false, held: true, from: 0, count: 50))
        #expect(answers.allSatisfy { !$0 })
    }

    @Test func drawnForUnderHalfASecondKeepsTheCanvas() {
        // Drawn at 0.0 ... 0.4 s.
        let answers = Self.answers(Self.polled(drawn: true, held: true, from: 0, count: 5))
        #expect(answers.allSatisfy { !$0 })
    }

    @Test func drawnForOverHalfASecondHandsOverToRealityKit() {
        let answers = Self.answers([(true, true, 10), (true, true, 10.4), (true, true, 10.6), (true, true, 12)])
        #expect(answers == [false, false, true, true])
    }

    @Test func confirmedThenOffScreenStaysOnRealityKit() {
        // The homeowner turns to the meter: the battery's middle leaves the view and the model is
        // still anchored and enabled. The Canvas must not come back and draw a second cable.
        let offScreen = Self.polled(drawn: false, held: true, from: 0.7, count: 20)
        let answers = Self.answers(Self.confirming + offScreen)
        #expect(answers == [false, false, false, false, false, true, true] + Array(repeating: true, count: 20))
    }

    @Test func losingTheAnchorGoesBackToTheCanvasAtOnce() {
        let lost: [Look] = [
            (false, false, 0.7), (false, false, 0.8),
            // Held again (tracking back) with the battery out of view: the same model, already
            // seen drawing, takes the result back.
            (false, true, 0.9), (true, true, 1.0),
        ]
        let answers = Self.answers(Self.confirming + lost)
        #expect(answers == [false, false, false, false, false, true, true, false, false, true, true])
    }

    @Test func aBreakRestartsTheConfirmation() {
        // Out of view at 0.4 s, before the half second: the run starts again at 0.5 s.
        let answers = Self.answers([
            (true, true, 0), (true, true, 0.3), (false, true, 0.4), (true, true, 0.5), (true, true, 0.9), (true, true, 1.0),
        ])
        #expect(answers == [false, false, false, false, false, true])
    }

    @Test func aClockThatRunsBackDoesNotConfirmEarly() {
        let answers = Self.answers([(true, true, 5), (true, true, 1), (true, true, 1.4), (true, true, 1.5)])
        #expect(answers == [false, false, false, true])
    }

    @Test func drawnImpliesHeld() {
        // A look that reports drawn but not held still confirms, and isn't dropped for it.
        let answers = Self.answers(Self.polled(drawn: true, held: false, from: 0, count: 7))
        #expect(answers == [false, false, false, false, false, true, true])
    }

    @Test func aReplacedModelGoesBackToTheCanvasAndIsConfirmedAgain() {
        var policy = ResultOverlayPolicy()
        let confirmed = Self.answers(Self.confirming, to: &policy)
        #expect(confirmed.last == true)

        // publishWall rebuilt the model for a moved wall.
        policy.modelReplaced()
        #expect(!policy.usesRealityKit)

        // The new model looks anchored and in view at the very next look. That alone isn't
        // enough: it has to be seen for the half second again.
        let replacement = Self.answers(Self.polled(drawn: true, held: true, from: 0.7, count: 6), to: &policy)
        #expect(replacement == [false, false, false, false, false, true])

        // Nor does holding a replaced model out of view confirm it.
        policy.modelReplaced()
        let heldOnly = Self.answers(Self.polled(drawn: false, held: true, from: 1.3, count: 10), to: &policy)
        #expect(heldOnly.allSatisfy { !$0 })
    }

    @Test func usesRealityKitMatchesTheLastAnswer() {
        var policy = ResultOverlayPolicy()
        _ = Self.answers(Self.polled(drawn: true, held: true, from: 0, count: 6), to: &policy)
        let confirmed = policy.usesRealityKit
        policy.update(drawn: false, held: true, time: 0.6)
        let offScreen = policy.usesRealityKit
        policy.update(drawn: false, held: false, time: 0.7)
        let afterLoss = policy.usesRealityKit
        #expect(confirmed)
        #expect(offScreen)
        #expect(!afterLoss)
    }
}
