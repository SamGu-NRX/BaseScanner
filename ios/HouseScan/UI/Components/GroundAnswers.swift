import SwiftUI

/// The answers to the spot check's ground question: the six ground types in two columns, "Not
/// sure" across the full width under them (one column at accessibility text sizes).
struct GroundAnswers: View {
    let answer: (GroundAnswer) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : 2
        let types = GroundType.allCases
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
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
        AnswerButton(title: ScanCopy.groundAnswer(option), selected: false) { answer(option) }
    }
}
