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
}
