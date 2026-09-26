import SwiftUI

/// "Anything else near your meter?": review what was marked, answer the one question a camera
/// can't (does this window open?), add anything missed, then confirm.
///
/// A panel over the dimmed camera rather than a new page: the homeowner is still standing at
/// the wall, and the list refers to things they can see.
struct MarkFeaturesScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    ModeBadge(isReplay: state.isReplay, isAutopilot: state.isAutopilot)
                    Spacer()
                }
                .padding(.horizontal, Metrics.edge)
                Spacer(minLength: 40)
                panel
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Anything else near your meter?")
                            .font(Typeface.screenTitle)
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Gas meters, doors, windows, AC units, driveways and fences all change where a battery can go.")
                            .font(Typeface.hint)
                            .foregroundStyle(Palette.muted)
                    }

                    if state.features.isEmpty {
                        Text("Nothing marked yet.")
                            .font(Typeface.hint)
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Palette.canvas, in: .rect(cornerRadius: 16, style: .continuous))
                    } else {
                        VStack(spacing: 10) {
                            ForEach(state.features) { feature in
                                FeatureRow(feature: feature, actions: actions)
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            }
                        }
                        .animation(Motion.settle, value: state.features)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add something")
                            .font(Typeface.sectionTitle)
                            .accessibilityAddTraits(.isHeader)
                        FlowChips { kind in actions.beginMarking(kind) }
                    }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button {
                actions.confirmFeatures()
            } label: {
                Text("Looks complete")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("action.confirmFeatures")
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Palette.surface)
                .ignoresSafeArea(edges: .bottom)
        }
        .environment(\.colorScheme, .light)
    }
}

private struct FeatureRow: View {
    var feature: MarkedFeature
    var actions: any ScanActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: ScanCopy.symbol(feature.kind))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.signal)
                    .frame(width: 44, height: 44)
                    .background(Palette.signal.opacity(0.1), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScanCopy.name(feature.kind))
                        .font(Typeface.hint.weight(.semibold))
                    Text(Distance.aroundFromMeter(feature.span).prefix(1).uppercased() + Distance.aroundFromMeter(feature.span).dropFirst())
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button(role: .destructive) {
                    actions.deleteFeature(feature.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.body.weight(.semibold))
                        .frame(width: Metrics.minTarget, height: Metrics.minTarget)
                }
                .foregroundStyle(Palette.danger)
                .accessibilityLabel("Remove \(ScanCopy.name(feature.kind).lowercased())")
                .accessibilityIdentifier("action.deleteFeature")
            }
            if feature.kind == .window {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Does this window open?")
                        .font(.subheadline.weight(.semibold))
                    // Stacked, so both answers stay full width at every text size (checklist I4).
                    VStack(spacing: 8) {
                        answer("It opens", selected: feature.opens == true) { actions.setWindowOpens(feature.id, opens: true) }
                            .accessibilityIdentifier("window.opens.yes")
                        answer("It stays shut", selected: feature.opens == false) { actions.setWindowOpens(feature.id, opens: false) }
                            .accessibilityIdentifier("window.opens.no")
                    }
                }
            }
        }
        .padding(14)
        .background(Palette.canvas, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func answer(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.button)
                .foregroundStyle(selected ? .white : Palette.signalText)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(selected ? Palette.signal : Palette.signal.opacity(0.1), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// Quick-add chips in as many columns as the text size allows.
private struct FlowChips: View {
    var onPick: (FeatureKind) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : 2
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: FeatureKind.allCases.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(FeatureKind.allCases[start..<min(start + columns, FeatureKind.allCases.count)]) { kind in
                        chip(kind)
                    }
                }
            }
        }
    }

    private func chip(_ kind: FeatureKind) -> some View {
        Button {
            onPick(kind)
        } label: {
            Label(ScanCopy.name(kind), systemImage: ScanCopy.symbol(kind))
                .font(Typeface.caption)
                .foregroundStyle(Palette.signalText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: Metrics.minTarget, alignment: .leading)
                .background(Palette.signal.opacity(0.1), in: .rect(cornerRadius: 14, style: .continuous))
                .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Add \(ScanCopy.name(kind).lowercased())")
        .accessibilityIdentifier("feature.\(kind.rawValue)")
    }
}
