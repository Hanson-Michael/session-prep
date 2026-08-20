import Foundation
import AVFoundation

/// Sample peak and RMS for one channel, plus a rough noise-floor estimate
/// (RMS of the quietest short window in the file) used to pick the
/// "cleaner" side when a polarity-inverted pair is otherwise a coin flip.
/// `peakDBFS` here is a plain per-sample peak, not True Peak.
struct ChannelMetrics {
    let peakDBFS: Double
    let rmsDBFS: Double
    let noiseFloorDBFS: Double
}

/// Full-file stereo analysis: per-channel metrics, plus the mid/side
/// (sum/difference) metrics the classifier uses as its primary tests, plus
/// a correlation coefficient as a secondary/diagnostic signal, plus per-
/// channel True Peak (see TruePeakMeter.swift) — this is what the table
/// displays and sorts on now (see AudioFileRecord.peakLeftDBFS/
/// peakRightDBFS), while `left`/`right.peakDBFS` above (plain sample peak)
/// stays reserved for the classifier's silence test, unchanged.
struct StereoAnalysis {
    let left: ChannelMetrics
    let right: ChannelMetrics
    let sumRMSDBFS: Double   // L+R — collapses toward silence for true polarity inversion
    let diffRMSDBFS: Double  // L-R — collapses toward silence for identical (dual mono) channels
    let correlation: Double
    let truePeakLeftDBTP: Double
    let truePeakRightDBTP: Double
}

enum AnalyzerError: Error {
    case unreadable(String)
}

enum AudioFileAnalyzer {

    /// Reads format metadata and, for stereo files, runs the full channel
    /// analysis needed for classification. Reads in blocks rather than
    /// loading the whole file into memory, so this scales to long files.
    static func analyze(url: URL) -> AudioFileRecord {
        let filename = url.lastPathComponent
        let ext = url.pathExtension

        guard let file = try? AVAudioFile(forReading: url) else {
            return AudioFileRecord(
                url: url, filename: filename, fileExtension: ext,
                bitDepth: nil, sampleRate: 0, duration: 0,
                fileSizeBytes: fileSize(url), channelCount: 0,
                status: .error(reason: "Could not open file")
            )
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        let bitDepth = bitDepthFromSettings(file: file) ?? bitsPerSample(format: format)

        var record = AudioFileRecord(
            url: url, filename: filename, fileExtension: ext,
            bitDepth: bitDepth, sampleRate: sampleRate, duration: duration,
            fileSizeBytes: fileSize(url), channelCount: channelCount,
            status: .alreadyMono
        )

        if channelCount == 0 {
            record.status = .error(reason: "No channels")
            return record
        }
        if channelCount == 1 {
            if let result = try? analyzeMonoChannel(file: file) {
                // Peak L/R shows True Peak now, not the plain sample peak
                // — see the Suggested Gain column, which needs it anyway.
                record.peakLeftDBFS = result.truePeakDBTP
                record.rmsLeftDBFS = result.metrics.rmsDBFS
            }
            record.status = .alreadyMono
            return record
        }
        if channelCount > 2 {
            // Multichannel (5.1, etc.) is outside v1 scope — reported, not classified.
            record.status = .needsReview(reason: "\(channelCount)-channel file, not stereo/mono")
            return record
        }

        do {
            let analysis = try analyzeStereoChannels(file: file)
            // Peak L/R shows True Peak now, not the plain sample peak the
            // classifier still uses internally (analysis.left/right.
            // peakDBFS, untouched below) for its silence test.
            record.peakLeftDBFS = analysis.truePeakLeftDBTP
            record.peakRightDBFS = analysis.truePeakRightDBTP
            record.rmsLeftDBFS = analysis.left.rmsDBFS
            record.rmsRightDBFS = analysis.right.rmsDBFS
            record.correlation = analysis.correlation
            record.status = StereoClassifier.classify(analysis: analysis, settings: AppSettings.shared)
        } catch {
            record.status = .error(reason: "Could not read audio data")
        }

        return record
    }

    private static func analyzeStereoChannels(file: AVAudioFile) throws -> StereoAnalysis {
        let blockSize: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockSize) else {
            throw AnalyzerError.unreadable("Could not allocate buffer")
        }

        var peakL: Float = 0
        var peakR: Float = 0
        // Suggested Gain column needs True Peak at scan time now, not just
        // at conversion time — accepted per-file oversampling cost (see
        // BACKLOG.md) in exchange for the column being accurate immediately.
        let truePeakL = TruePeakAccumulator(sampleRate: file.processingFormat.sampleRate)
        let truePeakR = TruePeakAccumulator(sampleRate: file.processingFormat.sampleRate)

        var sumSqL = 0.0, sumSqR = 0.0, sumSqSum = 0.0, sumSqDiff = 0.0
        var dotLR = 0.0
        var totalFrames: Int64 = 0

        // Rough noise-floor estimate: RMS of the quietest short window
        // (2048 samples) anywhere in the file, tracked per channel.
        let noiseWindowSize = 2048
        var windowSumSqL = 0.0, windowSumSqR = 0.0
        var windowCount = 0
        var minWindowRMS_L = Double.greatestFiniteMagnitude
        var minWindowRMS_R = Double.greatestFiniteMagnitude

        func flushNoiseWindow() {
            guard windowCount > 0 else { return }
            let rmsL = sqrt(windowSumSqL / Double(windowCount))
            let rmsR = sqrt(windowSumSqR / Double(windowCount))
            if rmsL > 0 { minWindowRMS_L = min(minWindowRMS_L, rmsL) }
            if rmsR > 0 { minWindowRMS_R = min(minWindowRMS_R, rmsR) }
            windowSumSqL = 0; windowSumSqR = 0; windowCount = 0
        }

        file.framePosition = 0
        while true {
            try file.read(into: buffer, frameCount: blockSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }
            let l = channelData[0]
            let r = channelData[1]
            for i in 0..<n {
                let lv = Double(l[i])
                let rv = Double(r[i])
                peakL = max(peakL, abs(l[i]))
                peakR = max(peakR, abs(r[i]))
                let s = lv + rv
                let d = lv - rv
                sumSqL += lv * lv
                sumSqR += rv * rv
                sumSqSum += s * s
                sumSqDiff += d * d
                dotLR += lv * rv

                windowSumSqL += lv * lv
                windowSumSqR += rv * rv
                windowCount += 1
                if windowCount >= noiseWindowSize { flushNoiseWindow() }
            }
            truePeakL.process(l, count: n)
            truePeakR.process(r, count: n)
            totalFrames += Int64(n)
            if n < Int(blockSize) { break }
        }
        flushNoiseWindow()

        guard totalFrames > 0 else {
            throw AnalyzerError.unreadable("Zero-length audio")
        }

        let rmsL = sqrt(sumSqL / Double(totalFrames))
        let rmsR = sqrt(sumSqR / Double(totalFrames))
        let rmsSum = sqrt(sumSqSum / Double(totalFrames))
        let rmsDiff = sqrt(sumSqDiff / Double(totalFrames))

        // Cosine-similarity form of correlation — fine for audio, which is
        // effectively zero-mean over any file-length window.
        let denom = sqrt(sumSqL * sumSqR)
        let correlation = denom > 0 ? dotLR / denom : 0

        let noiseFloorL = minWindowRMS_L == .greatestFiniteMagnitude ? 0 : minWindowRMS_L
        let noiseFloorR = minWindowRMS_R == .greatestFiniteMagnitude ? 0 : minWindowRMS_R

        return StereoAnalysis(
            left: ChannelMetrics(peakDBFS: dbfs(Double(peakL)), rmsDBFS: dbfs(rmsL), noiseFloorDBFS: dbfs(noiseFloorL)),
            right: ChannelMetrics(peakDBFS: dbfs(Double(peakR)), rmsDBFS: dbfs(rmsR), noiseFloorDBFS: dbfs(noiseFloorR)),
            sumRMSDBFS: dbfs(rmsSum),
            diffRMSDBFS: dbfs(rmsDiff),
            correlation: correlation,
            truePeakLeftDBTP: truePeakL.peakDBTP,
            truePeakRightDBTP: truePeakR.peakDBTP
        )
    }

    /// Same idea as analyzeStereoChannels but for a single-channel file —
    /// mono files were previously reported with no level info at all, which
    /// looked odd sitting next to every stereo file's numbers.
    private static func analyzeMonoChannel(file: AVAudioFile) throws -> (metrics: ChannelMetrics, truePeakDBTP: Double) {
        let blockSize: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockSize) else {
            throw AnalyzerError.unreadable("Could not allocate buffer")
        }

        var peak: Float = 0
        var sumSq = 0.0
        var totalFrames: Int64 = 0
        let truePeak = TruePeakAccumulator(sampleRate: file.processingFormat.sampleRate)

        file.framePosition = 0
        while true {
            try file.read(into: buffer, frameCount: blockSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }
            let c = channelData[0]
            for i in 0..<n {
                let v = Double(c[i])
                peak = max(peak, abs(c[i]))
                sumSq += v * v
            }
            truePeak.process(c, count: n)
            totalFrames += Int64(n)
            if n < Int(blockSize) { break }
        }

        guard totalFrames > 0 else {
            throw AnalyzerError.unreadable("Zero-length audio")
        }

        let rms = sqrt(sumSq / Double(totalFrames))
        let metrics = ChannelMetrics(peakDBFS: dbfs(Double(peak)), rmsDBFS: dbfs(rms), noiseFloorDBFS: 0)
        return (metrics, truePeak.peakDBTP)
    }

    private static func dbfs(_ linear: Double) -> Double {
        linear > 0 ? 20 * log10(linear) : -160.0
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
    }

    private static func bitsPerSample(format: AVAudioFormat) -> Int? {
        let asbd = format.streamDescription.pointee
        return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
    }

    /// AVAudioFile.processingFormat is often converted to Float32 for
    /// decoding, which loses the file's real on-disk bit depth — read it
    /// from the file's own format settings instead, which reflect what's
    /// actually stored on disk.
    private static func bitDepthFromSettings(file: AVAudioFile) -> Int? {
        file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int
    }
}
