import Foundation
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

    /// A wall of one straight piece: the meter, the ground, the ends, along and out.
    private static func shape(meter: SIMD3<Float> = .zero, groundY: Float = -1.2, rightEnd: Float? = 3,
                              along: SIMD3<Float> = SIMD3(1, 0, 0)) -> ResultModelShape {
        ResultModelShape(points: [meter], values: [groundY, -2, rightEnd], directions: [along, SIMD3(0, 0, 1)])
    }

    /// The policy as the engine has it after "See it on your wall" opened and the AR scene was
    /// seen drawing the first model.
    private static func confirmedPolicy() -> ResultOverlayPolicy {
        var policy = ResultOverlayPolicy()
        #expect(policy.needsModel(for: shape(), rising: true))
        let answers = Self.answers(Self.confirming, to: &policy)
        #expect(answers.last == true)
        return policy
    }

    @Test func theFirstModelIsBuiltAndStartsOnTheCanvas() {
        var policy = ResultOverlayPolicy()
        #expect(policy.needsModel(for: Self.shape(), rising: false))
        #expect(policy.builtFor == Self.shape())
        #expect(!policy.usesRealityKit)
    }

    @Test func aWallThatMovedALittleKeepsItsConfirmedModel() {
        var policy = Self.confirmedPolicy()
        // The ground refined by 2 cm, the meter's anchor by 3 cm, the wall turned 1°.
        let turned = SIMD3<Float>(cos(Float.pi / 180), 0, sin(Float.pi / 180))
        let moved = Self.shape(meter: SIMD3(0.03, 0, 0), groundY: -1.22, along: turned)
        #expect(!policy.needsModel(for: moved, rising: false))
        #expect(policy.usesRealityKit)
        #expect(policy.update(drawn: false, held: true, time: 0.8))
    }

    /// Codex and Sam on #100: a model rebuilt for a moved wall kept the old one's confirmation,
    /// so a replacement that looked anchored and in view at the next look hid the Canvas at once.
    @Test func aRebuiltModelGoesBackToTheCanvasAndIsConfirmedAgain() {
        var policy = Self.confirmedPolicy()
        // The ground moved 10 cm: a new model.
        #expect(policy.needsModel(for: Self.shape(groundY: -1.3), rising: false))
        #expect(!policy.usesRealityKit)

        // The new model looks anchored and in view at the very next look. That alone isn't
        // enough: it has to be seen for the half second again.
        let replacement = Self.answers(Self.polled(drawn: true, held: true, from: 0.7, count: 6), to: &policy)
        #expect(replacement == [false, false, false, false, false, true])
    }

    /// Sam on #100: a model rebuilt while the battery is out of view is held, not drawn, so it
    /// stays behind the Canvas until the battery comes into view. The engine keeps it
    /// see-through meanwhile, so only the Canvas shows.
    @Test func aModelRebuiltOutOfViewStaysOnTheCanvasUntilSeen() {
        var policy = Self.confirmedPolicy()
        #expect(policy.needsModel(for: Self.shape(rightEnd: 3.5), rising: false))
        let heldOnly = Self.answers(Self.polled(drawn: false, held: true, from: 0.7, count: 30), to: &policy)
        #expect(heldOnly.allSatisfy { !$0 })
        let inView = Self.answers(Self.polled(drawn: true, held: true, from: 3.7, count: 6), to: &policy)
        #expect(inView == [false, false, false, false, false, true])
    }

    @Test func turningPastTwoDegreesOrAnotherPieceRebuilds() {
        var policy = Self.confirmedPolicy()
        let turned = SIMD3<Float>(cos(3 * Float.pi / 180), 0, sin(3 * Float.pi / 180))
        #expect(policy.needsModel(for: Self.shape(along: turned), rising: false))
        #expect(!policy.usesRealityKit)

        var cornered = Self.confirmedPolicy()
        var withCorner = Self.shape()
        withCorner.points.append(SIMD3(3, 0, 0))
        #expect(cornered.needsModel(for: withCorner, rising: false))
    }

    @Test func reopeningTheScreenAlwaysRebuilds() {
        var policy = Self.confirmedPolicy()
        #expect(policy.needsModel(for: Self.shape(), rising: true))
        #expect(!policy.usesRealityKit)
    }

    @Test func aModelThatCouldNotGoInLeavesNone() {
        var policy = Self.confirmedPolicy()
        policy.modelRemoved()
        #expect(policy.builtFor == nil)
        #expect(!policy.usesRealityKit)
        // The next wall update builds one, however little the wall moved.
        #expect(policy.needsModel(for: Self.shape(), rising: false))
    }

    @Test func anOpenEndCountsAsTheSameOnlyIfBothAreOpen() {
        #expect(Self.shape(rightEnd: nil).isClose(to: Self.shape(rightEnd: nil)))
        #expect(!Self.shape(rightEnd: nil).isClose(to: Self.shape(rightEnd: 3)))
        let open = ResultModelShape(points: [], values: [Float.infinity], directions: [])
        #expect(open.isClose(to: open))
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
