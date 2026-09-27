import SwiftUI

/// The meter close-up. A ring around the meter fills while every photo check passes; at full
/// the phone takes the photo itself, the screen flashes and the photo shrinks into the counter.
/// Problems show one short fix under the ring. After two failed attempts, "Can't get a clear
/// shot" appears so the homeowner is never stuck here.
///
/// After the photo, the phone reads the meter number and asks which reading is right. Nothing
/// is filled in: the homeowner taps the number that matches the meter, or "None of these" for
/// another photo.
struct MeterCloseUpScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var lockedOn = false
    @State private var flashes = 0
    @State private var flyingThumbnail: CGImage?
    @State private var thumbnailLanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ring
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            // The shutter flash lights the camera, under the chrome, so the words stay readable.
            Color.white
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .phaseAnimator([0.0, 0.7, 0.0], trigger: flashes) { flash, opacity in
                    flash.opacity(opacity)
                } animation: { opacity in
                    opacity > 0 ? .easeOut(duration: 0.06) : .easeOut(duration: 0.3)
                }
            CameraChrome(
                instruction: ScanCopy.meterNumber(state.meterNumber) ?? ScanCopy.guidance(.holdOnMeter),
                photoCount: state.captureCount,
                lastCaptureID: state.lastCapture?.id,
                isReplay: state.isReplay,
                isAutopilot: state.isAutopilot
            ) {
                VStack(spacing: 12) {
                    if case .choose(let candidates) = state.meterNumber {
                        MeterNumberPicker(
                            candidates: candidates,
                            brand: state.meterBrand,
                            choose: actions.chooseMeterNumber,
                            rejectBrand: actions.rejectMeterBrand
                        )
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)))
                    } else if state.meterNumber == .reading {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Palette.chalk)
                            .frame(width: 64, height: 64)
                            .background(ScrimShape.capsule)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                    if let problem {
                        Label(ScanCopy.closeUpProblem(problem), systemImage: "exclamationmark.circle.fill")
                            .font(Typeface.hint.weight(.semibold))
                            .foregroundStyle(Palette.chalk)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(ScrimShape.capsule)
                            // Swapped, not faded or scaled: a shrinking, half-faded line is
                            // what the audit reported as clipped text on this screen.
                            .transition(.identity)
                            .id(problem)
                            .accessibilityIdentifier("closeUp.problem")
                    }
                    if offerSkip {
                        Button("Can't get a clear shot") { actions.skipCloseUp() }
                            .buttonStyle(.secondaryProminent)
                            .accessibilityHint("Skips the close-up. An installer will read the meter instead.")
                            .accessibilityIdentifier("action.skipCloseUp")
                            .transition(.identity)
                    }
                }
                .animation(Motion.text, value: problem)
                .animation(Motion.screen, value: offerSkip)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.screen, value: state.meterNumber)
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
                        .onAppear {
                            // Inserted at the center first; landing starts once it is on screen.
                            withAnimation(.spring(duration: 0.55, bounce: 0).delay(0.25)) { thumbnailLanded = true }
                        }
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
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(width: 250, height: 250)
        // Closes in on the meter; with Reduce Motion it only fades in.
        .scaleEffect(lockedOn || reduceMotion ? 1 : 1.25)
        // The ring steps back while the answers are up, so it never sits behind them.
        .opacity(lockedOn && !isChoosing ? 1 : 0)
        .animation(Motion.pin, value: done)
        .animation(Motion.screen, value: isChoosing)
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
    /// `closeUpFailedAttempts`), never on the first try, and not while the number is being read
    /// or asked about, so the screen holds one question.
    private var offerSkip: Bool {
        guard state.meterNumber != .reading, !isChoosing else { return false }
        return state.closeUpFailedAttempts >= 2 || state.closeUp == .skipped
    }

    private var isChoosing: Bool {
        if case .choose = state.meterNumber { return true }
        return false
    }

    private var isCaptured: Bool {
        if case .captured = state.closeUp { return true }
        return false
    }

    private var capturedImageID: Int? {
        isCaptured ? (state.lastCapture?.id ?? 0) : nil
    }

    private func acknowledgeCapture() {
        flashes += 1
        guard !reduceMotion else { return }
        var image: CGImage?
        if case .captured(let captured) = state.closeUp { image = captured }
        guard let thumbnail = image ?? state.lastCapture?.thumbnail else { return }
        thumbnailLanded = false
        flyingThumbnail = thumbnail
    }
}

/// "Which number is on your meter?": the maker when one was read, up to three readings as
/// full-width answers, then "None of these". The numbers are set in a monospaced face so similar
/// readings line up character by character (8 against B, 0 against O) and the homeowner can
/// compare them with the meter. The maker is never taken silently: it sits above the numbers
/// with "Not <maker>", and counts only with the number the homeowner taps.
private struct MeterNumberPicker: View {
    var candidates: [MeterNumberCandidate]
    var brand: String?
    var choose: (MeterNumberCandidate?) -> Void
    var rejectBrand: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let brand {
                // A chip, not a full-width answer: it states what was read, and the one thing to
                // do with it is say it's wrong. Caption size keeps it below the numbers in rank.
                HStack(spacing: 10) {
                    Text(ScanCopy.meterBrand(brand))
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.chalk)
                    Button(action: rejectBrand) {
                        Text(ScanCopy.notMeterBrand(brand))
                            .font(Typeface.caption)
                            .underline()
                            .foregroundStyle(Palette.chalk.opacity(0.8))
                            // 44 pt both ways: "Not GE" in caption type is narrower than that.
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityHint("Leaves the brand out.")
                    .accessibilityIdentifier("action.rejectMeterBrand")
                }
                .padding(.horizontal, 16)
                .background(ScrimShape.capsule)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("meter.brand")
            }
            ForEach(Array(candidates.prefix(3).enumerated()), id: \.element.id) { index, candidate in
                Button {
                    choose(candidate)
                } label: {
                    VStack(spacing: 2) {
                        Text(candidate.text)
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .speechSpellsOutCharacters()
                            .fixedSize(horizontal: false, vertical: true)
                        if candidate.barcodeConfirmed {
                            Label(ScanCopy.barcodeMatch, systemImage: "barcode")
                                .font(Typeface.caption)
                                .foregroundStyle(Palette.chalk.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryProminent)
                .accessibilityIdentifier("meter.candidate.\(index)")
            }
            Button {
                choose(nil)
            } label: {
                Text(ScanCopy.noneOfThese)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            .accessibilityHint("Takes another photo of the meter.")
            .accessibilityIdentifier("action.noneOfThese")
        }
        // "Not <brand>" fades the chip out, and the numbers close the gap in the same 0.2 s.
        .animation(Motion.text, value: brand)
    }
}
