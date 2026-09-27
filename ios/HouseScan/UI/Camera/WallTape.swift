import SwiftUI

/// The live map of the wall, unrolled into a strip like a tape measure with the meter at zero.
///
/// Top row is the wall face, bottom row the ground at its foot. Gray is not seen yet, amber
/// seen once, green seen well enough (docs/05 section 2); green is evidence, not approval.
/// Foot ticks run along the bottom edge so distances read at a glance without numbers.
///
/// The two states that aren't about how well the phone saw get a pattern as well as a color,
/// so they read in grayscale, and a legend line under the strip while any is on it: skipped is
/// slate with a slash, hidden (depth saw something in front) a violet dashed outline round the
/// stretch, as on the camera. On a phone with depth the same line says the map is depth-checked.
///
/// While ending the wall is on offer, a dashed chalk line shows where the end would land and the
/// strip past it on that side is dimmed: that part would be left out. The line follows the phone
/// (or the reticle) frame by frame, so it doesn't animate.
struct WallTape: View {
    var coverage: CoverageStrip
    var wall: WallGeometry
    var features: [MarkedFeature]
    /// The homeowner's position along the wall, meters of s, when known.
    var cameraS: Float?
    var highlight: GapRequest?
    /// The phone has depth, so a cell counts only where depth confirms the wall itself.
    var depthChecked = false
    /// Where a wall end would land now (`ScanViewState.endPreview`); nil hides the line.
    var endPreview: EndPreview?

    /// Glyph size for the meter and feature marks. It follows the text size, like every other
    /// glyph in the app (fixed 9 and 10 pt sizes failed the audit's Dynamic Type check), and
    /// stops growing at 16 pt so the marks still fit the strip's 58 pt height.
    @ScaledMetric(relativeTo: .caption2) private var glyphSize: CGFloat = 10
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var glyph: CGFloat { min(glyphSize, 16) }
    private var glyphBox: CGFloat { glyph * 1.8 }

    private static let footInMeters: Float = 0.3048

    var body: some View {
        let extent = Self.extent(coverage: coverage, wall: wall, cameraS: cameraS, also: markedS + [endPreview?.s].compactMap(\.self))
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
                            .font(.system(size: glyph, weight: .bold))
                            .foregroundStyle(Palette.chalk)
                            .frame(width: glyphBox, height: glyphBox * 0.9)
                            .background(Palette.ink.opacity(0.9), in: .rect(cornerRadius: 4))
                            .position(x: Self.inside(map.x(center), halfWidth: glyphBox / 2, width: proxy.size.width), y: glyphBox / 2 - 1)
                    }
                    Image(systemName: "bolt.fill")
                        .font(.system(size: glyph * 0.9, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: glyphBox, height: glyphBox)
                        .background(Palette.signal, in: .circle)
                        .position(x: Self.inside(map.x(0), halfWidth: glyphBox / 2, width: proxy.size.width), y: glyphBox / 2 - 1)
                }
            }
            .frame(height: 58)
            if showsFooter {
                footer
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsFooter)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ScrimShape.rounded(18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the wall")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("wallTape")
    }

    // MARK: Legend

    private var hiddenSections: [ClosedRange<Float>] { sections(of: .hidden) }
    private var skippedSections: [ClosedRange<Float>] { sections(of: .skipped) }

    private var showsFooter: Bool {
        depthChecked || !hiddenSections.isEmpty || !skippedSections.isEmpty || leavesOutWalked != nil
    }

    private var leavesOutWalked: Float? { endPreview?.leavesOutWalked }

    private var footer: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if let leavesOutWalked {
                LegendEntry(title: ScanCopy.endLeavesOut(leavesOutWalked)) { EndPreviewSwatch() }
            }
            if !hiddenSections.isEmpty {
                LegendEntry(title: "Hidden behind something") { HiddenSwatch() }
            }
            if !skippedSections.isEmpty {
                LegendEntry(title: "Skipped") { SkippedSwatch() }
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            if depthChecked {
                Label("Depth-checked", systemImage: "cube.transparent")
                    .font(Typeface.caption)
                    .foregroundStyle(Palette.chalk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Layout

    /// Keeps a glyph of `halfWidth` inside the strip. When the walk covers only one side, the
    /// meter sits at the strip's end, and a glyph centred there hung half outside it, which the
    /// accessibility audit reported as clipped on the real ADVIO replay.
    static func inside(_ x: CGFloat, halfWidth: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, halfWidth), max(halfWidth, width - halfWidth))
    }

    struct TapeMap {
        var extent: ClosedRange<Float>
        var width: CGFloat

        func x(_ s: Float) -> CGFloat {
            let span = max(extent.upperBound - extent.lowerBound, 0.01)
            return CGFloat((s - extent.lowerBound) / span) * width
        }
    }

    /// The middle of each marked feature. A mark past an end still counts (the server puts it on
    /// the wall's line continued past the end), so the strip draws it where it is rather than
    /// pinned to the strip's edge.
    private var markedS: [Float] {
        features.map { ($0.span.lowerBound + $0.span.upperBound) / 2 }
    }

    /// The s range drawn: everything the engine considers worth drawing, the marked ends, the
    /// meter, the homeowner and `also`, plus a little air on both sides.
    static func extent(coverage: CoverageStrip, wall: WallGeometry, cameraS: Float?, also: [Float] = []) -> ClosedRange<Float> {
        var lower = min(coverage.visibleRange.lowerBound, 0)
        var upper = max(coverage.visibleRange.upperBound, 0)
        for value in [wall.leftEnd, wall.rightEnd, cameraS].compactMap(\.self) + also {
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
                // Cells outside the engine's visible range are neither fog nor evidence.
                guard FogMemory.interiorsOverlap(range, coverage.visibleRange), isInsideEnds(range) else { continue }
                let x0 = map.x(range.lowerBound)
                let x1 = map.x(range.upperBound)
                let rect = CGRect(x: x0 + 0.5, y: row.minY, width: max(1, x1 - x0 - 1), height: row.height)
                // Hidden is a tint under a dashed outline drawn per stretch below: hollow, so it
                // never reads as a solid covered cell.
                let opacity = switch state {
                case .unseen: 0.55
                case .hidden: 0.22
                default: 1.0
                }
                context.fill(Path(rect), with: .color(Palette.cell(state).opacity(opacity)))
                if state == .skipped {
                    var slash = Path()
                    slash.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                    slash.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    context.stroke(slash, with: .color(.white.opacity(0.7)), lineWidth: 1)
                }
            }
            for run in runs(of: .hidden, in: band) {
                let rect = CGRect(x: map.x(run.lowerBound), y: row.minY, width: map.x(run.upperBound) - map.x(run.lowerBound), height: row.height)
                    .insetBy(dx: 0.75, dy: 0.75)
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(Palette.hidden),
                               style: StrokeStyle(lineWidth: 1.5, dash: Palette.hiddenDash))
            }
            if let gap = highlight, gap.band == band {
                let rect = CGRect(x: map.x(gap.span.lowerBound), y: row.minY - 2,
                                  width: map.x(gap.span.upperBound) - map.x(gap.span.lowerBound), height: row.height + 4)
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Palette.caution), lineWidth: 2)
            }
        }

        // What ending the wall at the preview would leave out: everything past it on that side.
        if let preview = endPreview {
            let x = map.x(preview.s)
            let band = CGRect(x: 0, y: wallRow.minY, width: size.width, height: groundRow.maxY - wallRow.minY)
            let veil = preview.side == .left
                ? band.divided(atDistance: max(0, x), from: .minXEdge).slice
                : band.divided(atDistance: max(0, x), from: .minXEdge).remainder
            context.fill(Path(veil), with: .color(.black.opacity(0.55)))
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

        // Where the end would land: a dashed chalk line as tall as the end caps, on a dark
        // underlay so it reads over bright cells in sun.
        if let preview = endPreview {
            let x = map.x(preview.s)
            var line = Path()
            line.move(to: CGPoint(x: x, y: wallRow.minY - 4))
            line.addLine(to: CGPoint(x: x, y: groundRow.maxY + 4))
            context.stroke(line, with: .color(.black.opacity(0.6)), lineWidth: 4)
            context.stroke(line, with: .color(Palette.chalk), style: StrokeStyle(lineWidth: 2, dash: [3, 2.5]))
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

    /// Runs of cells in `state` within one band, as s ranges, over the cells the strip draws.
    private func runs(of state: CellState, in band: CoverageBand) -> [ClosedRange<Float>] {
        var runs: [ClosedRange<Float>] = []
        for (index, cell) in coverage.cells(band).enumerated() {
            let range = coverage.cellRange(index)
            guard cell == state, FogMemory.interiorsOverlap(range, coverage.visibleRange), isInsideEnds(range) else { continue }
            if let last = runs.last, last.upperBound >= range.lowerBound - 0.001 {
                runs[runs.count - 1] = last.lowerBound...range.upperBound
            } else {
                runs.append(range)
            }
        }
        return runs
    }

    /// Stretches of wall with cells in `state` in either band, overlapping runs merged: a bush
    /// that hides both the wall and the ground in front of it is one section, not two.
    private func sections(of state: CellState) -> [ClosedRange<Float>] {
        let all = (runs(of: state, in: .wall) + runs(of: state, in: .ground)).sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Float>] = []
        for run in all {
            if let last = merged.last, last.upperBound >= run.lowerBound - 0.001 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, run.upperBound)
            } else {
                merged.append(run)
            }
        }
        return merged
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
        if let hidden = Self.count(hiddenSections.count, "section") {
            parts.append("\(hidden) hidden behind something")
        }
        if let skipped = Self.count(skippedSections.count, "section") {
            parts.append("\(skipped) skipped")
        }
        if let preview = endPreview {
            var sentence = preview.atReticle
                ? "Wall ends here marks the \(preview.side.rawValue) end \(Self.spokenFromMeter(preview.s))"
                : "If you end the wall now, the \(preview.side.rawValue) end goes \(Self.spokenFromMeter(preview.s))"
            if let leavesOutWalked {
                sentence += ", leaving out \(Distance.spoken(leavesOutWalked)) you walked"
            }
            parts.append(sentence)
        }
        for (side, end) in [("Left", wall.leftEnd), ("Right", wall.rightEnd)] {
            if let end { parts.append("\(side) end \(Self.spokenFromMeter(end))") }
        }
        if wall.leftEnd != nil, wall.rightEnd != nil {
            parts.append("Both ends marked")
        }
        if depthChecked {
            parts.append("Checked with your phone's depth sensor")
        }
        return parts.joined(separator: ". ")
    }

    /// "5 feet 2 inches left of your meter", or "at your meter" within 3 in, as `Distance.fromMeter`.
    static func spokenFromMeter(_ s: Float) -> String {
        if abs(s) < Distance.metersPerInch * 3 { return "at your meter" }
        return "\(Distance.spoken(s)) \(s < 0 ? "left" : "right") of your meter"
    }

    /// "1 section", "2 sections"; nil for none.
    private static func count(_ n: Int, _ noun: String) -> String? {
        n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private func percentSeen(in range: ClosedRange<Float>) -> Int {
        let states = coverage.wall.indices.filter { range.overlaps(coverage.cellRange($0)) }.map { coverage.wall[$0] }
        guard !states.isEmpty else { return 0 }
        // Split up: as one expression it took the type checker over 60 ms.
        let seen = Double(states.filter { $0 == .seen || $0 == .covered }.count)
        let fraction = seen / Double(states.count)
        return Int((fraction * 100).rounded())
    }
}

// MARK: - Legend pieces

private struct LegendEntry<Swatch: View>: View {
    var title: String
    @ViewBuilder var swatch: Swatch

    var body: some View {
        HStack(spacing: 6) {
            swatch
            Text(title)
                .font(Typeface.caption)
                .foregroundStyle(Palette.chalk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A hidden cell as the strip draws it: violet tint inside a dashed violet outline.
private struct HiddenSwatch: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Palette.hidden.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.hidden, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
            .frame(width: 18, height: 12)
    }
}

/// The end preview as the strip draws it: a dashed chalk line with the stretch past it dimmed.
private struct EndPreviewSwatch: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Palette.cell(.covered)))
            context.fill(Path(rect.divided(atDistance: size.width / 2, from: .minXEdge).remainder), with: .color(.black.opacity(0.55)))
            var line = Path()
            line.move(to: CGPoint(x: size.width / 2, y: 0))
            line.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(line, with: .color(Palette.chalk), style: StrokeStyle(lineWidth: 2, dash: [3, 2.5]))
        }
        .frame(width: 18, height: 12)
    }
}

/// A skipped cell as the strip draws it: slate with a white slash.
private struct SkippedSwatch: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Palette.skipped))
            var slash = Path()
            slash.move(to: CGPoint(x: rect.minX + 3, y: rect.maxY))
            slash.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.minY))
            context.stroke(slash, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        .frame(width: 18, height: 12)
    }
}
