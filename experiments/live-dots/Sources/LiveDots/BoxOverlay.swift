import LiveDotsCore
import SwiftUI

/// Brackets around the recognised things on the wall (simulated from the fixture's scene), in
/// the manner of RoomPlan's outlines. The electric meter is solid Signal blue from the first
/// keyframe it is in view; the others appear dashed at 60% Hologram (not settled) and turn solid
/// at 90% once seen face-on. Appearing fades in over 200 ms, settling crossfades over 150 ms, and
/// the meter flashes once when the hold completes. All of it is opacity, so Reduce Motion needs
/// no variant.
struct BoxOverlay: View {
    var keyframe: Keyframe
    var boxes: [BoxState]
    var time: Float

    static let signalBlue = Color(red: 0x1F / 255, green: 0x66 / 255, blue: 0xF2 / 255)
    static let viewSize = SIMD2<Float>(390, 844)

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            let projection = ScreenProjection(keyframe: keyframe, viewSize: Self.viewSize)
            for (box, state) in zip(RecognisedBox.fixture, boxes) {
                guard let appeared = state.appearedAt, time >= appeared else { continue }
                let points = box.corners.compactMap(projection.screenPoint)
                guard points.count == 4 else { continue }
                let corners = Self.outset(points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
                let shown = Double(CubicBezier.strongEaseOut((time - appeared) / 0.2))
                let settled = state.solidAt.map { Double(CubicBezier.strongEaseOut((time - $0) / 0.15)) } ?? 0
                let path = Self.bracket(corners)
                if box.isMeter {
                    context.stroke(path, with: .color(Self.signalBlue.opacity(shown)), style: Self.solid)
                    let flash = flashStrength
                    if flash > 0 {
                        context.stroke(path, with: .color(.white.opacity(0.8 * flash)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    context.stroke(path, with: .color(Palette.hologram.opacity(0.6 * (1 - settled) * shown)), style: Self.dashed)
                    context.stroke(path, with: .color(Palette.hologram.opacity(0.9 * settled * shown)), style: Self.solid)
                }
                drawCaption(box.caption, above: corners, opacity: shown, in: &context)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    static let solid = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    static let dashed = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 4])

    /// The 150 ms brighten after the hold's ring completes, a sine bump.
    private var flashStrength: Double {
        let start = Schedule.start(of: Schedule.holdIndex) + Schedule.holdDuration
        let p = (time - start) / Schedule.flashDuration
        guard p > 0, p < 1 else { return 0 }
        return Double(sin(p * Float.pi))
    }

    /// Moves each corner 6 pt away from the box's centre. On the edge itself, a light bracket
    /// vanished against the window's white frame.
    static func outset(_ corners: [CGPoint]) -> [CGPoint] {
        let cx = corners.map(\.x).reduce(0, +) / 4, cy = corners.map(\.y).reduce(0, +) / 4
        return corners.map { p in
            let dx = p.x - cx, dy = p.y - cy
            let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
            return CGPoint(x: p.x + dx / length * 6, y: p.y + dy / length * 6)
        }
    }

    /// Four L-shaped corners, each arm 18 pt or 40% of its edge, with a 4 pt rounded bend.
    static func bracket(_ corners: [CGPoint]) -> Path {
        var path = Path()
        for i in corners.indices {
            let corner = corners[i], previous = corners[(i + 3) % 4], next = corners[(i + 1) % 4]
            func toward(_ other: CGPoint) -> CGPoint {
                let dx = other.x - corner.x, dy = other.y - corner.y
                let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
                let arm = min(18, 0.4 * length)
                return CGPoint(x: corner.x + dx / length * arm, y: corner.y + dy / length * arm)
            }
            path.move(to: toward(previous))
            path.addArc(tangent1End: corner, tangent2End: toward(next), radius: 4)
            path.addLine(to: toward(next))
        }
        return path
    }

    private func drawCaption(_ caption: String, above corners: [CGPoint], opacity: Double, in context: inout GraphicsContext) {
        let top = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: min(corners[0].y, corners[1].y) - 13)
        var layer = context
        layer.opacity = opacity
        layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 6, y: 1))
        let text = Text(caption)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
        layer.draw(text, at: top, anchor: .center)
    }

    private var accessibilitySummary: String {
        let names = zip(RecognisedBox.fixture, boxes).compactMap { box, state in
            state.appearedAt.map { time >= $0 ? box.caption : nil } ?? nil
        }
        return names.isEmpty ? "Nothing recognised yet" : "Recognised: " + names.joined(separator: ", ")
    }
}
