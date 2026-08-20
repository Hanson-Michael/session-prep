import Foundation
import AVFoundation

/// Approximates ITU-R BS.1770-style True Peak: 4x-oversamples a channel's
/// samples (via AVAudioConverter's built-in high-quality resampler) and
/// tracks the peak absolute value of the oversampled signal, which catches
/// inter-sample peaks a plain sample-peak scan misses — the reconstructed
/// analog waveform can exceed the level of any single digital sample. This
/// is a practical approximation suited to a production tool, not a
/// certified broadcast-loudness meter (a certified meter follows the exact
/// filter coefficients specified in BS.1770-4 Annex 2; this leans on
/// Apple's resampler instead, which is simpler to get right and more than
/// accurate enough for catching hot inter-sample peaks worth knowing about).
///
/// Fed one analysis block at a time so it slots into the existing
/// block-by-block file-reading loops without holding a whole channel in
/// memory. Each block is oversampled independently — a true inter-sample
/// peak could in principle straddle a block boundary and be missed, but
/// blocks are tens of thousands of samples long, making that a
/// negligible/rare edge case here.
final class TruePeakAccumulator {
    private static let oversampleFactor = 4

    private let converter: AVAudioConverter?
    private let sourceFormat: AVAudioFormat?
    private let destFormat: AVAudioFormat?
    private(set) var peakLinear: Float = 0

    init(sampleRate: Double) {
        guard sampleRate > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let dest = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate * Double(Self.oversampleFactor), channels: 1, interleaved: false) else {
            sourceFormat = nil
            destFormat = nil
            converter = nil
            return
        }
        sourceFormat = source
        destFormat = dest
        converter = AVAudioConverter(from: source, to: dest)
    }

    /// Feed one block's worth of samples for this channel. Always tracks
    /// the plain sample peak as a floor/fallback (in case the converter
    /// couldn't be set up), and additionally tracks the oversampled peak
    /// when it could — the true peak is mathematically always ≥ the plain
    /// sample peak, so folding both into one running max is safe either way.
    func process(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        for i in 0..<count {
            peakLinear = max(peakLinear, abs(samples[i]))
        }

        guard let converter, let sourceFormat, let destFormat else { return }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        inputBuffer.frameLength = AVAudioFrameCount(count)
        guard let inputChannel = inputBuffer.floatChannelData?[0] else { return }
        inputChannel.update(from: samples, count: count)

        let outCapacity = AVAudioFrameCount(count * Self.oversampleFactor + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: outCapacity) else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil, let outData = outputBuffer.floatChannelData else { return }
        let n = Int(outputBuffer.frameLength)
        let ch = outData[0]
        for i in 0..<n {
            peakLinear = max(peakLinear, abs(ch[i]))
        }
    }

    /// True Peak in dBTP (dB relative to full scale, measured on the
    /// oversampled/reconstructed waveform rather than the raw samples).
    var peakDBTP: Double {
        peakLinear > 0 ? 20 * log10(Double(peakLinear)) : -160.0
    }
}
