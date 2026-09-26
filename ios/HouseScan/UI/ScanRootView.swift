import SwiftUI

/// The root of every screen, switched on `state.phase`. Each screen's root view carries the
/// accessibility identifier `screen.<phase.rawValue>`.
///
/// The camera stays mounted across the camera phases, so moving from finding the meter to the
/// walk to a gap request never blinks the feed; only the chrome above it crossfades.
struct ScanRootView: View {
    let state: ScanViewState
    let actions: any ScanActions

    init(state: ScanViewState, actions: any ScanActions) {
        self.state = state
        self.actions = actions
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        stack
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.screen, value: state.phase)
            .preferredColorScheme(Self.showsCamera(state.phase) ? .dark : nil)
            .modifier(ScanHaptics(state: state))
    }

    private var stack: some View {
        ZStack {
            if Self.showsCamera(state.phase) {
                CameraBackdrop(feed: state.feed, actions: actions)
                    .transition(.opacity)
                CameraEdgeShade()
            }
            screen
                .id(state.phase)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch state.phase {
        case .onboarding:
            OnboardingScreen(state: state, actions: actions)
                .screenIdentifier(.onboarding)
        case .findMeter:
            FindMeterScreen(state: state, actions: actions)
                .screenIdentifier(.findMeter)
        case .meterCloseUp:
            MeterCloseUpScreen(state: state, actions: actions)
                .screenIdentifier(.meterCloseUp)
        case .wallWalk:
            WallWalkScreen(state: state, actions: actions)
                .screenIdentifier(.wallWalk)
        case .markFeatures:
            MarkFeaturesScreen(state: state, actions: actions)
                .screenIdentifier(.markFeatures)
        case .gapRequest:
            GapRequestScreen(state: state, actions: actions)
                .screenIdentifier(.gapRequest)
        case .uploading:
            UploadingScreen(state: state, actions: actions)
                .screenIdentifier(.uploading)
        case .result:
            ResultScreen(state: state, actions: actions)
                .screenIdentifier(.result)
        case .resultAR:
            ResultARScreen(state: state, actions: actions)
                .screenIdentifier(.resultAR)
        case .unsupported:
            UnsupportedScreen(state: state, actions: actions)
                .screenIdentifier(.unsupported)
        }
    }

    static func showsCamera(_ phase: ScanPhase) -> Bool {
        switch phase {
        case .findMeter, .meterCloseUp, .wallWalk, .gapRequest, .resultAR, .markFeatures: true
        case .onboarding, .uploading, .result, .unsupported: false
        }
    }
}

/// Haptics for the moments that matter, fired on the same state change the screen animates:
/// a photo taken, the meter pinned, a mark placed or refused, a requested view done, the result.
private struct ScanHaptics: ViewModifier {
    let state: ScanViewState

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: state.lastCapture?.id)
            .sensoryFeedback(.success, trigger: state.phase, condition: Self.isMilestone)
            .sensoryFeedback(.success, trigger: state.gap?.isSatisfied ?? false) { _, new in new }
            .sensoryFeedback(.impact(weight: .medium), trigger: state.features.count) { old, new in new > old }
            .sensoryFeedback(.warning, trigger: state.marking?.refusal) { _, new in new != nil }
    }

    private static func isMilestone(_ old: ScanPhase, _ new: ScanPhase) -> Bool {
        (old == .findMeter && new == .meterCloseUp) || (old != .resultAR && new == .result)
    }
}

private extension View {
    func screenIdentifier(_ phase: ScanPhase) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen.\(phase.rawValue)")
    }
}
