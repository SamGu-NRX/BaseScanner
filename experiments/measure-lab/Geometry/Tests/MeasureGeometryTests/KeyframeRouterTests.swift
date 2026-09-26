import Testing
@testable import MeasureGeometry

struct KeyframeRouterTests {
    // Regression for review defect 2: with a single "closed session" slot, switching A → B → C
    // before A's pending write reported back dropped that keyframe from A's session.json.
    @Test func `a write survives two session switches`() {
        var router = KeyframeRouter<String>()
        router.open("A")
        let keepA = router.closeCurrent(reserved: 1)
        router.open("B")
        let keepB = router.closeCurrent(reserved: 0)
        router.open("C")
        #expect(keepA)
        #expect(!keepB)
        #expect(router.waitingSessions == ["A"])
        let late = router.report(for: "A")
        #expect(late.route == .closed)
        #expect(late.drained)
        #expect(router.waitingSessions.isEmpty)
    }

    @Test func `writes already reported before closing need no waiting`() {
        var router = KeyframeRouter<String>()
        router.open("A")
        let first = router.report(for: "A")
        let second = router.report(for: "A")
        let keep = router.closeCurrent(reserved: 2)
        let after = router.report(for: "A")
        #expect(first.route == .current && !first.drained)
        #expect(second.route == .current)
        #expect(!keep)
        #expect(after.route == .unknown)
    }

    @Test func `a closed session drains only after its last write`() {
        var router = KeyframeRouter<String>()
        router.open("A")
        _ = router.report(for: "A")
        let keep = router.closeCurrent(reserved: 3)
        router.open("B")
        let second = router.report(for: "A")
        let other = router.report(for: "B")
        let third = router.report(for: "A")
        let extra = router.report(for: "A")
        #expect(keep)
        #expect(second.route == .closed && !second.drained)
        #expect(other.route == .current)
        #expect(third.route == .closed && third.drained)
        #expect(extra.route == .unknown)
    }

    @Test func `an unknown session is not routed`() {
        var router = KeyframeRouter<String>()
        router.open("A")
        let stray = router.report(for: "Z")
        #expect(stray.route == .unknown)
    }
}
