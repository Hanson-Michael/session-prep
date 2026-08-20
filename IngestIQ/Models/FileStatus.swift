import SwiftUI

/// Which channel of a stereo pair to keep when collapsing to mono.
enum Channel: String, Equatable {
    case left = "L"
    case right = "R"
}

/// Which side went silent in a "Silent Channel" file.
enum SilentSide: String, Equatable {
    case left = "Left"
    case right = "Right"

    /// Single-letter form for the Action column — "Convert to mono (drop
    /// silent Left)" was long enough to get clipped in the 165pt Action
    /// column; "(drop L)" fits and reads just as clearly.
    var shortCode: String {
        self == .left ? "L" : "R"
    }
}

/// Every classification a scanned file can land in. See SPEC.md for the
/// full decision tree and threshold reasoning.
enum FileStatus: Equatable {
    case alreadyMono
    case noAudioContent
    case silentChannel(SilentSide)
    /// Sum (L+R) collapses to near-silence — the "L + R = 0" test. `keep`
    /// is the channel auto-picked by comparing per-channel noise floor.
    case polarityInverted(keep: Channel)
    case dualMono
    /// Same waveform, different channel gain. `keep` is the louder channel.
    case pannedMono(keep: Channel)
    case trueStereo
    /// Metrics fell in an ambiguous zone between two thresholds — never
    /// auto-classified into an actionable bucket, flagged for a manual look.
    case needsReview(reason: String)
    case error(reason: String)

    var label: String {
        switch self {
        case .alreadyMono: return "Already Mono"
        case .noAudioContent: return "No Audio Content"
        case .silentChannel(let side): return "Silent \(side.rawValue) Channel"
        case .polarityInverted: return "Polarity Inverted"
        case .dualMono: return "Dual Mono"
        case .pannedMono: return "Panned Mono"
        case .trueStereo: return "True Stereo"
        case .needsReview: return "Needs Review"
        case .error: return "Error"
        }
    }

    var color: Color {
        switch self {
        case .alreadyMono: return .gray
        case .noAudioContent: return .gray
        case .silentChannel: return .purple
        case .polarityInverted: return .red
        case .dualMono: return .orange
        case .pannedMono: return .yellow
        case .trueStereo: return .blue
        case .needsReview: return .pink
        case .error: return .red
        }
    }

    /// Whether this file is offered as a conversion candidate at all.
    var isConvertible: Bool {
        switch self {
        case .polarityInverted, .dualMono, .pannedMono, .silentChannel:
            return true
        default:
            return false
        }
    }

    /// Filename suffix for the new mono file — encodes both what kind of
    /// conversion happened and which channel was kept, so a glance at the
    /// filename tells you what to trust vs. what's worth spot-checking.
    /// See SPEC.md's suffix table.
    var conversionSuffix: String? {
        switch self {
        case .dualMono:
            return "_mono"
        case .pannedMono(let keep):
            return "_mono-pan-\(keep.rawValue)"
        case .polarityInverted(let keep):
            return "_mono-inv-\(keep.rawValue)"
        case .silentChannel(let side):
            let keep: Channel = side == .left ? .right : .left
            return "_mono-sc-\(keep.rawValue)"
        default:
            return nil
        }
    }

    /// Read-only description of what a batch run will do, shown in the
    /// Action column for the auto-fix categories. True Stereo's action is a
    /// user choice instead (see AudioFileRecord.splitToLR), not derived
    /// from status — handled separately in the UI. Kept to the same
    /// "Convert to mono (keep X)" shape/length across every case so the
    /// column can stay narrow — polarityInverted used to add "auto-picked"
    /// here too, which was both the longest string in the column and the
    /// reason it needed to be wide; that detail moved to a tooltip on the
    /// cell instead (see ContentView.actionCell).
    var actionDescription: String? {
        switch self {
        case .dualMono:
            return "Convert to mono"
        case .pannedMono(let keep):
            return "Convert to mono (keep \(keep.rawValue))"
        case .polarityInverted(let keep):
            return "Convert to mono (keep \(keep.rawValue))"
        case .silentChannel(let side):
            return "Convert to mono (drop \(side.shortCode))"
        default:
            return nil
        }
    }
}
