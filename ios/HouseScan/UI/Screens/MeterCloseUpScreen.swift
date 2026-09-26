import SwiftUI

/// The meter close-up. A ring around the meter fills while every photo check passes; at full
/// the phone takes the photo itself, the screen flashes and the photo shrinks into the counter.
/// Problems show one short fix under the ring. After two failed attempts, "Can't get a clear
/// shot" appears so the homeowner is never stuck here.
struct MeterCloseUpScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var lockedOn = false
    @State private var flash = false
    @State private var flyingThumbnail: CGImage?
    @State private var thumbnailLanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ring
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            CameraChrome(
                instruction: ScanCopy.guidance(.holdOnMeter),
                photoCount: state.captureCount,
                lastCaptureID: state.lastCapture?.id,
                isReplay: state.isReplay,
                isAutopilot: state.isAutopilot
            ) {
                VStack(spacing: 12) {
                    if let problem {
                        Label(ScanCopy.closeUpProblem(problem), systemImage: "exclamationmark.circle.fill")
                            .font(Typeface.hint.weight(.semibold))
                            .foregroundStyle(Palette.chalk)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(ScrimShape.capsule)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .id(problem)
                            .accessibilityIdentifier("closeUp.problem")
                    }
                    if offerSkip {
                        Button("Can't get a clear shot") { actions.skipCloseUp() }
                            .buttonStyle(.secondaryProminent)
                            .frame(maxWidth: .infinity)
                            .accessibilityHint("Skips the close-up. An installer will read the meter instead.")
                            .accessibilityIdentifier("action.skipCloseUp")
                            .transition(.opacity)
                    }
                }
                .animation(Motion.text, value: problem)
                .animation(Motion.screen, value: offerSkip)
            }
            if flash {
                Color.white.opacity(0.7).ignoresSafeArea().allowsHitTesting(false).transition(.opacity)
            }
            if let flyingThumbnail {
                GeometryReader { proxy in
                    Image(decorative: flyingThumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbnailLanded ? 36 : 180, height: thumbnailLanded ? 36 : 180)
                        .clipShape(.rect(cornerRadius: thumbnailLanded ? 8 : 20))
                        .overlay(RoundedRectangle(cornerRadius: thumbnailLanded ? 8 : 20).strokeBorder(.white, lineWidth: 3))
                        .shadow(radius: 10)
                        .position(thumbnailLanded
                                  ? CGPoint(x: proxy.size.width - 48, y: proxy.safeAreaInsets.top + 22)
                                  : CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2))
                        .opacity(thumbnailLanded ? 0 : 1)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.pin) { lockedOn = true }
        }
        .onChange(of: capturedImageID) { _, newValue in
            guard newValue != nil else { return }
            acknowledgeCapture()
        }
    }

    // MARK: Ring

    private var ring: some View {
        let hold = holdFraction
        let done = isCaptured
        return ZStack {
            Circle()
                .strokeBorder(.black.opacity(0.3), lineWidth: 14)
            Circle()
                .strokeBorder(.white.opacity(0.55), lineWidth: 8)
            Circle()
                .inset(by: 4)
                .trim(from: 0, to: done ? 1 : hold)
                .stroke(done ? Palette.covered : Palette.signal, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.12), value: hold)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(.white)
                    .padding(22)
                    .background(Palette.covered, in: .circle)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(width: 250, height: 250)
        .scaleEffect(lockedOn ? 1 : 1.25)
        .opacity(lockedOn ? 1 : 0)
        .animation(Motion.pin, value: done)
        .accessibilityElement()
        .accessibilityLabel("Photo of your meter")
        .accessibilityValue(done ? "Taken" : "\(Int(hold * 100)) percent ready")
        .accessibilityIdentifier("closeUp.ring")
    }

    // MARK: State

    private var holdFraction: Double {
        if case .aiming(let hold, _) = state.closeUp { return min(max(hold, 0), 1) }
        return 1
    }

    private var problem: CloseUpProblem? {
        if case .aiming(_, let problem) = state.closeUp { return problem }
        return nil
    }

    /// The way out appears from the second failed attempt on (contract
    /// `closeUpFailedAttempts`), never on the first try.
    private var offerSkip: Bool {
        state.closeUpFailedAttempts >= 2 || state.closeUp == .skipped
    }

    private var isCaptured: Bool {
        if case .captured = state.closeUp { return true }
        return false
    }

    private var capturedImageID: Int? {
        isCaptured ? (state.lastCapture?.id ?? 0) : nil
    }

    private func acknowledgeCapture() {
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        withAnimation(.easeOut(duration: 0.3).delay(0.08)) { flash = false }
        guard !reduceMotion else { return }
        var image: CGImage?
        if case .captured(let captured) = state.closeUp { image = captured }
        guard let thumbnail = image ?? state.lastCapture?.thumbnail else { return }
        thumbnailLanded = false
        flyingThumbnail = thumbnail
        withAnimation(.spring(duration: 0.55, bounce: 0).delay(0.25)) { thumbnailLanded = true }
    }
}
