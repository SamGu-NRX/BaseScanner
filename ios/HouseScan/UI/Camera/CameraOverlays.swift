import SwiftUI

/// The overlays every walking screen draws over the camera, in paint order.
struct CameraOverlays: View {
    let state: ScanViewState
    var highlight: GapRequest?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment

    var body: some View {
        ZStack {
            overlays
        }
        .animation(.easeOut(duration: 0.2), value: state.tracking == .normal)
    }

    @ViewBuilder
    private var overlays: some View {
        // Hidden while tracking isn't normal: drawn from a pose the phone doesn't trust, the fog,
        // path and marks would sit in the wrong place (checklist T3). They fade back on recovery.
        if state.tracking == .normal, let projection = state.projection, let wall = state.wall {
            ZStack {
                fog(projection: projection, wall: wall)
                    .ignoresSafeArea()
                WallMarksOverlay(
                    projection: projection,
                    wall: wall,
                    features: state.features,
                    wallBandHeight: state.coverage.wallBandHeight
                )
                if state.marking == nil {
                    // While marking, the reticle is the only aim; the path and ring would compete.
                    WayfindingOverlay(projection: projection, wall: wall, path: state.path, target: state.target)
                        .transition(.opacity)
                }
            }
        }
    }

    /// The live fog, with dots when the phone has depth. The frosted strip stands in while the
    /// shaders compile at launch, and for good if Metal fails, so unseen wall never shows clear.
    @ViewBuilder
    private func fog(projection: CameraProjection, wall: WallGeometry) -> some View {
        switch LiveFogSupport.shared.status {
        case let .ready(gpu):
            ZStack {
                LiveFogView(gpu: gpu, input: LiveFogInput(
                    projection: projection, wall: wall, coverage: state.coverage, highlight: highlight,
                    dots: state.depthAvailable ? state.liveDots : .empty, reduceMotion: reduceMotion,
                    requestedColor: requestedColor))
                FogMarks(coverage: state.coverage, wall: wall, projection: projection, highlight: highlight)
            }
            .transition(.opacity)
        case .preparing, .failed:
            FogOverlay(coverage: state.coverage, wall: wall, projection: projection, highlight: highlight)
        }
    }

    private var requestedColor: SIMD3<Float> {
        let resolved = Palette.caution.resolve(in: environment)
        return SIMD3(resolved.red, resolved.green, resolved.blue)
    }
}
