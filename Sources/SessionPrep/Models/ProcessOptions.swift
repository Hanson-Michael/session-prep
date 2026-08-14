import Foundation

/// Common shape for the two per-run choice enums below, so the review sheet
/// can render both with one generic radio-row helper instead of duplicating
/// layout code per enum.
protocol OptionLabeled: Hashable, Identifiable {
    var label: String { get }
}

/// What to do with a file's original once it's been converted/split — a
/// per-run choice made in the pre-flight review sheet, not a standing
/// preference. Always resets to `.moveToSubfolder` (the original, safest
/// behavior) rather than remembering the last choice between runs. Case
/// order here is display order in the sheet's radio group.
enum OriginalFilesHandling: String, CaseIterable, Identifiable, Hashable, OptionLabeled {
    case leaveInPlace
    case customFolder
    case moveToSubfolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leaveInPlace: return "Leave in place"
        case .customFolder: return "Move to a custom folder…"
        case .moveToSubfolder: return "Move to \"Source - Stereo\" (default)"
        }
    }
}

/// Where newly-created mono/split files are written — also a per-run choice.
/// `.sourceFolder` writes directly into the folder being scanned, no
/// subfolder created at all — distinct from `.defaultSubfolder`, which is
/// the original, safest behavior.
enum OutputLocation: String, CaseIterable, Identifiable, Hashable, OptionLabeled {
    case sourceFolder
    case customFolder
    case defaultSubfolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sourceFolder: return "Write to source folder"
        case .customFolder: return "Move to a custom folder…"
        case .defaultSubfolder: return "Move to \"Processed - Mono\" (default)"
        }
    }
}

/// Everything the pre-flight review sheet collects before Process Selected
/// actually runs. A fresh value each time the sheet opens — deliberately not
/// persisted, since these are decisions about this run, not app-wide
/// settings (Peak Safety is the one exception: it reads/writes AppSettings
/// directly since it *is* a standing preference, just surfaced here too for
/// convenience).
struct ProcessOptions {
    var originalHandling: OriginalFilesHandling = .moveToSubfolder
    var customOriginalsFolder: URL?
    var outputLocation: OutputLocation = .defaultSubfolder
    var customOutputFolder: URL?
    /// When off, new files reuse the original filename instead of the
    /// descriptive suffix (e.g. `_mono-pan-L`). Split output's `.L`/`.R` is
    /// unaffected — that's structural (two files from one source need
    /// distinct names), not the optional descriptive suffix.
    var suffixesEnabled: Bool = true
}
