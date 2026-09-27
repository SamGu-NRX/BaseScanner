import HouseScanKit
import SwiftUI

/// The reveal: the homeowner's own wall in 3D with the battery on it, then one card that answers
/// the question in their words, shows the checks that decided it and offers the one next step.
/// Footnotes and the full list of checks sit under it; the full list stays folded under Details.
struct ResultScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var revealed = false
    @State private var detailsExpanded = false

    var body: some View {
        if let result = state.result {
            content(result)
        } else {
            ContentUnavailableView {
                Label("No result yet", systemImage: "hourglass")
            } description: {
                Text("Your scan is still being checked.")
            } actions: {
                Button("Start over") { actions.startOver() }
                    .accessibilityIdentifier("action.startOver")
            }
        }
    }

    private func content(_ result: ResultPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                diorama(result)
                VStack(alignment: .leading, spacing: 20) {
                    AnswerCard(result: result, canShowAR: state.spatialResultAvailable, revealed: revealed, actions: actions)
                    if result.spot != nil, let answer = state.spotCheck?.answer, let leftOut = ScanCopy.spotLeftOut(answer) {
                        Notice(symbol: "exclamationmark.triangle.fill", text: leftOut)
                            .accessibilityIdentifier("result.spotRefused")
                    }
                    footnotes(result)
                        .padding(.horizontal, 4)
                    details(result)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, Metrics.edge)
                .padding(.top, Metrics.edge)
                .padding(.bottom, 28)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.canvas.ignoresSafeArea())
        .overlay(alignment: .top) {
            // Keeps scrolled text from running under the status bar.
            Palette.canvas
                .ignoresSafeArea(edges: .top)
                .frame(height: 0)
                .accessibilityHidden(true)
        }
        .onAppear { revealed = true }
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
            VStack(alignment: .leading, spacing: 6) {
                ModeBadge(isReplay: state.isReplay, isAutopilot: state.isAutopilot)
                if result.isSample {
                    // The same quiet pill as ModeBadge: the answer, not the test mode, is the
                    // loudest thing on this screen.
                    // One Text with the flask inline, built as ModeBadge is. As a Label with
                    // fixedSize, the audit reported its Dynamic Type as partially unsupported.
                    Text("\(Image(systemName: "flask.fill")) Sample result, not from the server")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Palette.chalk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Palette.ink.opacity(0.7), in: .capsule)
                        .accessibilityLabel("Sample result, not from the server")
                        .accessibilityIdentifier("result.sampleBadge")
                }
            }
            .padding(14)
        }
        .frame(height: 340)
        .clipShape(.rect(bottomLeadingRadius: 28, bottomTrailingRadius: 28, style: .continuous))
        .ignoresSafeArea(edges: .top)
    }

    /// Plain small print, never boxes: none of it changes what the homeowner does next.
    private func footnotes(_ result: ResultPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            footnote(ScanCopy.installerConfirms, id: "result.installerConfirms")
            if let notice = result.rulesNotice {
                footnote(notice, id: "result.rulesNotice")
            }
            if !result.policyApproved {
                footnote(ScanCopy.rulesNotFinal, id: "result.rulesNotFinal")
            }
            if let hash = result.rulesHash {
                footnote(ScanCopy.rulesHash(hash), id: "result.rulesHash")
            }
            if let side = result.unseenSide {
                footnote(ScanCopy.unseenSide(side), id: "result.unseenSide")
            }
            if let line = ScanCopy.unmeasuredMarks(result.unmeasuredMarks) {
                footnote(line, id: "result.unmeasuredMarks")
            }
            footnote(ScanCopy.panelReview, id: "result.panelReview")
        }
    }

    private func footnote(_ text: String, id: String) -> some View {
        Text(text)
            .font(Typeface.caption)
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }

    private func details(_ result: ResultPresentation) -> some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 22) {
                if !result.summary.isEmpty {
                    Text(result.summary)
                        .font(Typeface.hint)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("result.summary")
                }
                if !result.checks.isEmpty {
                    ChecksList(checks: result.checks)
                }
                if !result.missing.isEmpty {
                    MissingList(missing: result.missing, checks: result.checks, canCapture: state.spatialResultAvailable, actions: actions)
                }
                VStack(spacing: 16) {
                    if let scan = state.shareableScan {
                        ShareScanButton(url: scan)
                    }
                    // Last, so the one action that throws the scan away is the farthest. The card's
                    // button already starts over after a reject.
                    if result.answer != .notHere {
                        Button("Start over") { actions.startOver() }
                            .buttonStyle(TextActionStyle())
                            .accessibilityHint("Starts a new scan. This phone keeps your two latest finished scans.")
                            .accessibilityIdentifier("action.startOver")
                    }
                }
            }
            .padding(.top, 14)
        } label: {
            Text(ScanCopy.details)
                .font(Typeface.sectionTitle)
                .foregroundStyle(Color.primary)
                .frame(minHeight: Metrics.minTarget)
                .accessibilityIdentifier("result.details")
        }
        .tint(Palette.signalText)
    }
}

/// A text-only action inside Details: the card's primary button stays the one filled button.
private struct TextActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.hint.weight(.semibold))
            .foregroundStyle(Palette.signalText)
            .frame(minHeight: Metrics.minTarget)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - The card

/// The answer, where the spot is (or why the closest one fails), the checks that decided it and
/// the one next step.
private struct AnswerCard: View {
    let result: ResultPresentation
    /// False once the camera failed after the scan was sent: the AR buttons are neither shown nor
    /// offered (`ScanViewState.spatialResultAvailable`).
    let canShowAR: Bool
    let revealed: Bool
    let actions: any ScanActions

    var body: some View {
        let answer = result.answer
        let lines = result.cardChecks
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ScanCopy.headline(answer))
                    .font(Typeface.screenTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("result.headline")
                if let placement = ScanCopy.placement(result) {
                    Text(placement)
                        .font(Typeface.sectionTitle)
                        .foregroundStyle(Palette.signalText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("result.placement")
                } else if let nearest = ScanCopy.nearest(result) {
                    Text(nearest)
                        .font(Typeface.hint)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(ScanCopy.nearest(result, spoken: true) ?? nearest)
                        .accessibilityIdentifier("result.nearest")
                }
            }
            .modifier(Reveal(revealed: revealed, order: 0))

            if !lines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 34)
                        }
                        line(row)
                            .modifier(Reveal(revealed: revealed, order: index + 1))
                    }
                }
                .padding(.top, 14)
            }

            primaryButton(answer)
                .padding(.top, 18)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func line(_ row: CheckRow) -> some View {
        // After a reject, the line above already gave the nearest spot's failing measurement.
        let repeatsNearest = row.id == result.nearestFailingCheck && result.nearestSpot != nil
        let view = result.viewToTake(for: row)
        return CardCheckLine(
            row: row,
            sentence: repeatsNearest ? nil : ScanCopy.cardLine(row),
            spokenSentence: repeatsNearest ? nil : ScanCopy.cardLine(row, spoken: true),
            showMe: view.map { view in { actions.captureMissing(view.id) } }
        )
    }

    @ViewBuilder
    private func primaryButton(_ answer: ResultReading.Answer) -> some View {
        switch answer {
        case .fits:
            if result.spot != nil, canShowAR { showAR(ScanCopy.seeOnWall) }
        case .oneMoreLook:
            if let view = result.firstViewToTake {
                Button {
                    actions.captureMissing(view.id)
                } label: {
                    Label(ScanCopy.showMe, systemImage: "camera.fill")
                }
                .buttonStyle(.primary)
                .accessibilityHint(view.text)
                .accessibilityIdentifier("action.showMe")
            }
        case .installer:
            if result.spot != nil, canShowAR { showAR(result.spotIsClean ? ScanCopy.seeOnWall : ScanCopy.seeClosest) }
        case .notHere:
            Button {
                actions.startOver()
            } label: {
                Label(ScanCopy.scanAnotherWall, systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.primary)
            .accessibilityHint("Starts a new scan. This phone keeps your two latest finished scans.")
            .accessibilityIdentifier("action.startOver")
        }
    }

    private func showAR(_ title: String) -> some View {
        Button {
            actions.showAR()
        } label: {
            Label(title, systemImage: "camera.viewfinder")
        }
        .buttonStyle(.primary)
        .accessibilityIdentifier("action.showAR")
    }
}

/// One check on the card: its outcome, its title and, for a failed or unsure check, the
/// measurement against the rule. An unsure check that a view can settle is a button to that view.
private struct CardCheckLine: View {
    let row: CheckRow
    let sentence: String?
    let spokenSentence: String?
    let showMe: (() -> Void)?

    var body: some View {
        if let showMe {
            Button(action: showMe) { content }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(label)
                .accessibilityValue(spokenSentence ?? "")
                .accessibilityHint("Opens the camera for the view that settles it.")
                .accessibilityIdentifier("check.\(row.id)")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(spokenSentence ?? "")
                .accessibilityIdentifier("check.\(row.id)")
        }
    }

    private var label: String {
        "\(row.title): \(ScanCopy.outcomeWord(row.outcome))"
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: CheckSymbol.name(row.outcome))
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.outcomeInk(row.outcome))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(Typeface.hint.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let sentence {
                    Text(sentence)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showMe != nil {
                Text(ScanCopy.showMe)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.signalText)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: Metrics.minTarget)
        .contentShape(.rect)
    }
}

/// The card's rise: 12 pt up into place and a fade to full strength on `Motion.settle`, each
/// line 60 ms after the one above. Reduce Motion keeps the fade alone, all at once.
///
/// The fade starts at 0.9, not 0. Fading in from transparent left the headline and summary under
/// 4.5:1 on the light background for the length of the fade, which the accessibility audit caught. At 0.9 every text color
/// on the card still clears it on Surface: muted and SignalText, the lowest, are about 5.6:1 in
/// light mode (7.2 and 7.0 at full strength), and the primary button's white label about 5.1:1.
private struct Reveal: ViewModifier {
    let revealed: Bool
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0.9)
            .offset(y: revealed || reduceMotion ? 0 : 12)
            .animation(reduceMotion ? Motion.text : Motion.settle.delay(0.06 * Double(order)), value: revealed)
    }
}

private enum CheckSymbol {
    static func name(_ outcome: CheckOutcome) -> String {
        switch outcome {
        case .pass: "checkmark.circle.fill"
        case .unsure: "questionmark.circle.fill"
        case .fail: "xmark.circle.fill"
        }
    }
}

// MARK: - Details

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
            Image(systemName: CheckSymbol.name(row.outcome))
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
        .accessibilityValue([row.reason, ScanCopy.measurement(row, spoken: true), row.outcome == .unsure ? ScanCopy.unsureNote(row) : nil]
            .compactMap(\.self).joined(separator: ". "))
        // The card shows the deciding checks as `check.<id>`; this is the full list.
        .accessibilityIdentifier("detail.check.\(row.id)")
    }
}

private struct MissingList: View {
    var missing: [MissingEvidence]
    var checks: [CheckRow]
    /// False once the camera has failed: no view can be taken, so none is offered.
    var canCapture: Bool
    var actions: any ScanActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Still needed")
                .font(Typeface.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            ForEach(missing) { item in
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text)
                            .font(Typeface.hint)
                            .fixedSize(horizontal: false, vertical: true)
                        if let settles = ScanCopy.settles(item, checks: checks) {
                            Text(settles)
                                .font(.subheadline)
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("missing.settles")
                        }
                    }
                    if item.capturable, canCapture {
                        Button {
                            actions.captureMissing(item.id)
                        } label: {
                            Label("Capture it now", systemImage: "camera.fill")
                        }
                        .buttonStyle(TextActionStyle())
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

/// The one boxed notice left on the result: the homeowner said something stands in the checked
/// area, so the scan leaves that stretch out, which changes what the answer covers. The rest of
/// the small print stays plain footnotes.
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
