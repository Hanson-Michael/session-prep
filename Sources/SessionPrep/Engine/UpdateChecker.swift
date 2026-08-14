import Foundation
import AppKit

/// Placeholder until Sparkle is wired in (see README.md). Keeps the Help
/// menu fully functional now, structured the way Sparkle's checkForUpdates
/// flow will eventually slot in — swap the body of `check(manual:)` for
/// real SPUStandardUpdaterController calls once Sparkle is added as a
/// package dependency.
final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    func check(manual: Bool) {
        guard manual else { return } // no silent startup check until Sparkle is wired in
        let alert = NSAlert()
        alert.messageText = "Update Checking Not Yet Configured"
        alert.informativeText = "Auto-update via Sparkle hasn't been wired in yet — see README.md for the next step."
        alert.alertStyle = .informational
        alert.runModal()
    }
}
