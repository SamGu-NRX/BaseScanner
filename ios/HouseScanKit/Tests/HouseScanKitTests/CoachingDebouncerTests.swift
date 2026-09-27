import Foundation
import HouseScanKit
import Testing

/// Synthetic frame sequences at the gate's pace, about ten judged frames a second.
@Suite struct CoachingDebouncerTests {
    typealias Problem = CoachingDebouncer.GateProblem

    /// One judged frame.
    struct Frame {
        var time: Double
        var skip: CaptureDecision.SkipReason?
        var luma: Double? = 128
        var aiming = false
    }

    /// What the debouncer says for each frame.
    static func run(_ frames: [Frame], on debouncer: inout CoachingDebouncer) -> [Problem?] {
        frames.map { debouncer.update(time: $0.time, skip: $0.skip, meanLuma: $0.luma, aiming: $0.aiming) }
    }

    static func run(_ frames: [Frame]) -> [Problem?] {
        var debouncer = CoachingDebouncer()
        return run(frames, on: &debouncer)
    }

    /// Frames every 0.1 s from `start` for `seconds`.
    static func times(from start: Double = 0, for seconds: Double) -> [Double] {
        (0..<Int((seconds * 10).rounded())).map { start + Double($0) / 10 }
    }

    /// How many times the answer turns on (`shows`) and off (`clears`) for `problems`.
    static func transitions(_ said: [Problem?], of problems: Set<Problem>) -> (shows: Int, clears: Int) {
        var shows = 0
        var clears = 0
        var up = false
        for answer in said {
            let now = answer.map { problems.contains($0) } ?? false
            if now, !up { shows += 1 }
            if !now, up { clears += 1 }
            up = now
        }
        return (shows, clears)
    }

    static let dark: Set<Problem> = [.tooDark, .persistentlyDark]

    /// #80: a night scene's luma sitting on the gate's 40 made the dark card come and go every few
    /// seconds. With hysteresis it shows once and clears once, when the light is really back.
    @Test func lumaOscillatingAroundTheGateShowsOnceAndClearsOnce() {
        // 40 ± 6 luma, a few seconds a swing, for 30 s; then 60 luma for 4 s.
        let night = Self.times(for: 30).map { t -> Frame in
            let luma = 40 + 6 * sin(t * 1.7)
            return Frame(time: t, skip: luma < 40 ? .tooDark : .redundant, luma: luma)
        }
        let light = Self.times(from: 30, for: 4).map { Frame(time: $0, skip: .redundant, luma: 60) }
        let said = Self.run(night + light)
        let (shows, clears) = Self.transitions(said, of: Self.dark)
        #expect(shows == 1)
        #expect(clears == 1)
        #expect(said.last! == nil)
    }

    /// #80: a tilt in the dark turned the gate's reason from too dark to moving and back, which
    /// swapped the card. Darkness is judged from luma, so the flip neither hides it nor restarts it.
    @Test func tooDarkAndMovingFlipsDontRestartTheDarkCoaching() {
        let frames = Self.times(for: 6).enumerated().map { index, t in
            Frame(time: t, skip: index % 3 == 0 ? .movingFast : .tooDark, luma: 30)
        }
        let said = Self.run(frames)
        let first = said.firstIndex { $0 == .tooDark }
        #expect(first != nil)
        // Up within the first second, and never down or replaced after that.
        #expect((first ?? .max) <= 10)
        #expect(said[(first ?? 0)...].allSatisfy { $0 == .tooDark })
    }

    /// Once shown, a different problem on some frames doesn't restart moving fast.
    @Test func movingFastStaysThroughOtherReasons() {
        var debouncer = CoachingDebouncer()
        let fast = Self.times(for: 1).map { Frame(time: $0, skip: .movingFast) }
        #expect(Self.run(fast, on: &debouncer).last! == .movingFast)
        // Fast frames with a blurry one in between (a frame the gate found not moving, 0.1 s).
        let mixed = Self.times(from: 1, for: 1).enumerated().map { index, t in
            Frame(time: t, skip: index == 4 ? .blurry : .movingFast)
        }
        #expect(Self.run(mixed, on: &debouncer).allSatisfy { $0 == .movingFast })
    }

    /// A single fast frame is a jolt: nothing shows.
    @Test func shortSpellsSayNothing() {
        let frames = Self.times(for: 3).enumerated().map { index, t in
            Frame(time: t, skip: index % 5 == 0 ? .movingFast : .redundant)
        }
        #expect(Self.run(frames).allSatisfy { $0 == nil })
    }

    /// #26: during an aim or a tilt the motion is the phone turning, so "Slow down" is not said.
    @Test func slowDownIsSuppressedWhileAiming() {
        let aiming = Self.times(for: 3).map { Frame(time: $0, skip: .movingFast, aiming: true) }
        #expect(Self.run(aiming).allSatisfy { $0 == nil })
        let walking = Self.times(for: 3).map { Frame(time: $0, skip: .movingFast, aiming: false) }
        #expect(Self.run(walking).last! == .movingFast)
    }

    /// A gap request to walk the stretch far enough out asks for walking, so hurrying along it is
    /// still told to slow down. The other requests ask the homeowner to stand and aim.
    @Test func aWalkOutRequestStillSaysSlowDown() {
        #expect(GapPlan.Need.walkOut(1.5).asksToWalk)
        let standing: [GapPlan.Need] = [.cells, .groundOut(1.5), .overhead(nil), .overhead(2), .wallUp(2)]
        for need in standing {
            #expect(!need.asksToWalk, "\(need)")
        }
        let walkOut = Self.times(for: 3).map { Frame(time: $0, skip: .movingFast, aiming: !GapPlan.Need.walkOut(1.5).asksToWalk) }
        #expect(Self.run(walkOut).last! == .movingFast)
        let groundOut = Self.times(for: 3).map { Frame(time: $0, skip: .movingFast, aiming: !GapPlan.Need.groundOut(1.5).asksToWalk) }
        #expect(Self.run(groundOut).allSatisfy { $0 == nil })
    }

    /// Turning fast is its own problem, said while aiming too.
    @Test func turningFastShowsAfterItsSpell() {
        let frames = Self.times(for: 2).map { Frame(time: $0, skip: .turningFast, aiming: true) }
        let said = Self.run(frames)
        #expect(said.prefix(7).allSatisfy { $0 == nil })
        #expect(said.last! == .turningFast)
    }

    /// Blur from a tilt that changes the view: under 2 s it says nothing.
    @Test func shortBlurSaysNothing() {
        let blur = Self.times(for: 1.8).map { Frame(time: $0, skip: .blurry) }
        let after = Self.times(from: 1.8, for: 1).map { Frame(time: $0, skip: .redundant) }
        #expect(Self.run(blur + after).allSatisfy { $0 == nil })
        let long = Self.times(for: 2.5).map { Frame(time: $0, skip: .blurry) }
        #expect(Self.run(long).last! == .blurry)
    }

    /// A shown problem clears half a second after its last frame.
    @Test func motionClearsAfterItsLastFrame() {
        let fast = Self.times(for: 1).map { Frame(time: $0, skip: .movingFast) }
        let calm = Self.times(from: 1, for: 1).map { Frame(time: $0, skip: .redundant) }
        let said = Self.run(fast + calm)
        #expect(said[10] == .movingFast)
        #expect(said.last! == nil)
    }

    /// Mostly dark for more than 20 s: said once, instead of "It's dark here", until it's light.
    @Test func persistentDarkIsSaidOnce() {
        var debouncer = CoachingDebouncer()
        let night = Self.times(for: 25).map { Frame(time: $0, skip: .tooDark, luma: 25) }
        let said = Self.run(night, on: &debouncer)
        #expect(said[30] == .tooDark)
        #expect(said.last! == .persistentlyDark)
        let light = Self.times(from: 25, for: 4).map { Frame(time: $0, skip: .redundant, luma: 90) }
        #expect(Self.run(light, on: &debouncer).last! == nil)
        let nightAgain = Self.times(from: 29, for: 25).map { Frame(time: $0, skip: .tooDark, luma: 25) }
        let again = Self.run(nightAgain, on: &debouncer)
        #expect(again.last! == .tooDark)
        #expect(!again.contains { $0 == .persistentlyDark })
    }

    /// Frames without a luma measurement don't count toward darkness either way.
    @Test func unmeasuredFramesDontRaiseDarkness() {
        let frames = Self.times(for: 3).map { Frame(time: $0, skip: .tooDark, luma: nil) }
        #expect(Self.run(frames).allSatisfy { $0 == nil })
    }

    /// A replay that restarts (time going back) starts over.
    @Test func timeGoingBackStartsOver() {
        var debouncer = CoachingDebouncer()
        let night = Self.times(for: 2).map { Frame(time: $0, skip: .tooDark, luma: 25) }
        #expect(Self.run(night, on: &debouncer).last! == .tooDark)
        #expect(debouncer.update(time: 0, skip: nil, meanLuma: 128, aiming: false) == nil)
        #expect(!debouncer.isDark)
    }
}
