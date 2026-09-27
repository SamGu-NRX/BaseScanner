import Foundation
import HouseScanKit
import Observation
import StoreKit

/// The developer options sheet's settings, and whether this install may show them.
///
/// The switch lives in the app, not in the iOS Settings app: a Settings.bundle is a file in the
/// app bundle, and a TestFlight build is the same binary the App Store later ships, so its
/// switch would show in App Store installs too. Here the sheet and the switch appear only where
/// `PracticeMeter.isAvailable` says, decided at run time from where the install came from.
@MainActor
@Observable
final class DeveloperSettings {
    static let shared = DeveloperSettings(simulateAppStore: LaunchOptions().simulateAppStore)

    /// The UserDefaults key the sheet's switch writes. A launch argument `-practiceMeter NO`
    /// overrides it for one run (UserDefaults' argument domain), which the UI tests use.
    static let practiceMeterKey = "practiceMeter"

    /// Where this install came from; `.unknown` until StoreKit answers.
    private(set) var environment: PracticeMeter.InstallEnvironment

    init(simulateAppStore: Bool) {
        if simulateAppStore {
            environment = .appStore
            return
        }
        #if DEBUG
        environment = .development
        #else
        environment = .unknown
        Task { [weak self] in
            let found = await Self.storeEnvironment()
            self?.environment = found
            RuntimeLog.engine.info("install environment: \(found.rawValue, privacy: .public)")
        }
        #endif
    }

    /// Whether the developer options are offered at all.
    var isAvailable: Bool { PracticeMeter.isAvailable(in: environment) }

    /// Whether a scan started now is a practice scan.
    var practiceMeterOn: Bool {
        PracticeMeter.isOn(requested: UserDefaults.standard.bool(forKey: Self.practiceMeterKey), in: environment)
    }

    /// StoreKit's signed app transaction says which server signed it: the sandbox for TestFlight,
    /// production for the App Store, Xcode for StoreKit testing. Anything unverified or missing is
    /// `.unknown`, which offers nothing.
    nonisolated private static func storeEnvironment() async -> PracticeMeter.InstallEnvironment {
        do {
            guard case .verified(let transaction) = try await AppTransaction.shared else { return .unknown }
            switch transaction.environment {
            case .sandbox: return .testFlight
            case .production: return .appStore
            case .xcode: return .development
            default: return .unknown
            }
        } catch {
            RuntimeLog.engine.error("install environment unknown: \(String(describing: error), privacy: .public)")
            return .unknown
        }
    }
}
