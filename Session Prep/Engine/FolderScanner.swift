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
    static func scan(folder: URL) -> [AudioFileRecord] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let audioFiles = contents.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }

        return audioFiles
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { AudioFileAnalyzer.analyze(url: $0) }
    }
}
