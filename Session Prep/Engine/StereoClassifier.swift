import Foundation

/// Applies the SPEC.md decision tree to a stereo file's measurements.
/// Order matters — silence checks first, then the L+R-sum polarity-
/// inversion test (the authoritative one, since it requires both inverted
/// shape AND matched level to collapse), then the L-R-difference dual/
/// panned-mono test, with a "Needs Review" bucket for anything that lands
/// in a genuinely ambiguous zone rather than guessing.
enum StereoClassifier {

    static func classify(analysis: StereoAnalysis, settings: AppSettings) -> FileStatus {
        let silenceFloor = settings.silenceFloorDBFS
        let reliabilityFloor = settings.reliabilityFloorDBFS
        let inversionThreshold = settings.inversionCorrelationThreshold
        let similarityThreshold = settings.similarityCorrelationThreshold
        let levelTolerance = settings.levelMatchToleranceDB

        let leftSilent = analysis.left.peakDBFS < silenceFloor
        let rightSilent = analysis.right.peakDBFS < silenceFloor

        if leftSilent && rightSilent {
            return .noAudioContent
        }
        if leftSilent {
            return .silentChannel(.left)
        }
        if rightSilent {
            return .silentChannel(.right)
        }

        let correlation = analysis.correlation
        let bothReliable = analysis.left.rmsDBFS > reliabilityFloor && analysis.right.rmsDBFS > reliabilityFloor

        // Polarity Inverted: the sum (L+R) collapsing toward silence,
        // relative to the individual channel levels, is the "L + R = 0"
        // test — the authoritative one, since only a truly inverted,
        // level-matched pair cancels this completely. Correlation ≤
        // threshold is required too, as a supporting check, and both
        // channels must clear the reliability floor so we're not trusting
        // a correlation computed mostly on noise.
        let referenceLevel = max(analysis.left.rmsDBFS, analysis.right.rmsDBFS)
        let sumCancellationDB = referenceLevel - analysis.sumRMSDBFS // large positive = strong cancellation

        if bothReliable && correlation <= inversionThreshold && sumCancellationDB > 20 {
            // Auto-pick the cleaner (lower noise-floor) channel as the keeper.
            let keep: Channel = analysis.left.noiseFloorDBFS <= analysis.right.noiseFloorDBFS ? .left : .right
            return .polarityInverted(keep: keep)
        }
        if correlation <= -0.90 && correlation > inversionThreshold {
            return .needsReview(reason: "Strong negative correlation (\(formatted(correlation))) but doesn't clear the polarity-inversion bar")
        }

        // Dual Mono / Panned Mono: high positive correlation means the
        // channels are the same waveform; the difference (L-R) collapsing
        // toward silence means the levels also match (Dual Mono). If it
        // doesn't collapse, it's the same content at different gain
        // (Panned Mono) — keep the louder channel.
        let levelDiffDB = abs(analysis.left.rmsDBFS - analysis.right.rmsDBFS)

        if correlation >= similarityThreshold {
            if levelDiffDB <= levelTolerance {
                return .dualMono
            } else {
                let keep: Channel = analysis.left.rmsDBFS >= analysis.right.rmsDBFS ? .left : .right
                return .pannedMono(keep: keep)
            }
        }
        if correlation >= 0.90 && correlation < similarityThreshold {
            return .needsReview(reason: "High correlation (\(formatted(correlation))) but doesn't clear the dual/panned-mono bar")
        }

        return .trueStereo
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
