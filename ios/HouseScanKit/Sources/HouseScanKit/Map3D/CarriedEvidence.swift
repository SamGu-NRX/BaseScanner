import Foundation
import simd

extension ObservedSpan {
    /// Clear-space claims measured along one wall (`from`, the walk's tapped wall), restated
    /// along another (`to`, the measured chain scene.json describes) so that each restated
    /// claim covers only ground the original covered.
    ///
    /// A claim is the rectangle in front of the wall over its span: out to its own `out` when
    /// `depth` is nil (walked facing), or out to `depth` with `out` a height (confirmed overhead
    /// over the battery's depth). Only the meter's piece of each wall is used: past a corner of
    /// either, one straight stretch of the other can face two ways, so what lies past one is
    /// dropped. On the meter's pieces the span's ends are carried through their places on the
    /// ground; the reach loses the most the new line stands in front of the old over the span;
    /// both ends come in by the reach times the sine of the angle between the lines; and the
    /// restated rectangle's corners are checked against the original. Walked facing is the gap
    /// from the wall to whatever faces it, so only its far edge must stay within the walked
    /// reach; its near edge is the new wall's face, which may stand behind the old line. An
    /// overhead claim vouches for the space over the battery's depth, so its whole rectangle
    /// must lie inside the original. A claim that fails the check, or has nothing left, is
    /// dropped.
    public static func carried(_ spans: [ObservedSpan], depth: Float?, from tapped: WallFrame, to measured: WallFrame) -> [ObservedSpan] {
        guard tapped != measured else { return spans }
        let tappedPiece = tapped.segments[tapped.meterSegmentIndex]
        let measuredPiece = measured.segments[measured.meterSegmentIndex]
        let sine = abs(simd_cross(tappedPiece.outward, measuredPiece.outward).y)
        // Where a point in front of the measured wall lies in front of the tapped one.
        func onTapped(_ s: Float, _ out: Float) -> (s: Float, out: Float) {
            let c = tappedPiece.coordinates(ofOffset: measured.world(s: s, height: 0, out: out) - tapped.origin)
            return (c.s, c.out)
        }
        let tolerance: Float = 1e-4
        return spans.compactMap { item in
            let a = max(item.span.lowerBound, tappedPiece.span.lowerBound)
            let b = min(item.span.upperBound, tappedPiece.span.upperBound)
            guard a < b else { return nil }
            let ends = [tapped.s(a, along: measured), tapped.s(b, along: measured)]
            var low = max(ends.min() ?? 0, measuredPiece.span.lowerBound)
            var high = min(ends.max() ?? 0, measuredPiece.span.upperBound)
            guard low < high else { return nil }
            let original = depth ?? item.out
            let standsOut = max(0, onTapped(low, 0).out, onTapped(high, 0).out)
            let reach = depth ?? (item.out - standsOut)
            guard reach > 0 else { return nil }
            low += reach * sine
            high -= reach * sine
            guard low < high else { return nil }
            for (s, out) in [(low, Float(0)), (low, reach), (high, 0), (high, reach)] {
                let p = onTapped(s, out)
                guard p.s >= a - tolerance, p.s <= b + tolerance, p.out <= original + tolerance else { return nil }
                if depth != nil, p.out < -tolerance { return nil }
            }
            return ObservedSpan(span: low...high, out: depth == nil ? reach : item.out)
        }
    }
}
