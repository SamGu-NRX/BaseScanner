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
                    Label(state.isPracticeScan ? ScanCopy.practiceMarkMeter : "This is my meter", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.primary)
                .accessibilityHint(state.isPracticeScan
                    ? "Puts the sample meter on the wall at the circle in the middle of the screen"
                    : "Pins your electric meter at the circle in the middle of the screen")
                .accessibilityIdentifier("action.markMeter")
            }
        }
    }

    private var instruction: Instruction {
        if let coaching = state.coaching { return ScanCopy.coaching(coaching) }
        if state.guidance == .aimAtWallForMeter { return ScanCopy.guidance(.aimAtWallForMeter) }
        return state.isPracticeScan ? ScanCopy.practiceFindMeter : ScanCopy.guidance(.findMeter)
    }

    private var tone: InstructionCard.Tone {
        if let coaching = state.coaching { return .coaching(symbol: ScanCopy.coachingSymbol(coaching)) }
        return .normal
    }

    private func ripple(at point: CGPoint) {
        taps.append(.init(point: point))
    }
}
