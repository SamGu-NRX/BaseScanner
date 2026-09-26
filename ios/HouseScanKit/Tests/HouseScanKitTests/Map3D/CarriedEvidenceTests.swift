import HouseScanKit
import simd
import Testing

/// Walked-facing and confirmed-overhead evidence is measured along the walk's tapped wall; when
/// scene.json describes the measured chain, `ObservedSpan.carried` restates it along that chain.
@Suite struct CarriedEvidenceTests {
    static let tapped = WallFrame(meter: SIMD3(0, 1.2, 0), outward: SIMD3(0, 0, 1), groundY: 0)!

    /// The measured wall: its line 0.1 m in front of the tapped one, turned 5 degrees.
    static var measured: WallFrame {
        let angle: Float = 5 * .pi / 180
        return WallFrame(meter: SIMD3(0, 1.2, 0.1), outward: SIMD3(sin(angle), 0, cos(angle)), groundY: 0)!
    }

    @Test func aWalkedReachIsRestatedInsideWhatWasWalked() throws {
        let walked = [ObservedSpan(span: -2...2, out: 1.5)]
        let carried = try #require(ObservedSpan.carried(walked, depth: nil, from: Self.tapped, to: Self.measured).first)
        // The carried claim's corners lie over the walked span, and its far edge within the walked
        // reach, in the tapped wall's frame.
        for s in [carried.span.lowerBound, carried.span.upperBound] {
            for out in [Float(0), carried.out] {
                let p = Self.tapped.wallPoint(Self.measured.world(s: s, height: 0, out: out))
                #expect(p.s >= -2 - 1e-4 && p.s <= 2 + 1e-4 && p.out <= 1.5 + 1e-4, "(\(s), \(out)) lands at \(p)")
            }
        }
        // The measured line stands up to 0.1 + 2 sin 5 degrees = 0.27 m in front of the tapped one
        // over the span, which comes off the reach; the turn trims the ends.
        #expect(carried.out > 1.2 && carried.out < 1.4)
        #expect(carried.span.lowerBound > -2 && carried.span.upperBound < 2)
        #expect(carried.span.upperBound - carried.span.lowerBound > 3.5)
    }

    @Test func overheadKeepsItsHeightOverTheBatterysDepth() throws {
        let clear = [ObservedSpan(span: -1...1, out: 2.4)]
        let carried = ObservedSpan.carried(clear, depth: 0.5588, from: Self.tapped, to: Self.tapped)
        #expect(carried == clear)
        // A measured line 0.1 m out moves the battery's depth past what the tilt-up view vouched
        // for, so nothing is carried.
        #expect(ObservedSpan.carried(clear, depth: 0.5588, from: Self.tapped, to: Self.measured).isEmpty)
    }

    /// Past a corner of either wall, the evidence is not carried: only the meter's pieces are
    /// straight in both.
    @Test func nothingIsCarriedPastACorner() {
        var cornered = Self.tapped
        cornered.turn(.right, at: WallCorner(s: 1, outward: SIMD3(1, 0, 0)))
        let carried = ObservedSpan.carried([ObservedSpan(span: -1...3, out: 1)], depth: nil, from: Self.tapped, to: cornered)
        #expect(carried.allSatisfy { $0.span.upperBound <= 1 + 1e-4 })
        #expect(!carried.isEmpty)
    }
}
