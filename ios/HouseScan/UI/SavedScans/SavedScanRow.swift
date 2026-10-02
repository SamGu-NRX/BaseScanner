import HouseScanKit
import SwiftUI

/// One saved scan: when its bundle was saved, its size, a Practice tag when the stamp says so, and
/// its Share button. Nothing in the row reads as a result or a place on a wall.
struct SavedScanRow: View {
    let scan: SavedScan
    /// This scan's copy is being made for the share sheet.
    let isPreparing: Bool
    /// Some scan's copy is being made; Share waits for it.
    let isBusy: Bool
    let onShare: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: scan.practice == true ? "wrench.and.screwdriver.fill" : "doc.zipper")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(scan.practice == true ? Palette.ink : Palette.signal)
                    .frame(width: 44, height: 44)
                    .background(scan.practice == true ? Palette.caution : Palette.signal.opacity(0.1), in: .circle)
                    .accessibilityHidden(true)
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            shareButton
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("savedScan.\(scan.id)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scan.savedAt.map { SavedScansCopy.saved($0) } ?? SavedScansCopy.unknownTime)
                .font(Typeface.hint.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if scan.practice == true {
                    Text(SavedScansCopy.practice)
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Palette.caution, in: .capsule)
                        .accessibilityIdentifier("savedScan.practice")
                }
                Text(scan.byteCount, format: .byteCount(style: .file))
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
            if scan.practice == true {
                Text(SavedScansCopy.practiceDetail)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The quiet button's look (`QuietButtonStyle`) at row size: a tinted capsule, 44 pt tall.
    private var shareButton: some View {
        Button(action: onShare) {
            HStack(spacing: 6) {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Palette.signalText)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
                Text(SavedScansCopy.share)
            }
            .font(Typeface.caption)
            .foregroundStyle(Palette.signalText)
            .padding(.horizontal, 16)
            .frame(minHeight: Metrics.minTarget)
            .background(Palette.signal.opacity(0.1), in: .capsule)
            .contentShape(.capsule)
            .opacity(isBusy && !isPreparing ? 0.45 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(isBusy)
        .accessibilityLabel(SavedScansCopy.share)
        .accessibilityHint("Opens the share sheet for this scan")
        .accessibilityIdentifier("action.shareSavedScan")
    }
}
