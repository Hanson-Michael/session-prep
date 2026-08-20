import Foundation
import Combine

/// User-editable settings, backed by UserDefaults so they persist across
/// launches. Every value here is exposed in SettingsView per the "everything
/// editable" requirement — defaults are the v1 starting points from SPEC.md,
/// meant to be tuned once you've run the app on real files.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: Output / peak safety
    // Not loudness normalization — this never raises level, only lowers a
    // file that peaks hotter than the ceiling, to leave headroom on files
    // we're already touching. "Peak Safety" rather than "Normalize" so the
    // name doesn't imply the wrong kind of processing.

    @Published var peakSafetyEnabled: Bool {
        didSet { UserDefaults.standard.set(peakSafetyEnabled, forKey: Keys.peakSafetyEnabled) }
    }
    /// Attenuate-only ceiling, measured via a 4x-oversampled True Peak scan
    /// at conversion time (see TruePeakMeter.swift) — not the table's Peak
    /// column, which is plain sample peak for fast scanning.
    @Published var peakSafetyCeilingDBTP: Double {
        didSet { UserDefaults.standard.set(peakSafetyCeilingDBTP, forKey: Keys.peakSafetyCeiling) }
    }

    // MARK: Leveling
    // Independent of Peak Safety, not gated by it — both are attenuate-only
    // (never raise level), so there's no scenario where Leveling alone
    // could push a file somewhere unsafe. When both are on, whichever wants
    // the bigger cut wins; see MonoConverter.combinedGain.

    @Published var levelingEnabled: Bool {
        didSet { UserDefaults.standard.set(levelingEnabled, forKey: Keys.levelingEnabled) }
    }
    /// Attenuate-only RMS target — files whose average level is already at
    /// or under this are left alone; hotter ones get pulled down to it.
    @Published var levelingTargetDBFS: Double {
        didSet { UserDefaults.standard.set(levelingTargetDBFS, forKey: Keys.levelingTarget) }
    }

    // MARK: Classification thresholds

    @Published var silenceFloorDBFS: Double {
        didSet { UserDefaults.standard.set(silenceFloorDBFS, forKey: Keys.silenceFloor) }
    }
    /// Below this per-channel RMS, correlation is considered unreliable
    /// (mostly noise floor) and the polarity-inversion test is skipped.
    @Published var reliabilityFloorDBFS: Double {
        didSet { UserDefaults.standard.set(reliabilityFloorDBFS, forKey: Keys.reliabilityFloor) }
    }
    /// Correlation ≤ this (and the L+R sum test passing) = Polarity Inverted.
    @Published var inversionCorrelationThreshold: Double {
        didSet { UserDefaults.standard.set(inversionCorrelationThreshold, forKey: Keys.inversionThreshold) }
    }
    /// Correlation ≥ this = Dual Mono or Panned Mono (split by level match).
    @Published var similarityCorrelationThreshold: Double {
        didSet { UserDefaults.standard.set(similarityCorrelationThreshold, forKey: Keys.similarityThreshold) }
    }
    /// Channel RMS difference at/under this = Dual Mono; over = Panned Mono.
    @Published var levelMatchToleranceDB: Double {
        didSet { UserDefaults.standard.set(levelMatchToleranceDB, forKey: Keys.levelMatchTolerance) }
    }

    // MARK: Updates

    @Published var automaticallyCheckForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyCheckForUpdates, forKey: Keys.autoCheckUpdates) }
    }

    // MARK: Batch behavior

    /// What to do, without asking, when a new folder is opened (Select
    /// Folder…, or a folder dropped onto the window) while the current batch
    /// already has files loaded. `nil` means "always ask" — the
    /// Replace/Append/Cancel prompt shown from ContentView. Per-machine, not
    /// synced — see SettingsView's Batch tab.
    @Published var rememberedFolderOpenAction: FolderOpenAction? {
        didSet { UserDefaults.standard.set(rememberedFolderOpenAction?.rawValue, forKey: Keys.rememberedFolderOpenAction) }
    }

    // MARK: Goniometer

    /// Trace color for the top-right stereo scope, stored as a hex string —
    /// see Color.hexString in BusyOverlayView.swift for the round-trip with
    /// the ColorPicker binding in SettingsView's Goniometer tab.
    @Published var goniometerColorHex: String {
        didSet { UserDefaults.standard.set(goniometerColorHex, forKey: Keys.goniometerColorHex) }
    }

    private enum Keys {
        static let peakSafetyEnabled = "peakSafetyEnabled"
        static let peakSafetyCeiling = "peakSafetyCeilingDBTP"
        static let levelingEnabled = "levelingEnabled"
        static let levelingTarget = "levelingTargetDBFS"
        static let silenceFloor = "silenceFloorDBFS"
        static let reliabilityFloor = "reliabilityFloorDBFS"
        static let inversionThreshold = "inversionCorrelationThreshold"
        static let similarityThreshold = "similarityCorrelationThreshold"
        static let levelMatchTolerance = "levelMatchToleranceDB"
        static let autoCheckUpdates = "automaticallyCheckForUpdates"
        static let goniometerColorHex = "goniometerColorHex"
        static let rememberedFolderOpenAction = "rememberedFolderOpenAction"
    }

    /// v1 starting-point values — the same numbers used as UserDefaults
    /// fallbacks in `init()` below. Named here too so the Settings window's
    /// per-tab "Reset to Defaults" buttons have a single source of truth
    /// instead of repeating the numbers a second time.
    enum Defaults {
        static let peakSafetyEnabled = false
        static let peakSafetyCeilingDBTP = -4.0
        static let levelingEnabled = false
        static let levelingTargetDBFS = -14.0
        static let silenceFloorDBFS = -80.0
        static let reliabilityFloorDBFS = -50.0
        static let inversionCorrelationThreshold = -0.98
        static let similarityCorrelationThreshold = 0.95
        static let levelMatchToleranceDB = 0.3
        static let goniometerColorHex = "a855f7"
    }

    private init() {
        let d = UserDefaults.standard
        peakSafetyEnabled = (d.object(forKey: Keys.peakSafetyEnabled) as? Bool) ?? Defaults.peakSafetyEnabled
        peakSafetyCeilingDBTP = (d.object(forKey: Keys.peakSafetyCeiling) as? Double) ?? Defaults.peakSafetyCeilingDBTP
        levelingEnabled = (d.object(forKey: Keys.levelingEnabled) as? Bool) ?? Defaults.levelingEnabled
        levelingTargetDBFS = (d.object(forKey: Keys.levelingTarget) as? Double) ?? Defaults.levelingTargetDBFS
        silenceFloorDBFS = (d.object(forKey: Keys.silenceFloor) as? Double) ?? Defaults.silenceFloorDBFS
        reliabilityFloorDBFS = (d.object(forKey: Keys.reliabilityFloor) as? Double) ?? Defaults.reliabilityFloorDBFS
        inversionCorrelationThreshold = (d.object(forKey: Keys.inversionThreshold) as? Double) ?? Defaults.inversionCorrelationThreshold
        similarityCorrelationThreshold = (d.object(forKey: Keys.similarityThreshold) as? Double) ?? Defaults.similarityCorrelationThreshold
        levelMatchToleranceDB = (d.object(forKey: Keys.levelMatchTolerance) as? Double) ?? Defaults.levelMatchToleranceDB
        automaticallyCheckForUpdates = (d.object(forKey: Keys.autoCheckUpdates) as? Bool) ?? true
        goniometerColorHex = (d.object(forKey: Keys.goniometerColorHex) as? String) ?? Defaults.goniometerColorHex
        rememberedFolderOpenAction = d.string(forKey: Keys.rememberedFolderOpenAction).flatMap(FolderOpenAction.init(rawValue:))
    }

    /// Resets just the Output tab's fields (Peak Safety) — matches that
    /// tab's own "Reset to Defaults" button, not a global reset.
    func resetOutputDefaults() {
        peakSafetyEnabled = Defaults.peakSafetyEnabled
        peakSafetyCeilingDBTP = Defaults.peakSafetyCeilingDBTP
        levelingEnabled = Defaults.levelingEnabled
        levelingTargetDBFS = Defaults.levelingTargetDBFS
    }

    /// Resets just the Thresholds tab's fields (classification thresholds).
    func resetThresholdDefaults() {
        silenceFloorDBFS = Defaults.silenceFloorDBFS
        reliabilityFloorDBFS = Defaults.reliabilityFloorDBFS
        inversionCorrelationThreshold = Defaults.inversionCorrelationThreshold
        similarityCorrelationThreshold = Defaults.similarityCorrelationThreshold
        levelMatchToleranceDB = Defaults.levelMatchToleranceDB
    }

    /// Resets just the Goniometer tab's fields (trace color).
    func resetGoniometerDefaults() {
        goniometerColorHex = Defaults.goniometerColorHex
    }

    /// Back to "always ask" — matches the Batch tab's own reset action.
    func forgetRememberedFolderOpenAction() {
        rememberedFolderOpenAction = nil
    }
}

/// What to do, without asking again, when opening a new folder while the
/// current batch already has files loaded — see
/// `AppSettings.rememberedFolderOpenAction` and ContentView's
/// requestFolderOpen(_:).
enum FolderOpenAction: String, CaseIterable, Identifiable {
    case replace
    case append

    var id: String { rawValue }

    var label: String {
        switch self {
        case .replace: return "Replace the batch"
        case .append: return "Append to the batch"
        }
    }
}
