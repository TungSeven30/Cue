import CryptoKit
import Darwin
import Foundation

/// Shared cache of extracted WAV files, byte-compatible with the embedded
/// Python helper (`audio_cache_path` / `prune_audio_cache` in
/// BackendScriptWriter). Both sides must derive identical file names from the
/// same source file so Swift and Python reuse a single cache.
enum AudioCache {
    /// Same location the Python helper hardcodes.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/WhisperDesk/audio", isDirectory: true)
    }

    /// Cache file for `sourceURL`: sha256 over
    /// "<resolved path>|<size>|<mtime_ns>|preprocess=<True/False>", first 24
    /// hex chars, ".wav". Parity with the Python helper was verified
    /// empirically (see `cacheKeyMatchesPythonHelperDigest` in
    /// AudioCacheTests, which shells out to python3 and compares digests).
    /// Foundation is deliberately avoided for the two payload inputs: `Date`
    /// mtimes round-trip through Double and drift from Python's integer
    /// `st_mtime_ns`, and `resolvingSymlinksInPath()` strips the "/private"
    /// prefix that Python's `Path.resolve()` keeps (e.g. /tmp), so Darwin
    /// `stat`/`realpath` are used instead.
    static func cachedAudioURL(for sourceURL: URL, preprocess: Bool) throws -> URL {
        var info = stat()
        guard stat(sourceURL.path, &info) == 0,
              let resolved = realpath(sourceURL.path, nil) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        defer { free(resolved) }

        let mtimeNS = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        let payload = "\(String(cString: resolved))|\(info.st_size)|\(mtimeNS)|preprocess=\(preprocess ? "True" : "False")"
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(24)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(digest).wav")
    }

    /// Deletes the oldest .wav files until the cache fits `maxBytes`, never
    /// deleting `keeping`, and sweeps stale "*.partial-*" temp files left by
    /// a hard kill during extraction (nothing else deletes those). Mirrors
    /// the Python helper's prune, including silent tolerance of filesystem
    /// errors: a failed delete must never fail a transcription.
    static func prune(directory: URL, maxBytes: UInt64 = 10 * 1024 * 1024 * 1024, keeping: URL?) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        // Safe to sweep unconditionally: the app runs one extraction at a time
        // (single activeTask in AppModel), so no in-flight temp file can exist
        // when prune runs.
        for url in entries where url.lastPathComponent.contains(".partial-") {
            try? fileManager.removeItem(at: url)
        }

        let wavs: [(url: URL, size: UInt64, mtime: Date)] = entries.compactMap { url in
            guard url.pathExtension == "wav",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let size = values.fileSize,
                  let mtime = values.contentModificationDate else { return nil }
            return (url, UInt64(size), mtime)
        }.sorted { $0.mtime < $1.mtime }

        var total = wavs.reduce(UInt64(0)) { $0 + $1.size }
        let keepPath = keeping?.standardizedFileURL.path
        for file in wavs {
            if total <= maxBytes { break }
            if file.url.standardizedFileURL.path == keepPath { continue }
            if (try? fileManager.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }
}
