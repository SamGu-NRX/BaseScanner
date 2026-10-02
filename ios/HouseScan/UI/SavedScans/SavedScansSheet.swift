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

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(SavedScansCopy.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .disabled(preparing != nil)
                            .accessibilityIdentifier("action.closeSavedScans")
                    }
                }
        }
        // A copy being made belongs to the share sheet that follows it; closing now would leave
        // the copy with no sheet to delete it.
        .interactiveDismissDisabled(preparing != nil)
        .presentationDetents([.medium, .large])
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

    @ViewBuilder
    private var content: some View {
        if let scans {
            if scans.isEmpty {
                // Not ContentUnavailableView: it doesn't scroll, so at large text sizes in the
                // half-height sheet its description was cut off.
                ScrollView {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                        Text(SavedScansCopy.emptyTitle)
                            .font(Typeface.sectionTitle)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(SavedScansCopy.emptyDetail)
                            .font(Typeface.hint)
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("savedScans.empty")
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                List {
                    Section {
                        ForEach(scans) { scan in
                            SavedScanRow(scan: scan, isPreparing: preparing == scan.id, isBusy: preparing != nil) {
                                share(scan)
                            }
                        }
                    } header: {
                        Text(SavedScansCopy.intro)
                            .textCase(nil)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Palette.muted)
                            .padding(.bottom, 4)
                            .accessibilityIdentifier("savedScans.intro")
                    } footer: {
                        Label(SavedScansCopy.shareFooter, systemImage: "lock.fill")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Palette.muted)
                            .accessibilityIdentifier("savedScans.privacy")
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else {
            // A list read takes milliseconds; a spinner would only flash.
            Color.clear
        }
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
