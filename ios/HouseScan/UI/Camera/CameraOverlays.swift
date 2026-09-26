import SwiftUI

/// The overlays every walking screen draws over the camera, in paint order.
struct CameraOverlays: View {
    let state: ScanViewState
    var highlight: GapRequest?

    var body: some View {
        if let projection = state.projection, let wall = state.wall {
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
