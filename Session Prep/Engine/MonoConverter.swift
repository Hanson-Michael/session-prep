import Foundation
import AVFoundation

enum ConversionError: Error, LocalizedError {
    case notConvertible
    case couldNotCreateOutputFolders
    case couldNotReadSource(String)
    case couldNotWriteOutput(String)
    case couldNotMoveOriginal(String)

    var errorDescription: String? {
        switch self {
        case .notConvertible: return "This file's status isn't a convertible type."
        case .couldNotCreateOutputFolders: return "Could not create the output folders."
        case .couldNotReadSource(let msg): return "Could not read the source file: \(msg)"
        case .couldNotWriteOutput(let msg): return "Could not write the mono file: \(msg)"
        case .couldNotMoveOriginal(let msg): return "Could not move the original file: \(msg)"
        }
    }
}

struct ConversionResult {
    let originalMovedTo: URL
    let newMonoFileAt: URL
}

struct SplitResult {
    let originalMovedTo: URL
    let leftFileAt: URL
    let rightFileAt: URL
}

/// Converts or splits a stereo file's source into true mono output(s). Never
/// sums L+R to build output — every case is resolved by *selecting* a single
/// channel per file. Moves the original into "Source - Stereo/" and
/// writes new mono file(s) into "Processed - Mono/", both siblings of the
/// scanned folder — files that aren't touched are never moved.
enum MonoConverter {

    /// Auto-fix conversion for a detected problem (Dual Mono, Panned, etc.)
    /// — writes one new mono file using the channel FileStatus already
    /// decided on. `options` (from the pre-flight review sheet) controls
    /// where the original and new file end up, and whether the descriptive
    /// suffix is applied.
    static func convert(record: AudioFileRecord, sourceFolder: URL, settings: AppSettings, options: ProcessOptions) throws -> ConversionResult {
        guard record.status.conversionSuffix != nil, let keep = keepChannel(for: record.status) else {
            throw ConversionError.notConvertible
        }
        let suffix = options.suffixesEnabled ? (record.status.conversionSuffix ?? "") : ""

        let folders = try resolveFolders(sourceFolder: sourceFolder, options: options)
        guard let sourceFile = try? AVAudioFile(forReading: record.url) else {
            throw ConversionError.couldNotReadSource(record.filename)
        }

        let baseName = (record.filename as NSString).deletingPathExtension
        let (outSettings, outExtension) = resolvedOutputSettings(sourceFile: sourceFile, channels: 1)
        let newMonoURL = uniqueURL(in: folders.newMono, baseName: "\(baseName)\(suffix)", ext: outExtension)

        do {
            try writeMonoFile(from: sourceFile, keeping: keep, to: newMonoURL, outputSettings: outSettings, settings: settings)
        } catch {
            throw ConversionError.couldNotWriteOutput(error.localizedDescription)
        }
        preserveBroadcastMetadata(from: record.url, into: newMonoURL)

        let movedOriginalURL = try moveOriginalIfNeeded(record: record, baseName: baseName, to: folders.original)
        return ConversionResult(originalMovedTo: movedOriginalURL, newMonoFileAt: newMonoURL)
    }

    /// Deliberate split, not a "fix" — for a genuinely stereo (or any
    /// two-channel) file where you want the channels apart as two discrete
    /// mono files. Suffixed literally `.L` / `.R` (e.g. "Vocal.L.wav",
    /// "Vocal.R.wav") — always, regardless of `options.suffixesEnabled`,
    /// since that's the only thing keeping the two output files distinct,
    /// not a decorative marker. Original/output locations still follow
    /// `options` like convert() does.
    static func split(record: AudioFileRecord, sourceFolder: URL, settings: AppSettings, options: ProcessOptions) throws -> SplitResult {
        let folders = try resolveFolders(sourceFolder: sourceFolder, options: options)
        guard let sourceFile = try? AVAudioFile(forReading: record.url) else {
            throw ConversionError.couldNotReadSource(record.filename)
        }

        let baseName = (record.filename as NSString).deletingPathExtension
        let (outSettings, outExtension) = resolvedOutputSettings(sourceFile: sourceFile, channels: 1)

        let leftURL = uniqueURL(in: folders.newMono, baseName: "\(baseName).L", ext: outExtension)
        do {
            try writeMonoFile(from: sourceFile, keeping: .left, to: leftURL, outputSettings: outSettings, settings: settings)
        } catch {
            throw ConversionError.couldNotWriteOutput(error.localizedDescription)
        }
        preserveBroadcastMetadata(from: record.url, into: leftURL)

        let rightURL = uniqueURL(in: folders.newMono, baseName: "\(baseName).R", ext: outExtension)
        do {
            try writeMonoFile(from: sourceFile, keeping: .right, to: rightURL, outputSettings: outSettings, settings: settings)
        } catch {
            throw ConversionError.couldNotWriteOutput(error.localizedDescription)
        }
        preserveBroadcastMetadata(from: record.url, into: rightURL)

        let movedOriginalURL = try moveOriginalIfNeeded(record: record, baseName: baseName, to: folders.original)
        return SplitResult(originalMovedTo: movedOriginalURL, leftFileAt: leftURL, rightFileAt: rightURL)
    }

    /// "Peak Safety" action for a row that isn't being converted or split —
    /// an Already Mono file, or a True Stereo file left as stereo. Not a
    /// conversion: channel count/layout never changes, this only ever
    /// applies the same combined Peak Safety/Leveling gain every other
    /// write path uses. Works for either channel count generically: a
    /// mono source measures its one channel directly; a stereo source uses
    /// the hotter of the two channels' True Peak (so neither can clip past
    /// the ceiling) and the average of their RMS (a stand-in for overall
    /// loudness without a full LUFS measurement) — the same gain is then
    /// applied uniformly to both channels, so the L/R balance never shifts.
    /// Returns nil (writes nothing, moves nothing) if the computed gain is
    /// exactly 1.0 — a file already within both limits is left completely
    /// untouched rather than duplicated.
    static func levelOnly(record: AudioFileRecord, sourceFolder: URL, settings: AppSettings, options: ProcessOptions) throws -> ConversionResult? {
        guard let sourceFile = try? AVAudioFile(forReading: record.url) else {
            throw ConversionError.couldNotReadSource(record.filename)
        }

        let channelCount = Int(sourceFile.processingFormat.channelCount)
        let blockSize: AVAudioFrameCount = 65536
        let peakLinear: Float
        let rmsLinear: Float
        if channelCount == 2 {
            let (peakL, rmsL) = try measureGainInputs(sourceFile: sourceFile, channelIndex: 0, blockSize: blockSize)
            let (peakR, rmsR) = try measureGainInputs(sourceFile: sourceFile, channelIndex: 1, blockSize: blockSize)
            peakLinear = max(peakL, peakR)
            rmsLinear = (rmsL + rmsR) / 2
        } else {
            (peakLinear, rmsLinear) = try measureGainInputs(sourceFile: sourceFile, channelIndex: 0, blockSize: blockSize)
        }

        let gain = combinedGain(peakLinear: peakLinear, rmsLinear: rmsLinear, settings: settings)
        guard gain < 1.0 else { return nil }

        let folders = try resolveFolders(sourceFolder: sourceFolder, options: options)
        let baseName = (record.filename as NSString).deletingPathExtension
        let (outSettings, outExtension) = resolvedOutputSettings(sourceFile: sourceFile, channels: UInt32(channelCount))
        let newURL = uniqueURL(in: folders.newMono, baseName: baseName, ext: outExtension)

        do {
            try writeGainAdjustedFile(from: sourceFile, channelCount: channelCount, gain: gain, to: newURL, outputSettings: outSettings)
        } catch {
            throw ConversionError.couldNotWriteOutput(error.localizedDescription)
        }
        preserveBroadcastMetadata(from: record.url, into: newURL)

        let movedOriginalURL = try moveOriginalIfNeeded(record: record, baseName: baseName, to: folders.original)
        return ConversionResult(originalMovedTo: movedOriginalURL, newMonoFileAt: newURL)
    }

    /// Carries BWF/broadcast chunks (or, for an MP3 source, its ID3v2 tag)
    /// from the original file into a newly-written one — see
    /// BroadcastMetadata.swift. Best-effort and non-throwing: AVAudioFile
    /// has no concept of any of this on its own, so without this step
    /// every conversion/split would silently drop session-critical
    /// metadata like BWF's TimeReference field.
    private static func preserveBroadcastMetadata(from source: URL, into destination: URL) {
        var chunks = BroadcastMetadata.extractChunks(from: source)
        if chunks.isEmpty, let id3Chunk = BroadcastMetadata.extractID3TagAsWavChunk(from: source) {
            chunks = [id3Chunk]
        }
        BroadcastMetadata.injectChunks(chunks, into: destination)
    }

    private static func keepChannel(for status: FileStatus) -> Channel? {
        switch status {
        case .dualMono: return .left // channels are identical — arbitrary, either works
        case .pannedMono(let keep): return keep
        case .polarityInverted(let keep): return keep
        case .silentChannel(let side): return side == .left ? .right : .left
        default: return nil
        }
    }

    /// Resolves where originals and new files actually go based on the
    /// pre-flight review sheet's choices — defaults match the original,
    /// always-on behavior ("Source - Stereo/" + "Processed - Mono/" siblings
    /// of the source folder), but either can be overridden to a custom
    /// folder, output can skip the subfolder entirely (written straight
    /// into the source folder), and originals can be left in place
    /// entirely (`original` comes back nil in that case).
    private static func resolveFolders(sourceFolder: URL, options: ProcessOptions) throws -> (original: URL?, newMono: URL) {
        let fm = FileManager.default

        let newMonoFolder: URL
        switch options.outputLocation {
        case .defaultSubfolder:
            newMonoFolder = sourceFolder.appendingPathComponent("Processed - Mono", isDirectory: true)
        case .sourceFolder:
            newMonoFolder = sourceFolder
        case .customFolder:
            guard let custom = options.customOutputFolder else {
                throw ConversionError.couldNotCreateOutputFolders
            }
            newMonoFolder = custom
        }
        do {
            // No-op if the folder already exists (true for .sourceFolder,
            // which is always the already-existing scanned folder).
            try fm.createDirectory(at: newMonoFolder, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.couldNotCreateOutputFolders
        }

        let originalFolder: URL?
        switch options.originalHandling {
        case .moveToSubfolder:
            let folder = sourceFolder.appendingPathComponent("Source - Stereo", isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw ConversionError.couldNotCreateOutputFolders
            }
            originalFolder = folder
        case .leaveInPlace:
            originalFolder = nil
        case .customFolder:
            guard let custom = options.customOriginalsFolder else {
                throw ConversionError.couldNotCreateOutputFolders
            }
            do {
                try fm.createDirectory(at: custom, withIntermediateDirectories: true)
            } catch {
                throw ConversionError.couldNotCreateOutputFolders
            }
            originalFolder = custom
        }

        return (originalFolder, newMonoFolder)
    }

    /// A nil `originalFolder` means "Leave in place" was chosen — the
    /// original never moves, and its URL is returned unchanged so callers
    /// still get a valid ConversionResult/SplitResult.
    private static func moveOriginalIfNeeded(record: AudioFileRecord, baseName: String, to originalFolder: URL?) throws -> URL {
        guard let originalFolder else {
            return record.url
        }
        let originalExt = record.fileExtension.isEmpty ? "wav" : record.fileExtension
        let movedOriginalURL = uniqueURL(in: originalFolder, baseName: baseName, ext: originalExt)
        do {
            try FileManager.default.moveItem(at: record.url, to: movedOriginalURL)
        } catch {
            throw ConversionError.couldNotMoveOriginal(error.localizedDescription)
        }
        return movedOriginalURL
    }

    /// AVAudioFile can decode MP3 but cannot encode it. If the source isn't
    /// writable as linear PCM, fall back to a standard 24-bit PCM WAV
    /// rather than trying to preserve the original container/codec.
    private static func resolvedOutputSettings(sourceFile: AVAudioFile, channels: UInt32) -> (settings: [String: Any], extension: String) {
        var settings = sourceFile.fileFormat.settings
        let formatID = settings[AVFormatIDKey] as? UInt32
        let isWritablePCM = formatID == kAudioFormatLinearPCM

        if isWritablePCM {
            settings[AVNumberOfChannelsKey] = channels
            let ext = (settings[AVFormatIDKey] != nil) ? currentFileExtension(sourceFile: sourceFile) : "wav"
            return (settings, ext)
        } else {
            let fallback: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sourceFile.fileFormat.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            return (fallback, "wav")
        }
    }

    private static func currentFileExtension(sourceFile: AVAudioFile) -> String {
        sourceFile.url.pathExtension.isEmpty ? "wav" : sourceFile.url.pathExtension
    }

    private static func writeMonoFile(from sourceFile: AVAudioFile, keeping channel: Channel, to destination: URL, outputSettings: [String: Any], settings: AppSettings) throws {
        let sourceFormat = sourceFile.processingFormat
        guard let monoBufferFormat = AVAudioFormat(
            commonFormat: sourceFormat.commonFormat,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ConversionError.couldNotWriteOutput("Could not build mono buffer format")
        }

        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: outputSettings,
            commonFormat: sourceFormat.commonFormat,
            interleaved: false
        )

        let channelIndex = channel == .left ? 0 : 1
        let blockSize: AVAudioFrameCount = 65536
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: blockSize),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: monoBufferFormat, frameCapacity: blockSize) else {
            throw ConversionError.couldNotWriteOutput("Could not allocate buffers")
        }

        // Peak Safety + Leveling: measure the True Peak and RMS of the
        // channel we're keeping, then apply whichever of the two wants the
        // bigger cut — see combinedGain(). This is the only place True Peak
        // gets computed; the table shows plain sample peak (fast — no
        // oversampling) to keep folder scans quick.
        var gain: Float = 1.0
        if settings.peakSafetyEnabled || settings.levelingEnabled {
            let (peakLinear, rmsLinear) = try measureGainInputs(sourceFile: sourceFile, channelIndex: channelIndex, blockSize: blockSize)
            gain = combinedGain(peakLinear: peakLinear, rmsLinear: rmsLinear, settings: settings)
        }

        sourceFile.framePosition = 0
        while true {
            try sourceFile.read(into: readBuffer, frameCount: blockSize)
            let n = Int(readBuffer.frameLength)
            if n == 0 { break }
            guard let src = readBuffer.floatChannelData, let dst = writeBuffer.floatChannelData else { break }
            let channelSrc = src[channelIndex]
            let channelDst = dst[0]
            for i in 0..<n {
                channelDst[i] = channelSrc[i] * gain
            }
            writeBuffer.frameLength = AVAudioFrameCount(n)
            try outputFile.write(from: writeBuffer)
            if n < Int(blockSize) { break }
        }
    }

    /// Writes every channel of `sourceFile` back out unchanged in layout —
    /// no channel selection/collapsing, unlike writeMonoFile — with `gain`
    /// applied uniformly across all of them. Used by levelOnly(), where the
    /// point is a level change only, never a channel-count change.
    private static func writeGainAdjustedFile(from sourceFile: AVAudioFile, channelCount: Int, gain: Float, to destination: URL, outputSettings: [String: Any]) throws {
        let sourceFormat = sourceFile.processingFormat
        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: outputSettings,
            commonFormat: sourceFormat.commonFormat,
            interleaved: false
        )

        let blockSize: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: blockSize) else {
            throw ConversionError.couldNotWriteOutput("Could not allocate buffer")
        }

        sourceFile.framePosition = 0
        while true {
            try sourceFile.read(into: buffer, frameCount: blockSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for ch in 0..<channelCount {
                let channelData = data[ch]
                for i in 0..<n {
                    channelData[i] *= gain
                }
            }
            try outputFile.write(from: buffer)
            if n < Int(blockSize) { break }
        }
    }

    /// One pass over the channel giving both measurements Peak Safety and
    /// Leveling need — avoids a second full read of the file just to also
    /// get RMS, now that both mechanisms exist side by side.
    private static func measureGainInputs(sourceFile: AVAudioFile, channelIndex: Int, blockSize: AVAudioFrameCount) throws -> (peakLinear: Float, rmsLinear: Float) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: blockSize) else { return (0, 0) }
        let peakAccumulator = TruePeakAccumulator(sampleRate: sourceFile.processingFormat.sampleRate)
        var sumSq: Double = 0
        var count = 0
        sourceFile.framePosition = 0
        while true {
            try sourceFile.read(into: buffer, frameCount: blockSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            let channelData = data[channelIndex]
            peakAccumulator.process(channelData, count: n)
            for i in 0..<n {
                let v = Double(channelData[i])
                sumSq += v * v
            }
            count += n
            if n < Int(blockSize) { break }
        }
        sourceFile.framePosition = 0
        let rms = count > 0 ? Float(sqrt(sumSq / Double(count))) : 0
        return (peakAccumulator.peakLinear, rms)
    }

    /// Peak Safety and Leveling are both attenuate-only and fully
    /// independent — neither can ever raise the gain above 1.0. Each
    /// computes its own cut (if enabled and the file's hotter than its
    /// target), and whichever one wants the bigger cut is what actually
    /// gets applied, so turning both on can never leave a file peaking
    /// hotter than Peak Safety's own ceiling.
    private static func combinedGain(peakLinear: Float, rmsLinear: Float, settings: AppSettings) -> Float {
        var gain: Float = 1.0
        if settings.peakSafetyEnabled, peakLinear > 0 {
            let ceilingLinear = Float(pow(10.0, settings.peakSafetyCeilingDBTP / 20.0))
            gain = min(gain, min(1.0, ceilingLinear / peakLinear))
        }
        if settings.levelingEnabled, rmsLinear > 0 {
            let targetLinear = Float(pow(10.0, settings.levelingTargetDBFS / 20.0))
            gain = min(gain, min(1.0, targetLinear / rmsLinear))
        }
        return gain
    }

    private static func uniqueURL(in folder: URL, baseName: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
