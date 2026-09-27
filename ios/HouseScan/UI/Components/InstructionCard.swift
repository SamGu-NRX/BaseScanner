import SwiftUI

/// The single instruction at the top of a camera screen.
///
/// When the text changes, the words swap at once and the card eases to its new height. A
/// blur or fade between them left both lines half-transparent for a moment, which the
/// accessibility audit reported as low contrast and, for the outgoing line, as clipped text
/// (the marking prompt, the end question). Coaching
/// takes the same slot with an amber icon so a problem replaces the instruction instead of
/// stacking on top of it.
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
    }

    var instruction: Instruction
    var tone: Tone = .normal
    var reply: Reply?
    /// A short line above the instruction that places it in the flow ("One more view to
    /// finish"). Read with the instruction as one VoiceOver element.
    var eyebrow: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .accessibilityHint(reply.hint)
                    .accessibilityIdentifier(reply.identifier)
                    .padding([.horizontal, .bottom], 12)
                    .padding(.top, -4)
                    // Appears and goes at once, like the message above it: the walk's request can
                    // change every few seconds, and a fading button spends those moments as faint
                    // text on the card, which the accessibility audit caught twice on CI (runs
                    // 36295565916, and the LiDAR replay after the coaching fix).
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity)
        .background(ScrimShape.rounded())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.text, value: instruction)
        .animation(Motion.text, value: reply == nil)
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
