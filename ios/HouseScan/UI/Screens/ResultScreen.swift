import SwiftUI

/// The reveal: the homeowner's own wall in 3D with the battery on it, the answer in one line,
/// and the reasons behind it.
struct ResultScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let result = state.result {
            content(result)
        } else {
            ContentUnavailableView("No result yet", systemImage: "hourglass", description: Text("Your scan is still being checked."))
        }
    }

    private func content(_ result: ResultPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                diorama(result)
                VStack(alignment: .leading, spacing: 22) {
                    headline(result)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed || reduceMotion ? 0 : 12)
                    if result.spot != nil {
                        // Right under the answer: seeing it on the real wall is the next thing
                        // anyone wants to do.
                        Button {
                            actions.showAR()
                        } label: {
                            Label("See it on your wall", systemImage: "camera.viewfinder")
                        }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("action.showAR")
                    }
                    if !result.policyApproved {
                        Notice(symbol: "info.circle.fill", text: ScanCopy.rulesNotFinal)
                            .accessibilityIdentifier("result.rulesNotFinal")
                    }
                    if let side = result.unseenSide {
                        Notice(symbol: "arrow.left.and.right", text: "A closer spot may exist on the \(side.rawValue) of your meter. The scan didn't reach that side.")
                            .accessibilityIdentifier("result.unseenSide")
                    }
                    if !result.checks.isEmpty {
                        ChecksList(checks: result.checks)
                    }
                    if !result.missing.isEmpty {
                        MissingList(missing: result.missing, actions: actions)
                    }
                    Button("Start over") { actions.startOver() }
                        .buttonStyle(.quiet)
                        .accessibilityIdentifier("action.startOver")
                        .padding(.top, 8)
                }
                .padding(20)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.canvas.ignoresSafeArea())
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.settle.delay(0.35)) { revealed = true }
        }
    }

    // MARK: Parts

    @ViewBuilder
    private func diorama(_ result: ResultPresentation) -> some View {
        ZStack(alignment: .topLeading) {
            if let wall = state.wall {
                ResultScene3D(wall: wall, result: result, features: state.features, wallHeight: max(state.coverage.wallBandHeight, 2.4))
            } else {
                Palette.canvas
            }
            VStack(alignment: .leading, spacing: 8) {
                if result.isSample {
                    Label("Sample result, not from the server", systemImage: "flask.fill")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.caution, in: .capsule)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("result.sampleBadge")
                }
                ModeBadge(isReplay: state.isReplay, isAutopilot: state.isAutopilot)
            }
            .padding(14)
        }
        .frame(height: 340)
        .clipShape(.rect(bottomLeadingRadius: 28, bottomTrailingRadius: 28, style: .continuous))
        .ignoresSafeArea(edges: .top)
    }

    private func headline(_ result: ResultPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(ScanCopy.headline(result))
            } icon: {
                Image(systemName: decisionSymbol(result.decision))
                    .foregroundStyle(decisionColor(result.decision))
            }
                .font(Typeface.screenTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("result.headline")
            if let placement = ScanCopy.placement(result) {
                Text(placement)
                    .font(Typeface.sectionTitle)
                    .foregroundStyle(Palette.signal)
                    .accessibilityIdentifier("result.placement")
            }
            if !result.summary.isEmpty {
                Text(result.summary)
                    .font(Typeface.hint)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if result.decision == .reject, let reason = result.checks.first(where: { $0.outcome == .fail })?.reason {
                Text(reason)
                    .font(Typeface.hint)
                    .foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func decisionSymbol(_ decision: ResultPresentation.Decision) -> String {
        switch decision {
        case .pass: "checkmark.seal.fill"
        case .manualReview: "person.fill.questionmark"
        case .reject: "xmark.octagon.fill"
        }
    }

    private func decisionColor(_ decision: ResultPresentation.Decision) -> Color {
        switch decision {
        case .pass: Palette.passInk
        case .manualReview: Palette.reviewInk
        case .reject: Palette.failInk
        }
    }
}

// MARK: - Pieces

private struct Notice: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.reviewInk)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.caution.opacity(0.18), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ChecksList: View {
    var checks: [CheckRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What we checked")
                .font(Typeface.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.element.id) { index, row in
                    CheckRowView(row: row)
                    if index < checks.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct CheckRowView: View {
    var row: CheckRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.outcomeInk(row.outcome))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(Typeface.hint.weight(.semibold))
                Text(row.reason)
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let measurement = ScanCopy.measurement(row) {
                    Text(measurement)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if row.outcome == .unsure {
                    Label(ScanCopy.unsureNote(row), systemImage: row.needsPerson ? "person.fill" : "camera.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.reviewInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title): \(ScanCopy.outcomeWord(row.outcome))")
        .accessibilityValue([row.reason, ScanCopy.measurement(row), row.outcome == .unsure ? ScanCopy.unsureNote(row) : nil]
            .compactMap(\.self).joined(separator: ". "))
        .accessibilityIdentifier("check.\(row.id)")
    }

    private var symbol: String {
        switch row.outcome {
        case .pass: "checkmark.circle.fill"
        case .unsure: "questionmark.circle.fill"
        case .fail: "xmark.circle.fill"
        }
    }
}

private struct MissingList: View {
    var missing: [MissingEvidence]
    var actions: any ScanActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Still needed")
                .font(Typeface.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            ForEach(missing) { item in
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.text)
                        .font(Typeface.hint)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.capturable {
                        Button {
                            actions.captureMissing(item.id)
                        } label: {
                            Label("Capture it now", systemImage: "camera.fill")
                        }
                        .buttonStyle(.quiet)
                        .accessibilityIdentifier("action.captureMissing")
                    } else {
                        Label("An installer will check this", systemImage: "person.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
            }
        }
    }
}
