import SwiftUI

/// "Checking your wall": a calm wait. Three steps tick off in order; progress is shown
/// separately from how complete the scan was (docs/05 section 2). Offline, the scan is saved on
/// the phone and one button tries again.
struct UploadingScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    var body: some View {
        let copy = ScanCopy.upload(state.upload, sample: state.usesSampleResult)
        CenteredScroll {
            VStack(spacing: 28) {
                UploadEmblem(upload: state.upload)
                VStack(spacing: 8) {
                    Text(copy.title)
                        .font(Typeface.screenTitle)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .contentTransition(.opacity)
                    if let detail = copy.detail {
                        Text(detail)
                            .font(Typeface.hint)
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .animation(Motion.text, value: copy)

                if isFailed {
                    Button("Try again") { actions.retryUpload() }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("action.retryUpload")
                } else {
                    UploadSteps(upload: state.upload)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
        .overlay(alignment: .topLeading) {
            ModeBadge(isReplay: state.isReplay, isAutopilot: state.isAutopilot)
                .padding(.horizontal, 24)
        }
        .background(Palette.canvas.ignoresSafeArea())
    }

    private var isFailed: Bool {
        if case .failed = state.upload { return true }
        return false
    }
}

private struct UploadEmblem: View {
    var upload: UploadState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 132, height: 132)
            Image(systemName: symbol)
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: isWorking && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityHidden(true)
    }

    private var isWorking: Bool {
        switch upload {
        case .failed, .done: false
        default: true
        }
    }

    private var symbol: String {
        switch upload {
        case .idle, .packaging: "photo.stack"
        case .uploading: "arrow.up.circle"
        case .analyzing: "ruler"
        case .failed(_, let offline): offline ? "wifi.slash" : "exclamationmark.triangle"
        case .done: "checkmark.circle"
        }
    }

    private var tint: Color {
        if case .failed = upload { return Palette.caution }
        return Palette.signal
    }
}

private struct UploadSteps: View {
    var upload: UploadState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(index: 0)
            step(index: 1)
            step(index: 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("upload.steps")
    }

    private var current: Int {
        switch upload {
        case .idle, .packaging: 0
        case .uploading: 1
        case .analyzing: 2
        case .done: 3
        case .failed: 1
        }
    }

    /// Each step says what it will do until it's done, then what it did.
    private func title(_ index: Int) -> String {
        switch index {
        case 0:
            return index < current ? "Photos ready" : "Get photos ready"
        case 1:
            if case .uploading(let fraction) = upload {
                return "Sending photos, \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
            }
            return index < current ? "Photos sent" : "Send photos"
        default:
            return index < current ? "Clearances checked" : "Check clearances"
        }
    }

    private func step(index: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if index < current {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.covered)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else if index == current {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.title3)
            .frame(width: 28, height: 28)
            .animation(Motion.settle, value: current)
            Text(title(index))
                .font(Typeface.hint)
                .foregroundStyle(index <= current ? Color.primary : Palette.muted)
                .contentTransition(.numericText())
        }
    }
}
