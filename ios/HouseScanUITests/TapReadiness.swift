import XCTest

/// Decides which live reads are safe before a real element tap. The clock and reads are
/// explicit so a slow AX query exhausting the budget can be tested without a simulator stall.
enum TapReadiness {
    struct Read {
        var frame: CGRect
        var isEnabled: Bool
    }

    enum State: String {
        case ready
        case missing = "button missing or snapshot unreadable"
        case invalidFrame = "button frame not laid out"
        case disabled = "button disabled"
        case invalidWindow = "window missing or frame not laid out"
        case outsideWindow = "button outside window above or beside it"
        case notHittable = "button not hittable"
        case expired = "readiness deadline exhausted"
    }

    static func evaluate(
        deadline: TimeInterval,
        now: () -> TimeInterval,
        read: () -> Read?,
        window: () -> CGRect?,
        hittable: () -> Bool
    ) -> State {
        guard now() < deadline else { return .expired }
        let target = read()
        guard now() < deadline else { return .expired }
        guard let target else { return .missing }
        guard laidOut(target.frame) else { return .invalidFrame }
        guard target.isEnabled else { return .disabled }
        let bounds = window()
        guard now() < deadline else { return .expired }
        guard let bounds, laidOut(bounds) else { return .invalidWindow }

        // PR run 37022177313 attempt 2 failed computing an offscreen AC chip's hit point.
        // The successful b926 run scrolled that chip during target.tap(). Decide this before
        // isHittable, which computes a hit point but does not scroll. Keep the bottom-edge
        // case only; a control translated above or beside the window must finish entering.
        if !bounds.contains(target.frame) {
            let below = target.frame.minY >= bounds.minY && target.frame.maxY > bounds.maxY
                && target.frame.minX >= bounds.minX && target.frame.maxX <= bounds.maxX
            return below ? .ready : .outsideWindow
        }
        let reached = hittable()
        guard now() < deadline else { return .expired }
        return reached ? .ready : .notHittable
    }

    private static func laidOut(_ frame: CGRect) -> Bool {
        // CGRect.infinite uses finite sentinel coordinates. The isolated XCTest run caught
        // it passing isFinite. CGRect.width/height also normalize negative stored sizes,
        // so validate the stored size before using the standardized edges.
        !frame.isNull && !frame.isInfinite && frame.size.width > 0 && frame.size.height > 0
            && [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                frame.origin.x + frame.size.width, frame.origin.y + frame.size.height,
                frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }
}

final class TapReadinessTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let visible = CGRect(x: 20, y: 700, width: 360, height: 44)

    func testInvalidOrMissingTargetsNeverAskForAWindowOrHitPoint() {
        let frames: [CGRect?] = [nil, .zero, .null, .infinite,
                                CGRect(x: CGFloat.nan, y: 0, width: 44, height: 44),
                                CGRect(x: 0, y: 0, width: CGFloat.nan, height: 44),
                                CGRect(x: 0, y: 0, width: 44, height: -44),
                                CGRect(x: 0, y: 0, width: -44, height: 44),
                                CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                                       width: CGFloat.greatestFiniteMagnitude, height: 44)]
        for frame in frames {
            let result = TapReadiness.evaluate(deadline: 20, now: { 0 }, read: {
                frame.map { TapReadiness.Read(frame: $0, isEnabled: true) }
            }, window: { XCTFail("an unreadable frame must not query the window"); return self.bounds },
               hittable: { XCTFail("an unreadable frame must not compute a hit point"); return true })
            XCTAssertEqual(result, frame == nil ? .missing : .invalidFrame, "invalid frame: \(String(describing: frame))")
        }
    }

    func testDisabledOffscreenButtonIsNotReady() {
        let result = TapReadiness.evaluate(deadline: 20, now: { 0 }, read: {
            .init(frame: CGRect(x: 20, y: 900, width: 360, height: 44), isEnabled: false)
        }, window: { XCTFail("a disabled button must not query the window"); return self.bounds },
           hittable: { XCTFail("a disabled button must not compute a hit point"); return true })
        XCTAssertEqual(result, .disabled)
    }

    func testBottomEdgeButtonsUseTapScrollingWithoutComputingAHitPoint() {
        for y in [CGFloat(780), 900] {
            let result = TapReadiness.evaluate(deadline: 20, now: { 0 }, read: {
                .init(frame: CGRect(x: 20, y: y, width: 360, height: 44), isEnabled: true)
            }, window: { self.bounds },
               hittable: { XCTFail("the tap must scroll before computing a hit point"); return false })
            XCTAssertEqual(result, .ready)
        }
    }

    func testOtherOffscreenGeometryDoesNotPermitATap() {
        for frame in [CGRect(x: 20, y: -10, width: 360, height: 44),
                      CGRect(x: -10, y: 780, width: 360, height: 44),
                      CGRect(x: 390, y: 700, width: 44, height: 44)] {
            let result = TapReadiness.evaluate(deadline: 20, now: { 0 }, read: {
                .init(frame: frame, isEnabled: true)
            }, window: { self.bounds },
               hittable: { XCTFail("outside geometry must not compute a hit point"); return true })
            XCTAssertEqual(result, .outsideWindow)
        }
    }

    func testInvalidWindowDoesNotPermitATap() {
        for frame in [nil, .zero, .infinite] as [CGRect?] {
            let result = TapReadiness.evaluate(deadline: 20, now: { 0 }, read: {
                .init(frame: self.visible, isEnabled: true)
            }, window: { frame },
               hittable: { XCTFail("an invalid window must not compute a hit point"); return true })
            XCTAssertEqual(result, .invalidWindow)
        }
    }

    func testVisibleButtonReadsEachInputOnceAndRequiresHittability() {
        for reached in [false, true] {
            var reads = 0, windows = 0, hits = 0
            let result = TapReadiness.evaluate(deadline: 20, now: { 0 }, read: {
                reads += 1
                return .init(frame: self.visible, isEnabled: true)
            }, window: { windows += 1; return self.bounds }, hittable: { hits += 1; return reached })
            XCTAssertEqual(result, reached ? .ready : .notHittable)
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(windows, 1)
            XCTAssertEqual(hits, 1)
        }
    }

    func testSlowReadsExhaustOneDeadlineWithoutIssuingMoreQueries() {
        for exhaustedStage in 0...2 {
            var time: TimeInterval = 0
            var reads = 0, windows = 0, hits = 0
            func evaluate() -> TapReadiness.State {
                TapReadiness.evaluate(deadline: 20, now: { time }, read: {
                    reads += 1
                    if exhaustedStage == 0 { time = 21 }
                    return .init(frame: self.visible, isEnabled: true)
                }, window: {
                    windows += 1
                    if exhaustedStage == 1 { time = 21 }
                    return self.bounds
                }, hittable: {
                    hits += 1
                    time = 21
                    return true
                })
            }
            XCTAssertEqual(evaluate(), .expired)
            XCTAssertEqual(evaluate(), .expired, "the next poll must not renew the deadline")
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(windows, exhaustedStage >= 1 ? 1 : 0)
            XCTAssertEqual(hits, exhaustedStage == 2 ? 1 : 0)
        }
    }
}
