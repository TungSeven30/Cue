import Foundation
import Testing

@testable import Cue

struct SubtitleSidecarScannerTests {
    private let media = URL(filePath: "/videos/movie.mp4", directoryHint: .notDirectory)

    private func url(_ name: String) -> URL {
        URL(filePath: "/videos/\(name)", directoryHint: .notDirectory)
    }

    private func match(
        _ names: [String],
        source: String = "auto",
        target: String = "Vietnamese"
    ) -> [SubtitleSidecarScanner.Match] {
        SubtitleSidecarScanner.match(
            mediaURL: media,
            candidates: names.map(url),
            sourceLanguage: source,
            translationTargetLanguage: target
        )
    }

    // A translation with no transcript is a broken state here: bilingual
    // export and canTranslate both require a transcript.
    @Test func loneMatchAlwaysBecomesTheTranscriptWhateverItsTag() {
        let result = match(["movie.vi.srt"])
        #expect(result == [.init(url: url("movie.vi.srt"), slot: .transcript)])
    }

    @Test func routesSourceAndTargetLanguagesToSeparateSlots() {
        let result = match(["movie.ja.srt", "movie.vi.srt"], source: "ja", target: "Vietnamese")
        #expect(result.count == 2)
        #expect(result.first(where: { $0.slot == .transcript })?.url == url("movie.ja.srt"))
        #expect(result.first(where: { $0.slot == .translation })?.url == url("movie.vi.srt"))
    }

    // Bilingual cues interleave translation into every line; adopting one as a
    // transcript would poison both slots.
    @Test func bilingualSidecarIsNeverMatched() {
        let result = match(["movie.bilingual.srt"])
        #expect(result.isEmpty)
    }

    @Test func nearMissBaseNamesAreIgnored() {
        let result = match(["movie2.srt", "movie (1).srt", "other.srt"])
        #expect(result.isEmpty)
    }

    @Test func matchesUppercaseExtension() {
        let result = match(["movie.SRT"])
        #expect(result == [.init(url: url("movie.SRT"), slot: .transcript)])
    }

    // Preference order for the transcript slot: untagged, then "original",
    // then the source language, then anything else.
    @Test func transcriptTieBreakPrefersUntaggedThenOriginal() {
        let result = match(["movie.fr.srt", "movie.original.srt", "movie.srt", "movie.vi.srt"], target: "Vietnamese")
        #expect(result.first(where: { $0.slot == .transcript })?.url == url("movie.srt"))
        #expect(result.first(where: { $0.slot == .translation })?.url == url("movie.vi.srt"))
    }

    @Test func noTranslationSlotWhenNothingMatchesTheTarget() {
        let result = match(["movie.srt", "movie.fr.srt"], target: "Vietnamese")
        #expect(result.count == 1)
        #expect(result[0].slot == .transcript)
        #expect(result[0].url == url("movie.srt"))
    }

    @Test func vttSidecarsAreEligible() {
        let result = match(["movie.vtt"])
        #expect(result == [.init(url: url("movie.vtt"), slot: .transcript)])
    }
}
