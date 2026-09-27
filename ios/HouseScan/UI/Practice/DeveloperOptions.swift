import HouseScanKit
import SwiftUI

/// The way into the developer options, on the first screen. Only development and TestFlight
/// installs show it (`DeveloperSettings.isAvailable`); an App Store install shows nothing here.
/// While practice meter is on it says so, so nobody starts a scan without knowing.
struct DeveloperOptionsButton: View {
    @AppStorage(DeveloperSettings.practiceMeterKey) private var practiceMeter = false
    @State private var showing = false
    private let settings = DeveloperSettings.shared

    var body: some View {
        if settings.isAvailable {
            Button {
                showing = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    if practiceMeter {
                        // Wraps at the largest text sizes rather than dropping out.
                        Text("Practice meter on")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(Typeface.caption)
                .foregroundStyle(practiceMeter ? Palette.ink : Palette.muted)
                .padding(.horizontal, practiceMeter ? 10 : 0)
                .padding(.vertical, 5)
                .background {
                    if practiceMeter { Capsule().fill(Palette.caution) }
                }
                .frame(minWidth: Metrics.minTarget, minHeight: Metrics.minTarget)
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(practiceMeter ? "Developer options. Practice meter is on." : "Developer options")
            .accessibilityIdentifier("action.developerOptions")
            .sheet(isPresented: $showing) {
                DeveloperOptionsSheet(environment: settings.environment)
            }
        }
    }
}

/// One switch for now: practice meter.
private struct DeveloperOptionsSheet: View {
    var environment: PracticeMeter.InstallEnvironment
    @AppStorage(DeveloperSettings.practiceMeterKey) private var practiceMeter = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Practice meter", isOn: $practiceMeter)
                        .accessibilityIdentifier("developer.practiceMeter")
                } footer: {
                    Text("For trying the scan where there's no electric meter. Tap any spot on a wall and a sample meter is drawn there. A photo of it stands in for the meter close-up, and the rest of the scan runs for real. Each screen and the scan's stamp say it's practice. Starts with the next scan.")
                }
                Section {
                    LabeledContent("Build", value: Self.name(environment))
                }
            }
            .navigationTitle("Developer options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("action.closeDeveloperOptions")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private static func name(_ environment: PracticeMeter.InstallEnvironment) -> String {
        switch environment {
        case .development: "Development"
        case .testFlight: "TestFlight"
        case .appStore: "App Store"
        case .unknown: "Unknown"
        }
    }
}
