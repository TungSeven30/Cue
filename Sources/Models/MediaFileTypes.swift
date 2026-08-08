import Foundation

/// File extensions the watch folder treats as ingestable media. The picker
/// and drag-and-drop accept anything; the watch folder must be pickier
/// because nobody is present to dismiss a junk job.
enum MediaFileTypes {
    static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "mpg", "mpeg",
        "ts", "mts", "m2ts", "3gp", "flv",
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff",
    ]

    /// Extensions of in-progress downloads that must never be ingested.
    static let partialDownloadExtensions: Set<String> = ["part", "download", "crdownload"]

    /// Every media file under `url`, at any depth: hidden files/directories
    /// and package contents skipped, symlinked directories not followed,
    /// partial downloads excluded, sorted by path so episodic folders
    /// enqueue in order.
    static func collectMediaFiles(under url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let candidate as URL in enumerator {
            guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let ext = candidate.pathExtension.lowercased()
            guard extensions.contains(ext), !partialDownloadExtensions.contains(ext) else { continue }
            found.append(candidate)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Expands an interactive add: files pass through, folders contribute
    /// their recursive media contents in place, so a mixed drop keeps its
    /// order. Used by the workspace drop and the file picker.
    static func expandForAdd(urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            return isDirectory.boolValue ? collectMediaFiles(under: url) : [url]
        }
    }
}
