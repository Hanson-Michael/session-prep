import SwiftUI

/// Backing content for the Settings scene (⌘,). Update-check controls
/// (Check for Updates…, Automatically Check for Updates) live on the Help
/// menu already, so there's no separate Updates tab here — just the things
/// that actually change what conversion does.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            outputTab
                .tabItem { Label("Output", systemImage: "folder") }
            thresholdsTab
                .tabItem { Label("Thresholds", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 480, height: 420)
    }

    private var outputTab: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section {
                    Toggle("Lower level on files that peak above the ceiling", isOn: $settings.peakSafetyEnabled)
                    LabeledContent("Ceiling") {
                        HStack(spacing: 4) {
                            TextField("", value: $settings.peakSafetyCeilingDBTP, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .disabled(!settings.peakSafetyEnabled)
                            Text("dBTP")
                        }
                    }
                } header: {
                    Text("Peak Safety")
                } footer: {
                    Text("Attenuate-only — never raises level, only lowers it to make room for hot recordings. Measured via a 4x-oversampled True Peak scan at conversion time, not the table's Peak column.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle("Lower level on files hotter than the RMS target", isOn: $settings.levelingEnabled)
                    LabeledContent("Target") {
                        HStack(spacing: 4) {
                            TextField("", value: $settings.levelingTargetDBFS, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .disabled(!settings.levelingEnabled)
                            Text("dBFS")
                        }
                    }
                } header: {
                    Text("Leveling")
                } footer: {
                    Text("Also attenuate-only, and independent of Peak Safety — either can be on by itself. When both are on, whichever wants the bigger cut wins, so the peak ceiling can never be violated.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            resetButton { settings.resetOutputDefaults() }
        }
    }

    private var thresholdsTab: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section("Silence") {
                    labeledField("Silence floor (dBFS)", value: $settings.silenceFloorDBFS)
                    labeledField("Reliability floor (dBFS)", value: $settings.reliabilityFloorDBFS)
                }
                Section {
                    labeledField("Polarity-inversion correlation ≤", value: $settings.inversionCorrelationThreshold)
                    labeledField("Dual/panned-mono correlation ≥", value: $settings.similarityCorrelationThreshold)
                    labeledField("Level match tolerance (dB)", value: $settings.levelMatchToleranceDB)
                } header: {
                    Text("Classification")
                } footer: {
                    Text("Defaults are a v1 starting point — adjust based on what you see on real files.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            resetButton { settings.resetThresholdDefaults() }
        }
    }

    /// Bottom-right of each tab, matching the usual placement for a
    /// scoped reset action — resets only that tab's fields, not every
    /// setting in the app at once.
    private func resetButton(action: @escaping () -> Void) -> some View {
        Button("Reset to Defaults", action: action)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 4)
    }

    /// Uses LabeledContent rather than a manual HStack+Spacer — Form on
    /// macOS reserves its own label column and fights a hand-rolled Spacer
    /// for that space, which was pushing labels off the left edge.
    /// LabeledContent lets Form handle that alignment itself.
    private func labeledField(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
        }
    }
}
