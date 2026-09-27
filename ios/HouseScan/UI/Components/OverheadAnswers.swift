import SwiftUI

/// The two answers to the overhead question (`ScanViewState.overheadQuestion`), shared by the
/// walk's tilt-up step and an overhead gap request. Same shape as the end question: one question,
/// two equal full-width answers that say what they mean.
struct OverheadAnswers: View {
    let actions: any ScanActions

    var body: some View {
        VStack(spacing: 8) {
            Button {
                actions.answerOverhead(clear: true)
            } label: {
                Label(ScanCopy.overheadClear, systemImage: "sun.max")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryProminent)
            .accessibilityIdentifier("action.overheadClear")
            Button {
                actions.answerOverhead(clear: false)
            } label: {
                Label(ScanCopy.overheadCovered, systemImage: "house")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryProminent)
            .accessibilityIdentifier("action.overheadCovered")
        }
    }
}
