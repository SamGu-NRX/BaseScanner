import HouseScanKit
import SwiftUI

/// The completed scans still on the phone, each with a Share button. Opened from the onboarding.
///
/// Export only: a saved scan is not reopened, its result is not shown, and nothing is sent until
/// the homeowner taps Share and then picks a destination in the system share sheet. Share copies
/// the bundle out of the scan folder first (`SavedScanStaging`), so a cleanup can't delete it
/// while the sheet reads it, and deletes the copy when the sheet closes.
struct SavedScansSheet: View {
    let catalog: SavedScanCatalog
    let staging: SavedScanStaging

    /// Nil until the first read finishes, so an empty list is never shown before it is known.
    @State private var scans: [SavedScan]?
    @State private var preparing: SavedScan.ID?
    @State private var sharing: StagedCopy?
    /// The copy being shared, kept past `sharing` going nil so `finishSharing` can delete it.
    @State private var lastShared: URL?
    @State private var problem: SavedScanShareError?
    @State private var showsProblem = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct StagedCopy: Identifiable {
        let url: URL
        var id: URL { url }
    }

    // Built like the app's light screens rather than a system list in a half-height sheet. In
    // that sheet the onboarding showed through the glass behind the text (contrast), the list's
    // header and footer and the navigation bar's Done didn't fully follow Dynamic Type, and large
    // text ran off the sheet's bottom (hosted run 37051620836).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.canvas.ignoresSafeArea())
        .presentationBackground(Palette.canvas)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // A copy being made belongs to the share sheet that follows it; closing now would leave
        // the copy with no sheet to delete it.
        .interactiveDismissDisabled(preparing != nil)
        .task { await open() }
        .sheet(item: $sharing, onDismiss: finishSharing) { copy in
            ActivitySheet(file: copy.url) { sharing = nil }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert(
            problem.map(SavedScansCopy.problemTitle) ?? "",
            isPresented: $showsProblem,
            presenting: problem
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(SavedScansCopy.problemDetail(error))
        }
        .accessibilityIdentifier("savedScans")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(SavedScansCopy.title)
                .font(Typeface.instruction)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button("Done") { dismiss() }
                .font(Typeface.hint.weight(.semibold))
                .foregroundStyle(Palette.signalText)
                .frame(minWidth: Metrics.minTarget, minHeight: Metrics.minTarget)
                .contentShape(.rect)
                .buttonStyle(PressableStyle())
                .disabled(preparing != nil)
                .opacity(preparing != nil ? 0.45 : 1)
                .accessibilityIdentifier("action.closeSavedScans")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let scans {
            if scans.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    Text(SavedScansCopy.emptyTitle)
                        .font(Typeface.sectionTitle)
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(SavedScansCopy.emptyDetail)
                        .font(Typeface.hint)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.top, 48)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("savedScans.empty")
            } else {
                Text(SavedScansCopy.intro)
                    .font(Typeface.hint)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("savedScans.intro")
                VStack(spacing: 0) {
                    ForEach(scans) { scan in
                        if scan.id != scans.first?.id {
                            Divider().padding(.leading, 58)
                        }
                        SavedScanRow(scan: scan, isPreparing: preparing == scan.id, isBusy: preparing != nil) {
                            share(scan)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 16)
                .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
                Label(SavedScansCopy.shareFooter, systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("savedScans.privacy")
            }
        }
        // Until the first read finishes there is nothing: it takes milliseconds, and a spinner
        // would only flash.
    }

    /// No share sheet is open while this sheet opens, so copies a quit left behind go first.
    private func open() async {
        let catalog = catalog, staging = staging
        let found = await Task.detached(priority: .userInitiated) { () -> [SavedScan] in
            staging.removeAll()
            return catalog.scans()
        }.value
        scans = found
    }

    private func reload() async {
        let catalog = catalog
        let found = await Task.detached(priority: .userInitiated) { catalog.scans() }.value
        withAnimation(reduceMotion ? nil : Motion.settle) { scans = found }
    }

    private func share(_ scan: SavedScan) {
        guard preparing == nil else { return }
        preparing = scan.id
        let staging = staging
        Task {
            let staged = await Task.detached(priority: .userInitiated) { () -> Result<URL, SavedScanShareError> in
                do throws(SavedScanShareError) {
                    return .success(try staging.stage(scan))
                } catch {
                    return .failure(error)
                }
            }.value
            preparing = nil
            switch staged {
            case .success(let url):
                lastShared = url
                sharing = StagedCopy(url: url)
            case .failure(let error):
                problem = error
                showsProblem = true
                // A missing or damaged scan drops out of the list; a failed copy leaves it to retry.
                if error != .copyFailed { await reload() }
            }
        }
    }

    /// The share sheet is closed, by finishing, cancelling or a swipe: its copy goes.
    private func finishSharing() {
        guard let copy = lastShared else { return }
        lastShared = nil
        let staging = staging
        Task.detached(priority: .utility) { staging.remove(copy) }
    }

}
