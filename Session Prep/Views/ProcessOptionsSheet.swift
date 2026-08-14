import SwiftUI
import AppKit

/// Pre-flight review shown when "Process Selected…" is tapped — surfaces
/// every choice that affects what happens to files before anything actually
/// runs (original-file handling, output location, Peak Safety, suffixes),
/// rather than having them scattered across the bottom bar and Settings.
/// Resets to the safe defaults every time it's opened; these are per-run
/// choices, not standing preferences.
struct ProcessOptionsSheet: View {
    let toConvertCount: Int
    let toSplitCount: Int
    let toLevelCount: Int
    @Binding var options: ProcessOptions
    @ObservedObject var settings: AppSettings
    let onCancel: () -> Void
    let onProcess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Process Selected Files")
                .font(.title3.bold())

            Text(summaryText)
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()

            // Custom radio rows (not SwiftUI's native .radioGroup Picker) so
            // the folder-choose row can sit directly under "Move to a
            // custom folder…" specifically, rather than after the whole
            // group — which read as belonging to whichever option happened
            // to be listed last. The row is always laid out either way,
            // just enabled/disabled, so nothing resizes on selection.
            VStack(alignment: .leading, spacing: 6) {
                Text("Original Files").font(.headline)
                ForEach(OriginalFilesHandling.allCases) { choice in
                    radioRow(choice, selection: $options.originalHandling)
                    if choice == .customFolder {
                        folderRow(path: options.customOriginalsFolder?.path, isEnabled: options.originalHandling == .customFolder) {
                            options.customOriginalsFolder = pickFolder()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("New Mono Files").font(.headline)
                ForEach(OutputLocation.allCases) { choice in
                    radioRow(choice, selection: $options.outputLocation)
                    if choice == .customFolder {
                        folderRow(path: options.customOutputFolder?.path, isEnabled: options.outputLocation == .customFolder) {
                            options.customOutputFolder = pickFolder()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Peak Safety").font(.headline)
                // Not a limiter — this only ever turns a hot file's level
                // down before writing it, never shapes the dynamics.
                Toggle("Lower level on files that peak above the ceiling", isOn: $settings.peakSafetyEnabled)
                HStack(spacing: 4) {
                    Text("Ceiling")
                    TextField("", value: $settings.peakSafetyCeilingDBTP, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .disabled(!settings.peakSafetyEnabled)
                    Text("dBTP")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Divider()

            // Independent of Peak Safety, not gated by it — both are
            // attenuate-only, so there's no scenario where turning
            // Leveling on by itself could push a file somewhere unsafe.
            // When both are on, whichever wants the bigger cut wins.
            VStack(alignment: .leading, spacing: 6) {
                Text("Leveling").font(.headline)
                Toggle("Lower level on files hotter than the RMS target", isOn: $settings.levelingEnabled)
                HStack(spacing: 4) {
                    Text("Target")
                    TextField("", value: $settings.levelingTargetDBFS, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .disabled(!settings.levelingEnabled)
                    Text("dBFS")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Divider()

            // Caption stays fixed regardless of toggle state — both so the
            // sheet doesn't resize on toggle, and because the toggle's own
            // label already says what's being turned on/off.
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Add suffixes", isOn: $options.suffixesEnabled)
                    .font(.headline)
                // Real suffixes only — see FileStatus.conversionSuffix.
                // _mono-inv-L is Polarity Inverted; there's no separate
                // "_polarity" suffix.
                Text("e.g. _mono-pan-L, _mono-inv-L — flagging which process was used and which channel was kept. Split L/R files always keep .L/.R regardless of this setting.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Process") { onProcess() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canProcess)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var canProcess: Bool {
        guard toConvertCount + toSplitCount + toLevelCount > 0 else { return false }
        if options.originalHandling == .customFolder && options.customOriginalsFolder == nil { return false }
        if options.outputLocation == .customFolder && options.customOutputFolder == nil { return false }
        return true
    }

    private var summaryText: String {
        var parts = [
            "\(toConvertCount) file\(toConvertCount == 1 ? "" : "s") to convert to mono",
            "\(toSplitCount) file\(toSplitCount == 1 ? "" : "s") to split to L/R"
        ]
        if toLevelCount > 0 {
            // Some of these may turn out to already be within both limits
            // and end up untouched — "opted in for" rather than "will".
            parts.append("\(toLevelCount) file\(toLevelCount == 1 ? "" : "s") opted in for Peak Safety")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// A tappable radio row for any of the OptionLabeled enums — used
    /// instead of SwiftUI's native `.radioGroup` Picker so a sub-row (the
    /// folder-choose row) can be interleaved directly under one specific
    /// option rather than only ever appearing after the whole group.
    private func radioRow<T: OptionLabeled>(_ choice: T, selection: Binding<T>) -> some View {
        Button {
            selection.wrappedValue = choice
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.wrappedValue == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selection.wrappedValue == choice ? Color.accentColor : Color.secondary)
                Text(choice.label)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func folderRow(path: String?, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(path ?? "No folder chosen")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…", action: action)
        }
        .padding(.leading, 22)
        .disabled(!isEnabled)
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
