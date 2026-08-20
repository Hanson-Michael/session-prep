import Foundation

enum FolderScanner {

    /// Extensions AVFoundation can generally decode. WAV/AIFF are the
    /// primary target; the rest are here so the app isn't locked out of
    /// other formats even though it won't be the common case.
    static let supportedExtensions: Set<String> = [
        "wav", "wave", "aiff", "aif", "aifc", "caf", "m4a", "mp3", "flac", "alac"
    ]

    /// Top-level only in v1 — deliberately not recursive (see SPEC.md;
    /// flagged as a possible future toggle).
    ///
    /// Per-file analysis runs concurrently across the available cores
    /// (`DispatchQueue.concurrentPerform`) rather than serially — each
    /// iteration only computes its own result, but writing that result into
    /// the shared `results` array and incrementing `completed` both touch
    /// state shared across threads, so both go through `lock`.
    ///
    /// `onProgress` fires on whatever background thread happened to finish
    /// that file — callers touching UI state from it need to hop back to
    /// main themselves.
    static func scan(folder: URL, onProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil) -> [AudioFileRecord] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let audioFiles = contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let total = audioFiles.count
        guard total > 0 else { return [] }

        var results = [AudioFileRecord?](repeating: nil, count: total)
        let lock = NSLock()
        var completed = 0

        DispatchQueue.concurrentPerform(iterations: total) { index in
            let record = AudioFileAnalyzer.analyze(url: audioFiles[index])
            lock.lock()
            results[index] = record
            completed += 1
            let currentCompleted = completed
            lock.unlock()
            onProgress?(currentCompleted, total)
        }

        return results.compactMap { $0 }
    }
}
