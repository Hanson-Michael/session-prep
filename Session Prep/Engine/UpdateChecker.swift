import Foundation
import AppKit
import Sparkle

/// Thin wrapper around Sparkle's SPUStandardUpdaterController. `.shared` is
/// first touched at app launch (SessionPrepApp's Help menu references it
/// immediately), which is what actually creates the controller and starts
/// Sparkle's own scheduled background-check timer — driven by
/// `updater.automaticallyChecksForUpdates`, kept in sync with
/// AppSettings.automaticallyCheckForUpdates via
/// `setAutomaticallyChecksForUpdates(_:)` below. No separate silent-check
/// call is needed the way the old placeholder anticipated; Sparkle handles
/// that internally once started.
final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()

    private let controller: SPUStandardUpdaterController

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        controller.updater.automaticallyChecksForUpdates = AppSettings.shared.automaticallyCheckForUpdates
    }

    /// `manual` is kept for call-site compatibility with the Help menu's
    /// "Check for Updates…" item, which always passes `true` — Sparkle
    /// handles silent background checks on its own timer, so this method is
    /// only ever meant for the explicit, UI-visible check.
    func check(manual: Bool) {
        guard manual else { return }
        controller.checkForUpdates(nil)
    }

    /// Called from the "Automatically Check for Updates" toggle so Sparkle's
    /// own scheduling stays in sync with the persisted AppSettings value.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
