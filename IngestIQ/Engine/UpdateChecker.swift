import Foundation
import AppKit
import Combine
import Sparkle

/// Thin wrapper around Sparkle's SPUStandardUpdaterController. `.shared` is
/// first touched at app launch (AppDelegate.applicationDidFinishLaunching),
/// which is what actually creates the controller and starts Sparkle's own
/// scheduled background-check timer — driven by
/// `updater.automaticallyChecksForUpdates`, kept in sync with
/// AppSettings.automaticallyCheckForUpdates via a live Combine subscription
/// (rather than requiring every call site that changes the setting to also
/// remember to forward it here) — so the Help menu's checkbox, or any future
/// UI touching the same setting, all just work by writing to AppSettings. No
/// separate silent-check call is needed the way the old placeholder
/// anticipated; Sparkle handles that internally once started.
final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()

    private let controller: SPUStandardUpdaterController
    private var automaticChecksSubscription: AnyCancellable?

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()

        // Set directly rather than relying on the Info.plist
        // SUScheduledCheckInterval key — Xcode's Info.plist generation was
        // confirmed (via `plutil -p` on a built app) to silently drop that
        // key while other, string-valued SU* keys came through fine. Setting
        // it here in code sidesteps that build-system quirk entirely. 86400
        // is Sparkle's own default (24h); listed explicitly so it's a known,
        // intentional value rather than an implicit fallback.
        controller.updater.updateCheckInterval = 86400
        // $automaticallyCheckForUpdates emits the current value immediately
        // on subscribe, then again on every future change — covers both the
        // initial sync at launch and staying live afterward in one place.
        //
        // The guard below matters: Sparkle's own docs warn against setting
        // this property except when the user is actually making a change,
        // since doing so resets Sparkle's scheduled check cycle. Without the
        // guard, the immediate emission on every subscribe would re-set this
        // to its own current value on every single launch — a no-op change
        // that still resets the cycle, which could keep it from ever
        // reaching its interval and firing a real check.
        automaticChecksSubscription = AppSettings.shared.$automaticallyCheckForUpdates
            .sink { [weak self] enabled in
                guard let self else { return }
                guard self.controller.updater.automaticallyChecksForUpdates != enabled else { return }
                self.controller.updater.automaticallyChecksForUpdates = enabled
            }
    }

    /// `manual` is kept for call-site compatibility with the Help menu's
    /// "Check for Updates…" item, which always passes `true` — Sparkle
    /// handles silent background checks on its own timer, so this method is
    /// only ever meant for the explicit, UI-visible check.
    func check(manual: Bool) {
        guard manual else { return }
        controller.checkForUpdates(nil)
    }
}
