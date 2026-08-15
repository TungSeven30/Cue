# Subtitle Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When media is added, adopt any matching SRT/VTT sidecar sitting next to it as the job's transcript (and translation), and allow loading a subtitle file from any folder, so subtitles can be edited or burned in without re-transcribing.

**Architecture:** Four new self-contained units — `SubtitleReader` (parse), `SubtitleSidecarScanner` (route), `SubtitleImporter` (file I/O bridging the two), and provenance fields on `TranscriptionJob` — plus one new `AppModel` section for adoption, write-back sync, and manual loading. Imported subtitles land in the existing `transcriptSegments`/`translatedSegments` arrays, so `BurnInService`, `TranscriptView`, and the export sheet need no changes.

**Tech Stack:** Swift 5.9+, SwiftUI, swift-testing (`import Testing`, `@Test func`, `@testable import Cue`), AppKit (`NSOpenPanel`/`NSAlert`).

**Spec:** `docs/superpowers/specs/2026-08-15-subtitle-import-design.md`

## Global Constraints

- **Run tests with `./script/run_tests.sh`, never `swift test`.** With Command Line Tools only, `swift test` builds tests but silently runs zero of them. `--filter` is silently ignored on CLT-only machines, so **every test run executes the whole suite** — to check one test, run the suite and search the output for the test name.
- Format with `./script/format_swift.sh` before committing; `./script/lint_swift.sh` must pass.
- Coverage floors are enforced by `./script/run_coverage.sh`.
- New fields on `Codable` job types **must** decode with `decodeIfPresent` and a default, matching every other added field in `TranscriptionJob.swift` — job JSON on disk predates them.
- `AppModel` is `@MainActor`. Filesystem scanning and parsing must not run on the main actor; use `nonisolated` static functions awaited from a `Task`.
- Never add a field that affects the transcript to `JobSettingsSnapshot` without also adding it to `TranscriptionIdentity` (see the comment block at `TranscriptionJob.swift:126`). **This feature adds no such field** — provenance describes where a transcript came from, not what would produce it.
- Comments explain *why*, not *what*; match the density of surrounding code.

---

### Task 1: `SubtitleReader` — parse SRT and WebVTT

**Files:**
- Create: `Sources/Services/SubtitleReader.swift`
- Test: `Tests/CueTests/SubtitleReaderTests.swift`

**Interfaces:**
- Consumes: `TranscriptionSegment`, `SubtitleExportFormat`, `SubtitleWriter.sanitizedCueText` (all existing).
- Produces:
  - `SubtitleReader.ReadError` — `.unreadable`, `.unsupportedFormat(String)`, `.noCues`, `.tooLarge(Int)`
  - `SubtitleReader.format(for: URL) -> SubtitleExportFormat?`
  - `SubtitleReader.parse(contentsOf: URL) throws -> [TranscriptionSegment]`
  - `SubtitleReader.parse(_ text: String, format: SubtitleExportFormat) throws -> [TranscriptionSegment]`
  - `SubtitleReader.parseTimestamp(_ token: String) -> Double?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CueTests/SubtitleReaderTests.swift`:

```swift
import Foundation
import Testing

@testable import Cue

struct SubtitleReaderTests {
    @Test func parsesStandardSRT() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,500
            Hello there

            2
            00:00:03,000 --> 00:00:04,000
            Second cue
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.count == 2)
        #expect(segments[0].start == 1.0)
        #expect(segments[0].end == 2.5)
        #expect(segments[0].text == "Hello there")
        #expect(segments[1].id == 2)
    }

    // Cue ids double as the join key for bilingual export and translation
    // reconciliation, so the file's own indices must never be trusted.
    @Test func renumbersDuplicateAndNonMonotonicIndices() throws {
        let srt = """
            7
            00:00:01,000 --> 00:00:02,000
            First

            7
            00:00:02,000 --> 00:00:03,000
            Second

            3
            00:00:03,000 --> 00:00:04,000
            Third
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.map(\.id) == [1, 2, 3])
        #expect(segments.map(\.text) == ["First", "Second", "Third"])
    }

    @Test func acceptsDotSeparatorAndMissingHours() {
        #expect(SubtitleReader.parseTimestamp("00:00:01,500") == 1.5)
        #expect(SubtitleReader.parseTimestamp("00:00:01.500") == 1.5)
        #expect(SubtitleReader.parseTimestamp("01:02.500") == 62.5)
        #expect(SubtitleReader.parseTimestamp("01:01:01,000") == 3661.0)
        #expect(SubtitleReader.parseTimestamp("nonsense") == nil)
    }

    @Test func parsesVTTSkippingHeaderAndNotes() throws {
        let vtt = """
            WEBVTT

            NOTE this is a comment

            cue-1
            00:00:01.000 --> 00:00:02.000 align:start position:10%
            Hello
            """
        let segments = try SubtitleReader.parse(vtt, format: .vtt)
        #expect(segments.count == 1)
        #expect(segments[0].start == 1.0)
        #expect(segments[0].end == 2.0)
        #expect(segments[0].text == "Hello")
    }

    // Real files carry junk tails; one bad block must not lose the file.
    @Test func skipsMalformedBlockAndKeepsTheRest() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,000
            Good

            garbage with no timing at all

            2
            00:00:03,000 --> 00:00:04,000
            Also good
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.map(\.text) == ["Good", "Also good"])
    }

    @Test func arrowInsideCueTextStaysWithTheCue() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,000
            step one --> step two
            """
        let segments = try SubtitleReader.parse(srt, format: .srt)
        #expect(segments.count == 1)
        #expect(segments[0].text == "step one --> step two")
    }

    @Test func emptyFileThrowsNoCues() {
        #expect(throws: SubtitleReader.ReadError.noCues) {
            try SubtitleReader.parse("\n\n", format: .srt)
        }
    }

    @Test func decodesLatin1AndStripsBOM() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nCafé\n"
        let latin1 = try #require(srt.data(using: .windowsCP1252))
        let decoded = try #require(SubtitleReader.decode(latin1))
        #expect(decoded.contains("Café"))

        let withBOM = try #require(("\u{FEFF}" + srt).data(using: .utf8))
        let strippedText = try #require(SubtitleReader.decode(withBOM))
        #expect(strippedText.hasPrefix("1"))
    }

    @Test func rejectsUnsupportedExtension() {
        let url = URL(filePath: "/tmp/subs.ass", directoryHint: .notDirectory)
        #expect(throws: SubtitleReader.ReadError.unsupportedFormat("ass")) {
            try SubtitleReader.parse(contentsOf: url)
        }
    }

    // Guards both sides of the writer/reader pair against future drift, the
    // same tactic the repo uses for the generated Python backend script.
    @Test func roundTripsThroughSubtitleWriter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = [
            TranscriptionSegment(id: 1, start: 0.5, end: 2.25, text: "Hello"),
            TranscriptionSegment(id: 2, start: 3661.0, end: 3662.5, text: "World"),
        ]
        for format in [SubtitleExportFormat.srt, .vtt] {
            let url = dir.appendingPathComponent("round.\(format.fileExtension)")
            try SubtitleWriter.write(segments: original, format: format, to: url)
            let parsed = try SubtitleReader.parse(contentsOf: url)
            #expect(parsed == original, "\(format.label) round trip changed the segments")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/run_tests.sh`
Expected: compile failure — `cannot find 'SubtitleReader' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Services/SubtitleReader.swift`:

```swift
import Foundation

/// Parse-only counterpart to `SubtitleWriter`. Reads SRT and WebVTT into the
/// same `TranscriptionSegment` array every downstream consumer already uses.
enum SubtitleReader {
    enum ReadError: Error, Equatable {
        case unreadable
        case unsupportedFormat(String)
        case noCues
        case tooLarge(Int)
    }

    /// A 20 MB "subtitle" is a mislabeled video; refuse it rather than read it
    /// into memory.
    static let maximumFileSize = 20 * 1024 * 1024

    static func format(for url: URL) -> SubtitleExportFormat? {
        switch url.pathExtension.lowercased() {
        case "srt": return .srt
        case "vtt": return .vtt
        default: return nil
        }
    }

    static func parse(contentsOf url: URL) throws -> [TranscriptionSegment] {
        guard let format = format(for: url) else {
            throw ReadError.unsupportedFormat(url.pathExtension.lowercased())
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maximumFileSize else { throw ReadError.tooLarge(size) }
        guard let data = try? Data(contentsOf: url), let text = decode(data) else {
            throw ReadError.unreadable
        }
        return try parse(text, format: format)
    }

    /// SRT files in the wild are frequently Latin-1, so a UTF-8 failure must
    /// not end the attempt. Order matters: UTF-8 first (the modern default),
    /// then BOM-tagged UTF-16, then Windows-1252 last because it decodes any
    /// byte sequence and would otherwise shadow the others.
    static func decode(_ data: Data) -> String? {
        for encoding: String.Encoding in [.utf8, .utf16, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) {
                return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            }
        }
        return nil
    }

    static func parse(_ text: String, format: SubtitleExportFormat) throws -> [TranscriptionSegment] {
        let normalized =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var segments: [TranscriptionSegment] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let first = lines.first else { continue }
            if format == .vtt, isVTTMetadata(first) { continue }

            // A malformed block is skipped rather than fatal: real files carry
            // junk tails, and losing the whole transcript to one bad cue is
            // the worse failure.
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                let timing = parseTimingLine(lines[timingIndex])
            else { continue }

            let body = lines[lines.index(after: timingIndex)...].joined(separator: "\n")
            let cleaned = SubtitleWriter.sanitizedCueText(body)
            guard !cleaned.isEmpty else { continue }

            // Ids are assigned here, never read from the file: they double as
            // the join key for bilingual export and translation reconciliation,
            // and third-party files routinely repeat or skip indices.
            segments.append(
                TranscriptionSegment(
                    id: segments.count + 1,
                    start: timing.start,
                    end: max(timing.end, timing.start),
                    text: cleaned
                )
            )
        }
        guard !segments.isEmpty else { throw ReadError.noCues }
        return segments
    }

    private static func isVTTMetadata(_ line: String) -> Bool {
        ["WEBVTT", "NOTE", "STYLE", "REGION"].contains { line.hasPrefix($0) }
    }

    struct Timing: Equatable {
        let start: Double
        let end: Double
    }

    static func parseTimingLine(_ line: String) -> Timing? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        // Trailing WebVTT cue settings ("align:start position:10%") and legacy
        // SRT coordinates ("X1:0 X2:100") follow the end timestamp.
        let endToken =
            parts[1]
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .first ?? ""
        guard let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
            let end = parseTimestamp(endToken)
        else { return nil }
        return Timing(start: start, end: end)
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, and `MM:SS.mmm` — WebVTT makes
    /// the hours field optional and several exporters omit it.
    static func parseTimestamp(_ token: String) -> Double? {
        let pieces = token.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard (2...3).contains(pieces.count) else { return nil }
        var seconds = 0.0
        for piece in pieces.dropLast() {
            guard let value = Double(piece) else { return nil }
            seconds = seconds * 60 + value
        }
        guard let last = Double(pieces[pieces.count - 1]) else { return nil }
        return seconds * 60 + last
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./script/format_swift.sh && ./script/run_tests.sh`
Expected: PASS. Search the output for `SubtitleReaderTests` — all 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/SubtitleReader.swift Tests/CueTests/SubtitleReaderTests.swift
git commit -m "Add SubtitleReader for SRT and WebVTT parsing"
```

---

### Task 2: `SubtitleSidecarScanner` — route matches to slots

**Files:**
- Create: `Sources/Models/SubtitleSidecarScanner.swift`
- Test: `Tests/CueTests/SubtitleSidecarScannerTests.swift`

**Interfaces:**
- Consumes: `ExportCoordinator.sidecarLanguageCode(for:)` and `ExportCoordinator.languageSuffix(_:)` (existing statics — the same functions that *name* Cue's sidecars, so an export/re-import round trip is exact).
- Produces:
  - `SubtitleSidecarScanner.Slot` — `.transcript`, `.translation` (`String`-backed, `Codable`, `Hashable`, `CaseIterable`)
  - `SubtitleSidecarScanner.Match` — `let url: URL`, `let slot: Slot`
  - `SubtitleSidecarScanner.supportedExtensions: Set<String>`
  - `SubtitleSidecarScanner.match(mediaURL:candidates:sourceLanguage:translationTargetLanguage:) -> [Match]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CueTests/SubtitleSidecarScannerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/run_tests.sh`
Expected: compile failure — `cannot find 'SubtitleSidecarScanner' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Models/SubtitleSidecarScanner.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./script/format_swift.sh && ./script/run_tests.sh`
Expected: PASS — search output for `SubtitleSidecarScannerTests`, 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/SubtitleSidecarScanner.swift Tests/CueTests/SubtitleSidecarScannerTests.swift
git commit -m "Add SubtitleSidecarScanner for matching subtitles to jobs"
```

---

### Task 3: Provenance on `TranscriptionJob`

**Files:**
- Modify: `Sources/Services/SubtitleWriter.swift:3` (add `Codable` to `SubtitleExportFormat`)
- Modify: `Sources/Models/TranscriptionJob.swift` (new type + two fields + decoder lines)
- Test: `Tests/CueTests/ImportedSubtitleSourceTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `ImportedSubtitleSource` with `var path: String`, `var importedAt: Date`, `var format: SubtitleExportFormat`, `var fileSize: Int`, `var modifiedAt: Date`, `var didBackup: Bool`, `var syncPaused: Bool`, `var lastSyncError: String?`
  - `ImportedSubtitleSource.init?(url: URL, format: SubtitleExportFormat)` — `nil` when file attributes are unreadable
  - `ImportedSubtitleSource.url: URL`, `.fileName: String`, `.matchesFileOnDisk() -> Bool`, `mutating func refreshFileState()`
  - `TranscriptionJob.importedTranscriptSource: ImportedSubtitleSource?`
  - `TranscriptionJob.importedTranslationSource: ImportedSubtitleSource?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CueTests/ImportedSubtitleSourceTests.swift`:

```swift
import Foundation
import Testing

@testable import Cue

struct ImportedSubtitleSourceTests {
    private func makeFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("movie.en.srt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func capturesFileStateAtImport() throws {
        let url = try makeFile("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = try #require(ImportedSubtitleSource(url: url, format: .srt))
        #expect(source.fileName == "movie.en.srt")
        #expect(source.fileSize > 0)
        #expect(source.didBackup == false)
        #expect(source.syncPaused == false)
        #expect(source.matchesFileOnDisk())
    }

    // The guard that makes automatic write-back safe: if the file changed
    // under us, we must not overwrite it.
    @Test func detectsExternalModification() throws {
        let url = try makeFile("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var source = try #require(ImportedSubtitleSource(url: url, format: .srt))
        try Data("1\n00:00:01,000 --> 00:00:02,000\nEdited elsewhere\n".utf8).write(to: url)
        #expect(source.matchesFileOnDisk() == false)

        source.refreshFileState()
        #expect(source.matchesFileOnDisk(), "refreshFileState must re-baseline after our own write")
    }

    @Test func missingFileDoesNotMatch() throws {
        let url = try makeFile("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        let source = try #require(ImportedSubtitleSource(url: url, format: .srt))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        #expect(source.matchesFileOnDisk() == false)
    }

    // Job JSON on disk predates these fields.
    //
    // This uses a bare JSONDecoder (`.deferredToDate`, so the numeric `0`
    // dates are valid) rather than JobStore's `.iso8601` one, which is
    // private. The decoder strategy is irrelevant to what's under test: that
    // the two new keys are optional.
    @Test func legacyJobJSONDecodesWithoutProvenance() throws {
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "sourcePath": "/videos/movie.mp4",
              "createdAt": 0, "updatedAt": 0,
              "status": "idle",
              "progress": {"stage": "idle", "detail": "", "fraction": null},
              "settings": {
                "sourceLanguage": "auto", "whisperModel": "large-v3",
                "whisperBackend": "auto", "openAIModel": "gpt-4o-mini"
              },
              "transcriptSegments": [], "translatedSegments": [],
              "log": ""
            }
            """
        let decoder = JSONDecoder()
        let job = try decoder.decode(TranscriptionJob.self, from: Data(json.utf8))
        #expect(job.importedTranscriptSource == nil)
        #expect(job.importedTranslationSource == nil)
    }

    @Test func provenanceSurvivesEncodeDecode() throws {
        let url = try makeFile("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var source = try #require(ImportedSubtitleSource(url: url, format: .srt))
        source.didBackup = true
        source.lastSyncError = "boom"

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(ImportedSubtitleSource.self, from: data)
        #expect(decoded == source)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/run_tests.sh`
Expected: compile failure — `cannot find 'ImportedSubtitleSource' in scope`.

- [ ] **Step 3: Make `SubtitleExportFormat` Codable**

In `Sources/Services/SubtitleWriter.swift`, change line 3:

```swift
enum SubtitleExportFormat: String, Codable, CaseIterable, Identifiable {
```

- [ ] **Step 4: Add the provenance type and job fields**

In `Sources/Models/TranscriptionJob.swift`, add above `struct TranscriptionJob`:

```swift
/// Where a job's subtitles were imported from, and enough file state to tell
/// whether that file has changed under us since. Automatic write-back depends
/// on this: overwriting a file someone edited elsewhere would destroy their
/// work silently.
struct ImportedSubtitleSource: Codable, Hashable {
    var path: String
    var importedAt: Date
    /// Always `.srt` or `.vtt`; the other export formats are never parsed.
    var format: SubtitleExportFormat
    var fileSize: Int
    var modifiedAt: Date
    /// The one-time `.bak` of the untouched original has been taken.
    var didBackup: Bool
    /// Set when the file changed outside Cue; stops write-back until the user
    /// unlinks or re-imports.
    var syncPaused: Bool
    var lastSyncError: String?

    var url: URL {
        URL(filePath: path, directoryHint: .notDirectory)
    }

    var fileName: String {
        url.lastPathComponent
    }

    init?(url: URL, format: SubtitleExportFormat) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize,
            let modified = values.contentModificationDate
        else { return nil }
        self.path = url.path
        self.importedAt = Date()
        self.format = format
        self.fileSize = size
        self.modifiedAt = modified
        self.didBackup = false
        self.syncPaused = false
        self.lastSyncError = nil
    }

    /// True when the file on disk is byte-count and mtime identical to what we
    /// recorded. A missing file reads as changed.
    func matchesFileOnDisk() -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize,
            let modified = values.contentModificationDate
        else { return false }
        return size == fileSize && abs(modified.timeIntervalSince(modifiedAt)) < 0.001
    }

    /// Re-baselines after Cue itself writes the file, so the next edit does not
    /// mistake our own write for an external one.
    mutating func refreshFileState() {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize,
            let modified = values.contentModificationDate
        else { return }
        fileSize = size
        modifiedAt = modified
    }
}
```

In `struct TranscriptionJob`, add after `var archivedAt: Date?` (line 32):

```swift
    /// Set when the transcript came from a subtitle file rather than a run.
    var importedTranscriptSource: ImportedSubtitleSource?
    var importedTranslationSource: ImportedSubtitleSource?
```

In the `@MainActor init`, after `self.archivedAt = nil`:

```swift
        self.importedTranscriptSource = nil
        self.importedTranslationSource = nil
```

In `init(from decoder:)`, after the `archivedAt` line:

```swift
        importedTranscriptSource = try container.decodeIfPresent(ImportedSubtitleSource.self, forKey: .importedTranscriptSource)
        importedTranslationSource = try container.decodeIfPresent(ImportedSubtitleSource.self, forKey: .importedTranslationSource)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./script/format_swift.sh && ./script/run_tests.sh`
Expected: PASS — `ImportedSubtitleSourceTests`, 5 tests. The full suite must stay green; `JobStoreTests` exercises the same decoder.

- [ ] **Step 6: Commit**

```bash
git add Sources/Models/TranscriptionJob.swift Sources/Services/SubtitleWriter.swift Tests/CueTests/ImportedSubtitleSourceTests.swift
git commit -m "Track where imported subtitles came from on the job"
```

---

### Task 4: `SubtitleImporter` — scan a folder, parse, build documents

**Files:**
- Create: `Sources/Services/SubtitleImporter.swift`
- Test: `Tests/CueTests/SubtitleImporterTests.swift`

This is the only unit that touches the filesystem for import. It exists so `AppModel` gains a call, not sixty lines of I/O, and so the whole scan/parse path can be tested without an `AppModel`.

**Interfaces:**
- Consumes: `SubtitleReader`, `SubtitleSidecarScanner`, `ImportedSubtitleSource`.
- Produces:
  - `SubtitleImporter.Document` — `let source: ImportedSubtitleSource`, `let segments: [TranscriptionSegment]`
  - `SubtitleImporter.Result` — `let transcript: Document?`, `let translation: Document?`, `let logLines: [String]`
  - `static func importSidecars(mediaURL:sourceLanguage:translationTargetLanguage:) -> Result`
  - `static func importFile(at url: URL) throws -> Document`

Both statics are `nonisolated` by virtue of being on a plain `enum`, so `AppModel` can `await` them off the main actor.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CueTests/SubtitleImporterTests.swift`:

```swift
import Foundation
import Testing

@testable import Cue

struct SubtitleImporterTests {
    private let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Hello

        2
        00:00:03,000 --> 00:00:04,000
        World
        """

    private func makeFolder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-importer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: dir.appendingPathComponent("movie.mp4"))
        for name in names {
            try Data(srt.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test func importsBothSlotsFromRealFiles() throws {
        let dir = try makeFolder(["movie.ja.srt", "movie.vi.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = SubtitleImporter.importSidecars(
            mediaURL: dir.appendingPathComponent("movie.mp4"),
            sourceLanguage: "ja",
            translationTargetLanguage: "Vietnamese"
        )
        #expect(result.transcript?.source.fileName == "movie.ja.srt")
        #expect(result.transcript?.segments.count == 2)
        #expect(result.translation?.source.fileName == "movie.vi.srt")
        #expect(result.logLines.count == 2)
        #expect(result.logLines.allSatisfy { $0.contains("2 cues") })
    }

    @Test func noSidecarsYieldsEmptyResult() throws {
        let dir = try makeFolder([])
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = SubtitleImporter.importSidecars(
            mediaURL: dir.appendingPathComponent("movie.mp4"),
            sourceLanguage: "auto",
            translationTargetLanguage: "Vietnamese"
        )
        #expect(result.transcript == nil)
        #expect(result.translation == nil)
        #expect(result.logLines.isEmpty)
    }

    // A batch add cannot raise dialogs, so an unreadable sidecar is reported
    // in the job log and otherwise ignored.
    @Test func unparseableSidecarIsLoggedNotThrown() throws {
        let dir = try makeFolder([])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a subtitle at all".utf8).write(to: dir.appendingPathComponent("movie.srt"))

        let result = SubtitleImporter.importSidecars(
            mediaURL: dir.appendingPathComponent("movie.mp4"),
            sourceLanguage: "auto",
            translationTargetLanguage: "Vietnamese"
        )
        #expect(result.transcript == nil)
        #expect(result.logLines.count == 1)
        #expect(result.logLines[0].contains("Could not read"))
    }

    @Test func importFileParsesAnyFolder() throws {
        let dir = try makeFolder(["elsewhere.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = try SubtitleImporter.importFile(at: dir.appendingPathComponent("elsewhere.srt"))
        #expect(document.segments.count == 2)
        #expect(document.source.format == .srt)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/run_tests.sh`
Expected: compile failure — `cannot find 'SubtitleImporter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Services/SubtitleImporter.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./script/format_swift.sh && ./script/run_tests.sh`
Expected: PASS — `SubtitleImporterTests`, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/SubtitleImporter.swift Tests/CueTests/SubtitleImporterTests.swift
git commit -m "Add SubtitleImporter to read sidecars off the main actor"
```

---

### Task 5: Adopt sidecars when media is added

**Files:**
- Modify: `Sources/Stores/AppModel.swift` — new stored property; `jobViews` (line ~881); `jobNeedsWork` (line ~713); `addVideos(urls:)` (line ~469); `ingestWatchFolderFiles(_:folderID:)` (line ~1050); new `// MARK: - Subtitle import` section
- Test: `Tests/CueTests/AppModelSubtitleImportTests.swift`

**Interfaces:**
- Consumes: `SubtitleImporter.Result`, `SubtitleSidecarScanner.Slot`, `ImportedSubtitleSource`.
- Produces:
  - `AppModel.adoptSidecars(for ids: [UUID])` (private)
  - `AppModel.isScanningForSubtitles(_ id: UUID) -> Bool` (internal — the tests and the chip use it)

- [ ] **Step 1: Write the failing tests**

Create `Tests/CueTests/AppModelSubtitleImportTests.swift`:

```swift
import Foundation
import Testing

@testable import Cue

private actor EmptyImportDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

@MainActor
struct AppModelSubtitleImportTests {
    struct Fixture {
        let model: AppModel
        let baseURL: URL
        let suiteName: String

        var mediaURL: URL { baseURL.appendingPathComponent("movie.mp4") }

        func cleanUp() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    static let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Hello

        2
        00:00:03,000 --> 00:00:04,000
        World
        """

    func makeFixture(sidecars: [String], autoStart: Bool = false) throws -> Fixture {
        let suiteName = "app-model-import-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: baseURL.appendingPathComponent("movie.mp4"))
        for name in sidecars {
            try Data(Self.srt.utf8).write(to: baseURL.appendingPathComponent(name))
        }
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = autoStart
        settings.sourceLanguage = "ja"
        settings.translationTargetLanguage = "Vietnamese"
        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: baseURL),
            diagnosticsService: EmptyImportDiagnostics()
        )
        return Fixture(model: model, baseURL: baseURL, suiteName: suiteName)
    }

    /// Adoption runs in a detached Task; give it a moment to land.
    private func waitForAdoption(_ model: AppModel, jobID: UUID) async throws {
        for _ in 0..<100 {
            if !model.isScanningForSubtitles(jobID) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Sidecar scan never finished")
    }

    @Test func adoptsSidecarIntoTranscriptSlot() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.count == 2)
        #expect(job.status == .transcriptionComplete)
        #expect(job.importedTranscriptSource?.fileName == "movie.ja.srt")
        // Nothing was transcribed, so no transcription clock was ever started.
        #expect(job.transcriptionFinishedAt == nil)
        #expect(job.log.contains("Loaded subtitles from movie.ja.srt (2 cues)."))
    }

    @Test func adoptsBothSlotsWhenSourceAndTargetSidecarsExist() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt", "movie.vi.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.count == 2)
        #expect(job.translatedSegments.count == 2)
        #expect(job.importedTranslationSource?.fileName == "movie.vi.srt")
    }

    @Test func jobWithNoSidecarIsUntouched() async throws {
        let fixture = try makeFixture(sidecars: [])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.isEmpty)
        #expect(job.status == .idle)
        #expect(job.importedTranscriptSource == nil)
    }

    // PipelineScheduler only picks .queued jobs, for both slots. Clearing the
    // queued status on adoption would drop the job out of the queue and it
    // would never translate.
    @Test func adoptedJobStaysQueuedSoItCanTranslate() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"], autoStart: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.settings.openAIAPIKey = "test-key"
        #expect(model.settings.isTranslationReady, "Fixture must have a usable translation provider")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.count == 2)
        #expect(job.status == .queued, "An adopted job must stay queued to reach the translation slot")
    }

    // Both slots filled means no work is left, so the job leaves the queue
    // rather than waiting to be re-translated.
    @Test func adoptingBothSlotsLeavesTheQueue() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt", "movie.vi.srt"], autoStart: true)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        #expect(model.jobs.first?.status == .translationComplete)
    }

    // The race the pending set exists to close: pumpGPU schedules through
    // jobViews, not jobNeedsWork, so auto-start could otherwise begin ASR
    // before adoption lands.
    @Test func pendingScanKeepsTheJobOutOfScheduling() throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"], autoStart: true)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let job = try #require(model.jobs.first)
        #expect(model.isScanningForSubtitles(job.id))
        #expect(model.jobNeedsWork(job) == false)
        #expect(model.isRunningTranscription == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/run_tests.sh`
Expected: compile failure — `value of type 'AppModel' has no member 'isScanningForSubtitles'`.

- [ ] **Step 3: Add the pending set and gate scheduling on it**

In `Sources/Stores/AppModel.swift`, add near the other private state (beside `volumeRetryScheduled`, ~line 37):

```swift
    /// Jobs whose folder is still being scanned for subtitle sidecars. They
    /// must not be scheduled: an adopted transcript would arrive after ASR had
    /// already started. In-memory only — a scan interrupted by a quit simply
    /// never adopts, which is safe.
    private var subtitleScanPendingIDs: Set<UUID> = []
```

Add the accessor next to `isJobActive` (~line 242):

```swift
    func isScanningForSubtitles(_ id: UUID) -> Bool {
        subtitleScanPendingIDs.contains(id)
    }
```

In `jobNeedsWork` (~line 713), insert as the second line, right after the `archivedAt` check:

```swift
        if subtitleScanPendingIDs.contains(job.id) { return false }
```

In `jobViews` (~line 881), extend the filter — this is the one that actually gates `pumpGPU`/`pumpTranslation`:

```swift
        return jobs.filter { $0.archivedAt == nil && !subtitleScanPendingIDs.contains($0.id) }.map {
```

- [ ] **Step 4: Add the adoption section**

In `Sources/Stores/AppModel.swift`, add a new section immediately before `// MARK: - Sidecar auto-export` (~line 1774):

```swift
    // MARK: - Subtitle import

    /// Scans each job's folder for subtitle sidecars and adopts what it finds.
    /// Jobs are already in the sidebar by now; scanning and parsing happen off
    /// the main actor so a large batch add stays responsive.
    private func adoptSidecars(for ids: [UUID]) {
        let requests: [(id: UUID, url: URL, source: String, target: String)] = ids.compactMap { id in
            guard let job = jobs.first(where: { $0.id == id }) else { return nil }
            let resolved = job.settings.applying(job.overrides)
            return (id, job.sourceURL, resolved.sourceLanguage, resolved.translationTargetLanguage)
        }
        guard !requests.isEmpty else { return }
        subtitleScanPendingIDs.formUnion(requests.map(\.id))

        Task { [weak self] in
            var results: [(id: UUID, result: SubtitleImporter.Result)] = []
            for request in requests {
                // SubtitleImporter is nonisolated, so this hops off the main
                // actor for the directory listing and the parse.
                let result = await Task.detached {
                    SubtitleImporter.importSidecars(
                        mediaURL: request.url,
                        sourceLanguage: request.source,
                        translationTargetLanguage: request.target
                    )
                }.value
                results.append((request.id, result))
            }
            guard let self else { return }
            self.applyAdoptions(results)
        }
    }

    private func applyAdoptions(_ results: [(id: UUID, result: SubtitleImporter.Result)]) {
        for (id, result) in results {
            subtitleScanPendingIDs.remove(id)
            guard result.transcript != nil || result.translation != nil || !result.logLines.isEmpty else { continue }
            let translationReady = settings.isTranslationReady
            updateJob(id) { job in
                for line in result.logLines {
                    job.log += line + "\n"
                }
                // A job auto-started or ingested by a watch folder is .queued.
                // PipelineScheduler only ever picks .queued jobs (both slots),
                // so clearing that status here would drop the job out of the
                // queue and it would never translate. Adopting a transcript
                // just moves it from the GPU slot's filter to the translation
                // slot's — hasTranscript is now true.
                let wasQueued = job.status == .queued
                if let transcript = result.transcript {
                    job.transcriptSegments = transcript.segments
                    job.importedTranscriptSource = transcript.source
                    // Nothing ran, so the transcription clock stays unset.
                    job.progress = JobProgress(stage: .complete, detail: "Loaded existing subtitles.", fraction: 1)
                    job.status = wasQueued && translationReady ? .queued : .transcriptionComplete
                }
                if let translation = result.translation {
                    job.translatedSegments = translation.segments
                    job.importedTranslationSource = translation.source
                    // Both slots filled: there is no work left, so leave the
                    // queue rather than sit there waiting to be re-translated.
                    job.status = .translationComplete
                }
            }
        }
        processQueue()
    }
```

- [ ] **Step 5: Call it from both add paths**

In `addVideos(urls:)`, replace the tail of the function (from `jobs.insert` onward) with:

```swift
        jobs.insert(contentsOf: newJobs, at: 0)
        selectJob(newJobs.first?.id)
        jobRepository.save(newJobs)
        // Adoption gates scheduling via subtitleScanPendingIDs, so processQueue
        // is safe to call now: pending jobs are filtered out of jobViews and
        // picked up when the scan lands.
        adoptSidecars(for: newJobs.map(\.id))
        if shouldStart {
            processQueue()
        }
```

In `ingestWatchFolderFiles(_:folderID:)`, collect the ids and adopt before `processQueue()`:

```swift
        var addedIDs: [UUID] = []
        for url in urls {
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.origin = .watchFolder
            job.overrides = profile
            job.orderIndex = QueueOrdering.indexForWatchAdd(existing: jobs.map(\.orderIndex))
            job.status = .queued
            job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
            job.log = "Picked up from the watch folder: \(url.path(percentEncoded: false)).\n"
            jobs.append(job)
            addedIDs.append(job.id)
            persistJob(job.id)
        }
        adoptSidecars(for: addedIDs)
        processQueue()
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./script/format_swift.sh && ./script/run_tests.sh`
Expected: PASS — `AppModelSubtitleImportTests`, 6 tests. `WatchFolderCoordinatorTests` and `PipelineCoordinatorTests` must stay green.

- [ ] **Step 7: Commit**

```bash
git add Sources/Stores/AppModel.swift Tests/CueTests/AppModelSubtitleImportTests.swift
git commit -m "Adopt existing subtitle sidecars when media is added"
```

---

### Task 6: Force real ASR on an imported job

**Files:**
- Modify: `Sources/Stores/AppModel.swift:1190-1216` (skip branch) and `:1220` (translation reset)
- Test: `Tests/CueTests/AppModelSubtitleImportTests.swift` (append)

An imported transcript satisfies all three conditions of the skip-if-unchanged branch by accident — its settings snapshot describes globals at add time, not anything that produced those subtitles. Pressing Transcribe must mean *actually run ASR*.

**Interfaces:**
- Consumes: `TranscriptionJob.importedTranscriptSource` / `.importedTranslationSource` (Task 3).
- Produces: no new API.

- [ ] **Step 1: Write the failing tests**

Append to `AppModelSubtitleImportTests`:

```swift
    // The skip-if-unchanged branch would otherwise treat imported subtitles as
    // "already transcribed with these settings", which they never were.
    @Test func transcribeOnImportedJobDoesNotTakeTheSkipPath() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)
        #expect(model.jobs.first?.importedTranscriptSource != nil)

        model.startTranscription(jobID: jobID)

        let job = try #require(model.jobs.first)
        #expect(job.status != .transcriptionComplete, "Skip path was taken for an imported transcript")
        #expect(job.log.contains("Skipped transcription") == false)
        // A real run clears provenance for both slots: the old files no longer
        // describe this job's contents.
        #expect(job.importedTranscriptSource == nil)
        #expect(job.importedTranslationSource == nil)

        model.cancelActiveJob()
    }

    @Test func realRunClearsImportedTranslationProvenance() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt", "movie.vi.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)
        #expect(model.jobs.first?.importedTranslationSource != nil)

        model.startTranscription(jobID: jobID)

        #expect(model.jobs.first?.translatedSegments.isEmpty == true)
        #expect(model.jobs.first?.importedTranslationSource == nil)

        model.cancelActiveJob()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/run_tests.sh`
Expected: FAIL — `Skip path was taken for an imported transcript`.

- [ ] **Step 3: Bypass the skip branch and clear provenance**

In `startTranscriptionNow(at:force:)`, extend the skip condition at line 1190:

```swift
        // An imported transcript satisfies the checks below by accident: its
        // settings snapshot describes the globals at add time, not a run that
        // produced these subtitles. Pressing Transcribe on one means "actually
        // run ASR".
        if !force,
            jobs[index].importedTranscriptSource == nil,
            !jobs[index].transcriptSegments.isEmpty,
            jobs[index].sourceFingerprint == currentFingerprint,
            jobs[index].settings.transcriptionIdentity == resolved.transcriptionIdentity
        {
```

In the real-run block, beside the existing resets at line 1220:

```swift
        jobs[index].translatedSegments = []
        jobs[index].partialTranslatedSegments = []
        jobs[index].partialTranscriptSegments = []
        // The imported files no longer describe this job's contents, so write-
        // back must stop pointing at them.
        jobs[index].importedTranscriptSource = nil
        jobs[index].importedTranslationSource = nil
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./script/format_swift.sh && ./script/run_tests.sh`
Expected: PASS — 8 tests in `AppModelSubtitleImportTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Stores/AppModel.swift Tests/CueTests/AppModelSubtitleImportTests.swift
git commit -m "Run real transcription when a job's transcript was imported"
```

---

### Task 7: Stop sidecar auto-export from overwriting an imported file

**Files:**
- Modify: `Sources/Services/ExportCoordinator.swift:25-29` (`SidecarOptions`) and `:63-100` (`writeSidecars`)
- Modify: `Sources/Stores/AppModel.swift:1778-1804` (`autoExportSidecars`)
- Test: `Tests/CueTests/ExportCoordinatorTests.swift` (append)

Without this, a finished translation rewrites the imported file **with the intro summary prepended** — silently modifying a user's file.

**Interfaces:**
- Consumes: `TranscriptionJob.importedTranscriptSource` / `.importedTranslationSource`.
- Produces: `ExportCoordinator.SidecarOptions` gains `let protectedPaths: Set<String>` (standardized file paths that must never be written).

- [ ] **Step 1: Write the failing test**

Append to `ExportCoordinatorTests`:

```swift
    // Auto-export would otherwise rewrite the very file we imported, and not
    // byte-identically: applyingIntro prepends the summary cue.
    //
    // @MainActor because TranscriptionJob's designated init is main-actor
    // isolated (it reads AppSettingsStore); the rest of this suite is not.
    @MainActor @Test func sidecarExportSkipsProtectedImportedPaths() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-protected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mediaURL = dir.appendingPathComponent("movie.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let protectedURL = dir.appendingPathComponent("movie.en.srt")
        let originalContents = "untouched"
        try Data(originalContents.utf8).write(to: protectedURL)

        let suiteName = "cue-protected-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })

        var job = TranscriptionJob(sourceURL: mediaURL, settings: settings)
        job.settings.sourceLanguage = "en"
        job.settings.translationTargetLanguage = "Vietnamese"
        job.transcriptSegments = segments
        job.translatedSegments = segments

        let written = try ExportCoordinator().writeSidecars(
            job: job,
            options: .init(
                includeOriginal: true,
                includeTranslation: true,
                includeBilingual: false,
                protectedPaths: [protectedURL.standardizedFileURL.path]
            )
        )

        #expect(written == ["movie.vi.srt"], "The protected path must not be rewritten")
        #expect(try String(contentsOf: protectedURL, encoding: .utf8) == originalContents)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./script/run_tests.sh`
Expected: compile failure — `extra argument 'protectedPaths' in call`.

- [ ] **Step 3: Add the guard to `ExportCoordinator`**

In `Sources/Services/ExportCoordinator.swift`, extend `SidecarOptions`:

```swift
    struct SidecarOptions {
        let includeOriginal: Bool
        let includeTranslation: Bool
        let includeBilingual: Bool
        /// Standardized paths that must never be written — the files this job
        /// imported its subtitles from. Rewriting one would replace a user's
        /// file with a summary-prepended copy.
        var protectedPaths: Set<String> = []
    }
```

In `writeSidecars`, route every write through one helper. Replace the three `try SubtitleWriter.writeSRT(...)` calls with `try write(...)` and add the helper at the end of the struct:

```swift
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
```

Each call site becomes, for example:

```swift
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
```

- [ ] **Step 4: Pass the imported paths from `AppModel`**

In `autoExportSidecars(for:)`, build the set before the call:

```swift
        let protectedPaths = Set(
            [job.importedTranscriptSource, job.importedTranslationSource]
                .compactMap { $0?.url.standardizedFileURL.path }
        )
```

and add `protectedPaths: protectedPaths` to the `ExportCoordinator.SidecarOptions(...)` initializer.

- [ ] **Step 5: Run tests to verify they pass**

Run: `./script/format_swift.sh && ./script/run_tests.sh`
Expected: PASS — `ExportCoordinatorTests` including the new test.

- [ ] **Step 6: Commit**

```bash
git add Sources/Services/ExportCoordinator.swift Sources/Stores/AppModel.swift Tests/CueTests/ExportCoordinatorTests.swift
git commit -m "Never let sidecar export overwrite an imported subtitle file"
```

---

### Task 8: Write edits back to the imported file

**Files:**
- Modify: `Sources/Stores/AppModel.swift` — `updateSegment` (~line 2158), `flushPendingWork` (~line 175), `selectJob` (~line 379), the `// MARK: - Subtitle import` section
- Test: `Tests/CueTests/AppModelSubtitleImportTests.swift` (append)

**Interfaces:**
- Consumes: `ImportedSubtitleSource.matchesFileOnDisk()`, `.refreshFileState()`, `SubtitleWriter.write(segments:format:to:)`.
- Produces:
  - `AppModel.flushSubtitleSync()` — internal, drains pending debounced writes
  - `AppModel.unlinkImportedSubtitles(slot: SubtitleSidecarScanner.Slot, jobID: UUID?)` — used by Task 10's chip

- [ ] **Step 1: Write the failing tests**

Append to `AppModelSubtitleImportTests`:

```swift
    @Test func editsAreWrittenBackToTheImportedFile() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let segment = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(segment, text: "Edited text")
        model.flushSubtitleSync()

        let contents = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(contents.contains("Edited text"))
        #expect(contents.contains("Hello") == false)
    }

    @Test func firstWriteBacksUpTheOriginalExactlyOnce() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let backupURL = fixture.baseURL.appendingPathComponent("movie.ja.srt.bak")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let first = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(first, text: "One")
        model.flushSubtitleSync()
        let afterFirst = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(afterFirst.contains("Hello"), "The backup must hold the untouched original")

        let second = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(second, text: "Two")
        model.flushSubtitleSync()
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == afterFirst, "Backup was taken twice")
    }

    // The safeguard that makes automatic write-back defensible: an edit made
    // elsewhere must never be silently destroyed.
    @Test func externalChangePausesSyncInsteadOfOverwriting() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let external = "1\n00:00:01,000 --> 00:00:02,000\nChanged by another app\n"
        try Data(external.utf8).write(to: sidecarURL)

        let segment = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(segment, text: "Cue edit")
        model.flushSubtitleSync()

        #expect(try String(contentsOf: sidecarURL, encoding: .utf8) == external)
        #expect(model.jobs.first?.importedTranscriptSource?.syncPaused == true)
        #expect(model.jobs.first?.log.contains("changed outside Cue") == true)
    }

    @Test func manyEditsCoalesceIntoOneWrite() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        for text in ["a", "b", "c", "d"] {
            let segment = try #require(model.jobs.first?.transcriptSegments.first)
            model.updateTranscriptSegment(segment, text: text)
        }
        // Nothing on disk yet: the debounce has not fired.
        #expect(try String(contentsOf: sidecarURL, encoding: .utf8).contains("Hello"))

        model.flushSubtitleSync()
        #expect(try String(contentsOf: sidecarURL, encoding: .utf8).contains("d"))
    }

    @Test func unlinkStopsWriteBack() async throws {
        let fixture = try makeFixture(sidecars: ["movie.ja.srt"])
        defer { fixture.cleanUp() }
        let model = fixture.model
        let sidecarURL = fixture.baseURL.appendingPathComponent("movie.ja.srt")

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        model.unlinkImportedSubtitles(slot: .transcript, jobID: jobID)
        #expect(model.jobs.first?.importedTranscriptSource == nil)

        let segment = try #require(model.jobs.first?.transcriptSegments.first)
        model.updateTranscriptSegment(segment, text: "Should not reach disk")
        model.flushSubtitleSync()

        #expect(try String(contentsOf: sidecarURL, encoding: .utf8).contains("Hello"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/run_tests.sh`
Expected: compile failure — `value of type 'AppModel' has no member 'flushSubtitleSync'`.

- [ ] **Step 3: Add the sync machinery**

In the `// MARK: - Subtitle import` section of `Sources/Stores/AppModel.swift`, append:

```swift
    private struct SubtitleSyncKey: Hashable {
        let jobID: UUID
        let slot: SubtitleSidecarScanner.Slot
    }

    /// Edits are written back on a debounce so a Replace All firing hundreds of
    /// edits produces one write, not hundreds.
    private static let subtitleSyncDebounce: TimeInterval = 1.5

    private func scheduleSubtitleSync(jobID: UUID, slot: SubtitleSidecarScanner.Slot) {
        let key = SubtitleSyncKey(jobID: jobID, slot: slot)
        subtitleSyncWorkItems[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.subtitleSyncWorkItems[key] = nil
            self?.writeBackImportedSubtitles(jobID: jobID, slot: slot)
        }
        subtitleSyncWorkItems[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.subtitleSyncDebounce, execute: item)
    }

    /// Runs every pending write immediately. Called on quit and when the
    /// selection moves off a job.
    func flushSubtitleSync() {
        let pending = subtitleSyncWorkItems
        subtitleSyncWorkItems.removeAll()
        for (key, item) in pending {
            item.cancel()
            writeBackImportedSubtitles(jobID: key.jobID, slot: key.slot)
        }
    }

    func unlinkImportedSubtitles(slot: SubtitleSidecarScanner.Slot, jobID: UUID? = nil) {
        guard let id = jobID ?? selectedJobID else { return }
        subtitleSyncWorkItems[SubtitleSyncKey(jobID: id, slot: slot)]?.cancel()
        subtitleSyncWorkItems[SubtitleSyncKey(jobID: id, slot: slot)] = nil
        updateJob(id) { job in
            let name = job.importedSource(for: slot)?.fileName
            job.setImportedSource(nil, for: slot)
            if let name {
                job.log += "Stopped syncing edits to \(name).\n"
            }
        }
    }

    private func writeBackImportedSubtitles(jobID: UUID, slot: SubtitleSidecarScanner.Slot) {
        guard let job = jobs.first(where: { $0.id == jobID }),
            var source = job.importedSource(for: slot),
            !source.syncPaused
        else { return }

        let segments = slot == .transcript ? job.transcriptSegments : job.translatedSegments
        guard !segments.isEmpty else { return }

        // If the file changed under us, the user's other edits win. Pausing is
        // recoverable; overwriting is not.
        guard source.matchesFileOnDisk() else {
            source.syncPaused = true
            updateJob(jobID) { job in
                job.setImportedSource(source, for: slot)
                job.log += "\(source.fileName) changed outside Cue; sync paused.\n"
            }
            return
        }

        do {
            if !source.didBackup {
                let backupURL = source.url.appendingPathExtension("bak")
                if !FileManager.default.fileExists(atPath: backupURL.path) {
                    try FileManager.default.copyItem(at: source.url, to: backupURL)
                }
                source.didBackup = true
            }
            // Written without the intro summary: applyingIntro is export-only,
            // so the file mirrors exactly what the editor shows.
            try SubtitleWriter.write(segments: segments, format: source.format, to: source.url)
            // Re-baseline, or our own write looks like an external change next
            // time round.
            source.refreshFileState()
            source.lastSyncError = nil
            updateJob(jobID, debouncePersist: true) { job in
                job.setImportedSource(source, for: slot)
            }
        } catch {
            source.lastSyncError = error.localizedDescription
            updateJob(jobID) { job in
                job.setImportedSource(source, for: slot)
                job.log += "Could not update \(source.fileName): \(error.localizedDescription)\n"
            }
        }
    }
```

Add the work-item store beside `subtitleScanPendingIDs`:

```swift
    private var subtitleSyncWorkItems: [SubtitleSyncKey: DispatchWorkItem] = [:]
```

- [ ] **Step 4: Add the slot accessors to `TranscriptionJob`**

In `Sources/Models/TranscriptionJob.swift`, add inside `struct TranscriptionJob`:

```swift
    func importedSource(for slot: SubtitleSidecarScanner.Slot) -> ImportedSubtitleSource? {
        slot == .transcript ? importedTranscriptSource : importedTranslationSource
    }

    mutating func setImportedSource(_ source: ImportedSubtitleSource?, for slot: SubtitleSidecarScanner.Slot) {
        switch slot {
        case .transcript: importedTranscriptSource = source
        case .translation: importedTranslationSource = source
        }
    }
```

- [ ] **Step 5: Trigger sync from edits, and flush at the right moments**

In `updateSegment(_:text:keyPath:)` (~line 2158), append after the `updateJob` call:

```swift
        let slot: SubtitleSidecarScanner.Slot = keyPath == \TranscriptionJob.transcriptSegments ? .transcript : .translation
        if jobs.first(where: { $0.id == id })?.importedSource(for: slot) != nil {
            scheduleSubtitleSync(jobID: id, slot: slot)
        }
```

In `flushPendingWork()` (~line 175), add before `jobRepository.flush()`:

```swift
        flushSubtitleSync()
```

In `selectJob(_:)` (~line 379), add as the first line:

```swift
        flushSubtitleSync()
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./script/format_swift.sh && ./script/run_tests.sh`
Expected: PASS — 13 tests in `AppModelSubtitleImportTests`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Stores/AppModel.swift Sources/Models/TranscriptionJob.swift Tests/CueTests/AppModelSubtitleImportTests.swift
git commit -m "Sync subtitle edits back to the imported file"
```

---

### Task 9: Load a subtitle from any folder

**Files:**
- Create: `Sources/Views/SubtitleSlotPickerView.swift`
- Modify: `Sources/Stores/AppModel.swift` (`// MARK: - Subtitle import` section)
- Modify: `Sources/App/CueApp.swift:39-79` (File menu commands)
- Modify: `Sources/Views/DetailView.swift:210-240` (empty-state actions) and the sheet host
- Test: `Tests/CueTests/AppModelSubtitleImportTests.swift` (append)

**Interfaces:**
- Consumes: `SubtitleImporter.importFile(at:)`.
- Produces:
  - `AppModel.SubtitleLoadRequest` — `let id: UUID`, `let document: SubtitleImporter.Document`
  - `AppModel.subtitleLoadRequest: SubtitleLoadRequest?` (`@Published`, drives the sheet)
  - `AppModel.presentSubtitleLoadPanel()`
  - `AppModel.applySubtitleLoad(_ request: SubtitleLoadRequest, to slot: SubtitleSidecarScanner.Slot)`
  - `AppModel.canLoadSubtitles: Bool`, `AppModel.canLoadTranslationSubtitles: Bool`

- [ ] **Step 1: Write the failing tests**

Append to `AppModelSubtitleImportTests`:

```swift
    @Test func manualLoadFillsTheChosenSlotAndSetsProvenance() async throws {
        let fixture = try makeFixture(sidecars: [])
        defer { fixture.cleanUp() }
        let model = fixture.model

        let elsewhere = fixture.baseURL.appendingPathComponent("elsewhere.srt")
        try Data(Self.srt.utf8).write(to: elsewhere)

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        let document = try SubtitleImporter.importFile(at: elsewhere)
        model.applySubtitleLoad(.init(id: UUID(), document: document), to: .transcript)

        let job = try #require(model.jobs.first)
        #expect(job.transcriptSegments.count == 2)
        #expect(job.status == .transcriptionComplete)
        #expect(job.importedTranscriptSource?.fileName == "elsewhere.srt")
        #expect(job.log.contains("Loaded subtitles from elsewhere.srt (2 cues)."))
    }

    // Translation without a transcript is a state the rest of the app cannot
    // represent, so the picker must not offer it.
    @Test func translationSlotIsUnavailableWithoutATranscript() async throws {
        let fixture = try makeFixture(sidecars: [])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.addVideos(urls: [fixture.mediaURL])
        let jobID = try #require(model.jobs.first?.id)
        try await waitForAdoption(model, jobID: jobID)

        #expect(model.canLoadSubtitles)
        #expect(model.canLoadTranslationSubtitles == false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/run_tests.sh`
Expected: compile failure — `value of type 'AppModel' has no member 'applySubtitleLoad'`.

- [ ] **Step 3: Add the AppModel API**

Add the published property beside the other sheet flags (~line 23):

```swift
    /// Set when a subtitle file has been parsed and needs a slot chosen.
    @Published var subtitleLoadRequest: SubtitleLoadRequest?
```

Append to the `// MARK: - Subtitle import` section:

```swift
    struct SubtitleLoadRequest: Identifiable {
        let id: UUID
        let document: SubtitleImporter.Document
    }

    var canLoadSubtitles: Bool {
        currentJob != nil && !isSelectedJobRunning
    }

    /// A translation with no transcript is a state the rest of the app cannot
    /// represent — bilingual export and canTranslate both require one.
    var canLoadTranslationSubtitles: Bool {
        canLoadSubtitles && !transcriptSegments.isEmpty
    }

    func presentSubtitleLoadPanel() {
        guard canLoadSubtitles else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleSidecarScanner.supportedExtensions.compactMap {
            UTType(filenameExtension: $0, conformingTo: .plainText)
        }
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose an SRT or WebVTT subtitle file."
        panel.directoryURL = selectedVideoURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // Unlike auto-detect, this was an explicit request, so a failure
            // gets a dialog rather than a quiet log line.
            let document = try SubtitleImporter.importFile(at: url)
            subtitleLoadRequest = SubtitleLoadRequest(id: UUID(), document: document)
        } catch {
            presentExportError("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func applySubtitleLoad(_ request: SubtitleLoadRequest, to slot: SubtitleSidecarScanner.Slot) {
        guard let id = selectedJobID, let job = jobs.first(where: { $0.id == id }) else { return }
        let existing = slot == .transcript ? job.transcriptSegments : job.translatedSegments
        if !existing.isEmpty, !confirmReplacingSegments(slot: slot) { return }

        let document = request.document
        updateJob(id) { job in
            switch slot {
            case .transcript:
                job.transcriptSegments = document.segments
                job.importedTranscriptSource = document.source
                if job.status == .idle || job.status == .canceled || job.status == .failed {
                    job.status = .transcriptionComplete
                }
                job.progress = JobProgress(stage: .complete, detail: "Loaded existing subtitles.", fraction: 1)
            case .translation:
                job.translatedSegments = document.segments
                job.importedTranslationSource = document.source
                job.status = .translationComplete
            }
            job.log += "Loaded subtitles from \(document.source.fileName) (\(document.segments.count) cues).\n"
        }
        subtitleLoadRequest = nil
    }

    private func confirmReplacingSegments(slot: SubtitleSidecarScanner.Slot) -> Bool {
        let alert = NSAlert()
        alert.messageText = slot == .transcript ? "Replace the Transcript?" : "Replace the Translation?"
        alert.informativeText = "The segments currently in this tab will be replaced by the subtitle file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
```

- [ ] **Step 4: Add the slot picker sheet**

Create `Sources/Views/SubtitleSlotPickerView.swift`:

```swift
import SwiftUI

/// Asks which slot a manually loaded subtitle file should fill.
struct SubtitleSlotPickerView: View {
    @EnvironmentObject private var model: AppModel
    let request: AppModel.SubtitleLoadRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Load Subtitles")
                .font(.title3.weight(.semibold))
            Text("\(request.document.source.fileName) — ^[\(request.document.segments.count) cue](inflect: true)")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button("Load as Transcript") {
                    model.applySubtitleLoad(request, to: .transcript)
                }
                .buttonStyle(.borderedProminent)

                Button("Load as Translation") {
                    model.applySubtitleLoad(request, to: .translation)
                }
                .disabled(!model.canLoadTranslationSubtitles)
                if !model.canLoadTranslationSubtitles {
                    Text("Load a transcript first — a translation on its own cannot be exported or burned in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.subtitleLoadRequest = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 5: Wire the menu command and the empty states**

In `Sources/App/CueApp.swift`, inside the `CommandGroup(after: .newItem)` block, after the "Add Files..." button:

```swift
                Button("Load Subtitles…") {
                    model.presentSubtitleLoadPanel()
                }
                .disabled(!model.canLoadSubtitles)
                .keyboardShortcut("o", modifiers: [.command, .shift])
```

In `Sources/Views/DetailView.swift`, add to the transcript empty state's `actions:` block:

```swift
                    Button("Load Subtitles…") { model.presentSubtitleLoadPanel() }
                        .disabled(!model.canLoadSubtitles)
```

and the same button in the translation empty state's `actions:` block.

Host the sheet on the same view that hosts the export sheet (search for `.sheet(isPresented: $model.isShowingExportSheet)` and add beside it):

```swift
        .sheet(item: $model.subtitleLoadRequest) { request in
            SubtitleSlotPickerView(request: request)
                .environmentObject(model)
        }
```

- [ ] **Step 6: Run tests and build the app**

Run: `./script/format_swift.sh && ./script/run_tests.sh && ./script/build_and_run.sh --bundle`
Expected: tests PASS (15 in `AppModelSubtitleImportTests`), bundle builds clean.

- [ ] **Step 7: Commit**

```bash
git add Sources/Stores/AppModel.swift Sources/Views/SubtitleSlotPickerView.swift Sources/Views/DetailView.swift Sources/App/CueApp.swift Tests/CueTests/AppModelSubtitleImportTests.swift
git commit -m "Add Load Subtitles command with a slot picker"
```

---

### Task 10: Show where subtitles came from

**Files:**
- Create: `Sources/Views/ImportedSubtitleBanner.swift`
- Modify: `Sources/Views/DetailView.swift` (`tabContent`, both non-empty branches)

Automatic write-back means the user must be able to see that a file is being synced, and stop it. `unlinkImportedSubtitles` already exists from Task 8.

**Interfaces:**
- Consumes: `AppModel.currentJob`, `TranscriptionJob.importedSource(for:)`, `AppModel.unlinkImportedSubtitles(slot:jobID:)`.
- Produces: `ImportedSubtitleBanner(slot:)` view.

- [ ] **Step 1: Create the banner**

Create `Sources/Views/ImportedSubtitleBanner.swift`:

```swift
import AppKit
import SwiftUI

/// Shows that a tab's segments came from a file on disk, and that edits are
/// being written back to it. With automatic write-back, this is how the user
/// finds out — and how they stop it.
struct ImportedSubtitleBanner: View {
    @EnvironmentObject private var model: AppModel
    let slot: SubtitleSidecarScanner.Slot

    var body: some View {
        if let job = model.currentJob, let source = job.importedSource(for: slot) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(source))
                    .foregroundStyle(statusColor(source))
                Text("Imported from \(source.fileName)")
                    .font(.caption)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(statusText(source))
                    .font(.caption)
                    .foregroundStyle(statusColor(source))

                Spacer()

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                }
                .buttonStyle(.link)
                .font(.caption)

                Button("Unlink") {
                    model.unlinkImportedSubtitles(slot: slot, jobID: job.id)
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Stop writing edits back to this file")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func statusIcon(_ source: ImportedSubtitleSource) -> String {
        if source.lastSyncError != nil { return "exclamationmark.triangle.fill" }
        return source.syncPaused ? "pause.circle.fill" : "arrow.triangle.2.circlepath"
    }

    private func statusColor(_ source: ImportedSubtitleSource) -> Color {
        source.lastSyncError != nil || source.syncPaused ? .orange : .secondary
    }

    private func statusText(_ source: ImportedSubtitleSource) -> String {
        if let error = source.lastSyncError { return "Sync failed: \(error)" }
        return source.syncPaused ? "Sync paused — file changed outside Cue" : "Syncing"
    }
}
```

- [ ] **Step 2: Show it above each segment list**

In `Sources/Views/DetailView.swift`, wrap the two non-empty branches of `tabContent`:

```swift
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ImportedSubtitleBanner(slot: .transcript)
                    segmentList(segments: model.displayTranscriptSegments, onEdit: model.updateTranscriptSegment)
                }
            }
```

and the translation branch identically with `slot: .translation` and `model.displayTranslatedSegments` / `model.updateTranslatedSegment`.

- [ ] **Step 3: Build and check by hand**

Run: `./script/format_swift.sh && ./script/lint_swift.sh && ./script/run_tests.sh && ./script/build_and_run.sh`

Manual verification in the running app:
1. Add a video that has `movie.ja.srt` beside it → the job opens on *Transcript ready* with segments and the banner reads `Imported from movie.ja.srt · Syncing`.
2. Edit a segment, wait two seconds, open the file in a text editor → the edit is there, and `movie.ja.srt.bak` holds the original.
3. Change the file in the text editor, then edit a segment in Cue → the banner turns orange with *Sync paused*, and the file keeps the external edit.
4. Click **Unlink** → the banner disappears and further edits do not touch the file.
5. **File → Load Subtitles…** with a file from another folder → the slot picker appears; *Load as Translation* is disabled until a transcript exists.
6. Burn in the imported transcript → ffmpeg renders the imported cues.

- [ ] **Step 4: Commit**

```bash
git add Sources/Views/ImportedSubtitleBanner.swift Sources/Views/DetailView.swift
git commit -m "Show imported subtitle provenance and sync state"
```

---

## Verification

Run before opening a PR:

```bash
./script/lint_swift.sh && ./script/run_tests.sh && ./script/run_coverage.sh && ./script/build_and_run.sh --bundle
```

All four must pass. The manual checks in Task 10 Step 3 have no automated equivalent — SwiftUI views are not covered by this suite — so run them too.
