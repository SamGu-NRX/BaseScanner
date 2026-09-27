import SwiftUI

/// The overlays every walking screen draws over the camera, in paint order.
struct CameraOverlays: View {
    let state: ScanViewState
    var highlight: GapRequest?

    /// The step the aim ring's legend first showed with. The legend explains the first ring that
    /// fills and retires once that step ends (#81); it isn't needed on every ring after.
    @State private var legendStep: GuidanceStep? = nil
    @State private var legendRetired = false

    var body: some View {
        ZStack {
            overlays
        }
        .animation(.easeOut(duration: 0.2), value: state.tracking == .normal)
        .onChange(of: state.guidance) { _, step in
            if let legendStep, step != legendStep { legendRetired = true }
        }
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
                    let progress = state.aimProgress
                    WayfindingOverlay(
                        projection: projection,
                        wall: wall,
                        path: state.path,
                        target: state.target,
                        progress: progress,
                        legend: legend(progress: progress),
                        onLegendShown: {
                            if legendStep == nil { legendStep = state.guidance }
                        }
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    /// The legend, while the ring fills for the first time.
    private func legend(progress: Double?) -> String? {
        guard !legendRetired, let progress, progress < 1 else { return nil }
        return ScanCopy.aimRingLegend
    }
}
