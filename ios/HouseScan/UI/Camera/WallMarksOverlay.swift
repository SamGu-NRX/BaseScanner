import SwiftUI

/// What the homeowner has marked, pinned onto the camera image: the meter, the wall ends and
/// the marked features (openings as outlines, everything else as pins or lines).
struct WallMarksOverlay: View {
    var projection: CameraProjection
    var wall: WallGeometry
    var features: [MarkedFeature]
    var wallBandHeight: Float

    var body: some View {
        Canvas { context, size in
            let geometry = WallProjection(projection: projection, wall: wall, size: size)
            drawEnds(in: &context, geometry)
            for feature in features {
                drawFeature(feature, in: &context, geometry)
            }
            drawMeter(in: &context, geometry)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawMeter(in context: inout GraphicsContext, _ geometry: WallProjection) {
        guard let point = geometry.point(wall.meter) else { return }
        let outer = CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26)
        context.fill(Path(ellipseIn: outer), with: .color(.white))
        context.fill(Path(ellipseIn: outer.insetBy(dx: 4, dy: 4)), with: .color(Palette.signal))
        context.stroke(Path(ellipseIn: outer.insetBy(dx: -5, dy: -5)), with: .color(.white.opacity(0.6)), lineWidth: 2)
    }

    private func drawEnds(in context: inout GraphicsContext, _ geometry: WallProjection) {
        for end in [wall.leftEnd, wall.rightEnd].compactMap(\.self) {
            guard let bottom = geometry.point(s: end, height: 0), let top = geometry.point(s: end, height: wallBandHeight) else { continue }
            var line = Path()
            line.move(to: bottom)
            line.addLine(to: top)
            context.stroke(line, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            context.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            let cap = CGRect(x: bottom.x - 7, y: bottom.y - 7, width: 14, height: 14)
            context.fill(Path(ellipseIn: cap), with: .color(.white))
        }
    }

    private func drawFeature(_ feature: MarkedFeature, in context: inout GraphicsContext, _ geometry: WallProjection) {
        let color = Color.white
        switch feature.kind {
        case .door, .window, .battery, .elecBox:
            if let bottom = feature.bottom, let top = feature.top,
               let outline = geometry.wallQuad(s: feature.span, height: bottom...top, out: 0.01) {
                context.fill(outline, with: .color(Palette.signal.opacity(0.18)))
                context.stroke(outline, with: .color(color), style: StrokeStyle(lineWidth: 3, lineJoin: .round, dash: [9, 6]))
            }
        case .driveway, .fence:
            let points = feature.points.compactMap(geometry.point)
            if points.count >= 2 {
                var line = Path()
                line.addLines(points)
                context.stroke(line, with: .color(.black.opacity(0.3)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [10, 7]))
            }
        case .gasMeter, .acUnit:
            break
        }
        for point in feature.points.compactMap(geometry.point) {
            let dot = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            context.fill(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(.black.opacity(0.25)))
            context.fill(Path(ellipseIn: dot), with: .color(.white))
            context.fill(Path(ellipseIn: dot.insetBy(dx: 4, dy: 4)), with: .color(Palette.signal))
        }
    }
}
