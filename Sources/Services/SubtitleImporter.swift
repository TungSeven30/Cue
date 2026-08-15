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

    static func importSidecars(
        mediaURL: URL,
        sourceLanguage: String,
        translationTargetLanguage: String
    ) -> Result {
        let folder = mediaURL.deletingLastPathComponent()
        let candidates =
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )) ?? []

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
        return Result(transcript: transcript, translation: translation, logLines: logLines)
    }

    static func importFile(at url: URL) throws -> Document {
        let segments = try SubtitleReader.parse(contentsOf: url)
        guard let format = SubtitleReader.format(for: url),
            let source = ImportedSubtitleSource(url: url, format: format)
        else {
            throw SubtitleReader.ReadError.unreadable
        }
        return Document(source: source, segments: segments)
    }
}
