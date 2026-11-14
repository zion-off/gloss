#if os(macOS)
import Foundation
import Observation
import Sparkle
import SwiftUI

/// Sparkle's standard updater: it checks in the background (asking once, on the second launch)
/// and brings its own windows. Only release bundles carry a feed and a public key
/// (scripts/release.sh). Without them (scripts/run-mac.sh, `swift run`) there is no updater at
/// all, so Sparkle never shows its "misconfigured" alert and the menu item stays hidden.
@MainActor @Observable final class Updates {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// Sparkle's `canCheckForUpdates`: false while a check is already running.
    private(set) var canCheck = false

    init(bundle: Bundle = .main) {
        guard Self.isConfigured(bundle) else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // SPUUpdater is main-actor bound, so its changes arrive on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    var isAvailable: Bool { controller != nil }

    func check() {
        controller?.checkForUpdates(nil)
    }

    private static func isConfigured(_ bundle: Bundle) -> Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            (bundle.object(forInfoDictionaryKey: key) as? String).map { !$0.isEmpty } ?? false
        }
    }
}

/// "check for updates…" in the app menu, beside "install command line tool".
struct GlossUpdateCommands: Commands {
    let updates: Updates

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            if updates.isAvailable {
                Button("check for updates…") { updates.check() }
                    .disabled(!updates.canCheck)
            }
        }
    }
}
#endif
