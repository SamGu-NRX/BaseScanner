import Foundation
@testable import HouseScanKit
import Testing

/// Issue #75: the gap card names a server request's whole stretch, so a homeowner who shows
/// exactly what it names meets the request.
@Suite struct RequestStretchTests {
    private let metersPerFoot: Float = 0.3048

    private func feet(_ low: Float, _ high: Float) -> ClosedRange<Int> {
        RequestStretch.wholeFeet((low * metersPerFoot)...(high * metersPerFoot))
    }

    /// Nearest-foot rounding named 2.4...7.4 ft as 2...7 ft and left the last 0.4 ft unnamed.
    @Test func endsRoundOutward() {
        #expect(feet(2.4, 7.4) == 2...8)
        #expect(feet(-7.4, -2.4) == -8 ... -2)
        #expect(feet(-2.4, 7.4) == -3...8)
        #expect(feet(2.6, 7.6) == 2...8)
    }

    /// A span that starts or ends on a whole foot keeps it, after the trip to meters and back,
    /// and so does one within the server's 0.01 ft coverage tolerance of it.
    @Test func wholeFeetStayWhole() {
        #expect(feet(4, 7) == 4...7)
        #expect(feet(-9, -3) == -9 ... -3)
        #expect(feet(0, 5) == 0...5)
        #expect(feet(4.005, 6.995) == 4...7)
        #expect(feet(5.5, 5.5) == 5...6)
    }

    /// Run 2's request (#75): ground 4 ft 2 in to 33 ft 2 in right of the meter, with the right
    /// end marked as a limit at 19 ft 9 in. The planner raises it, because ground past a limit
    /// end is recorded, and it is met only over the whole span. Clipped at the end, the card said
    /// "from 4 ft to 20 ft" and the bar could never finish.
    @Test func aGroundRequestPastALimitEndIsNamedToItsFarEnd() throws {
        let item = try JSONDecoder().decode(PlacementMissingEvidence.self, from: Data(
            #"{"kind":"band","band":"ground","span_ft":[4.17,33.17],"out_ft":15.33,"message":"m"}"#.utf8))
        let rightEnd: Float = 19.75 * metersPerFoot
        let plan = try #require(GapPlanner().plan(for: item, leftEnd: -1, rightEnd: rightEnd, limitEnds: [.right]))
        let named = RequestStretch.wholeFeet(plan.span)
        #expect(named == 4...34)
        let requested = try #require(plan.requestedSpanFt)
        #expect(Double(named.lowerBound) <= requested.lowerBound)
        #expect(Double(named.upperBound) >= requested.upperBound)
    }

    /// Whatever the span, the whole feet named cover the feet the request needs, give or take
    /// the server's coverage tolerance (and float error on the way to meters and back).
    @Test func theNamedStretchCoversEveryRequestedSpan() {
        let slack = RequestStretch.toleranceFt + 1e-4
        for low in stride(from: Float(-30), through: 30, by: 0.37) {
            for length in [Float(0), 0.2, 1, 2.4, 9.99, 29.1] {
                let named = feet(low, low + length)
                #expect(Double(named.lowerBound) <= Double(low) + slack)
                #expect(Double(named.upperBound) >= Double(low + length) - slack)
            }
        }
    }
}
