import SwiftUI

/// The single instruction at the top of a camera screen.
///
/// When the text changes, the words and the reply land at once and the scrim eases to its new
/// height. A blur or fade between them left both lines half-transparent for a moment, which the
/// accessibility audit reported as low contrast and, for the outgoing line, as clipped text
/// (the marking prompt, the end question). When the task changes, the reply under the words
/// swaps with them. Coaching takes the same slot with an amber icon so a problem replaces the
/// instruction instead of stacking on top of it.
struct InstructionCard: View {
    enum Tone: Equatable {
        case normal
        case coaching(symbol: String)
        case refusal
    }

    /// A reply to the instruction itself, such as "Can't get there". Lives in the card so it
    /// reads as an answer to what the card asks, not as a competing primary action.
    struct Reply {
        var title: String
        var identifier: String
        var hint: String
        var perform: () -> Void
        /// The task the reply answers, when that isn't the card's words: the task under a
        /// coaching line, or the walk without its distance to go. The reply swaps with the words
        /// and takes no taps for `replyLock` when this changes. Nil: the card's instruction.
        var task: Instruction? = nil
    }

    var instruction: Instruction
    var tone: Tone = .normal
    var reply: Reply?
    /// A short line above the instruction that places it in the flow ("One more view to
    /// finish"). Read with the instruction as one VoiceOver element.
    var eyebrow: String?

    /// How long a new card's reply ignores taps, so a tap meant for the card that just left
    /// can't answer the next one: in the 4.1 field test, quick taps on "Can't get there" each
    /// answered a different card (#82). A guess, not measured: the card's own change
    /// (`Motion.text`, 0.2 s) plus a tap's reaction time.
    static let replyLock: Duration = .milliseconds(600)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The task whose reply has been on screen for `replyLock`. Compared with the current task
    /// in the same update that changes it, so a new reply is locked from its first frame.
    @State private var unlockedTask: Instruction?

    private var replyTask: Instruction { reply?.task ?? instruction }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            message
                .id(instruction)
                .transition(.identity)
            if let reply {
                Button(reply.title, action: reply.perform)
                    .font(Typeface.caption.weight(.bold))
                    .foregroundStyle(Palette.chalk)
                    .padding(.horizontal, 16)
                    .frame(minHeight: Metrics.minTarget)
                    .background(.white.opacity(0.14), in: .capsule)
                    .contentShape(.capsule)
                    .buttonStyle(PressableStyle())
                    // The colours are set above and PressableStyle doesn't read isEnabled, so the
                    // pill looks the same while locked; VoiceOver and UI tests read it as dimmed.
                    .disabled(unlockedTask != replyTask)
                    .accessibilityHint(reply.hint)
                    .accessibilityIdentifier(reply.identifier)
                    .padding([.horizontal, .bottom], 12)
                    .padding(.top, -4)
                    .transition(.opacity)
            }
        }
        // New words land at once with the reply at its final place; only the scrim, outside
        // this stack, eases to the new height. When the stack's layout eased too, the reply slid
        // from its old place over the new words for `Motion.text` (#64): on a coaching change,
        // which swaps the words and keeps the reply, and comes and goes often while walking.
        .transaction(value: instruction) { $0.animation = nil }
        // A new task swaps the words and the reply together, as one new view. With the reply
        // outside the swap it faded out over the new words (#64). The words alone still swap on
        // their own (a coaching line, the distance to go), so the reply keeps a press that is
        // under way.
        .id(replyTask)
        .transition(.identity)
        .frame(maxWidth: .infinity)
        .background(ScrimShape.rounded())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.text, value: instruction)
        .animation(Motion.text, value: reply == nil)
        .task(id: replyTask) {
            // Cleared first, so a task that comes back within the lock (A, B, A) is locked again.
            let shown = replyTask
            unlockedTask = nil
            // A new id cancels this wait and starts its own.
            do { try await Task.sleep(for: Self.replyLock) } catch { return }
            unlockedTask = shown
        }
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let symbol = iconName {
                Image(systemName: symbol)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Label(eyebrow, systemImage: "camera.viewfinder")
                        .font(Typeface.caption)
                        // The requested view's amber, as on the camera and the map.
                        .foregroundStyle(Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
                Text(instruction.title)
                    .font(Typeface.instruction)
                    .foregroundStyle(Palette.chalk)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = instruction.detail {
                    Text(detail)
                        .font(Typeface.hint)
                        .foregroundStyle(Palette.chalk.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("instruction")
    }

    private var iconName: String? {
        switch tone {
        case .normal: nil
        case .coaching(let symbol): symbol
        case .refusal: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        tone == .refusal ? Palette.danger : Palette.caution
    }
}
