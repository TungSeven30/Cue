import Foundation

/// Pure export planning plus sidecar writing. UI panels and alerts stay in
/// AppModel, while file naming/document selection live in one testable place.
struct ExportCoordinator {
    struct Document {
        let suffix: String
        let segments: [TranscriptionSegment]
    }

    struct SubtitleWrite {
        let url: URL
        let format: SubtitleExportFormat
        let segments: [TranscriptionSegment]
    }

    struct Plan {
        let subtitleWrites: [SubtitleWrite]
        let logURL: URL?

        var fileCount: Int { subtitleWrites.count + (logURL == nil ? 0 : 1) }
        var urls: [URL] { subtitleWrites.map(\.url) + [logURL].compactMap { $0 } }
    }

    struct SidecarOptions {
        let includeOriginal: Bool
        let includeTranslation: Bool
        let includeBilingual: Bool
        /// Standardized paths that must never be written — the files this job
        /// imported its subtitles from. Rewriting one would replace a user's
        /// file with a summary-prepended copy.
        var protectedPaths: Set<String> = []
    }

    func plan(
        folder: URL,
        baseName: String,
        documents: [Document],
        formats: [SubtitleExportFormat],
        includeLog: Bool,
        summary: String?
    ) -> Plan {
        let normalizedBase = Self.sanitizedBaseName(baseName)
        let useSuffixes = documents.count * formats.count > 1 || includeLog
        var subtitleWrites: [SubtitleWrite] = []
        for document in documents {
            for format in formats.sorted(by: { $0.rawValue < $1.rawValue }) {
                let name =
                    useSuffixes
                    ? "\(normalizedBase).\(document.suffix).\(format.fileExtension)"
                    : "\(normalizedBase).\(format.fileExtension)"
                subtitleWrites.append(
                    SubtitleWrite(
                        url: folder.appendingPathComponent(name),
                        format: format,
                        segments: Self.applyingIntro(document.segments, format: format, summary: summary)
                    )
                )
            }
        }
        return Plan(
            subtitleWrites: subtitleWrites,
            logURL: includeLog ? folder.appendingPathComponent("\(normalizedBase).log.txt") : nil
        )
    }

    func writeSidecars(job: TranscriptionJob, options: SidecarOptions) throws -> [String] {
        let folder = job.sourceURL.deletingLastPathComponent()
        let base = job.sourceURL.deletingPathExtension().lastPathComponent
        var written: [String] = []
        if options.includeOriginal, !job.transcriptSegments.isEmpty {
            let code = Self.sidecarLanguageCode(for: job.settings.sourceLanguage) ?? "original"
            try write(
                job.transcriptSegments,
                named: "\(base).\(code).srt",
                in: folder,
                summary: job.summary,
                protectedPaths: options.protectedPaths,
                into: &written
            )
        }
        if options.includeTranslation, !job.translatedSegments.isEmpty {
            let code =
                Self.sidecarLanguageCode(for: job.settings.translationTargetLanguage)
                ?? Self.languageSuffix(job.settings.translationTargetLanguage)
            try write(
                job.translatedSegments,
                named: "\(base).\(code).srt",
                in: folder,
                summary: job.summary,
                protectedPaths: options.protectedPaths,
                into: &written
            )
        }
        if options.includeBilingual, !job.transcriptSegments.isEmpty, !job.translatedSegments.isEmpty {
            try write(
                Self.bilingualSegments(transcript: job.transcriptSegments, translated: job.translatedSegments),
                named: "\(base).bilingual.srt",
                in: folder,
                summary: job.summary,
                protectedPaths: options.protectedPaths,
                into: &written
            )
        }
        return written
    }

    private func write(
        _ segments: [TranscriptionSegment],
        named name: String,
        in folder: URL,
        summary: String?,
        protectedPaths: Set<String>,
        into written: inout [String]
    ) throws {
        let url = folder.appendingPathComponent(name)
        guard !protectedPaths.contains(url.standardizedFileURL.path) else { return }
        try SubtitleWriter.writeSRT(
            segments: Self.applyingIntro(segments, format: .srt, summary: summary),
            to: url
        )
        written.append(name)
    }

    static func normalizedURL(_ url: URL, expectedExtension: String) -> URL {
        let expected = expectedExtension.lowercased()
        if url.pathExtension.lowercased() == expected { return url }
        let withoutAddedExtension = url.deletingPathExtension()
        if withoutAddedExtension.pathExtension.lowercased() == expected { return withoutAddedExtension }
        return withoutAddedExtension.appendingPathExtension(expectedExtension)
    }

    static func sanitizedBaseName(_ name: String) -> String {
        let cleaned =
            name
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "subtitles" : cleaned
    }

    static func languageSuffix(_ language: String) -> String {
        let normalized =
            language.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return normalized.isEmpty ? "translation" : normalized
    }

    static func sidecarLanguageCode(for language: String) -> String? {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let codes: [String: String] = [
            "english": "en", "japanese": "ja", "chinese": "zh", "korean": "ko",
            "spanish": "es", "french": "fr", "german": "de", "indonesian": "id",
            "thai": "th", "vietnamese": "vi",
        ]
        if normalized.isEmpty || normalized == "auto" { return nil }
        if codes.values.contains(normalized) { return normalized }
        return codes[normalized]
    }

    static func bilingualSegments(
        transcript: [TranscriptionSegment], translated: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        let translatedByID = Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0.text) })
        return transcript.map { source in
            TranscriptionSegment(
                id: source.id, start: source.start, end: source.end,
                text: "\(source.text)\n\(translatedByID[source.id] ?? "")"
            )
        }
    }

    static func applyingIntro(
        _ segments: [TranscriptionSegment], format: SubtitleExportFormat, summary: String?
    ) -> [TranscriptionSegment] {
        guard format == .srt || format == .vtt else { return segments }
        return SubtitleWriter.segmentsPrependingIntro(summary, to: segments)
    }
}
