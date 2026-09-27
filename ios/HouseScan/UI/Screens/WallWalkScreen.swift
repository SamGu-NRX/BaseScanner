import SwiftUI

/// The walk along the wall: the heart of the scan.
///
/// Over the camera: haze on what the phone hasn't seen, a blue dotted path on the ground, a
/// ring on the next thing to aim at, pins on what's been marked. At the bottom: the tape map
/// and at most two actions. At the top: one instruction, with coaching on a line of its own
/// under it while the photos have a problem, replaced while tracking has one, or by the marking
/// prompt while marking.
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
            // The mark (a feature, the next wall round a corner, or the wall's end when the walk
            // asks for it) lands under the circle.
            if state.marking != nil || controlsKey == .nextWall || controlsKey == .markEnd {
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
                            highlight: nil,
                            depthChecked: state.depthAvailable,
                            endPreview: showsEndPreview ? state.endPreview : nil
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
        if let side = state.endQuestion { return ScanCopy.endQuestion(side, leavesOut: state.endQuestionLeavesOut) }
        if state.overheadQuestion { return ScanCopy.overheadQuestion }
        if let confirm = state.nextWallConfirm { return ScanCopy.nextWallConfirm(confirm) }
        if let coaching, ScanCopy.coachingReplacesTask(coaching) { return ScanCopy.coaching(coaching) }
        // Coaching about how the photos come out (the capture gate's, and too little texture)
        // rides along with the task (`ScanCopy.withCoaching`), and its symbol marks the card (`tone`).
        if state.wallTooShort {
            return ScanCopy.withCoaching(Instruction(title: ScanCopy.wallTooShort, detail: ScanCopy.guidance(state.guidance).title), coaching)
        }
        return ScanCopy.withCoaching(ScanCopy.guidance(state.guidance, hint: state.guidanceHint), coaching)
    }

    /// "Slow down", "Turn more slowly" and "Hold steady" are for walking and aiming. With the tray
    /// open the homeowner has stopped to pick a mark and is only turning the phone, which the gate
    /// also reads as moving or turning (field test run 1). Tracking problems still show.
    private var coaching: Coaching? {
        switch state.coaching {
        case .slowDown?, .turnSlowly?, .holdSteady?: trayOpen ? nil : state.coaching
        default: state.coaching
        }
    }

    /// Coaching that replaces the task marks the card with its symbol. A refusal on the task
    /// (the next wall wasn't marked, the wall is too short) keeps its red triangle over coaching
    /// that only rides along: the refusal's words are on the card, so its tone should match.
    private var tone: InstructionCard.Tone {
        if state.marking?.refusal != nil { return .refusal }
        let coachingShows = state.marking == nil && state.endQuestion == nil && !state.overheadQuestion && state.nextWallConfirm == nil
        if coachingShows, let coaching, ScanCopy.coachingReplacesTask(coaching) {
            return .coaching(symbol: ScanCopy.coachingSymbol(coaching))
        }
        if state.marking == nil, case .markNextWall(_, _?) = state.guidance { return .refusal }
        if coachingShows, state.wallTooShort { return .refusal }
        if coachingShows, let coaching { return .coaching(symbol: ScanCopy.coachingSymbol(coaching)) }
        return .normal
    }

    // MARK: Controls

    private enum ControlsKey: Hashable {
        case marking, endQuestion, overheadQuestion, nextWallConfirm, tray, nextWall, markEnd, finish, walking
    }

    private var controlsKey: ControlsKey {
        if state.marking != nil { return .marking }
        if state.endQuestion != nil { return .endQuestion }
        if state.overheadQuestion { return .overheadQuestion }
        if state.nextWallConfirm != nil { return .nextWallConfirm }
        if trayOpen { return .tray }
        if isMarkingNextWall { return .nextWall }
        if case .markEnd = state.guidance { return .markEnd }
        if bothEndsMarked { return .finish }
        return .walking
    }

    /// The end preview shows only with the buttons that set it: not over a question, a mark or
    /// the feature tray.
    private var showsEndPreview: Bool {
        controlsKey == .walking || controlsKey == .markEnd
    }

    /// "Wall ends here" at the phone's place, offered whenever the walk is on a side whose end
    /// isn't marked (B-06), not only once it asks for the end.
    private var offersEndHere: Bool {
        controlsKey == .walking && state.endPreview?.atReticle == false
    }

    private var isMarkingNextWall: Bool {
        if case .markNextWall = state.guidance { return true }
        return false
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
            // One question, three equal full-width answers that say what they mean (checklist I4).
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
                // A garden wall or a fence can just stop, with no corner and nothing in the way,
                // and neither answer above fits it (#70). Ends the wall as "Something blocks it"
                // does: the usable wall stops here.
                Button {
                    actions.answerWallEnd(turnsCorner: false)
                } label: {
                    Label("The wall just ends", systemImage: "arrow.right.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryProminent)
                .accessibilityHint("No corner and nothing in the way. The wall stops here.")
                .accessibilityIdentifier("action.endEnds")
            }
            .transition(.opacity)
        case .overheadQuestion:
            OverheadAnswers(actions: actions)
                .transition(.opacity)
        case .nextWallConfirm:
            // "Is this the next wall?" before the walk follows the corner (#70).
            VStack(spacing: 8) {
                Button {
                    actions.confirmNextWall(true)
                } label: {
                    Label("Yes, this is the next wall", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("action.nextWallYes")
                Button {
                    actions.confirmNextWall(false)
                } label: {
                    Label("No, keep looking", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryProminent)
                .accessibilityHint("Aim at another wall and mark it")
                .accessibilityIdentifier("action.nextWallNo")
            }
            .transition(.opacity)
        case .nextWall:
            // Back asks about the end again (#70); marking something waits for the walk.
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Button {
                    actions.cancelNextWall()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                }
                .buttonStyle(.secondaryProminent)
                .accessibilityHint("Asks again what's at this end of the wall")
                .accessibilityIdentifier("action.nextWallBack")
                Button {
                    actions.markNextWall(at: nil, viewSize: cameraSize)
                } label: {
                    Label("Mark next wall", systemImage: nextWallSymbol)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .accessibilityHint("Marks the wall under the circle in the middle of the screen as the wall round the corner")
                .accessibilityIdentifier("action.markNextWall")
            }
            .transition(.opacity)
        case .tray:
            FeatureTray(
                onPick: { kind in actions.beginMarking(kind) },
                onClose: { trayOpen = false }
            )
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        case .markEnd, .finish, .walking:
            // One row for all three, so "Mark something" stays the same view while the button
            // beside it changes. Rebuilt per case, it crossfaded out as a frozen copy that the
            // accessibility audit reported as not following Dynamic Type.
            HStack(spacing: 10) {
                // While the walk asks to look past an obstruction, that step has one way out
                // ("Can't see past it" in the card), so "Mark something" steps aside without
                // leaving the row: it keeps its place and stays the same view.
                markSomethingButton
                    .opacity(isSeeingBehind ? 0 : 1)
                    .allowsHitTesting(!isSeeingBehind)
                    .accessibilityHidden(isSeeingBehind)
                switch controlsKey {
                case .markEnd:
                    Button {
                        actions.markWallEnd(at: nil, viewSize: cameraSize)
                    } label: {
                        Label("Wall ends here", systemImage: "flag.fill")
                    }
                    .buttonStyle(.primary)
                    .accessibilityHint("Marks the end of the wall at the circle in the middle of the screen")
                    .accessibilityIdentifier("action.markEnd")
                    .transition(.opacity)
                case .walking where offersEndHere:
                    Button {
                        actions.endWallHere()
                    } label: {
                        Label("Wall ends here", systemImage: "flag")
                            .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                    }
                    .buttonStyle(.secondaryProminent)
                    .accessibilityHint("Ends the wall where you're standing, at the dashed line on the map")
                    .accessibilityIdentifier("action.endHere")
                    .transition(.opacity)
                case .finish:
                    Button {
                        actions.finishWalk()
                    } label: {
                        Label("Done with this wall", systemImage: "checkmark")
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("action.finishWalk")
                    .transition(.opacity)
                default:
                    Spacer(minLength: 0)
                }
            }
            .transition(.opacity)
        }
    }

    /// The capture gate's coaching (slow down, texture, light, hold steady) comes and goes within
    /// a second while the homeowner walks, and the task under it stays the same, so the card's
    /// reply stays put through it: hiding it each time made the button fade in and out under the
    /// homeowner's thumb, and the accessibility audit caught it half faded (CI run 36295565916).
    /// Coaching about tracking itself hides it, since where an end would land needs the phone's
    /// place, as does being past an end, where the way on is to walk back (#80). No `default`:
    /// a new coaching case has to choose.
    private var coachingHidesReply: Bool {
        switch state.coaching {
        case nil, .slowDown?, .needsTexture?, .tooDark?, .tooDarkToMeasure?, .holdSteady?, .turnSlowly?: false
        case .initializing?, .relocalizing?, .trackingLost?, .pastWallEnd?: true
        }
    }

    /// The card's reply, worded for the step by `ScanCopy.reply(for:)` ("Skip this spot" on an
    /// aim step, "Can't get there" on the walk). Its identifier is `action.cannotAccess` on
    /// every step.
    private var reply: InstructionCard.Reply? {
        guard state.marking == nil, state.endQuestion == nil, !state.overheadQuestion, state.nextWallConfirm == nil, !coachingHidesReply, !trayOpen,
              let copy = ScanCopy.reply(for: state.guidance) else { return nil }
        return InstructionCard.Reply(
            title: copy.title,
            identifier: "action.cannotAccess",
            hint: copy.hint,
            perform: { actions.cannotAccessArea() },
            task: replyTask
        )
    }

    /// The step the reply answers, in words, for the card's input lock: the step's own words
    /// while coaching shows over it, and the walk without its distance to go, which changes as
    /// the homeowner walks and would lock "Can't get there" again each time.
    private var replyTask: Instruction {
        if case .walk(let side, _) = state.guidance { return ScanCopy.guidance(.walk(side: side, remaining: nil)) }
        return ScanCopy.guidance(state.guidance)
    }

    private var nextWallSymbol: String {
        if case .markNextWall(.left, _) = state.guidance { return "arrow.turn.up.left" }
        return "arrow.turn.up.right"
    }

    private var isSeeingBehind: Bool {
        if case .seeBehind = state.guidance { return true }
        return false
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
                    .accessibilityLabel("Mark \(ScanCopy.noun(kind))")
                    .accessibilityIdentifier("feature.\(kind.rawValue)")
                }
            }
        }
        .padding(16)
        .background(ScrimShape.rounded())
    }
}
