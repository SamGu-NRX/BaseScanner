import HouseScanKit
import Testing

/// #67: "See it on your wall" keeps the Canvas drawing until the AR scene has been seen drawing
/// the result for half a second, and falls back to it the moment the AR scene stops.
@Suite struct ResultOverlayPolicyTests {
    /// Feeds `looks` to a fresh policy in order and returns each answer (true: the AR scene
    /// draws the result, false: the Canvas does).
    private static func answers(_ looks: [(drawn: Bool, time: Double)]) -> [Bool] {
        var policy = ResultOverlayPolicy()
        return looks.map { policy.update(drawn: $0.drawn, time: $0.time) }
    }

    /// Looks every 0.1 s from `start`, `count` times, as the engine does.
    private static func polled(drawn: Bool, from start: Double, count: Int) -> [(drawn: Bool, time: Double)] {
        (0..<count).map { (drawn: drawn, time: start + Double($0) * 0.1) }
    }

    @Test func startsOnTheCanvas() {
        let policy = ResultOverlayPolicy()
        #expect(!policy.usesRealityKit)
    }

    @Test func neverDrawnKeepsTheCanvas() {
        let answers = Self.answers(Self.polled(drawn: false, from: 0, count: 50))
        #expect(answers.allSatisfy { !$0 })
    }

    @Test func drawnForUnderHalfASecondKeepsTheCanvas() {
        // Drawn at 0.0 ... 0.4 s.
        let answers = Self.answers(Self.polled(drawn: true, from: 0, count: 5))
        #expect(answers.allSatisfy { !$0 })
    }

    @Test func drawnForOverHalfASecondHandsOverToRealityKit() {
        let answers = Self.answers([(true, 10), (true, 10.4), (true, 10.6), (true, 12)])
        #expect(answers == [false, false, true, true])
    }

    @Test func losingTheDrawingGoesBackToTheCanvasAtOnce() {
        let lost: [(drawn: Bool, time: Double)] = [
            (false, 0.7),
            // Drawing again has to be confirmed again from the start.
            (true, 0.8), (true, 1.2), (true, 1.4),
        ]
        let answers = Self.answers(Self.polled(drawn: true, from: 0, count: 7) + lost)
        #expect(answers == [false, false, false, false, false, true, true, false, false, false, true])
    }

    @Test func aBreakRestartsTheConfirmation() {
        let answers = Self.answers([(true, 0), (true, 0.3), (false, 0.4), (true, 0.5), (true, 0.9), (true, 1.0)])
        #expect(answers == [false, false, false, false, false, true])
    }

    @Test func aClockThatRunsBackDoesNotConfirmEarly() {
        let answers = Self.answers([(true, 5), (true, 1), (true, 1.4), (true, 1.5)])
        #expect(answers == [false, false, false, true])
    }

    /// Review of #100: once the AR scene has taken over, turning to the meter puts the battery
    /// out of view, but the scene still holds the result, so the Canvas stays off. Losing the
    /// anchor or the model hands it back, and the next take-over is confirmed from the start.
    @Test func confirmedThenOutOfViewButHeldStaysOnRealityKit() {
        var policy = ResultOverlayPolicy()
        var answers: [Bool] = []
        for look in Self.polled(drawn: true, from: 0, count: 6) {
            answers.append(policy.update(drawn: look.drawn, held: true, time: look.time))
        }
        answers.append(policy.update(drawn: false, held: true, time: 0.6))
        answers.append(policy.update(drawn: false, held: true, time: 5))
        answers.append(policy.update(drawn: false, held: false, time: 5.1))
        answers.append(policy.update(drawn: true, held: true, time: 5.2))
        answers.append(policy.update(drawn: true, held: true, time: 5.8))
        #expect(answers == [false, false, false, false, false, true, true, true, false, false, true])
    }

    /// Held alone never takes over: the AR scene has to be seen drawing the result first.
    @Test func heldButNeverDrawnKeepsTheCanvas() {
        var policy = ResultOverlayPolicy()
        let answers = (0..<20).map { policy.update(drawn: false, held: true, time: Double($0) * 0.1) }
        #expect(answers.allSatisfy { !$0 })
    }

    @Test func usesRealityKitMatchesTheLastAnswer() {
        var policy = ResultOverlayPolicy()
        for look in Self.polled(drawn: true, from: 0, count: 6) {
            policy.update(drawn: look.drawn, time: look.time)
        }
        let confirmed = policy.usesRealityKit
        policy.update(drawn: false, time: 0.6)
        let afterLoss = policy.usesRealityKit
        #expect(confirmed)
        #expect(!afterLoss)
    }
}
