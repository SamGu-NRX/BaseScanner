import SwiftUI

/// One answer to a question on the light review panel: a tinted capsule that fills blue once it
/// is the answer given. Shared by the window question and the ground question so every answer on
/// the panel looks and behaves the same.
struct AnswerButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.button)
                .foregroundStyle(selected ? .white : Palette.signalText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 46)
                // The primary button's darker fill: white on it is about 6.2:1, on Signal 4.9:1.
                .background(selected ? Palette.signalFill : Palette.signal.opacity(0.1), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}
