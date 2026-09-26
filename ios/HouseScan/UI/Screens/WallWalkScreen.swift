import SwiftUI

/// The walk along the wall: the heart of the scan.
///
/// Over the camera: haze on what the phone hasn't seen, a blue dotted path on the ground, a
/// ring on the next thing to aim at, pins on what's been marked. At the bottom: the tape map
/// and at most two actions. At the top: one instruction, replaced by coaching while there is a
/// problem, or by the marking prompt while marking.
struct WallWalkScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var cameraSize: CGSize = .zero
    @State private var trayOpen = false
    @State private var taps: [TapRipple.Ripple] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            CameraSizeReader(size: $cameraSize)
            CameraOverlays(state: state, highlight: nil)
            if state.coaching == .relocalizing, let meterPhoto {
                // "Point at the meter like this.": the saved close-up shows what to aim at.
                SavedMeterPhoto(image: meterPhoto)
                    .transition(.opacity)
            }
            if state.marking != nil {
                Reticle(diameter: 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                TapRipple(ripples: $taps)
            }
            CameraChrome(
                instruction: instruction,
                tone: tone,
                reply: reply,
                photoCount: state.captureCount,
                lastCaptureID: state.lastCapture?.id,
                isReplay: state.isReplay,
                isAutopilot: state.isAutopilot,
                onCameraTap: state.marking == nil ? nil : { point in
                    taps.append(.init(point: point))
                    actions.markFeaturePoint(at: point, viewSize: cameraSize)
                }
            ) {
                VStack(spacing: 10) {
                    controls
                    if let wall = state.wall {
                        WallTape(
                            coverage: state.coverage,
                            wall: wall,
                            features: state.features,
                            cameraS: cameraS,
                            highlight: nil
                        )
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.settle, value: controlsKey)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.coaching == .relocalizing)
        .onChange(of: state.marking == nil) { _, notMarking in
            if !notMarking { trayOpen = false }
        }
    }

    // MARK: Instruction

    private var instruction: Instruction {
        if let marking = state.marking {
            let prompt = ScanCopy.markingPrompt(marking)
            if let refusal = marking.refusal {
                return Instruction(title: ScanCopy.refusal(refusal), detail: prompt.title)
            }
            return prompt
        }
        if let side = state.endQuestion { return ScanCopy.endQuestion(side) }
        if let coaching = state.coaching { return ScanCopy.coaching(coaching) }
        return ScanCopy.guidance(state.guidance)
    }

    private var tone: InstructionCard.Tone {
        if state.marking?.refusal != nil { return .refusal }
        if state.marking == nil, state.endQuestion == nil, let coaching = state.coaching {
            return .coaching(symbol: ScanCopy.coachingSymbol(coaching))
        }
        return .normal
    }

    // MARK: Controls

    private enum ControlsKey: Hashable {
        case marking, endQuestion, tray, markEnd, finish, walking
    }

    private var controlsKey: ControlsKey {
        if state.marking != nil { return .marking }
        if state.endQuestion != nil { return .endQuestion }
        if trayOpen { return .tray }
        if case .markEnd = state.guidance { return .markEnd }
        if bothEndsMarked { return .finish }
        return .walking
    }

    /// True while the guidance points at a particular stretch the homeowner might not reach.
    private var asksForArea: Bool {
        switch state.guidance {
        case .walk, .aimAtGround, .aimAtWall: true
        default: false
        }
    }

    private var bothEndsMarked: Bool {
        state.wall?.leftEnd != nil && state.wall?.rightEnd != nil
    }

    @ViewBuilder
    private var controls: some View {
        switch controlsKey {
        case .marking:
            HStack(spacing: 10) {
                Button("Cancel") { actions.cancelMarking() }
                    .buttonStyle(.secondaryProminent)
                    .accessibilityIdentifier("action.cancelMarking")
                Button {
                    taps.append(.init(point: CGPoint(x: cameraSize.width / 2, y: cameraSize.height / 2)))
                    actions.markFeaturePoint(at: nil, viewSize: cameraSize)
                } label: {
                    Label("Mark", systemImage: "plus.viewfinder")
                }
                .buttonStyle(.primary)
                .accessibilityHint("Marks the point under the circle in the middle of the screen")
                .accessibilityIdentifier("action.markPoint")
            }
            .transition(.opacity)
        case .endQuestion:
            // One question, two equal full-width answers that say what they mean (checklist I4).
            VStack(spacing: 8) {
                Button {
                    actions.answerWallEnd(turnsCorner: true)
                } label: {
                    Label("It turns a corner", systemImage: "arrow.turn.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryProminent)
                .accessibilityIdentifier("action.endCorner")
                Button {
                    actions.answerWallEnd(turnsCorner: false)
                } label: {
                    Label("Something blocks it", systemImage: "xmark.octagon")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryProminent)
                .accessibilityHint("A fence, gate, or your neighbor's yard")
                .accessibilityIdentifier("action.endBlocked")
            }
            .transition(.opacity)
        case .tray:
            FeatureTray(
                onPick: { kind in actions.beginMarking(kind) },
                onClose: { trayOpen = false }
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case .markEnd:
            HStack(spacing: 10) {
                markSomethingButton
                Button {
                    actions.markWallEnd(at: nil, viewSize: cameraSize)
                } label: {
                    Label("Wall ends here", systemImage: "flag.fill")
                }
                .buttonStyle(.primary)
                .accessibilityHint("Marks the end of the wall at the circle in the middle of the screen")
                .accessibilityIdentifier("action.markEnd")
            }
            .transition(.opacity)
        case .finish:
            HStack(spacing: 10) {
                markSomethingButton
                Button {
                    actions.finishWalk()
                } label: {
                    Label("Done with this wall", systemImage: "checkmark")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("action.finishWalk")
            }
            .transition(.opacity)
        case .walking:
            HStack {
                markSomethingButton
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        }
    }

    private var reply: InstructionCard.Reply? {
        guard asksForArea, state.marking == nil, state.endQuestion == nil, state.coaching == nil, !trayOpen else { return nil }
        return InstructionCard.Reply(
            title: "Can't get there",
            identifier: "action.cannotAccess",
            hint: "Skips this part of the wall. An installer will look at it instead.",
            perform: { actions.cannotAccessArea() }
        )
    }

    private var markSomethingButton: some View {
        Button {
            trayOpen = true
        } label: {
            Label("Mark something", systemImage: "mappin.and.ellipse")
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(.secondaryProminent)
        .accessibilityHint("Pin a gas meter, door, window, AC unit, driveway or fence")
        .accessibilityIdentifier("action.markSomething")
    }

    private var meterPhoto: CGImage? {
        if case .captured(let image) = state.closeUp { return image }
        return nil
    }

    private var cameraS: Float? {
        guard let projection = state.projection, let wall = state.wall else { return nil }
        return WallProjection(projection: projection, wall: wall, size: cameraSize).cameraS
    }
}

/// The chips for "Mark something": one tap picks what to pin.
struct FeatureTray: View {
    var onPick: (FeatureKind) -> Void
    var onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What do you see?")
                    .font(Typeface.sectionTitle)
                    .foregroundStyle(Palette.chalk)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Palette.chalk)
                        .frame(width: Metrics.minTarget, height: Metrics.minTarget)
                        .background(.white.opacity(0.12), in: .circle)
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("action.closeTray")
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(FeatureKind.allCases) { kind in
                    Button {
                        onPick(kind)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: ScanCopy.symbol(kind))
                                .font(.title3.weight(.semibold))
                            Text(ScanCopy.name(kind))
                                .font(Typeface.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Palette.chalk)
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .background(.white.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
                        .contentShape(.rect(cornerRadius: 14))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Mark \(ScanCopy.name(kind).lowercased())")
                    .accessibilityIdentifier("feature.\(kind.rawValue)")
                }
            }
        }
        .padding(16)
        .background(ScrimShape.rounded())
    }
}
