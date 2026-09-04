import Foundation

/// Turns subtitle files on disk into segments plus provenance. Kept out of
/// `AppModel` so the whole scan/parse path is testable without one, and so it
/// can run off the main actor during a batch add.
enum SubtitleImporter {
    struct Document: Equatable {
        let source: ImportedSubtitleSource
        let segments: [TranscriptionSegment]
    }

    struct Result {
        let transcript: Document?
        let translation: Document?
        /// Lines for the job log — one per adopted or rejected file.
        let logLines: [String]
    }

    /// Every file in `folder`, for `importSidecars` to match against. Listed
    /// separately so a batch add of one folder reads that folder once rather
    /// than once per video.
    static func folderContents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
    }

    static func importSidecars(
        mediaURL: URL,
        sourceLanguage: String,
        translationTargetLanguage: String
    ) -> Result {
        importSidecars(
            mediaURL: mediaURL,
            candidates: folderContents(of: mediaURL.deletingLastPathComponent()),
            sourceLanguage: sourceLanguage,
            translationTargetLanguage: translationTargetLanguage
        )
    }

    static func importSidecars(
        mediaURL: URL,
        candidates: [URL],
        sourceLanguage: String,
        translationTargetLanguage: String
    ) -> Result {
        let matches = SubtitleSidecarScanner.match(
            mediaURL: mediaURL,
            candidates: candidates,
            sourceLanguage: sourceLanguage,
            translationTargetLanguage: translationTargetLanguage
        )

        var transcript: Document?
        var translation: Document?
        var logLines: [String] = []
        for match in matches {
            do {
                let document = try importFile(at: match.url)
                logLines.append(
                    "Loaded subtitles from \(document.source.fileName) (\(document.segments.count) cues)."
                )
                switch match.slot {
                case .transcript: transcript = document
                case .translation: translation = document
                }
            } catch {
                // Silent skip with a log line: a 200-file batch add must not
                // raise dialogs.
                logLines.append(
                    "Could not read \(match.url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        // SubtitleSidecarScanner never returns a lone translation, but a
        // transcript that fails to parse turns a valid pair into one. A
        // translation with no transcript is a state the rest of the app cannot
        // represent: the job would be marked translated, then swept up for ASR
        // because it has no transcript, and the adopted translation discarded.
        if transcript == nil, let orphan = translation {
            translation = nil
            logLines.append("Ignored \(orphan.source.fileName): its matching transcript could not be read.")
        }
        return Result(transcript: transcript, translation: translation, logLines: logLines)
    }

    /// `backingUp: false` is for the manual load path, where the file is only
    /// read to fill the slot picker: the user may still cancel, and a cancelled
    /// load must leave nothing behind. That path backs up when it commits.
    static func importFile(at url: URL, backingUp: Bool = true) throws -> Document {
        let decoded = try SubtitleReader.readText(contentsOf: url)
        guard let format = SubtitleReader.format(for: url),
            var source = ImportedSubtitleSource(url: url, format: format)
        else {
            throw SubtitleReader.ReadError.unreadable
        }
        let segments = try SubtitleReader.parse(decoded.text, format: format)
        if decoded.requiresEncodingReview {
            source.syncPaused = true
            source.lastSyncError = "Legacy text encoding is uncertain. Review the text and export a UTF-8 copy before syncing edits."
        }
        if backingUp {
            source.didBackup = backUpOriginal(at: url)
        }
        return Document(source: source, segments: segments)
    }

    /// Copies the untouched original beside itself the moment Cue adopts it.
    /// Waiting for the first edit was not enough: a re-translation unlinks the
    /// file so auto-export may overwrite it, and a user who only imported has
    /// made no edit to trigger a backup. Returns whether a backup now exists —
    /// a failure here is not fatal, and write-back's own backup step remains
    /// the fallback.
    static func backUpOriginal(at url: URL) -> Bool {
        let backupURL = url.appendingPathExtension("bak")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return true }
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            return true
        } catch {
            return false
        }
    }
}
