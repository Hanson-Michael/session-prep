import Foundation

/// One row in the scan table — the measurements + classification for a
/// single audio file, plus (once acted on) where it ended up.
struct AudioFileRecord: Identifiable {
    let id = UUID()

    var url: URL
    var filename: String
    var fileExtension: String

    var bitDepth: Int?
    var sampleRate: Double
    var duration: TimeInterval
    var fileSizeBytes: Int64
    var channelCount: Int

    // Per-channel measurements. Right is nil for mono files — Left alone
    // still gets measured so mono rows aren't blank next to everyone else's.
    var peakLeftDBFS: Double?
    var peakRightDBFS: Double?
    var rmsLeftDBFS: Double?
    var rmsRightDBFS: Double?
    var correlation: Double?

    var status: FileStatus

    // Populated after a conversion runs.
    var convertedURL: URL?
    var movedOriginalURL: URL?

    /// Batch-inclusion flag for the auto-fix categories (Dual Mono, Panned,
    /// Polarity Inverted, Silent Channel) — driven by the row checkbox.
    var isSelectedForConversion: Bool = false

    /// What a True Stereo row's Action-column dropdown is set to. Leave As
    /// Is is the default — nothing happens to a True Stereo file without a
    /// deliberate per-row choice. `.peakSafety` writes a new stereo file
    /// (same L/R balance, no split) with the standing Peak Safety/Leveling
    /// gain pass applied; `.split` is the original opt-in behavior.
    enum TrueStereoAction: Hashable {
        case leaveAsIs
        case peakSafety
        case split
    }
    var trueStereoAction: TrueStereoAction = .leaveAsIs

    /// Opt-in only, same idea as trueStereoAction: an Already Mono file is
    /// never touched by default. There's nothing to choose between besides
    /// on/off here — no split is possible for a file that's already one
    /// channel — so this is a plain flag rather than its own enum.
    var applyPeakSafetyToMono: Bool = false
}
