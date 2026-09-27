import SwiftUI

/// The overlays every walking screen draws over the camera, in paint order.
struct CameraOverlays: View {
    let state: ScanViewState
    var highlight: GapRequest?

    var body: some View {
        ZStack {
            overlays
        }
        .animation(.easeOut(duration: 0.2), value: state.tracking == .normal)
    }

    @ViewBuilder
    private var overlays: some View {
        // Hidden while tracking isn't normal: drawn from a pose the phone doesn't trust, the haze,
        // path and pins would sit in the wrong place (checklist T3). They fade back on recovery.
        if state.tracking == .normal, let projection = state.projection, let wall = state.wall {
            ZStack {
                FogOverlay(coverage: state.coverage, wall: wall, projection: projection, highlight: highlight)
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
}
