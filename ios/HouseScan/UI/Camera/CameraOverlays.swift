import SwiftUI

/// The overlays every walking screen draws over the camera, in paint order.
struct CameraOverlays: View {
    let state: ScanViewState
    var highlight: GapRequest?

    /// The step the aim ring's legend first showed with. The legend explains the first ring that
    /// fills and retires once that step ends (#81); it isn't needed on every ring after.
    @State private var legendStep: GuidanceStep? = nil
    @State private var legendRetired = false
    /// The aim step on screen, with its target, so the update that ends it can still score it.
    @State private var lastAim: AimSnapshot? = nil
    /// The target of an aim step that just completed, held on screen as a full green ring with a
    /// tick for `completedHold` (#81). The planner moves on in the same update that fills the
    /// strip, so without the hold the ring would vanish short of full and never turn green.
    @State private var completedTarget: SIMD3<Float>? = nil
    /// Counts completions, so a second one inside the hold restarts its timer.
    @State private var completions = 0

    /// How long a completed ring stays: long enough to read as done, short enough not to hold up
    /// the next step's marker. A display choice.
    private static let completedHold: Duration = .seconds(1)

    var body: some View {
        ZStack {
            overlays
        }
        .animation(.easeOut(duration: 0.2), value: state.tracking == .normal)
        .onChange(of: AimSnapshot(step: state.guidance, target: state.target), initial: true) { old, new in
            if new.step != old.step {
                if let legendStep, new.step != legendStep { legendRetired = true }
                if let target = completed(old) {
                    completedTarget = target
                    completions += 1
                }
            }
            lastAim = state.aimProgress(for: new.step) == nil ? nil : new
        }
        .task(id: completions) {
            guard completedTarget != nil else { return }
            // A newer completion replaces this task; its cancellation must not clear the new ring.
            do { try await Task.sleep(for: Self.completedHold) } catch { return }
            completedTarget = nil
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
                    let held = heldTarget
                    WayfindingOverlay(
                        projection: projection,
                        wall: wall,
                        path: state.path,
                        target: state.target,
                        progress: progress,
                        completed: held,
                        legend: held == nil ? legend(progress: progress) : nil,
                        legendShort: ScanCopy.aimRingLegendShort,
                        onLegendShown: {
                            if legendStep == nil { legendStep = state.guidance }
                        }
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    /// The completed ring to hold. The update that ends an aim step draws before `onChange`
    /// runs, so the outgoing step is scored here too; otherwise that frame would show the next
    /// step's marker between the filling ring and the green one.
    private var heldTarget: SIMD3<Float>? {
        if let completedTarget { return completedTarget }
        guard let lastAim, lastAim.step != state.guidance else { return nil }
        return completed(lastAim)
    }

    /// The target of `snapshot`'s aim step if the strip as it is now completes it. The strip
    /// holds the view that ended the step.
    private func completed(_ snapshot: AimSnapshot) -> SIMD3<Float>? {
        guard let target = snapshot.target, let progress = state.aimProgress(for: snapshot.step), progress >= 1 else {
            return nil
        }
        return target
    }

    /// The legend, while the ring fills for the first time.
    private func legend(progress: Double?) -> String? {
        guard !legendRetired, let progress, progress < 1 else { return nil }
        return ScanCopy.aimRingLegend
    }
}

/// The step and its target together, so a change of step still has the target it ended with.
private struct AimSnapshot: Equatable {
    var step: GuidanceStep
    var target: SIMD3<Float>?
}
