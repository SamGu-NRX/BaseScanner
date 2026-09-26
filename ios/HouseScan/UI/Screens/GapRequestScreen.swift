import SwiftUI

/// One targeted request for a missing view. The requested cells turn amber on the camera and
/// on the tape map instead of fog, a bar fills as they're seen, and a check lands when done.
/// An overhead request asks what is above the wall once a tilted-up view covers it.
struct GapRequestScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var cameraSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CameraSizeReader(size: $cameraSize)
            CameraOverlays(state: state, highlight: state.gap)
            if state.gap?.isSatisfied == true {
                SuccessBadge()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            }
            CameraChrome(
                instruction: instruction,
                tone: asking ? .normal : state.coaching.map { .coaching(symbol: ScanCopy.coachingSymbol($0)) } ?? .normal,
                reply: state.gap?.isSatisfied == true || asking ? nil : InstructionCard.Reply(
                    title: "I can't get there",
                    identifier: "action.skipGap",
                    hint: "Skips this view. An installer will look at this part instead.",
                    perform: { actions.skipGap() }
                ),
                photoCount: state.captureCount,
                lastCaptureID: state.lastCapture?.id,
                isReplay: state.isReplay,
                isAutopilot: state.isAutopilot
            ) {
                VStack(spacing: 10) {
                    if asking {
                        OverheadAnswers(actions: actions)
                            .transition(.opacity)
                    }
                    if let gap = state.gap {
                        GapProgress(gap: gap)
                    }
                    if let wall = state.wall {
                        WallTape(
                            coverage: state.coverage,
                            wall: wall,
                            features: state.features,
                            cameraS: state.projection.map { WallProjection(projection: $0, wall: wall, size: cameraSize).cameraS },
                            highlight: state.gap
                        )
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.settle, value: asking)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.pin, value: state.gap?.isSatisfied)
    }

    /// The overhead question is up: it replaces the instruction, coaching and "I can't get there"
    /// until answered, as on the walk.
    private var asking: Bool { state.overheadQuestion && state.gap?.isSatisfied != true }

    private var instruction: Instruction {
        if asking { return ScanCopy.overheadQuestion }
        if let coaching = state.coaching { return ScanCopy.coaching(coaching) }
        guard let gap = state.gap else { return ScanCopy.guidance(.gap) }
        if gap.isSatisfied { return Instruction(title: "Got it, thanks", detail: "That's the view we needed.") }
        return ScanCopy.gap(gap)
    }
}

private struct GapProgress: View {
    var gap: GapRequest

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: gap.isSatisfied ? "checkmark.circle.fill" : "scope")
                .font(.title3.weight(.bold))
                .foregroundStyle(gap.isSatisfied ? Palette.covered : Palette.caution)
                .contentTransition(.symbolEffect(.replace))
            ProgressView(value: min(max(gap.progress, 0), 1))
                .tint(gap.isSatisfied ? Palette.covered : Palette.caution)
                .animation(.easeOut(duration: 0.25), value: gap.progress)
            Text("\(Int((min(max(gap.progress, 0), 1) * 100).rounded()))%")
                .font(Typeface.caption.monospacedDigit())
                .foregroundStyle(Palette.chalk)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(ScrimShape.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gap.isSatisfied ? "View captured" : "Captured so far")
        .accessibilityValue("\(Int((min(max(gap.progress, 0), 1) * 100).rounded())) percent")
        .accessibilityIdentifier("gap.progress")
    }
}

/// The big green check that lands when a requested view is complete.
struct SuccessBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 60, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 128, height: 128)
            .background(Palette.covered, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 4))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
