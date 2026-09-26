import SwiftUI

/// "What's on the ground along this wall?", first on the feature review. The camera can't tell
/// mulch from soil, so the homeowner says; leaving it unanswered counts as "Not sure".
///
/// Unanswered, the card asks: the six ground types in two columns, "Not sure" across the full
/// width under them (one column at accessibility text sizes). Answered, it folds into one line
/// with the answer and Change, which opens the answers again with the current one filled in.
struct GroundQuestion: View {
    let answer: GroundAnswer?
    let actions: any ScanActions

    /// Change was tapped: the answers show although there is an answer.
    @State private var isChanging = false
    @AccessibilityFocusState private var focus: Focus?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Focus: Hashable { case question, answered }

    private var asks: Bool { answer == nil || isChanging }

    var body: some View {
        // Overlaid, not stacked, so the outgoing content fades inside the card while the card
        // resizes to the incoming one.
        ZStack(alignment: .topLeading) {
            if asks {
                question
                    .transition(Self.swap)
            } else if let answer {
                answered(answer)
                    .transition(Self.swap)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.canvas, in: .rect(cornerRadius: 18, style: .continuous))
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        // The tapped button is gone after the swap, so VoiceOver moves to what replaced it.
        .onChange(of: asks) { _, asks in
            focus = asks ? .question : .answered
        }
    }

    /// The outgoing side leaves fast; the incoming side fades in once the card has mostly
    /// resized, so the two never read as overlapping.
    private static let swap = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.1)),
        removal: .opacity.animation(.easeOut(duration: 0.1))
    )

    /// The card's resize and the review sliding up or down under it. Critically damped, so the
    /// panel settles without a wobble; under Reduce Motion a short ease, as elsewhere in the app.
    private var fold: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0)
    }

    private func give(_ newAnswer: GroundAnswer) {
        withAnimation(fold) {
            actions.answerGround(newAnswer)
            isChanging = false
        }
    }

    // MARK: Asking

    private var question: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ScanCopy.groundQuestion.title)
                    .font(Typeface.sectionTitle)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .question)
                if let detail = ScanCopy.groundQuestion.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            answers
        }
    }

    private var answers: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : 2
        let types = GroundType.allCases
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: types.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(types[start..<min(start + columns, types.count)]) { type in
                        choice(.type(type))
                            .accessibilityIdentifier("ground.answer.\(type.rawValue)")
                    }
                }
            }
            // Outside a GridRow, so it spans every column: the way out, set apart from the types.
            choice(.notSure)
                .accessibilityIdentifier("ground.answer.notSure")
        }
    }

    private func choice(_ option: GroundAnswer) -> some View {
        AnswerButton(title: ScanCopy.groundAnswer(option), selected: answer == option) {
            give(option)
        }
    }

    // MARK: Answered

    private func answered(_ answer: GroundAnswer) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(ScanCopy.groundAnsweredLabel)
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                Text(ScanCopy.groundAnswer(answer))
                    .font(Typeface.hint.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ground.answered")
            .accessibilityFocused($focus, equals: .answered)
            Button {
                withAnimation(fold) { isChanging = true }
            } label: {
                Text(ScanCopy.groundChange)
                    .font(Typeface.button)
                    .foregroundStyle(Palette.signalText)
                    .padding(.horizontal, 18)
                    .frame(minHeight: Metrics.minTarget)
                    .background(Palette.signal.opacity(0.1), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Change ground")
            .accessibilityIdentifier("ground.change")
        }
    }
}
