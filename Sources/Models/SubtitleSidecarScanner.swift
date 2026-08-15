import Foundation

/// Decides which subtitle files sitting beside a media file should be adopted
/// and which slot each belongs in. Pure — it takes a candidate list instead of
/// touching the filesystem, so it is fully testable (same shape as
/// `WatchFolderScanEngine`).
struct SubtitleSidecarScanner {
    enum Slot: String, Codable, Hashable, CaseIterable {
        case transcript
        case translation
    }

    struct Match: Hashable {
        let url: URL
        let slot: Slot
    }

    static let supportedExtensions: Set<String> = ["srt", "vtt"]

    static func match(
        mediaURL: URL,
        candidates: [URL],
        sourceLanguage: String,
        translationTargetLanguage: String
    ) -> [Match] {
        let base = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        var tagged: [(url: URL, tag: String)] = []
        for candidate in candidates {
            guard supportedExtensions.contains(candidate.pathExtension.lowercased()) else { continue }
            let stem = candidate.deletingPathExtension().lastPathComponent.lowercased()
            // Exact `<base>` or `<base>.<tag>` only; no fuzzy matching, or
            // "movie (1).srt" would attach to the wrong video.
            guard stem == base || stem.hasPrefix(base + ".") else { continue }
            let tag = stem == base ? "" : String(stem.dropFirst(base.count + 1))
            guard tag != "bilingual" else { continue }
            tagged.append((candidate, tag))
        }
        guard !tagged.isEmpty else { return [] }

        // A lone file always becomes the transcript, whatever it is tagged.
        // A translation with no transcript is a state the rest of the app
        // cannot represent.
        if tagged.count == 1 {
            return [Match(url: tagged[0].url, slot: .transcript)]
        }

        // The same codes ExportCoordinator writes sidecars with, so a Cue
        // export re-imports into exactly the slots it came from.
        let targetTag =
            ExportCoordinator.sidecarLanguageCode(for: translationTargetLanguage)
            ?? ExportCoordinator.languageSuffix(translationTargetLanguage)
        let sourceTag = ExportCoordinator.sidecarLanguageCode(for: sourceLanguage)

        let translation = tagged.first { $0.tag == targetTag }
        let remaining = tagged.filter { $0.url != translation?.url }
        let sorted = remaining.sorted {
            (rank($0.tag, sourceTag: sourceTag), $0.url.lastPathComponent)
                < (rank($1.tag, sourceTag: sourceTag), $1.url.lastPathComponent)
        }
        guard let transcript = sorted.first else {
            return tagged.first.map { [Match(url: $0.url, slot: .transcript)] } ?? []
        }

        var matches = [Match(url: transcript.url, slot: .transcript)]
        if let translation {
            matches.append(Match(url: translation.url, slot: .translation))
        }
        return matches
    }

    private static func rank(_ tag: String, sourceTag: String?) -> Int {
        if tag.isEmpty { return 0 }
        if tag == "original" { return 1 }
        if let sourceTag, tag == sourceTag { return 2 }
        return 3
    }
}
