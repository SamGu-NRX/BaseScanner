import SwiftUI

/// The live map of the wall, unrolled into a strip like a tape measure with the meter at zero.
///
/// Top row is the wall face, bottom row the ground at its foot. Gray is not seen yet, amber
/// seen once, green seen well enough (docs/05 section 2); green is evidence, not approval.
/// Foot ticks run along the bottom edge so distances read at a glance without numbers.
struct WallTape: View {
    var coverage: CoverageStrip
    var wall: WallGeometry
    var features: [MarkedFeature]
    /// The homeowner's position along the wall, meters of s, when known.
    var cameraS: Float?
    var highlight: GapRequest?

    private static let footInMeters: Float = 0.3048

    var body: some View {
        let extent = Self.extent(coverage: coverage, wall: wall, cameraS: cameraS)
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let map = TapeMap(extent: extent, width: proxy.size.width)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(in: &context, size: size, map: map)
                    }
                    ForEach(features) { feature in
                        let center = (feature.span.lowerBound + feature.span.upperBound) / 2
                        Image(systemName: ScanCopy.symbol(feature.kind))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.chalk)
                            .frame(width: 18, height: 16)
                            .background(Palette.ink.opacity(0.9), in: .rect(cornerRadius: 4))
                            .position(x: map.x(center), y: 8)
                    }
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Palette.signal, in: .circle)
                        .position(x: map.x(0), y: 8)
                }
            }
            .frame(height: 58)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ScrimShape.rounded(18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the wall")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("wallTape")
    }

    // MARK: Layout

    struct TapeMap {
        var extent: ClosedRange<Float>
        var width: CGFloat

        func x(_ s: Float) -> CGFloat {
            let span = max(extent.upperBound - extent.lowerBound, 0.01)
            return CGFloat((s - extent.lowerBound) / span) * width
        }
    }

    /// The s range drawn: everything the engine considers worth drawing, the marked ends, the
    /// meter and the homeowner, plus a little air on both sides.
    static func extent(coverage: CoverageStrip, wall: WallGeometry, cameraS: Float?) -> ClosedRange<Float> {
        var lower = min(coverage.visibleRange.lowerBound, 0)
        var upper = max(coverage.visibleRange.upperBound, 0)
        for value in [wall.leftEnd, wall.rightEnd, cameraS].compactMap(\.self) {
            lower = min(lower, value)
            upper = max(upper, value)
        }
        let minimumSpan: Float = 3
        if upper - lower < minimumSpan {
            let pad = (minimumSpan - (upper - lower)) / 2
            lower -= pad
            upper += pad
        }
        return (lower - 0.25)...(upper + 0.25)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, map: TapeMap) {
        let wallRow = CGRect(x: 0, y: 20, width: size.width, height: 14)
        let groundRow = CGRect(x: 0, y: wallRow.maxY + 3, width: size.width, height: 9)
        let tickTop = groundRow.maxY + 3

        // Base track, so unknown stretches read as "tape" rather than nothing.
        context.fill(Path(roundedRect: wallRow, cornerRadius: 3), with: .color(.white.opacity(0.08)))
        context.fill(Path(roundedRect: groundRow, cornerRadius: 3), with: .color(.white.opacity(0.08)))

        for band in CoverageBand.allCases {
            let row = band == .wall ? wallRow : groundRow
            for (index, state) in coverage.cells(band).enumerated() {
                let range = coverage.cellRange(index)
                guard range.overlaps(map.extent), isInsideEnds(range) else { continue }
                let x0 = map.x(range.lowerBound)
                let x1 = map.x(range.upperBound)
                let rect = CGRect(x: x0 + 0.5, y: row.minY, width: max(1, x1 - x0 - 1), height: row.height)
                context.fill(Path(rect), with: .color(Palette.cell(state).opacity(state == .unseen ? 0.55 : 1)))
                if state == .skipped {
                    var slash = Path()
                    slash.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                    slash.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    context.stroke(slash, with: .color(.white.opacity(0.7)), lineWidth: 1)
                }
            }
            if let gap = highlight, gap.band == band {
                let rect = CGRect(x: map.x(gap.span.lowerBound), y: row.minY - 2,
                                  width: map.x(gap.span.upperBound) - map.x(gap.span.lowerBound), height: row.height + 4)
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Palette.caution), lineWidth: 2)
            }
        }

        // Foot ticks along the bottom edge; every fifth foot is longer.
        let firstFoot = Int((map.extent.lowerBound / Self.footInMeters).rounded(.up))
        let lastFoot = Int((map.extent.upperBound / Self.footInMeters).rounded(.down))
        if firstFoot <= lastFoot {
            var ticks = Path()
            for foot in firstFoot...lastFoot {
                let x = map.x(Float(foot) * Self.footInMeters)
                ticks.move(to: CGPoint(x: x, y: tickTop))
                ticks.addLine(to: CGPoint(x: x, y: tickTop + (foot % 5 == 0 ? 7 : 3.5)))
            }
            context.stroke(ticks, with: .color(Palette.chalk.opacity(0.7)), lineWidth: 1)
        }

        // Meter line through both rows.
        var meterLine = Path()
        meterLine.move(to: CGPoint(x: map.x(0), y: 16))
        meterLine.addLine(to: CGPoint(x: map.x(0), y: groundRow.maxY + 2))
        context.stroke(meterLine, with: .color(Palette.signal), lineWidth: 2)

        // Marked ends: tall chalk caps.
        for end in [wall.leftEnd, wall.rightEnd].compactMap(\.self) {
            let x = map.x(end)
            let cap = CGRect(x: x - 1.5, y: wallRow.minY - 4, width: 3, height: groundRow.maxY - wallRow.minY + 8)
            context.fill(Path(roundedRect: cap, cornerRadius: 1.5), with: .color(Palette.chalk))
        }

        // The homeowner: a white pointer under the strip, like the cursor on a tape.
        if let cameraS {
            let x = map.x(min(max(cameraS, map.extent.lowerBound), map.extent.upperBound))
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: groundRow.maxY + 1))
            marker.addLine(to: CGPoint(x: x - 7, y: groundRow.maxY + 11))
            marker.addLine(to: CGPoint(x: x + 7, y: groundRow.maxY + 11))
            marker.closeSubpath()
            context.fill(marker, with: .color(.white))
            context.stroke(marker, with: .color(Palette.signal), lineWidth: 1.5)
        }
    }

    private func isInsideEnds(_ range: ClosedRange<Float>) -> Bool {
        if let left = wall.leftEnd, range.upperBound <= left { return false }
        if let right = wall.rightEnd, range.lowerBound >= right { return false }
        return true
    }

    // MARK: Accessibility

    private var accessibilitySummary: String {
        var parts: [String] = []
        let lowerLeft = wall.leftEnd ?? min(coverage.visibleRange.lowerBound, 0)
        let upperRight = wall.rightEnd ?? max(coverage.visibleRange.upperBound, 0)
        if lowerLeft < -0.05 {
            parts.append("Left of your meter: \(percentSeen(in: lowerLeft...0)) percent seen")
        }
        if upperRight > 0.05 {
            parts.append("Right of your meter: \(percentSeen(in: 0...upperRight)) percent seen")
        }
        if let cameraS {
            parts.append("You are \(Distance.spoken(cameraS)) \(cameraS < 0 ? "left" : "right") of your meter")
        }
        if wall.leftEnd != nil, wall.rightEnd != nil {
            parts.append("Both ends marked")
        }
        return parts.joined(separator: ". ")
    }

    private func percentSeen(in range: ClosedRange<Float>) -> Int {
        let states = coverage.wall.indices.filter { range.overlaps(coverage.cellRange($0)) }.map { coverage.wall[$0] }
        guard !states.isEmpty else { return 0 }
        return Int((Double(states.filter { $0 == .seen || $0 == .covered }.count) / Double(states.count) * 100).rounded())
    }
}
