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
    /// True Peak (4x-oversampled, see TruePeakMeter.swift), not plain
    /// sample peak — measured at scan time now so this is accurate
    /// immediately instead of an estimate, and doubles as the Suggested
    /// Gain column's input (see MonoConverter.suggestedGainDB). The
    /// classifier's own silence test uses a separate, un-displayed plain
    /// sample-peak measurement internally — see AudioFileAnalyzer.swift.
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

    /// What a Needs Review row's Action-column dropdown is set to — same
    /// shape and same default as TrueStereoAction above, since these rows
    /// get the identical three-way choice (an ambiguous classification
    /// isn't a reason to withhold the same actions a confirmed True Stereo
    /// file already has).
    enum NeedsReviewAction: Hashable {
        case leaveAsIs
        case peakSafety
        case split
    }
    var needsReviewAction: NeedsReviewAction = .leaveAsIs

    // MARK: Sort keys
    //
    // Table column sorting (see ContentView.table) needs a plain Comparable
    // KeyPath per sortable column. The optional measurement fields above
    // can't be used directly — Optional<Double> isn't Comparable — so these
    // give each one a non-optional stand-in. Missing values sort to the
    // bottom for descending peak/RMS columns (a row with nothing measured
    // reads as "quietest"/least notable, not as a false top hit).

    var bitDepthSortValue: Int { bitDepth ?? -1 }

    /// Peak L/R and RMS L/R sort by whichever channel is louder, not just
    /// Left — sorting on Left alone pinned a real-signal-on-Right/
    /// silent-Left file to the bottom regardless of direction, since Left
    /// alone read as "quietest." Missing-value-sorts-to-bottom still
    /// applies per channel before the max is taken.
    var peakSortValue: Double {
        max(peakLeftDBFS ?? -.infinity, peakRightDBFS ?? -.infinity)
    }
    var rmsSortValue: Double {
        max(rmsLeftDBFS ?? -.infinity, rmsRightDBFS ?? -.infinity)
    }
}
