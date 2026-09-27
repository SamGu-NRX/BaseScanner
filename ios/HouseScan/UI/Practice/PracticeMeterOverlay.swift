import HouseScanKit
import simd
import SwiftUI

/// On a practice scan, the sample meter drawn on the wall at the tapped spot, in perspective, on
/// every camera screen after the tap. It follows `state.wall.meter`, which the engine moves with
/// the meter's anchor as ARKit corrects it, so the drawing stays where the anchor is, as the fog
/// and marks do. Painted just above the camera image, so the fog and marks draw over it as they
/// would over a real meter.
struct PracticeMeterOverlay: View {
    let state: ScanViewState

    var body: some View {
        GeometryReader { proxy in
            // Hidden while tracking isn't normal, like the other overlays: from a pose the phone
            // doesn't trust, it would sit in the wrong place.
            if state.tracking == .normal, let face = SampleMeterArt.face, let placed = placement(in: proxy.size) {
                ZStack(alignment: .topLeading) {
                    Image(decorative: face, scale: 1)
                        .resizable()
                        .frame(width: CGFloat(face.width), height: CGFloat(face.height))
                        .projectionEffect(placed.transform)
                        .accessibilityHidden(true)
                    // The camera shows a real meter to anyone who can see it; this one exists only
                    // in the app, so VoiceOver finds it where it is drawn.
                    Color.clear
                        .frame(width: placed.bounds.width, height: placed.bounds.height)
                        .position(x: placed.bounds.midX, y: placed.bounds.midY)
                        .accessibilityElement()
                        .accessibilityLabel("Sample meter")
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("practiceMeter")
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The transform that takes the face image's rectangle onto the sample's four corners on
    /// screen, and the corners' bounding box; nil when the wall isn't set yet or any corner is
    /// behind the camera.
    private func placement(in size: CGSize) -> (transform: ProjectionTransform, bounds: CGRect)? {
        guard let wall = state.wall, let projection = state.projection, let face = SampleMeterArt.face else { return nil }
        var quad: [SIMD2<Double>] = []
        for corner in PracticeMeter.plateCorners(meter: wall.meter, along: wall.along, outward: wall.outward) {
            guard let point = projection.viewPoint(for: corner, in: size) else { return nil }
            quad.append(SIMD2(Double(point.x), Double(point.y)))
        }
        guard let m = QuadHomography.mapping(width: Double(face.width), height: Double(face.height), to: quad) else { return nil }
        // `m[column][row]`; ProjectionTransform names its entries row first.
        var transform = ProjectionTransform()
        transform.m11 = m[0][0]
        transform.m12 = m[1][0]
        transform.m13 = m[2][0]
        transform.m21 = m[0][1]
        transform.m22 = m[1][1]
        transform.m23 = m[2][1]
        transform.m31 = m[0][2]
        transform.m32 = m[1][2]
        transform.m33 = m[2][2]
        let xs = quad.map(\.x)
        let ys = quad.map(\.y)
        let bounds = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        return (transform, bounds)
    }
}

extension EnvironmentValues {
    /// True on every screen of a practice scan (`ScanViewState.isPracticeScan`).
    @Entry var isPracticeScan = false
}
