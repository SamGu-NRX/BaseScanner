import SwiftUI

/// What the last tap or measurement did: accepted, accepted with a warning, or refused and why.
struct ResultCard: View {
    let event: LabEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.tone.systemImage)
                .foregroundStyle(event.tone.color)
                .font(.headline)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.headline)
                ForEach(event.lines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: Theme.panelShape)
        .overlay {
            Theme.panelShape.strokeBorder(event.tone.color.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
