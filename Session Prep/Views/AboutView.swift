import SwiftUI
import AppKit

/// Custom About window (not the native panel) so it matches the Budget
/// app's branding — same reasoning as that app: consistent look across the
/// series rather than the OS's default panel styling.
struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 10) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Session Prep")
                .font(.system(size: 16, weight: .semibold))
            // .primary at reduced opacity instead of .secondary — .secondary
            // reads too washed-out next to the title; this keeps it clearly
            // de-emphasized but still legible/dark enough to match the rest
            // of the series' About windows.
            Text("Version \(appVersion) (\(buildNumber))")
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.75))
            Text("Copyright © 2026 Michael Hanson.\nAll rights reserved.")
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34) // clears the traffic lights — see fullSizeContentView in SessionPrepApp
        .padding(.bottom, 20)
        .frame(width: 320, height: 260)
        .background(
            // Invisible, but its keyboardShortcut still registers while
            // this window is key — Esc closes the window like any other
            // "cancel" action.
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }
}
