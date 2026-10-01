import SwiftUI

/// "Find your electric meter": aim the reticle at the meter and tap the big button, or tap the
/// meter on screen. A ring blooms where the homeowner tapped, on touch, before the engine
/// answers; if the engine asks them to step closer, the instruction changes instead.
///
/// At the largest text sizes the card folds its second line under Details and the chrome keeps
/// the camera open between the card and the button (`CameraChrome.aims`). The middle of the
/// screen is then under the card, so the reticle moves to the middle of that open camera and
/// the button marks there: the same mark a tap on that spot makes.
struct FindMeterScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var cameraSize: CGSize = .zero
    @State private var taps: [TapRipple.Ripple] = []
    @State private var cameraWindow = CameraWindow()
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            CameraSizeReader(size: $cameraSize)
            reticle
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
                },
                cameraWindow: cameraWindow,
                aims: aims
            ) {
                Button {
                    ripple(at: aimPoint ?? CGPoint(x: cameraSize.width / 2, y: cameraSize.height / 2))
                    actions.markMeter(at: aimPoint, viewSize: cameraSize)
                } label: {
                    Label(state.isPracticeScan ? ScanCopy.practiceMarkMeter : "This is my meter", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.primary)
                .accessibilityHint(markHint)
                .accessibilityIdentifier("action.markMeter")
            }
        }
    }

    /// The reticle at the middle of the screen, or of the open camera when the card folds.
    private var reticle: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let center = aimPoint ?? CGPoint(x: proxy.size.width / 2 + origin.x, y: proxy.size.height / 2 + origin.y)
            Reticle(diameter: 76)
                .position(x: center.x - origin.x, y: center.y - origin.y)
        }
        .ignoresSafeArea()
    }

    /// Whether the card folds at the largest text sizes: always, except for coaching that
    /// replaces the task (lost tracking, starting up), whose words are the only thing to do and
    /// during which the engine refuses a meter mark anyway.
    private var aims: Bool {
        guard let coaching = state.coaching else { return true }
        return !ScanCopy.coachingReplacesTask(coaching)
    }

    /// Where the reticle is and the button marks, in the camera view's (global) coordinates, when
    /// the card folds: the middle of the open camera's part on screen. Nil means the middle of
    /// the screen, as at every other size.
    private var aimPoint: CGPoint? {
        guard aims, typeSize.isAccessibilitySize, let window = cameraWindow.frame else { return nil }
        let shown = window.intersection(CGRect(origin: .zero, size: cameraSize))
        guard !shown.isNull, shown.height > 0 else { return nil }
        return CGPoint(x: shown.midX, y: shown.midY)
    }

    private var markHint: String {
        let place = aimPoint == nil ? "the circle in the middle of the screen" : "the circle below the instructions"
        return state.isPracticeScan ? "Puts the sample meter on the wall at \(place)" : "Pins your electric meter at \(place)"
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
