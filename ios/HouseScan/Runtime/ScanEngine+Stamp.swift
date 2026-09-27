import Foundation
import HouseScanKit
import OSLog

extension ScanEngine {
    /// Writes `scan-stamp.json` into the scan's folder: the app version, build and commit, the
    /// server the scan goes to, and the latest answer's rules (`ScanStamp`). Written when the
    /// scan is packaged and again when an answer arrives, so a scan pulled off the phone says what
    /// built and judged it. A failed write is logged; the scan goes on without it.
    func writeScanStamp(answer: PlacementResult?) {
        let info = Bundle.main.infoDictionary ?? [:]
        let stamp = ScanStamp(
            app: .init(
                version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                build: info["CFBundleVersion"] as? String ?? "unknown",
                // Written into the built Info.plist by the "Stamp the git commit" build phase.
                commit: info["HouseScanGitCommit"] as? String ?? "unknown"),
            server: .init(url: (resultClient as? HTTPResultClient)?.serverURL.absoluteString),
            answer: answer.map { ScanStamp.Answer($0, sample: resultClient.isSample) })
        let file = store.directory.appending(path: ScanStamp.fileName)
        do {
            try stamp.jsonData().write(to: file, options: .atomic)
        } catch {
            RuntimeLog.engine.error("scan stamp not written: \(String(describing: error), privacy: .public)")
        }
    }
}
