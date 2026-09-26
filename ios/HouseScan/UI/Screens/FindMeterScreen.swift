import SwiftUI

/// "Find your electric meter": aim the reticle at the meter and tap the big button, or tap the
/// meter on screen. A ring blooms where the homeowner tapped, on touch, before the engine
/// answers; if the engine asks them to step closer, the instruction changes instead.
struct FindMeterScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var cameraSize: CGSize = .zero
    @State private var taps: [TapRipple.Ripple] = []

    var body: some View {
        ZStack {
            CameraSizeReader(size: $cameraSize)
            Reticle(diameter: 76)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            TapRipple(ripples: $taps)
            CameraChrome(
                instruction: instruction,
                tone: tone,
                photoCount: nil,
                isReplay: state.isReplay,
                isAutopilot: state.isAutopilot,
                onCameraTap: { point in
                    ripple(at: point)
                    actions.markMeter(at: point, viewSize: cameraSize)
                }
            ) {
                Button {
                    ripple(at: CGPoint(x: cameraSize.width / 2, y: cameraSize.height / 2))
                    actions.markMeter(at: nil, viewSize: cameraSize)
                } label: {
                    Label("This is my meter", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.primary)
                .accessibilityHint("Pins your electric meter at the circle in the middle of the screen")
                .accessibilityIdentifier("action.markMeter")
            }
        }
    }

    private var instruction: Instruction {
        if let coaching = state.coaching { return ScanCopy.coaching(coaching) }
        if state.guidance == .aimAtWallForMeter { return ScanCopy.guidance(.aimAtWallForMeter) }
        return ScanCopy.guidance(.findMeter)
    }

    private var tone: InstructionCard.Tone {
        if let coaching = state.coaching { return .coaching(symbol: ScanCopy.coachingSymbol(coaching)) }
        return .normal
    }

    private func ripple(at point: CGPoint) {
        taps.append(.init(point: point))
    }
}

/// A ring that blooms outward and fades where the homeowner touched: immediate proof the tap
/// landed, independent of how long the engine takes to answer.
struct TapRipple: View {
    struct Ripple: Identifiable, Equatable {
        let id = UUID()
        var point: CGPoint
    }

    @Binding var ripples: [Ripple]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(ripples) { ripple in
                RippleRing(reduceMotion: reduceMotion)
                    .position(ripple.point)
                    .task {
                        try? await Task.sleep(for: .milliseconds(650))
                        ripples.removeAll { $0.id == ripple.id }
                    }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RippleRing: View {
    var reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 4)
            .frame(width: 70, height: 70)
            .scaleEffect(reduceMotion ? 1 : (expanded ? 1.35 : 0.7))
            .opacity(expanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55)) { expanded = true }
            }
    }
}
