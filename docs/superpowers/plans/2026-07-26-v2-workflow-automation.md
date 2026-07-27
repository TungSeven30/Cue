# v2 Workflow Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watch folder producing translated sidecars unattended, ffmpeg burn-in MP4 export, and a reorderable queue with per-job settings overrides.

**Architecture:** Phase 0 makes jobs run on a resolved value-type `JobSettingsSnapshot` instead of the live `AppSettingsStore` (spec §0). Phase 1 adds `orderIndex` ordering and a five-field override sheet. Phase 2 adds a ledger-driven watch-folder scanner (kqueue hint + periodic scan truth). Phase 3 adds an ffmpeg burn-in pipeline through the existing job machinery.

**Tech Stack:** Swift 6 (language mode 5), SwiftUI, Swift Testing (`@Test`/`#expect`), Process + ffmpeg (burn-in only), no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-26-v2-workflow-automation-design.md` — read it before starting.

**Conventions (non-negotiable):**
- Tests run ONLY via `./script/run_tests.sh`. Baseline: 27 tests / 5 suites green.
- For a compiled language the "failing test" step usually fails as a compile error. That counts.
- Commit after every task with a `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` trailer.
- Tests must never construct `AppSettingsStore` (it touches UserDefaults + Keychain). Build `JobSettingsSnapshot`/`TranscriptionJob` fixtures by decoding JSON, as `JobStoreTests.makeJob` does.
- One deliberate deviation from the spec's letter: the spec's "FSEvents hint" (§2.2) is implemented as a kqueue `DispatchSource.makeFileSystemObjectSource` on the folder. It delivers the same change signal with no C plumbing; the 60-second rescan stays the source of truth either way.

**File map (created files):**

| File | Responsibility |
| --- | --- |
| `Sources/Models/JobSettingsOverrides.swift` | Override set + `JobOrigin` |
| `Sources/Models/QueueOrdering.swift` | Pure orderIndex math |
| `Sources/Models/MediaFileTypes.swift` | Media extension list |
| `Sources/Services/WatchFolderScanEngine.swift` | Pure scan/stability/dedup logic |
| `Sources/Services/WatchFolderLedger.swift` | Processed-file ledger |
| `Sources/Services/WatchFolderService.swift` | kqueue + timer + wake plumbing |
| `Sources/Services/BurnInService.swift` | ffmpeg args, progress parse, execution |
| `Sources/Views/JobSettingsOverridesView.swift` | Five-field override editor (jobs + watch profile) |
| `Sources/Views/BurnInOptionsView.swift` | Burn-in sheet |

---

## Phase 0 — Effective-settings backbone

### Task 1: Extract quality-preset parameters into a pure value

**Files:**
- Modify: `Sources/Models/AppSettingsStore.swift` (enum `TranscriptionQualityPreset` ~line 91, `applyQualityPreset()` ~line 494)
- Test: `Tests/WhisperDeskTests/SettingsResolutionTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/WhisperDeskTests/SettingsResolutionTests.swift`:

```swift
import Foundation
import Testing
@testable import WhisperDesk

struct QualityPresetParameterTests {
    @Test func customHasNoParameters() {
        #expect(TranscriptionQualityPreset.custom.parameters == nil)
    }

    // Values must match the table previously hard-coded in
    // AppSettingsStore.applyQualityPreset(), which this replaces.
    @Test func balancedMatchesLegacyTable() throws {
        let p = try #require(TranscriptionQualityPreset.balanced.parameters)
        #expect(p.preprocessAudio == true)
        #expect(p.vadFilter == true)
        #expect(p.removeEmptySegments == true)
        #expect(p.removeRepeatedText == true)
        #expect(p.mergeShortSegments == true)
        #expect(p.minSegmentDuration == 0.7)
        #expect(p.maxMergeGap == 0.45)
        #expect(p.beamSize == 5)
        #expect(p.bestOf == 5)
        #expect(p.temperature == 0)
        #expect(p.noSpeechThreshold == 0.6)
    }

    @Test func everyNonCustomPresetHasParameters() {
        for preset in TranscriptionQualityPreset.allCases where preset != .custom {
            #expect(preset.parameters != nil, "\(preset) must provide parameters")
        }
    }

    @Test func fastDisablesPreprocessAndMerge() throws {
        let p = try #require(TranscriptionQualityPreset.fast.parameters)
        #expect(p.preprocessAudio == false)
        #expect(p.mergeShortSegments == false)
        #expect(p.beamSize == 3)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./script/run_tests.sh`
Expected: build error — `TranscriptionQualityParameters` / `.parameters` not defined.

- [ ] **Step 3: Implement**

In `Sources/Models/AppSettingsStore.swift`, directly below the `TranscriptionQualityPreset` enum, add:

```swift
/// The decoding/cleanup parameter set a quality preset stands for, as a pure
/// value so job-settings resolution can use it without mutating the store.
struct TranscriptionQualityParameters: Hashable {
    var preprocessAudio: Bool
    var vadFilter: Bool
    var removeEmptySegments: Bool
    var removeRepeatedText: Bool
    var mergeShortSegments: Bool
    var minSegmentDuration: Double
    var maxMergeGap: Double
    var beamSize: Int
    var bestOf: Int
    var temperature: Double
    var noSpeechThreshold: Double
}

extension TranscriptionQualityPreset {
    /// `nil` for `.custom`, which means "whatever the individual fields say".
    var parameters: TranscriptionQualityParameters? {
        switch self {
        case .fast:
            return TranscriptionQualityParameters(
                preprocessAudio: false, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: false,
                minSegmentDuration: 0.45, maxMergeGap: 0.25,
                beamSize: 3, bestOf: 3, temperature: 0, noSpeechThreshold: 0.6)
        case .balanced:
            return TranscriptionQualityParameters(
                preprocessAudio: true, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: true,
                minSegmentDuration: 0.7, maxMergeGap: 0.45,
                beamSize: 5, bestOf: 5, temperature: 0, noSpeechThreshold: 0.6)
        case .movieDialogue:
            return TranscriptionQualityParameters(
                preprocessAudio: true, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: true,
                minSegmentDuration: 0.9, maxMergeGap: 0.65,
                beamSize: 6, bestOf: 6, temperature: 0, noSpeechThreshold: 0.5)
        case .noisyAudio:
            return TranscriptionQualityParameters(
                preprocessAudio: true, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: true,
                minSegmentDuration: 1.0, maxMergeGap: 0.8,
                beamSize: 7, bestOf: 7, temperature: 0, noSpeechThreshold: 0.45)
        case .maximumAccuracy:
            return TranscriptionQualityParameters(
                preprocessAudio: true, vadFilter: true, removeEmptySegments: true,
                removeRepeatedText: true, mergeShortSegments: true,
                minSegmentDuration: 0.8, maxMergeGap: 0.5,
                beamSize: 8, bestOf: 8, temperature: 0, noSpeechThreshold: 0.5)
        case .custom:
            return nil
        }
    }
}
```

Then replace the body of `applyQualityPreset()` so the switch reads from the table (keep the existing `isApplyingQualityPreset` guard/set/reset structure exactly as it is — only the middle changes):

```swift
    private func applyQualityPreset() {
        guard !isApplyingQualityPreset else { return }
        guard let params = transcriptionQualityPreset.parameters else { return }
        isApplyingQualityPreset = true
        preprocessAudio = params.preprocessAudio
        vadFilter = params.vadFilter
        removeEmptySegments = params.removeEmptySegments
        removeRepeatedText = params.removeRepeatedText
        mergeShortSegments = params.mergeShortSegments
        minSegmentDuration = params.minSegmentDuration
        maxMergeGap = params.maxMergeGap
        beamSize = params.beamSize
        bestOf = params.bestOf
        temperature = params.temperature
        noSpeechThreshold = params.noSpeechThreshold
        isApplyingQualityPreset = false
    }
```

(If the current function performs anything after the switch besides resetting the flag, preserve it.)

- [ ] **Step 4: Run to verify pass**

Run: `./script/run_tests.sh`
Expected: 31 tests pass (27 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/AppSettingsStore.swift Tests/WhisperDeskTests/SettingsResolutionTests.swift
git commit -m "Extract quality-preset parameters into a testable pure value"
```

---

### Task 2: JobSettingsOverrides and JobOrigin types

**Files:**
- Create: `Sources/Models/JobSettingsOverrides.swift`
- Test: `Tests/WhisperDeskTests/SettingsResolutionTests.swift` (append)

- [ ] **Step 1: Write the failing tests** (append to `SettingsResolutionTests.swift`)

```swift
struct JobSettingsOverridesTests {
    @Test func defaultIsEmpty() {
        #expect(JobSettingsOverrides().isEmpty)
    }

    @Test func anyFieldMakesItNonEmpty() {
        var o = JobSettingsOverrides()
        o.translationTargetLanguage = "Vietnamese"
        #expect(!o.isEmpty)
    }

    @Test func decodesFromEmptyObject() throws {
        let o = try JSONDecoder().decode(JobSettingsOverrides.self, from: Data("{}".utf8))
        #expect(o.isEmpty)
    }

    // Spec error-handling table: an override naming a preset this build no
    // longer knows must decode as nil (inherit), not fail the whole job file.
    @Test func unknownPresetRawValueDecodesAsInherit() throws {
        let json = #"{"transcriptionPreset":"laserFocus","sourceLanguage":"ja"}"#
        let o = try JSONDecoder().decode(JobSettingsOverrides.self, from: Data(json.utf8))
        #expect(o.transcriptionPreset == nil)
        #expect(o.sourceLanguage == "ja")
    }

    @Test func roundTrips() throws {
        var o = JobSettingsOverrides()
        o.sourceLanguage = "ja"
        o.transcriptionPreset = .bestAccuracy
        o.transcriptionQualityPreset = .movieDialogue
        o.translationTargetLanguage = "Vietnamese"
        o.autoTranslate = true
        let data = try JSONEncoder().encode(o)
        let back = try JSONDecoder().decode(JobSettingsOverrides.self, from: data)
        #expect(back == o)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./script/run_tests.sh`
Expected: build error — `JobSettingsOverrides` not defined.

- [ ] **Step 3: Implement** — create `Sources/Models/JobSettingsOverrides.swift`:

```swift
import Foundation

/// How a job entered the app. Watch-folder jobs get implicit sidecar export
/// and write the watch ledger on terminal states; manual jobs do neither.
enum JobOrigin: String, Codable, Hashable {
    case manual
    case watchFolder
}

/// Per-job settings overrides. `nil` means "inherit the global setting at the
/// time the job runs". This is the *input* side; the job's `settings`
/// snapshot remains the record of what a run actually used.
struct JobSettingsOverrides: Codable, Hashable {
    var sourceLanguage: String?
    var transcriptionPreset: TranscriptionPreset?
    var transcriptionQualityPreset: TranscriptionQualityPreset?
    var translationTargetLanguage: String?
    var autoTranslate: Bool?

    var isEmpty: Bool {
        sourceLanguage == nil
            && transcriptionPreset == nil
            && transcriptionQualityPreset == nil
            && translationTargetLanguage == nil
            && autoTranslate == nil
    }

    init() {}

    // Unknown enum raw values (a preset removed in a later build) must fall
    // back to inherit instead of failing the containing job file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        transcriptionPreset = (try? container.decodeIfPresent(TranscriptionPreset.self, forKey: .transcriptionPreset)) ?? nil
        transcriptionQualityPreset = (try? container.decodeIfPresent(TranscriptionQualityPreset.self, forKey: .transcriptionQualityPreset)) ?? nil
        translationTargetLanguage = try container.decodeIfPresent(String.self, forKey: .translationTargetLanguage)
        autoTranslate = try container.decodeIfPresent(Bool.self, forKey: .autoTranslate)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `./script/run_tests.sh`
Expected: 36 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/JobSettingsOverrides.swift Tests/WhisperDeskTests/SettingsResolutionTests.swift
git commit -m "Add JobSettingsOverrides and JobOrigin types"
```

---

### Task 3: New TranscriptionJob fields with migration defaults

**Files:**
- Modify: `Sources/Models/TranscriptionJob.swift`
- Test: `Tests/WhisperDeskTests/SettingsResolutionTests.swift` (append)

- [ ] **Step 1: Write the failing tests** (append)

```swift
struct TranscriptionJobMigrationTests {
    private func decodeJob(_ json: String) throws -> TranscriptionJob {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: Data(json.utf8))
    }

    private var legacyJobJSON: String {
        """
        {
          "id": "\(UUID().uuidString)",
          "sourcePath": "/tmp/example.mp4",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z",
          "status": "idle",
          "progress": {"stage": "idle", "detail": "x"},
          "settings": {
            "sourceLanguage": "auto",
            "whisperModel": "m",
            "whisperBackend": "auto",
            "openAIModel": "gpt-5.5"
          },
          "transcriptSegments": [],
          "translatedSegments": [],
          "log": "log\\n"
        }
        """
    }

    @Test func legacyJobGetsDefaultsForNewFields() throws {
        let job = try decodeJob(legacyJobJSON)
        #expect(job.overrides.isEmpty)
        #expect(job.origin == .manual)
        // Spec §0.5: -createdAt approximates today's newest-first ordering.
        #expect(job.orderIndex == -job.createdAt.timeIntervalSince1970)
    }

    @Test func newFieldsRoundTrip() throws {
        var job = try decodeJob(legacyJobJSON)
        job.overrides.translationTargetLanguage = "Vietnamese"
        job.origin = .watchFolder
        job.orderIndex = 42.5
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(TranscriptionJob.self, from: try encoder.encode(job))
        #expect(back.overrides.translationTargetLanguage == "Vietnamese")
        #expect(back.origin == .watchFolder)
        #expect(back.orderIndex == 42.5)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./script/run_tests.sh`
Expected: build error — `overrides`/`origin`/`orderIndex` not members of `TranscriptionJob`.

- [ ] **Step 3: Implement** — in `Sources/Models/TranscriptionJob.swift`:

Add stored properties after `var summary: String?`:

```swift
    /// Per-job settings overrides; nil fields inherit globals at run time.
    var overrides: JobSettingsOverrides
    /// How this job entered the app (manual add vs. watch-folder ingest).
    var origin: JobOrigin
    /// Queue/list position; lower runs and displays first.
    var orderIndex: Double
```

In `init(sourceURL:settings:)`, after `self.summary = nil`:

```swift
        self.overrides = JobSettingsOverrides()
        self.origin = .manual
        self.orderIndex = -now.timeIntervalSince1970
```

In `init(from decoder:)`, after the `summary` line:

```swift
        overrides = try container.decodeIfPresent(JobSettingsOverrides.self, forKey: .overrides) ?? JobSettingsOverrides()
        origin = try container.decodeIfPresent(JobOrigin.self, forKey: .origin) ?? .manual
        orderIndex = try container.decodeIfPresent(Double.self, forKey: .orderIndex) ?? -createdAt.timeIntervalSince1970
```

(CodingKeys are synthesized from stored properties; adding the properties adds the keys. Encoding stays synthesized.)

- [ ] **Step 4: Run to verify pass**

Run: `./script/run_tests.sh`
Expected: 38 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/TranscriptionJob.swift Tests/WhisperDeskTests/SettingsResolutionTests.swift
git commit -m "Add overrides, origin, and orderIndex to TranscriptionJob"
```

---

### Task 4: Snapshot resolution — applying(overrides:) and transcriptionIdentity

**Files:**
- Modify: `Sources/Models/TranscriptionJob.swift` (extend `JobSettingsSnapshot`)
- Test: `Tests/WhisperDeskTests/SettingsResolutionTests.swift` (append)

- [ ] **Step 1: Write the failing tests** (append)

```swift
struct SnapshotResolutionTests {
    /// Decodes a baseline snapshot without touching AppSettingsStore
    /// (UserDefaults/Keychain). decodeIfPresent fills defaults.
    private func makeSnapshot() throws -> JobSettingsSnapshot {
        let json = """
        {
          "sourceLanguage": "auto",
          "whisperModel": "mlx-community/whisper-large-v3-turbo",
          "whisperBackend": "mlx-whisper",
          "openAIModel": "gpt-5.5"
        }
        """
        return try JSONDecoder().decode(JobSettingsSnapshot.self, from: Data(json.utf8))
    }

    @Test func emptyOverridesChangeNothing() throws {
        let base = try makeSnapshot()
        #expect(base.applying(JobSettingsOverrides()) == base)
    }

    @Test func languageOverridesWin() throws {
        var o = JobSettingsOverrides()
        o.sourceLanguage = "ja"
        o.translationTargetLanguage = "Vietnamese"
        let resolved = try makeSnapshot().applying(o)
        #expect(resolved.sourceLanguage == "ja")
        #expect(resolved.translationTargetLanguage == "Vietnamese")
        // Untouched fields inherit.
        #expect(resolved.whisperModel == "mlx-community/whisper-large-v3-turbo")
    }

    @Test func transcriptionPresetExpandsToBackendAndModel() throws {
        var o = JobSettingsOverrides()
        o.transcriptionPreset = .bestAccuracy
        let resolved = try makeSnapshot().applying(o)
        #expect(resolved.transcriptionPreset == .bestAccuracy)
        #expect(resolved.whisperBackend == .qwen3ASR)
        #expect(resolved.whisperModel == AppSettingsStore.qwen3DefaultModel)
    }

    @Test func qualityPresetExpandsToParameters() throws {
        var o = JobSettingsOverrides()
        o.transcriptionQualityPreset = .noisyAudio
        let resolved = try makeSnapshot().applying(o)
        #expect(resolved.transcriptionQualityPreset == .noisyAudio)
        #expect(resolved.beamSize == 7)
        #expect(resolved.noSpeechThreshold == 0.45)
        #expect(resolved.minSegmentDuration == 1.0)
    }

    @Test func identityIgnoresTranslationFields() throws {
        let base = try makeSnapshot()
        var o = JobSettingsOverrides()
        o.translationTargetLanguage = "Vietnamese"
        #expect(base.applying(o).transcriptionIdentity == base.transcriptionIdentity)
    }

    @Test func identityChangesWithTranscriptionFields() throws {
        let base = try makeSnapshot()
        var o = JobSettingsOverrides()
        o.sourceLanguage = "ja"
        #expect(base.applying(o).transcriptionIdentity != base.transcriptionIdentity)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./script/run_tests.sh`
Expected: build error — `applying`/`transcriptionIdentity` not defined.

- [ ] **Step 3: Implement** — append to `Sources/Models/TranscriptionJob.swift`:

```swift
extension JobSettingsSnapshot {
    /// Layers per-job overrides over this (global-derived) snapshot.
    /// Spec §0.3: presets expand to their constituent fields so services
    /// never need to interpret presets themselves.
    func applying(_ overrides: JobSettingsOverrides) -> JobSettingsSnapshot {
        var resolved = self
        if let language = overrides.sourceLanguage {
            resolved.sourceLanguage = language
        }
        if let target = overrides.translationTargetLanguage {
            resolved.translationTargetLanguage = target
        }
        if let preset = overrides.transcriptionPreset,
           let backend = preset.backend, let model = preset.model {
            resolved.transcriptionPreset = preset
            resolved.whisperBackend = backend
            resolved.whisperModel = model
        }
        if let quality = overrides.transcriptionQualityPreset,
           let params = quality.parameters {
            resolved.transcriptionQualityPreset = quality
            resolved.preprocessAudio = params.preprocessAudio
            resolved.vadFilter = params.vadFilter
            resolved.removeEmptySegments = params.removeEmptySegments
            resolved.removeRepeatedText = params.removeRepeatedText
            resolved.mergeShortSegments = params.mergeShortSegments
            resolved.minSegmentDuration = params.minSegmentDuration
            resolved.maxMergeGap = params.maxMergeGap
            resolved.beamSize = params.beamSize
            resolved.bestOf = params.bestOf
            resolved.temperature = params.temperature
            resolved.noSpeechThreshold = params.noSpeechThreshold
        }
        return resolved
    }

    /// The fields that determine what transcript a run produces. Two
    /// snapshots with equal identity yield the same transcript, so re-running
    /// can be skipped (spec §0.6). Translation and summary settings are
    /// deliberately excluded.
    struct TranscriptionIdentity: Hashable {
        let processingVersion: Int
        let sourceLanguage: String
        let whisperModel: String
        let whisperBackend: WhisperBackend
        let preprocessAudio: Bool
        let vadFilter: Bool
        let removeEmptySegments: Bool
        let removeRepeatedText: Bool
        let mergeShortSegments: Bool
        let minSegmentDuration: Double
        let maxMergeGap: Double
        let beamSize: Int
        let bestOf: Int
        let temperature: Double
        let noSpeechThreshold: Double
    }

    var transcriptionIdentity: TranscriptionIdentity {
        TranscriptionIdentity(
            processingVersion: transcriptionProcessingVersion,
            sourceLanguage: sourceLanguage,
            whisperModel: whisperModel,
            whisperBackend: whisperBackend,
            preprocessAudio: preprocessAudio,
            vadFilter: vadFilter,
            removeEmptySegments: removeEmptySegments,
            removeRepeatedText: removeRepeatedText,
            mergeShortSegments: mergeShortSegments,
            minSegmentDuration: minSegmentDuration,
            maxMergeGap: maxMergeGap,
            beamSize: beamSize,
            bestOf: bestOf,
            temperature: temperature,
            noSpeechThreshold: noSpeechThreshold
        )
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `./script/run_tests.sh`
Expected: 44 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/TranscriptionJob.swift Tests/WhisperDeskTests/SettingsResolutionTests.swift
git commit -m "Add snapshot override resolution and transcription identity"
```

---

### Task 5: Services take value types instead of AppSettingsStore

No new behaviour — a mechanical signature change, so no new tests; the existing suite plus the compiler are the check.

**Files:**
- Modify: `Sources/Services/TranscriptionService.swift:23-45`
- Modify: `Sources/Services/TranslationService.swift` (translate ~line 69, summarize ~line 326, plus a `TranslationCredentials` struct)
- Modify: `Sources/Stores/AppModel.swift` (call sites, minimal edits to compile — full wiring is Task 6)

- [ ] **Step 1: Add TranslationCredentials** — in `Sources/Services/TranslationService.swift`, above `struct TranslationService`:

```swift
/// Secrets and prompt for a translation run, passed separately from the
/// persisted JobSettingsSnapshot so keys never reach a job file on disk.
struct TranslationCredentials {
    let apiKey: String
    let prompt: String
    let provider: TranslationProvider
}
```

- [ ] **Step 2: Change TranscriptionService.transcribe**

Replace the signature and the snapshot construction (`Sources/Services/TranscriptionService.swift:23-45`):

```swift
    @MainActor
    func transcribe(
        videoURL: URL,
        settings: JobSettingsSnapshot,
        progress: @escaping @MainActor (JobProgress) -> Void
    ) async throws -> TranscriptionResult {
        let snapshot = TranscriptionSettingsSnapshot(
            sourceLanguage: settings.sourceLanguage,
            whisperModel: settings.whisperModel,
            whisperBackendRawValue: settings.whisperBackend.rawValue,
            preprocessAudio: settings.preprocessAudio,
            vadFilter: settings.vadFilter,
            removeEmptySegments: settings.removeEmptySegments,
            removeRepeatedText: settings.removeRepeatedText,
            mergeShortSegments: settings.mergeShortSegments,
            minSegmentDuration: settings.minSegmentDuration,
            maxMergeGap: settings.maxMergeGap,
            beamSize: settings.beamSize,
            bestOf: settings.bestOf,
            temperature: settings.temperature,
            noSpeechThreshold: settings.noSpeechThreshold
        )
```

The rest of the function already reads only `snapshot`; later post-processing reads `settings.removeRepeatedText` etc. (lines ~230-248) which work identically on `JobSettingsSnapshot` because the field names match.

- [ ] **Step 3: Change TranslationService.translate and summarize**

`translate` head becomes:

```swift
    @MainActor
    func translate(
        segments: [TranscriptionSegment],
        sourceLanguage: String,
        settings: JobSettingsSnapshot,
        credentials: TranslationCredentials,
        existingTranslations: [TranscriptionSegment],
        progress: @escaping @MainActor (JobProgress) -> Void,
        onPartial: @escaping @MainActor ([TranscriptionSegment]) -> Void
    ) async throws -> [TranscriptionSegment] {
        let model = settings.openAIModel
        let provider = credentials.provider
        let apiKey = credentials.apiKey
        let chunkSize = settings.translationChunkMode.chunkSize
        let parallelism = max(1, min(4, settings.translationParallelism))
        let translationSourceLanguage = Self.translationSourceLanguage(
            translationSetting: settings.translationSourceLanguage,
            transcriptionSetting: sourceLanguage
        )
        let targetLanguage = settings.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = credentials.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppSettingsStore.defaultTranslationPrompt
            : credentials.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
```

The `guard !apiKey.isEmpty` line and everything below stay unchanged. If `translate` forwards `settings` to private helpers (e.g. the internal batching function at ~line 204), change those parameter types the same way — the compiler will list them.

`summarize` head becomes:

```swift
    @MainActor
    func summarize(
        segments: [TranscriptionSegment],
        language: String,
        settings: JobSettingsSnapshot,
        credentials: TranslationCredentials
    ) async throws -> String {
        let model = settings.openAIModel
        let provider = credentials.provider
        let apiKey = credentials.apiKey
```

- [ ] **Step 4: Patch AppModel call sites minimally so it compiles**

In `Sources/Stores/AppModel.swift` add a credentials helper near the top of the class:

```swift
    /// Secrets + prompt for the current translation model. Built fresh per
    /// run; never stored on the job.
    private func makeTranslationCredentials() -> TranslationCredentials {
        let provider = settings.currentTranslationProvider
        return TranslationCredentials(
            apiKey: settings.translationAPIKey(for: provider),
            prompt: settings.translationPrompt,
            provider: provider
        )
    }
```

Then, for this task only, pass resolved snapshots built without overrides (Task 6 wires real overrides):
- `startTranscriptionNow` (~line 427): `transcriptionService.transcribe(videoURL: videoURL, settings: JobSettingsSnapshot(settings: settings), progress: ...)`
- `startTranslationNow` (~line 500): add `credentials: makeTranslationCredentials()` and pass `JobSettingsSnapshot(settings: settings)`.
- `generateSummaryNow` and `makeIntroSummary` (~lines 866, 903): add `credentials: makeTranslationCredentials()` and pass `JobSettingsSnapshot(settings: settings)`.

- [ ] **Step 5: Run to verify pass**

Run: `./script/run_tests.sh`
Expected: 44 tests pass (no count change; the suite compiles and behaviour is identical).

- [ ] **Step 6: Commit**

```bash
git add Sources/Services/TranscriptionService.swift Sources/Services/TranslationService.swift Sources/Stores/AppModel.swift
git commit -m "Run services on JobSettingsSnapshot plus separate credentials"
```

---

### Task 6: AppModel resolves overrides; identity-based skip; per-job autoTranslate

**Files:**
- Modify: `Sources/Stores/AppModel.swift` (`startTranscriptionNow` ~371-468, `startTranslationNow` ~483, `generateSummaryNow`, `makeIntroSummary`)

- [ ] **Step 1: Rewire startTranscriptionNow**

Replace the section from `let currentFingerprint = ...` (~line 380) through the `jobs[index].settings = JobSettingsSnapshot(settings: settings)` stamp (~line 418) with:

```swift
        let currentFingerprint = TranscriptionJob.fingerprint(for: videoURL)
        let resolved = JobSettingsSnapshot(settings: settings).applying(jobs[index].overrides)
        // Per-job autoTranslate wins over the global toggle (spec §0.3).
        let autoTranslate = jobs[index].overrides.autoTranslate ?? settings.autoTranslateAfterTranscription

        if !force,
           !jobs[index].transcriptSegments.isEmpty,
           jobs[index].sourceFingerprint == currentFingerprint,
           jobs[index].settings.transcriptionIdentity == resolved.transcriptionIdentity {
            let hasTranslation = !jobs[index].translatedSegments.isEmpty
            jobs[index].status = hasTranslation ? .translationComplete : .transcriptionComplete
            jobs[index].progress = JobProgress(stage: .complete, detail: "Using existing transcript for unchanged file and settings.", fraction: 1)
            appendLog("Skipped transcription because this file and transcription settings already have a transcript.", to: jobID)
            // Same guard as the real completion path: auto-translating with
            // no API key would immediately mark this finished job as Failed.
            if autoTranslate && !hasTranslation && !settings.currentTranslationAPIKey.isEmpty {
                startTranslation(jobID: jobID)
            } else {
                processQueue()
            }
            return
        }

        jobs[index].status = .transcribing
        jobs[index].progress = JobProgress(stage: .preflight, detail: "Starting transcription.", fraction: 0)
        jobs[index].translatedSegments = []
        jobs[index].partialTranslatedSegments = []
        jobs[index].sourceFingerprint = currentFingerprint
        jobs[index].settings = resolved
```

Notes:
- Delete the old 18-comparison chain entirely; `transcriptionIdentity` replaces it.
- The `validationMessage` / `repairTranscriptionModelForBackend()` lines above this section stay as they are.
- In the `activeTask` closure below, change `transcriptionService.transcribe(videoURL: videoURL, settings: JobSettingsSnapshot(settings: settings), ...)` to `settings: resolved`, and change `let willTranslate = settings.autoTranslateAfterTranscription && !settings.currentTranslationAPIKey.isEmpty` to `let willTranslate = autoTranslate && !settings.currentTranslationAPIKey.isEmpty` (capture `autoTranslate` and `resolved` — both are value types, safe in the closure).

- [ ] **Step 2: Rewire startTranslationNow**

At the top of `startTranslationNow`, after `let segments = ...`:

```swift
        let resolved = JobSettingsSnapshot(settings: settings).applying(jobs[index].overrides)
```

Replace `jobs[index].settings = JobSettingsSnapshot(settings: settings)` with `jobs[index].settings = resolved`. In the log line and the `translationService.translate(...)` call, use `resolved.translationSourceLanguage`, `resolved.translationTargetLanguage`, `resolved.openAIModel`, `resolved.translationChunkMode`, `resolved.translationParallelism`, and pass `settings: resolved, credentials: makeTranslationCredentials()`. The summary target language becomes `resolved.translationTargetLanguage` instead of `settings.translationTargetLanguage`.

- [ ] **Step 3: Rewire summaries**

In `makeIntroSummary` and `generateSummaryNow`, replace `JobSettingsSnapshot(settings: settings)` stopgaps from Task 5 with resolution against the job's overrides:

```swift
        // In generateSummaryNow (has `job` in scope):
        let resolvedSettings = JobSettingsSnapshot(settings: settings).applying(job.overrides)
```

and pass `settings: resolvedSettings, credentials: makeTranslationCredentials()`. In `makeIntroSummary`, resolve from the job looked up by `id` (`jobs.first(where: { $0.id == id })?.overrides ?? JobSettingsOverrides()`).

- [ ] **Step 4: Run tests and build**

Run: `./script/run_tests.sh`
Expected: 44 tests pass.
Run: `swift build`
Expected: clean build.

- [ ] **Step 5: Manual sanity check**

Run: `./script/build_and_run.sh`. Transcribe a short clip; confirm the log line "Starting transcription with … and model …" shows the expected backend, and re-running the same job reports "Skipped transcription…".

- [ ] **Step 6: Commit**

```bash
git add Sources/Stores/AppModel.swift
git commit -m "Resolve per-job overrides at run start; skip check via identity"
```

---

## Phase 1 — Queue upgrades

### Task 7: QueueOrdering pure math

**Files:**
- Create: `Sources/Models/QueueOrdering.swift`
- Test: `Tests/WhisperDeskTests/QueueOrderingTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperDesk

struct QueueOrderingTests {
    @Test func manualAddGoesOnTop() {
        #expect(QueueOrdering.indexForManualAdd(existing: [0, 1, 2]) == -1)
        #expect(QueueOrdering.indexForManualAdd(existing: []) == -1)
    }

    @Test func watchAddGoesToBottom() {
        #expect(QueueOrdering.indexForWatchAdd(existing: [0, 1, 2]) == 3)
        #expect(QueueOrdering.indexForWatchAdd(existing: []) == 1)
    }

    @Test func destinationBetweenNeighborsIsMidpoint() {
        #expect(QueueOrdering.destinationIndex(before: 1, after: 2) == 1.5)
    }

    @Test func destinationAtEdges() {
        #expect(QueueOrdering.destinationIndex(before: nil, after: 5) == 4)
        #expect(QueueOrdering.destinationIndex(before: 5, after: nil) == 6)
        #expect(QueueOrdering.destinationIndex(before: nil, after: nil) == 0)
    }

    @Test func renormalizationTriggersOnTinyGap() {
        #expect(QueueOrdering.needsRenormalization(before: 1, after: 1 + 1e-10))
        #expect(!QueueOrdering.needsRenormalization(before: 1, after: 2))
        #expect(!QueueOrdering.needsRenormalization(before: nil, after: 2))
    }

    @Test func renormalizedIsZeroBasedSequential() {
        #expect(QueueOrdering.renormalized(count: 4) == [0, 1, 2, 3])
        #expect(QueueOrdering.renormalized(count: 0) == [])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./script/run_tests.sh` — build error, `QueueOrdering` not defined.

- [ ] **Step 3: Implement** — create `Sources/Models/QueueOrdering.swift`:

```swift
import Foundation

/// Pure math for job list ordering. Jobs sort ascending by orderIndex; new
/// manual jobs go on top, watch-folder ingests at the bottom, and a drag
/// rewrites only the moved job (spec §1.1).
enum QueueOrdering {
    static let minimumGap = 1e-9

    static func indexForManualAdd(existing: [Double]) -> Double {
        (existing.min() ?? 0) - 1
    }

    static func indexForWatchAdd(existing: [Double]) -> Double {
        (existing.max() ?? 0) + 1
    }

    /// Index for a job landing between two neighbours (nil = list edge).
    static func destinationIndex(before: Double?, after: Double?) -> Double {
        switch (before, after) {
        case let (b?, a?): return (b + a) / 2
        case let (nil, a?): return a - 1
        case let (b?, nil): return b + 1
        case (nil, nil): return 0
        }
    }

    static func needsRenormalization(before: Double?, after: Double?) -> Bool {
        guard let before, let after else { return false }
        return abs(after - before) < minimumGap
    }

    static func renormalized(count: Int) -> [Double] {
        (0..<count).map(Double.init)
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./script/run_tests.sh`, 50 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/QueueOrdering.swift Tests/WhisperDeskTests/QueueOrderingTests.swift
git commit -m "Add pure orderIndex math for queue ordering"
```

---

### Task 8: AppModel adopts orderIndex

**Files:**
- Modify: `Sources/Stores/AppModel.swift` (`init` ~47, `addVideos` ~254, `processQueue` ~335)

- [ ] **Step 1: Sort by orderIndex on load**

In `init`, replace `jobs = jobStore.loadJobs().sorted { $0.updatedAt > $1.updatedAt }` with:

```swift
        jobs = jobStore.loadJobs().sorted { $0.orderIndex < $1.orderIndex }
```

(Migration default `-createdAt` makes this reproduce the old visible order for existing jobs.)

- [ ] **Step 2: Assign indices in addVideos**

In `addVideos(urls:)`, replace the `let newJobs = urls.map { ... }` block with:

```swift
        var minIndex = jobs.map(\.orderIndex).min() ?? 0
        let newJobs = urls.map { url in
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.log = "Selected \(url.path(percentEncoded: false)).\n"
            minIndex = QueueOrdering.indexForManualAdd(existing: [minIndex])
            job.orderIndex = minIndex
            return job
        }
```

(The first URL gets the topmost slot; `jobs.insert(contentsOf:at: 0)` below already puts them at the top of the array in the same order.)

- [ ] **Step 3: Pick the queued job by orderIndex**

In `processQueue()`, replace `guard let next = jobs.first(where: { $0.status == .queued })` with:

```swift
        guard let next = jobs.filter({ $0.status == .queued }).min(by: { $0.orderIndex < $1.orderIndex })
```

- [ ] **Step 4: Add move/renormalize API** (used by Task 9's UI):

```swift
    // MARK: - Ordering

    /// Moves jobs for SwiftUI's onMove. Only moved jobs are re-persisted,
    /// unless the midpoint gap collapses and forces a renormalization pass.
    func moveJobs(from source: IndexSet, to destination: Int) {
        jobs.move(fromOffsets: source, toOffset: destination)
        reindexAfterMove()
    }

    func moveJobToTop(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
        reindexAfterMove()
    }

    func moveJobToBottom(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.move(fromOffsets: IndexSet(integer: index), toOffset: jobs.count)
        reindexAfterMove()
    }

    func removeFromQueue(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .queued else { return }
        updateJob(id) { job in
            job.status = .idle
            job.progress = .idle
        }
    }

    /// After an array move, stamp each displaced job whose neighbours no
    /// longer bracket its index; in the common case that's just the moved
    /// job(s). Falls back to a full renormalization when gaps collapse.
    private func reindexAfterMove() {
        var needsFullPass = false
        for i in jobs.indices {
            let before = i > 0 ? jobs[i - 1].orderIndex : nil
            let after = i < jobs.count - 1 ? jobs[i + 1].orderIndex : nil
            let current = jobs[i].orderIndex
            let inPlace = (before.map { $0 < current } ?? true) && (after.map { current < $0 } ?? true)
            if inPlace { continue }
            if QueueOrdering.needsRenormalization(before: before, after: after) {
                needsFullPass = true
                break
            }
            jobs[i].orderIndex = QueueOrdering.destinationIndex(before: before, after: after)
            persistJob(jobs[i].id)
        }
        if needsFullPass {
            let indices = QueueOrdering.renormalized(count: jobs.count)
            for i in jobs.indices {
                jobs[i].orderIndex = indices[i]
                persistJob(jobs[i].id)
            }
        }
    }
```

- [ ] **Step 5: Run tests and build** — `./script/run_tests.sh` (50 pass), `swift build` clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/Stores/AppModel.swift
git commit -m "Order the job list and queue by orderIndex"
```

---

### Task 9: Sidebar reorder UI and queue affordances

**Files:**
- Modify: `Sources/Views/SidebarView.swift`

- [ ] **Step 1: Enable drag reorder**

In `SidebarView`, add `.onMove` to the `ForEach`:

```swift
                    ForEach(model.jobs) { job in
                        JobRow(job: job, hasOverrides: !job.overrides.isEmpty)
                            .tag(job.id)
                            .contextMenu { contextMenu(for: job) }
                    }
                    .onMove { source, destination in
                        model.moveJobs(from: source, to: destination)
                    }
```

Extract the context menu into a builder on `SidebarView` (existing Add to Queue / Delete items plus the new ones):

```swift
    @ViewBuilder
    private func contextMenu(for job: TranscriptionJob) -> some View {
        if model.jobNeedsWork(job) && job.status != .queued {
            Button {
                model.enqueueJob(job.id)
            } label: {
                Label("Add to Queue", systemImage: "clock")
            }
        }
        if job.status == .queued {
            Button {
                model.removeFromQueue(job.id)
            } label: {
                Label("Remove from Queue", systemImage: "clock.badge.xmark")
            }
        }
        Button {
            model.moveJobToTop(job.id)
        } label: {
            Label("Move to Top", systemImage: "arrow.up.to.line")
        }
        Button {
            model.moveJobToBottom(job.id)
        } label: {
            Label("Move to Bottom", systemImage: "arrow.down.to.line")
        }
        Divider()
        Button(role: .destructive) {
            model.deleteJob(job.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(job.id == model.activeJobID)
    }
```

- [ ] **Step 2: Override badge in JobRow**

```swift
private struct JobRow: View {
    let job: TranscriptionJob
    let hasOverrides: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.status.systemImage)
                .foregroundStyle(job.status.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .lineLimit(1)
                Text(job.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hasOverrides {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This job has its own settings")
            }
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 3: Build and verify manually**

`swift build` clean, then `./script/build_and_run.sh`: add three files, drag rows to reorder, quit and relaunch — order must persist. Queue two jobs, Move to Top on the second, Start All: the moved one runs first.

- [ ] **Step 4: Run tests** — `./script/run_tests.sh`, 50 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Views/SidebarView.swift
git commit -m "Add drag reorder, queue context actions, and override badge"
```

---

### Task 10: Per-job override editor sheet

**Files:**
- Create: `Sources/Views/JobSettingsOverridesView.swift`
- Modify: `Sources/Views/SidebarView.swift` (context menu entry), `Sources/Stores/AppModel.swift` (sheet state + apply), `Sources/Views/ContentView.swift` (sheet presentation)

- [ ] **Step 1: AppModel state and mutation**

```swift
    // In the published-properties block:
    @Published var overridesEditorJobID: UUID?

    // With the other job functions:
    func setOverrides(_ overrides: JobSettingsOverrides, for id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.status.isRunning else { return }
        updateJob(id) { job in
            job.overrides = overrides
            job.log += overrides.isEmpty
                ? "Cleared job-specific settings.\n"
                : "Set job-specific settings.\n"
        }
    }
```

- [ ] **Step 2: Create the editor view** — `Sources/Views/JobSettingsOverridesView.swift`.

The same view serves per-job editing and (Task 15) the watch-folder profile, so it binds a plain `JobSettingsOverrides` and takes labels from outside:

```swift
import SwiftUI

/// Editor for the five-field override set (spec §1.2). Every control's first
/// choice is "Inherit (<current global value>)" so the effective value is
/// always visible. Used for per-job overrides and the watch-folder profile.
struct JobSettingsOverridesView: View {
    let title: String
    @ObservedObject var settings: AppSettingsStore
    @State var overrides: JobSettingsOverrides
    let onSave: (JobSettingsOverrides) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            Form {
                Picker("Source language", selection: $overrides.sourceLanguage) {
                    Text("Inherit (\(globalLanguageLabel))").tag(String?.none)
                    ForEach(AppSettingPresets.transcriptionLanguages) { preset in
                        Text(preset.label).tag(String?.some(preset.value))
                    }
                }
                Picker("Transcription preset", selection: $overrides.transcriptionPreset) {
                    Text("Inherit (\(settings.transcriptionPreset.label))").tag(TranscriptionPreset?.none)
                    ForEach(TranscriptionPreset.allCases.filter { $0 != .custom }) { preset in
                        Text(preset.label).tag(TranscriptionPreset?.some(preset))
                    }
                }
                Picker("Quality preset", selection: $overrides.transcriptionQualityPreset) {
                    Text("Inherit (\(settings.transcriptionQualityPreset.label))").tag(TranscriptionQualityPreset?.none)
                    ForEach(TranscriptionQualityPreset.allCases.filter { $0 != .custom }) { preset in
                        Text(preset.label).tag(TranscriptionQualityPreset?.some(preset))
                    }
                }
                Picker("Translate to", selection: $overrides.translationTargetLanguage) {
                    Text("Inherit (\(settings.translationTargetLanguage))").tag(String?.none)
                    ForEach(AppSettingPresets.translationTargetLanguages) { preset in
                        Text(preset.label).tag(String?.some(preset.value))
                    }
                }
                Picker("Auto-translate", selection: $overrides.autoTranslate) {
                    Text("Inherit (\(settings.autoTranslateAfterTranscription ? "On" : "Off"))").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button("Reset to Inherit All") { overrides = JobSettingsOverrides() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(overrides)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 420)
    }

    private var globalLanguageLabel: String {
        AppSettingPresets.transcriptionLanguages.first { $0.value == settings.sourceLanguage }?.label
            ?? settings.sourceLanguage
    }
}
```

- [ ] **Step 3: Present the sheet**

In `Sources/Views/ContentView.swift`, alongside the existing sheet modifiers (find `isShowingExportSheet` usage), add:

```swift
        .sheet(item: Binding(
            get: { model.overridesEditorJobID.flatMap { id in model.jobs.first { $0.id == id } } },
            set: { model.overridesEditorJobID = $0?.id }
        )) { job in
            JobSettingsOverridesView(
                title: "Job Settings — \(job.title)",
                settings: model.settings,
                overrides: job.overrides
            ) { model.setOverrides($0, for: job.id) }
        }
```

In `SidebarView.contextMenu(for:)` add above the Divider:

```swift
        Button {
            model.overridesEditorJobID = job.id
        } label: {
            Label("Job Settings…", systemImage: "slider.horizontal.3")
        }
        .disabled(job.status.isRunning)
```

- [ ] **Step 4: Build and verify manually**

`swift build`; run the app: set a job's target language to Vietnamese, check the badge appears, run the job, confirm the log line "Starting translation from … to Vietnamese …". Global settings must be unchanged afterwards.

- [ ] **Step 5: Run tests** — `./script/run_tests.sh`, 50 pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Views/JobSettingsOverridesView.swift Sources/Views/SidebarView.swift Sources/Views/ContentView.swift Sources/Stores/AppModel.swift
git commit -m "Add per-job settings override editor"
```

---

## Phase 2 — Watch folder

### Task 11: Media types and the scan engine (pure logic)

**Files:**
- Create: `Sources/Models/MediaFileTypes.swift`
- Create: `Sources/Services/WatchFolderScanEngine.swift`
- Test: `Tests/WhisperDeskTests/WatchFolderTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperDesk

struct WatchFolderScanEngineTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func observation(_ path: String, size: Int64, mtime: TimeInterval = 0) -> FileObservation {
        FileObservation(path: path, size: size, modifiedAt: Date(timeIntervalSince1970: mtime))
    }

    @Test func ignoresNonMediaDotfilesAndPartials() {
        var engine = WatchFolderScanEngine()
        let files = [
            observation("/w/movie.txt", size: 10),
            observation("/w/.hidden.mp4", size: 10),
            observation("/w/movie.mp4.part", size: 10),
            observation("/w/movie.crdownload", size: 10),
        ]
        // First pass records candidates; second pass 3s later would ingest —
        // but none of these should even become candidates.
        _ = engine.filesReadyToIngest(observations: files, now: base, blockedFingerprints: [])
        let ready = engine.filesReadyToIngest(observations: files, now: base.addingTimeInterval(3), blockedFingerprints: [])
        #expect(ready.isEmpty)
    }

    @Test func stableFileIngestsAfterTwoChecks() {
        var engine = WatchFolderScanEngine()
        let file = [observation("/w/movie.mkv", size: 1000)]
        #expect(engine.filesReadyToIngest(observations: file, now: base, blockedFingerprints: []).isEmpty,
                "first sighting is never ingested")
        let ready = engine.filesReadyToIngest(observations: file, now: base.addingTimeInterval(2.5), blockedFingerprints: [])
        #expect(ready.map(\.path) == ["/w/movie.mkv"])
    }

    @Test func growingFileWaits() {
        var engine = WatchFolderScanEngine()
        _ = engine.filesReadyToIngest(observations: [observation("/w/movie.mkv", size: 1000)], now: base, blockedFingerprints: [])
        // Size changed: the copy is still running, restart the clock.
        let second = engine.filesReadyToIngest(observations: [observation("/w/movie.mkv", size: 2000)], now: base.addingTimeInterval(3), blockedFingerprints: [])
        #expect(second.isEmpty)
        let third = engine.filesReadyToIngest(observations: [observation("/w/movie.mkv", size: 2000)], now: base.addingTimeInterval(6), blockedFingerprints: [])
        #expect(third.map(\.path) == ["/w/movie.mkv"])
    }

    @Test func tooSoonSecondCheckWaits() {
        var engine = WatchFolderScanEngine()
        _ = engine.filesReadyToIngest(observations: [observation("/w/a.mp4", size: 5)], now: base, blockedFingerprints: [])
        #expect(engine.filesReadyToIngest(observations: [observation("/w/a.mp4", size: 5)], now: base.addingTimeInterval(1), blockedFingerprints: []).isEmpty)
    }

    // Spec §2.3 rule 3+4: ledger fingerprints and existing-job fingerprints
    // both block, regardless of job status.
    @Test func blockedFingerprintsAreSkipped() {
        var engine = WatchFolderScanEngine()
        let file = observation("/w/movie.mp4", size: 7, mtime: 99)
        let fingerprint = WatchFolderScanEngine.fingerprint(for: file)
        _ = engine.filesReadyToIngest(observations: [file], now: base, blockedFingerprints: [])
        let ready = engine.filesReadyToIngest(observations: [file], now: base.addingTimeInterval(3), blockedFingerprints: [fingerprint])
        #expect(ready.isEmpty)
    }

    @Test func fingerprintMatchesTranscriptionJobFormat() {
        let file = observation("/w/movie.mp4", size: 7, mtime: 99)
        #expect(WatchFolderScanEngine.fingerprint(for: file) == "/w/movie.mp4|7|99.0")
    }
}
```

- [ ] **Step 2: Run to verify failure** — build error, types not defined.

- [ ] **Step 3: Implement**

`Sources/Models/MediaFileTypes.swift`:

```swift
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
```

`Sources/Services/WatchFolderScanEngine.swift`:

```swift
import Foundation

/// One file sighting during a scan.
struct FileObservation: Hashable {
    let path: String
    let size: Int64
    let modifiedAt: Date
}

/// Pure ingestion logic for the watch folder (spec §2.3). Holds the
/// stability-gate state between scans; owns no I/O, timers, or file events,
/// so every rule is unit-testable.
struct WatchFolderScanEngine {
    /// How long a file's size must hold still before it is ingested.
    static let stabilityInterval: TimeInterval = 2.0

    private struct Candidate {
        var size: Int64
        var firstSeenAt: Date
    }

    private var candidates: [String: Candidate] = [:]

    /// Must match TranscriptionJob.fingerprint(for:) byte for byte, since
    /// ledger entries and job fingerprints are compared against it.
    static func fingerprint(for file: FileObservation) -> String {
        "\(file.path)|\(file.size)|\(file.modifiedAt.timeIntervalSince1970)"
    }

    mutating func filesReadyToIngest(
        observations: [FileObservation],
        now: Date,
        blockedFingerprints: Set<String>
    ) -> [FileObservation] {
        var ready: [FileObservation] = []
        var seenPaths = Set<String>()

        for file in observations {
            seenPaths.insert(file.path)
            let url = URL(fileURLWithPath: file.path)
            let ext = url.pathExtension.lowercased()
            guard MediaFileTypes.extensions.contains(ext) else { continue }
            guard !MediaFileTypes.partialDownloadExtensions.contains(ext) else { continue }
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            guard !blockedFingerprints.contains(Self.fingerprint(for: file)) else {
                candidates[file.path] = nil
                continue
            }

            if let candidate = candidates[file.path], candidate.size == file.size {
                if now.timeIntervalSince(candidate.firstSeenAt) >= Self.stabilityInterval {
                    ready.append(file)
                    candidates[file.path] = nil
                }
                // else: stable but too soon; keep waiting on the same entry.
            } else {
                // New file, or its size moved: (re)start the stability clock.
                candidates[file.path] = Candidate(size: file.size, firstSeenAt: now)
            }
        }

        // A file that vanished mid-wait must not linger as a candidate.
        candidates = candidates.filter { seenPaths.contains($0.key) }
        return ready
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./script/run_tests.sh`, 56 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/MediaFileTypes.swift Sources/Services/WatchFolderScanEngine.swift Tests/WhisperDeskTests/WatchFolderTests.swift
git commit -m "Add watch-folder scan engine with stability gate"
```

---

### Task 12: WatchFolderLedger

**Files:**
- Create: `Sources/Services/WatchFolderLedger.swift`
- Test: `Tests/WhisperDeskTests/WatchFolderTests.swift` (append)

- [ ] **Step 1: Write the failing tests** (append)

```swift
@MainActor
struct WatchFolderLedgerTests {
    private func makeBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperdesk-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func recordsAndPersists() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let ledger = WatchFolderLedger(baseURL: base)
        ledger.record("/w/a.mp4|1|2.0", outcome: .success)
        ledger.record("/w/b.mp4|3|4.0", outcome: .failure)
        #expect(ledger.contains("/w/a.mp4|1|2.0"))

        let reloaded = WatchFolderLedger(baseURL: base)
        #expect(reloaded.contains("/w/a.mp4|1|2.0"))
        #expect(reloaded.contains("/w/b.mp4|3|4.0"))
    }

    @Test func changedFingerprintIsNotContained() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let ledger = WatchFolderLedger(baseURL: base)
        ledger.record("/w/a.mp4|1|2.0", outcome: .success)
        // Same path, new size/mtime: a re-encoded file legitimately re-runs.
        #expect(!ledger.contains("/w/a.mp4|99|2.0"))
    }

    @Test func pruneDropsEntriesForMissingFiles() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let ledger = WatchFolderLedger(baseURL: base)
        ledger.record("/w/gone.mp4|1|2.0", outcome: .success)
        ledger.record("/w/kept.mp4|1|2.0", outcome: .success)
        ledger.prune(fileExists: { $0 == "/w/kept.mp4" })
        #expect(!ledger.contains("/w/gone.mp4|1|2.0"))
        #expect(ledger.contains("/w/kept.mp4|1|2.0"))
    }

    @Test func pathExtractionSurvivesPipesInNames() {
        #expect(WatchFolderLedger.path(fromFingerprint: "/w/we|ird.mp4|1|2.0") == "/w/we|ird.mp4")
    }

    @Test func clearEmptiesEverything() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let ledger = WatchFolderLedger(baseURL: base)
        ledger.record("/w/a.mp4|1|2.0", outcome: .success)
        ledger.clear()
        #expect(!ledger.contains("/w/a.mp4|1|2.0"))
        #expect(!WatchFolderLedger(baseURL: base).contains("/w/a.mp4|1|2.0"))
    }
}
```

- [ ] **Step 2: Run to verify failure** — build error, `WatchFolderLedger` not defined.

- [ ] **Step 3: Implement** — `Sources/Services/WatchFolderLedger.swift`:

```swift
import Foundation

/// Remembers which watch-folder files have already reached a terminal
/// outcome, so scans never re-ingest them (spec §2.4). Keyed by the same
/// path|size|mtime fingerprint jobs use, so replacing a file re-runs it.
@MainActor
final class WatchFolderLedger {
    enum Outcome: String, Codable {
        case success
        case failure
    }

    private var entries: [String: Outcome]
    private let fileURL: URL

    init(baseURL: URL? = nil) {
        let resolvedBase = baseURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = resolvedBase.appendingPathComponent("WhisperDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("watch-ledger.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Outcome].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    var fingerprints: Set<String> {
        Set(entries.keys)
    }

    func contains(_ fingerprint: String) -> Bool {
        entries[fingerprint] != nil
    }

    func record(_ fingerprint: String, outcome: Outcome) {
        entries[fingerprint] = outcome
        persist()
    }

    func prune(fileExists: (String) -> Bool) {
        let before = entries.count
        entries = entries.filter { fileExists(Self.path(fromFingerprint: $0.key)) }
        if entries.count != before {
            persist()
        }
    }

    func clear() {
        entries = [:]
        persist()
    }

    /// The fingerprint is "path|size|mtime"; the path itself may contain
    /// pipes, so strip exactly the two trailing components.
    static func path(fromFingerprint fingerprint: String) -> String {
        fingerprint.components(separatedBy: "|").dropLast(2).joined(separator: "|")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./script/run_tests.sh`, 61 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/WatchFolderLedger.swift Tests/WhisperDeskTests/WatchFolderTests.swift
git commit -m "Add watch-folder ledger with prune and pipe-safe paths"
```

---

### Task 13: Watch-folder settings storage

**Files:**
- Modify: `Sources/Models/AppSettingsStore.swift` (published properties block, `init`, `save()`)

- [ ] **Step 1: Add published properties** (with the other toggles, ~line 250):

```swift
    @Published var watchFolderEnabled: Bool { didSet { save() } }
    @Published var watchFolderPath: String { didSet { save() } }
    @Published var watchFolderProfile: JobSettingsOverrides { didSet { save() } }
```

- [ ] **Step 2: Load in init** (with the other reads):

```swift
        watchFolderEnabled = defaults.bool(forKey: "watchFolderEnabled")
        watchFolderPath = defaults.string(forKey: "watchFolderPath") ?? ""
        if let data = defaults.data(forKey: "watchFolderProfile"),
           let profile = try? JSONDecoder().decode(JobSettingsOverrides.self, from: data) {
            watchFolderProfile = profile
        } else {
            watchFolderProfile = JobSettingsOverrides()
        }
```

- [ ] **Step 3: Persist in save()** (with the other writes):

```swift
        defaults.set(watchFolderEnabled, forKey: "watchFolderEnabled")
        defaults.set(watchFolderPath, forKey: "watchFolderPath")
        if let data = try? JSONEncoder().encode(watchFolderProfile) {
            defaults.set(data, forKey: "watchFolderProfile")
        }
```

- [ ] **Step 4: Run tests and build** — `./script/run_tests.sh` (61 pass), `swift build` clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/AppSettingsStore.swift
git commit -m "Store watch-folder settings and profile"
```

---

### Task 14: WatchFolderService and AppModel ingestion

**Files:**
- Create: `Sources/Services/WatchFolderService.swift`
- Modify: `Sources/Stores/AppModel.swift` (init, ingestion, terminal-state ledger writes, sidecar guard)

- [ ] **Step 1: Create the service** — `Sources/Services/WatchFolderService.swift`:

```swift
import AppKit
import Foundation

/// Watches one folder and periodically reports files ready to ingest.
/// Detection strategy (spec §2.2): a kqueue DispatchSource on the folder is
/// the low-latency hint, a 60-second timer plus wake/launch scans are the
/// truth. scan() is idempotent, so redundant triggers are free.
@MainActor
final class WatchFolderService {
    static let rescanInterval: TimeInterval = 60

    private var engine = WatchFolderScanEngine()
    private var folderDescriptor: CInt = -1
    private var folderSource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private(set) var watchedPath: String?
    /// Set when the folder cannot be read; shown in Settings (spec errors).
    private(set) var lastError: String?

    /// Fingerprints that must not be ingested (ledger + all existing jobs).
    var blockedFingerprints: () -> Set<String> = { [] }
    /// Called with files that passed every scan rule.
    var onFilesReady: ([URL]) -> Void = { _ in }
    /// Lets the ledger prune entries for files that vanished.
    var onScanCompleted: (_ existingPaths: Set<String>) -> Void = { _ in }

    func start(path: String) {
        stop()
        watchedPath = path
        lastError = nil

        folderDescriptor = open(path, O_EVTONLY)
        if folderDescriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: folderDescriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scan() }
            }
            source.setCancelHandler { [descriptor = folderDescriptor] in
                close(descriptor)
            }
            source.resume()
            folderSource = source
        } else {
            lastError = "Could not open the watch folder. Check that it exists and is readable."
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.scan() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.scan() }
        }
        scan()
    }

    func stop() {
        folderSource?.cancel()
        folderSource = nil
        folderDescriptor = -1
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        watchedPath = nil
    }

    func scan() {
        guard let watchedPath else { return }
        let folderURL = URL(fileURLWithPath: watchedPath, isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: keys, options: []
        ) else {
            // Do not spin or tear down: the folder may be a briefly
            // unmounted volume. The timer keeps trying; Settings shows this.
            lastError = "The watch folder could not be read."
            return
        }
        lastError = nil

        let observations: [FileObservation] = contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }
            return FileObservation(
                path: url.path,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            )
        }

        let ready = engine.filesReadyToIngest(
            observations: observations,
            now: Date(),
            blockedFingerprints: blockedFingerprints()
        )
        onScanCompleted(Set(observations.map(\.path)))
        if !ready.isEmpty {
            onFilesReady(ready.map { URL(fileURLWithPath: $0.path) })
        }
    }
}
```

- [ ] **Step 2: Wire into AppModel**

Add stored properties:

```swift
    let watchFolderService = WatchFolderService()
    private let watchLedger = WatchFolderLedger()
```

At the end of `init()`:

```swift
        configureWatchFolder()
        if settings.watchFolderEnabled && !settings.watchFolderPath.isEmpty {
            watchFolderService.start(path: settings.watchFolderPath)
        }
```

Add the watch-folder section:

```swift
    // MARK: - Watch folder

    private func configureWatchFolder() {
        watchFolderService.blockedFingerprints = { [weak self] in
            guard let self else { return [] }
            // Ledger entries plus every job's fingerprint, any status
            // (spec §2.3 rule 4): canceled or manual jobs block too.
            return self.watchLedger.fingerprints.union(self.jobs.map(\.sourceFingerprint))
        }
        watchFolderService.onScanCompleted = { [weak self] existingPaths in
            self?.watchLedger.prune(fileExists: { existingPaths.contains($0) })
        }
        watchFolderService.onFilesReady = { [weak self] urls in
            self?.ingestWatchFolderFiles(urls)
        }
    }

    /// Called from Settings when the toggle or path changes.
    func restartWatchFolder() {
        watchFolderService.stop()
        if settings.watchFolderEnabled && !settings.watchFolderPath.isEmpty {
            watchFolderService.start(path: settings.watchFolderPath)
        }
    }

    func clearWatchHistory() {
        watchLedger.clear()
    }

    /// Ingest deliberately does NOT go through enqueueJob: that clears
    /// queuePaused (spec §2.3/2.6 — arriving files must not override an
    /// explicit stop), and ignores autoStartAddedJobs, which governs
    /// interactive adds only.
    private func ingestWatchFolderFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.origin = .watchFolder
            job.overrides = settings.watchFolderProfile
            job.orderIndex = QueueOrdering.indexForWatchAdd(existing: jobs.map(\.orderIndex))
            job.status = .queued
            job.progress = JobProgress(stage: .queued, detail: "Waiting in queue.", fraction: nil)
            job.log = "Picked up from the watch folder: \(url.path(percentEncoded: false)).\n"
            jobs.append(job)
            persistJob(job.id)
        }
        processQueue()
    }

    /// Terminal-state bookkeeping for watch jobs (spec §2.4): success and
    /// failure are recorded; cancel is not — the canceled job itself blocks
    /// re-ingest while it exists, and deleting it means "do it over".
    private func recordWatchOutcome(for id: UUID, success: Bool) {
        guard let job = jobs.first(where: { $0.id == id }), job.origin == .watchFolder else { return }
        watchLedger.record(job.sourceFingerprint, outcome: success ? .success : .failure)
    }
```

- [ ] **Step 3: Call recordWatchOutcome at terminal states**

- In `startTranscriptionNow`'s task, in the no-translation completion branch (after `autoExportSidecars(for: jobID)`): `recordWatchOutcome(for: jobID, success: true)`
- In `finishTranslation(_:summary:for:)`, after `autoExportSidecars(for: id)`: `recordWatchOutcome(for: id, success: true)`
- In `markFailed(_:message:)`, at the end: `recordWatchOutcome(for: id, success: false)`
- `markCanceled`: no call (deliberate).
- Also in the skip-transcription path when a watch job turns out already done: after `appendLog("Skipped transcription…")`, add `recordWatchOutcome(for: jobID, success: true)` — harmless for manual jobs (guarded by origin).

- [ ] **Step 4: Implicit sidecars for watch jobs**

In `autoExportSidecars(for:)` change the guard to:

```swift
        guard let job = jobs.first(where: { $0.id == id }),
              settings.autoExportSidecar || job.origin == .watchFolder
        else { return }
```

- [ ] **Step 5: Run tests and build** — `./script/run_tests.sh` (61 pass), `swift build` clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/Services/WatchFolderService.swift Sources/Stores/AppModel.swift
git commit -m "Ingest watch-folder files into the queue with ledger bookkeeping"
```

---

### Task 15: Watch-folder Settings UI

**Files:**
- Modify: `Sources/Views/SettingsView.swift`
- Modify: `Sources/Views/JobSettingsOverridesView.swift` (no change expected — reused as-is)

- [ ] **Step 1: Add a Watch Folder section**

In `SettingsView` (inside its Form, after the existing automation/export toggles — match surrounding style), add:

```swift
                Section("Watch Folder") {
                    Toggle("Watch a folder for new videos", isOn: Binding(
                        get: { model.settings.watchFolderEnabled },
                        set: { model.settings.watchFolderEnabled = $0; model.restartWatchFolder() }
                    ))
                    .help("Files dropped into the folder are queued, transcribed, and translated automatically; subtitles are saved next to each video")

                    if model.settings.watchFolderEnabled {
                        HStack {
                            Text(model.settings.watchFolderPath.isEmpty ? "No folder chosen" : model.settings.watchFolderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(model.settings.watchFolderPath.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button("Choose…") { chooseWatchFolder() }
                        }

                        Button("Folder Settings…") { isEditingWatchProfile = true }
                            .help("Language, model, and translation settings applied to every file this folder picks up")

                        if watchFolderNeedsAPIKeyWarning {
                            Label(
                                "Files will be transcribed but not translated until a translation API key is added.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        if let error = model.watchFolderService.lastError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button("Clear Watch History") { model.clearWatchHistory() }
                            .help("Forget which files were already processed, so everything in the folder is picked up again")
                    }
                }
```

Supporting pieces on the view:

```swift
    @State private var isEditingWatchProfile = false

    private var watchFolderNeedsAPIKeyWarning: Bool {
        // Spec §2.1: the promise is *translated* sidecars — surface the
        // missing key before bedtime, not at breakfast.
        let autoTranslate = model.settings.watchFolderProfile.autoTranslate
            ?? model.settings.autoTranslateAfterTranscription
        return autoTranslate && model.settings.currentTranslationAPIKey.isEmpty
    }

    private func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.watchFolderPath = url.path
            model.restartWatchFolder()
        }
    }
```

And the sheet (on the Form or outer container):

```swift
        .sheet(isPresented: $isEditingWatchProfile) {
            JobSettingsOverridesView(
                title: "Watch Folder Settings",
                settings: model.settings,
                overrides: model.settings.watchFolderProfile
            ) { model.settings.watchFolderProfile = $0 }
        }
```

(If `SettingsView` currently receives `settings` rather than `model`, pass `model: AppModel` through from the App scene — check `WhisperDeskApp.swift` and adjust the initializer accordingly.)

- [ ] **Step 2: Build and verify manually**

`swift build`, then run: enable the watch folder, point it at an empty test folder, set the profile target to Vietnamese, copy a small video in. Within ~65s a queued job must appear, run, and write sidecars next to the file. Copy the same file again (same mtime) — nothing should happen. `touch` it — it should re-run.

- [ ] **Step 3: Run tests** — `./script/run_tests.sh`, 61 pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Views/SettingsView.swift Sources/Views/JobSettingsOverridesView.swift Sources/App/WhisperDeskApp.swift
git commit -m "Add watch-folder settings with profile editor and warnings"
```

---

### Task 16: Sleep prevention while processing

**Files:**
- Modify: `Sources/Stores/AppModel.swift`

- [ ] **Step 1: Implement the activity assertion**

Add a property and helper:

```swift
    /// Held while any job is running so overnight batches survive idle sleep
    /// and App Nap (spec §2.7). Display sleep stays allowed.
    private var processingActivity: NSObjectProtocol?

    private func updateProcessingActivity() {
        if activeJobID != nil {
            guard processingActivity == nil else { return }
            processingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Processing transcription queue"
            )
        } else if let activity = processingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            processingActivity = nil
        }
    }
```

Call `updateProcessingActivity()`:
- in `startTranscriptionNow`, right after `activeJobID = jobID`
- in `startTranslationNow`, right after `activeJobID = jobID`
- at the very end of `processQueue()` (covers the drained/paused cases after a task completes)

- [ ] **Step 2: Build and verify**

`swift build` clean. Manual check: start a long transcription, run `pmset -g assertions | grep -i whisper` in a terminal — a `PreventUserIdleSystemSleep` assertion from WhisperDesk must be listed while running and gone when idle.

- [ ] **Step 3: Run tests** — `./script/run_tests.sh`, 61 pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Stores/AppModel.swift
git commit -m "Hold a sleep assertion while jobs are processing"
```

---

## Phase 3 — Burn-in export

### Task 17: burningIn status and stage

**Files:**
- Modify: `Sources/Models/JobStatus.swift`
- Modify: `Sources/Views/StatusStyle.swift`
- Test: `Tests/WhisperDeskTests/JobStoreTests.swift` (extend one test)

- [ ] **Step 1: Extend the interrupted-on-load test**

In `JobStoreTests.runningJobsAreMarkedInterruptedOnLoad`, add a burningIn job and bump the counts:

```swift
        store.saveJob(try makeJob(status: .transcribing))
        store.saveJob(try makeJob(status: .translating))
        store.saveJob(try makeJob(status: .burningIn))
        store.saveJob(try makeJob(status: .transcriptionComplete))
        store.flush()

        let reloaded = JobStore(baseURL: baseURL).loadJobs()
        #expect(reloaded.count == 4)
        #expect(!reloaded.contains { $0.status.isRunning }, "Running statuses must be sanitized on load")
        #expect(reloaded.filter { $0.status == .canceled }.count == 3)
        #expect(reloaded.filter { $0.status == .transcriptionComplete }.count == 1)
```

- [ ] **Step 2: Run to verify failure** — build error, `.burningIn` not defined.

- [ ] **Step 3: Implement**

`Sources/Models/JobStatus.swift` — add to `JobStatus`:

```swift
    case burningIn
```

with `label` case `return "Burning In"`, `systemImage` case `return "film"`, and — the line the crash-recovery guarantee hangs on (spec §3.4):

```swift
    var isRunning: Bool {
        self == .transcribing || self == .translating || self == .burningIn
    }
```

Add to `JobStage`: `case burningIn` with label `"Burning in subtitles"`.

`Sources/Views/StatusStyle.swift` — add `.burningIn` to the tint switch (use `.orange`, matching the "actively working" statuses; check the existing cases and match the pattern).

- [ ] **Step 4: Run to verify pass** — `./script/run_tests.sh`, 61 tests pass (same count; one test grew).

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/JobStatus.swift Sources/Views/StatusStyle.swift Tests/WhisperDeskTests/JobStoreTests.swift
git commit -m "Add burningIn status covered by running-state recovery"
```

---

### Task 18: BurnInService pure parts — args, style, progress, guards

**Files:**
- Create: `Sources/Services/BurnInService.swift`
- Test: `Tests/WhisperDeskTests/BurnInTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperDesk

struct BurnInArgumentTests {
    @Test func argumentsFollowSpecCommandShape() {
        let args = BurnInService.makeArguments(
            source: URL(fileURLWithPath: "/videos/movie.mkv"),
            subtitleFile: URL(fileURLWithPath: "/tmp/work/subs.srt"),
            forceStyle: "FontSize=20,MarginV=25,BorderStyle=3",
            output: URL(fileURLWithPath: "/videos/movie.burned.mp4")
        )
        #expect(args.first == "-y")
        #expect(args.contains("-nostdin"))
        #expect(args.contains("h264_videotoolbox"))
        #expect(args.contains("+faststart"))
        #expect(args.last == "/videos/movie.burned.mp4")
        let vfIndex = try! #require(args.firstIndex(of: "-vf"))
        #expect(args[vfIndex + 1] == "subtitles=filename=/tmp/work/subs.srt:force_style='FontSize=20,MarginV=25,BorderStyle=3'")
    }

    // Path safety (spec §3.2): the subtitle path we generate must never
    // contain filter metacharacters, since we do not escape it.
    @Test func workingSubtitlePathIsFilterSafe() {
        let url = BurnInService.makeWorkingSubtitleURL()
        for character in ":'[],;" {
            #expect(!url.path.contains(character), "temp path must not contain \(character)")
        }
        #expect(url.lastPathComponent == "subs.srt")
    }

    @Test func outputGuardRefusesSourcePath() {
        #expect(throws: BurnInService.BurnInError.self) {
            try BurnInService.validateOutput(
                source: URL(fileURLWithPath: "/v/movie.mp4"),
                output: URL(fileURLWithPath: "/v/../v/movie.mp4")
            )
        }
    }

    @Test func outputGuardAcceptsDistinctPath() throws {
        try BurnInService.validateOutput(
            source: URL(fileURLWithPath: "/v/movie.mp4"),
            output: URL(fileURLWithPath: "/v/movie.burned.mp4")
        )
    }

    @Test func everyTextSizeYieldsBoxedStyle() {
        for size in BurnInService.TextSize.allCases {
            let style = BurnInService.forceStyle(for: size)
            #expect(style.contains("BorderStyle=3"), "box background is non-negotiable for legibility")
            #expect(style.contains("FontSize="))
            #expect(style.contains("MarginV="))
        }
    }
}

struct BurnInProgressParsingTests {
    @Test func parsesStandardProgressLine() {
        let line = "frame= 2160 fps=120 q=-0.0 size=  102400KiB time=00:01:30.05 bitrate=9300.1kbits/s speed=4.1x"
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: line) == 90.05)
    }

    @Test func parsesHoursComponent() {
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: "time=01:02:03.50 bitrate=...") == 3723.5)
    }

    @Test func rejectsMalformedLines() {
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: "time=N/A bitrate=N/A") == nil)
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: "no timestamps here") == nil)
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: "time=12:34") == nil)
    }
}

struct BurnInPreflightParsingTests {
    @Test func detectsSubtitlesFilter() {
        let output = """
        Filters:
         ... scale            V->V  Scale the input video size...
         ... subtitles        V->V  Render text subtitles onto input video...
        """
        #expect(BurnInService.hasSubtitlesFilter(inFiltersOutput: output))
    }

    @Test func minimalBuildLacksFilter() {
        // Spec §3.1: a build without libass must be caught up front, not
        // forty minutes into an encode.
        #expect(!BurnInService.hasSubtitlesFilter(inFiltersOutput: "Filters:\n ... scale V->V ..."))
        #expect(!BurnInService.hasSubtitlesFilter(inFiltersOutput: ""))
    }
}
```

- [ ] **Step 2: Run to verify failure** — build error, `BurnInService` not defined.

- [ ] **Step 3: Implement** — create `Sources/Services/BurnInService.swift` (pure parts only; execution comes in Task 19):

```swift
import Foundation

/// Renders subtitles into an MP4 with ffmpeg (spec §3). ffmpeg is an
/// opt-in dependency for this feature alone; everything here degrades to a
/// disabled button when it is missing.
struct BurnInService {
    enum BurnInError: LocalizedError {
        case outputWouldReplaceSource
        case ffmpegFailed(String)

        var errorDescription: String? {
            switch self {
            case .outputWouldReplaceSource:
                return "The output file would replace the source video. Choose a different name."
            case .ffmpegFailed(let message):
                return message
            }
        }
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        var label: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    /// libass sizes against a default PlayResY of 384, so these values are
    /// resolution-independent.
    static func forceStyle(for size: TextSize) -> String {
        switch size {
        case .small: return "FontSize=14,MarginV=18,BorderStyle=3"
        case .medium: return "FontSize=20,MarginV=22,BorderStyle=3"
        case .large: return "FontSize=27,MarginV=26,BorderStyle=3"
        }
    }

    /// A fresh temp directory whose path contains no libass filter
    /// metacharacters; the SRT is always written here under a fixed name so
    /// user-controlled text never reaches the filter string (spec §3.2).
    static func makeWorkingSubtitleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperdesk-burnin-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("subs.srt")
    }

    static func validateOutput(source: URL, output: URL) throws {
        if source.standardizedFileURL.path == output.standardizedFileURL.path {
            throw BurnInError.outputWouldReplaceSource
        }
    }

    static func makeArguments(source: URL, subtitleFile: URL, forceStyle: String, output: URL) -> [String] {
        [
            "-y", "-nostdin",
            "-i", source.path,
            "-vf", "subtitles=filename=\(subtitleFile.path):force_style='\(forceStyle)'",
            "-c:v", "h264_videotoolbox", "-q:v", "60",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            output.path,
        ]
    }

    /// Parses "time=HH:MM:SS.cc" from an ffmpeg stderr stats line.
    static func parseProgressSeconds(fromStderrLine line: String) -> Double? {
        guard let range = line.range(of: #"time=(\d+):(\d{2}):(\d{2}(?:\.\d+)?)"#, options: .regularExpression) else {
            return nil
        }
        let value = line[range].dropFirst("time=".count)
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Preflight half 2 (spec §3.1): the filter list must include
    /// `subtitles`, or this build lacks libass and would fail mid-encode.
    static func hasSubtitlesFilter(inFiltersOutput output: String) -> Bool {
        output.contains(" subtitles ")
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./script/run_tests.sh`, 71 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/BurnInService.swift Tests/WhisperDeskTests/BurnInTests.swift
git commit -m "Add burn-in argument construction, progress parsing, and guards"
```

---

### Task 19: BurnInService execution and preflight

**Files:**
- Modify: `Sources/Services/BurnInService.swift`

- [ ] **Step 1: Add preflight execution** (append inside `BurnInService`):

```swift
    struct PreflightResult {
        let available: Bool
        let message: String?
    }

    /// Runs both preflight checks (spec §3.1). Not cached here — AppModel
    /// caches the result and exposes a Recheck, because "just installed
    /// ffmpeg" is exactly when a stale probe hurts.
    static func preflight() async -> PreflightResult {
        let output = await runCapturingOutput(arguments: ["ffmpeg", "-hide_banner", "-filters"])
        guard let output else {
            return PreflightResult(available: false, message: "ffmpeg was not found. Install it with: brew install ffmpeg")
        }
        guard hasSubtitlesFilter(inFiltersOutput: output) else {
            return PreflightResult(available: false, message: "This ffmpeg build lacks the subtitles filter (libass). Reinstall with: brew install ffmpeg")
        }
        return PreflightResult(available: true, message: nil)
    }

    /// Runs a command via /usr/bin/env with tool paths; nil if launch fails
    /// or it exits non-zero.
    private static func runCapturingOutput(arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.environment = ProcessEnvironment.withToolPaths()
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
```

- [ ] **Step 2: Add the encode entry point** (append inside `BurnInService`):

```swift
    /// Writes the SRT to a safe temp path, runs ffmpeg, reports progress from
    /// stderr, and cleans up. On any failure or cancellation the partial
    /// output and the temp directory are removed (spec §3.2/§3.4).
    @MainActor
    func burnIn(
        source: URL,
        segments: [TranscriptionSegment],
        textSize: TextSize,
        output: URL,
        durationSeconds: Double,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws {
        try Self.validateOutput(source: source, output: output)

        let subtitleURL = Self.makeWorkingSubtitleURL()
        let workingDirectory = subtitleURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        try SubtitleWriter.writeSRT(segments: segments, to: subtitleURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = ProcessEnvironment.withToolPaths()
        process.arguments = ["ffmpeg"] + Self.makeArguments(
            source: source,
            subtitleFile: subtitleURL,
            forceStyle: Self.forceStyle(for: textSize),
            output: output
        )

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        // Collect a stderr tail for error reporting while scanning lines for
        // progress stamps.
        let collector = StderrCollector()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            collector.append(text)
            if durationSeconds > 0, let seconds = Self.parseProgressSeconds(fromStderrLine: text) {
                let fraction = min(seconds / durationSeconds, 0.999)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        progress(fraction, String(format: "Rendering… %.0f%%", fraction * 100))
                    }
                }
            }
        }

        try await withTaskCancellationHandler {
            try process.run()
            if Task.isCancelled { process.terminate() }
            _ = await process.waitForTermination()
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            if Task.isCancelled {
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            }
            guard process.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: output)
                throw BurnInError.ffmpegFailed(collector.tail())
            }
        } onCancel: {
            process.terminate()
        }
    }
```

And the small thread-safe collector at file scope:

```swift
/// Accumulates ffmpeg stderr across the readability handler's background
/// queue; keeps only a bounded tail for error messages.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        if text.count > 8000 {
            text = String(text.suffix(4000))
        }
        lock.unlock()
    }

    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        let lines = text.split(separator: "\n").suffix(6)
        return lines.isEmpty ? "ffmpeg failed with no error output." : lines.joined(separator: "\n")
    }
}
```

Notes for the implementer:
- `process.waitForTermination()` already exists as an extension used by `TranscriptionService` — check `Sources/Services/TranscriptionService.swift` / `Sources/Support` for where `waitForTermination` is defined. If it is `private`, move it to internal scope in a shared location rather than duplicating it.
- `SubtitleWriter.writeSRT(segments:to:)` already exists (used by `autoExportSidecars`).

- [ ] **Step 3: Build and run tests** — `swift build` clean; `./script/run_tests.sh`, 71 pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Services/BurnInService.swift Sources/Services/TranscriptionService.swift
git commit -m "Add ffmpeg burn-in execution with preflight and cancellation"
```

---

### Task 20: AppModel burn-in orchestration

**Files:**
- Modify: `Sources/Stores/AppModel.swift`

- [ ] **Step 1: State and preflight**

```swift
    // With the other @Published properties:
    @Published var isShowingBurnInSheet = false
    /// nil = not yet checked; cached until Recheck (spec §3.1).
    @Published var burnInPreflight: BurnInService.PreflightResult?

    private let burnInService = BurnInService()

    func checkBurnInAvailability() {
        Task {
            burnInPreflight = await BurnInService.preflight()
        }
    }

    var canBurnIn: Bool {
        guard let job = currentJob else { return false }
        return !job.transcriptSegments.isEmpty && !isProcessing && !job.status.isRunning
    }
```

- [ ] **Step 2: The start function**

```swift
    struct BurnInRequest {
        let document: BurnInDocument
        let textSize: BurnInService.TextSize
        let output: URL
    }

    enum BurnInDocument: String, CaseIterable, Identifiable {
        case original
        case translation
        case bilingual

        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "Original transcript"
            case .translation: return "Translation"
            case .bilingual: return "Bilingual captions"
            }
        }
    }

    func startBurnIn(_ request: BurnInRequest) {
        guard let job = currentJob, canBurnIn else { return }
        let jobID = job.id

        let segments: [TranscriptionSegment]
        switch request.document {
        case .original:
            segments = applyingIntro(job.transcriptSegments, format: .srt, job: job)
        case .translation:
            segments = applyingIntro(job.translatedSegments, format: .srt, job: job)
        case .bilingual:
            segments = applyingIntro(
                bilingualSegments(transcript: job.transcriptSegments, translated: job.translatedSegments),
                format: .srt,
                job: job
            )
        }
        guard !segments.isEmpty else { return }

        // Restore whichever completed state the job had before burn-in.
        let restoredStatus: JobStatus = job.translatedSegments.isEmpty
            ? .transcriptionComplete
            : .translationComplete

        updateJob(jobID) { job in
            job.status = .burningIn
            job.progress = JobProgress(stage: .burningIn, detail: "Starting ffmpeg.", fraction: 0)
            job.log += "Burning \(request.document.label.lowercased()) into \(request.output.lastPathComponent).\n"
        }

        activeJobID = jobID
        updateProcessingActivity()
        activeTask = Task {
            do {
                let duration = await Self.assetDurationSeconds(for: job.sourceURL)
                try await burnInService.burnIn(
                    source: job.sourceURL,
                    segments: segments,
                    textSize: request.textSize,
                    output: request.output,
                    durationSeconds: duration
                ) { [weak self] fraction, detail in
                    self?.updateJob(jobID, debouncePersist: true) { job in
                        job.progress = JobProgress(stage: .burningIn, detail: detail, fraction: fraction)
                    }
                }
                updateJob(jobID) { job in
                    job.status = restoredStatus
                    job.progress = JobProgress(stage: .complete, detail: "Burned-in video saved.", fraction: 1)
                    job.log += "Saved burned-in video to \(request.output.path(percentEncoded: false)).\n"
                }
                notifyJobFinished(jobID)
            } catch is CancellationError {
                updateJob(jobID) { job in
                    job.status = restoredStatus
                    job.progress = JobProgress(stage: .canceled, detail: "Burn-in canceled.", fraction: nil)
                    job.log += "Burn-in canceled; partial output deleted.\n"
                }
            } catch {
                // Burn-in failure does not invalidate the finished transcript
                // or translation — restore the completed status, log loudly.
                updateJob(jobID) { job in
                    job.status = restoredStatus
                    job.progress = JobProgress(stage: .complete, detail: "Burn-in failed: \(error.localizedDescription)", fraction: nil)
                    job.log += "Burn-in failed: \(error.localizedDescription)\n"
                }
                presentExportError("Burn-in failed: \(error.localizedDescription)")
            }
            activeTask = nil
            activeJobID = nil
            processQueue()
        }
    }

    private nonisolated static func assetDurationSeconds(for url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        return duration.seconds.isFinite ? duration.seconds : 0
    }
```

Add `import AVFoundation` at the top of `AppModel.swift`.

Note: `cancelActiveJob()` already terminates via `activeTask?.cancel()` and stamps `.canceled`; for burn-in the catch block above overwrites that stamp with `restoredStatus` + canceled progress, which is the desired end state (the transcript is still valid). Also note `jobNeedsWork` naturally returns false for these restored statuses — burn-in never auto-queues (spec §3.4).

- [ ] **Step 3: Build and run tests** — `swift build`, `./script/run_tests.sh`, 71 pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Stores/AppModel.swift
git commit -m "Orchestrate burn-in through the job machinery"
```

---

### Task 21: Burn-in UI

**Files:**
- Create: `Sources/Views/BurnInOptionsView.swift`
- Modify: `Sources/Views/ExportOptionsView.swift`, `Sources/Views/SidebarView.swift`, `Sources/Views/ContentView.swift`

- [ ] **Step 1: Create the sheet** — `Sources/Views/BurnInOptionsView.swift`:

```swift
import AppKit
import SwiftUI

/// Burn-in options (spec §3.4 entry point): pick the document, text size,
/// and destination, then hand off to AppModel.startBurnIn.
struct BurnInOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var document: AppModel.BurnInDocument = .translation
    @AppStorage("burnInTextSize") private var textSizeRaw = BurnInService.TextSize.medium.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Burn In Subtitles")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            Form {
                if model.burnInPreflight?.available != true {
                    Section {
                        Label(
                            model.burnInPreflight?.message ?? "Checking for ffmpeg…",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        Button("Recheck") { model.checkBurnInAvailability() }
                    }
                }
                Picker("Subtitles", selection: $document) {
                    ForEach(availableDocuments) { doc in
                        Text(doc.label).tag(doc)
                    }
                }
                Picker("Text size", selection: $textSizeRaw) {
                    ForEach(BurnInService.TextSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
            } 
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Text("Re-encodes the whole video — takes a while.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseDestinationAndStart() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.burnInPreflight?.available != true)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if model.burnInPreflight == nil { model.checkBurnInAvailability() }
            if !availableDocuments.contains(document) {
                document = availableDocuments.first ?? .original
            }
        }
    }

    private var availableDocuments: [AppModel.BurnInDocument] {
        var docs: [AppModel.BurnInDocument] = [.original]
        if !model.translatedSegments.isEmpty {
            docs.append(.translation)
            docs.append(.bilingual)
        }
        return docs
    }

    private func chooseDestinationAndStart() {
        guard let source = model.selectedVideoURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".burned.mp4"
        panel.directoryURL = source.deletingLastPathComponent()
        let size = BurnInService.TextSize(rawValue: textSizeRaw) ?? .medium
        let doc = document
        dismiss()
        DispatchQueue.main.async {
            if panel.runModal() == .OK, let output = panel.url {
                model.startBurnIn(AppModel.BurnInRequest(document: doc, textSize: size, output: output))
            }
        }
    }
}
```

- [ ] **Step 2: Entry points**

`ContentView.swift` — add alongside the export sheet:

```swift
        .sheet(isPresented: $model.isShowingBurnInSheet) {
            BurnInOptionsView(model: model)
        }
```

`ExportOptionsView.swift` — in the bottom HStack, before the Cancel button:

```swift
                Button("Burn In Video…") {
                    dismiss()
                    DispatchQueue.main.async {
                        model.isShowingBurnInSheet = true
                    }
                }
```

`SidebarView.contextMenu(for:)` — after "Job Settings…":

```swift
        if !job.transcriptSegments.isEmpty {
            Button {
                model.selectJob(job.id)
                model.isShowingBurnInSheet = true
            } label: {
                Label("Burn In Video…", systemImage: "film")
            }
            .disabled(model.isProcessing || job.status.isRunning)
        }
```

- [ ] **Step 3: Manual verification (requires ffmpeg installed)**

`./script/build_and_run.sh`. On a job with a transcript: context menu → Burn In Video… → Export a short clip. Verify: progress percentage ticks up, the resulting MP4 plays with visible boxed subtitles, cancel mid-encode deletes the partial file, and with ffmpeg missing (`PATH` without it) the sheet shows the install hint and disables Export.

- [ ] **Step 4: Run tests** — `./script/run_tests.sh`, 71 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Views/BurnInOptionsView.swift Sources/Views/ExportOptionsView.swift Sources/Views/SidebarView.swift Sources/Views/ContentView.swift
git commit -m "Add burn-in sheet and entry points"
```

---

### Task 22: Docs and final verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the three features in README.md**

Add a "Automation & export" section (match the README's existing voice) covering:
- Watch folder: enabling it, the per-folder settings, "leave the lid open or connect a display for overnight runs" (spec §2.7), Clear Watch History, and that sidecars appear next to each video.
- Burn-in: requires `brew install ffmpeg` (the only feature that does), where the button lives, output is `<name>.burned.mp4`, HDR sources come out SDR (spec non-goal).
- Queue: drag to reorder, context-menu Move to Top/Bottom, per-job "Job Settings…" overrides.

- [ ] **Step 2: Full verification pass**

```bash
./script/run_tests.sh
```
Expected: 71 tests, 0 failures.

```bash
swift build -c release
```
Expected: clean.

Manual sweep (all three features): drop two files in the watch folder while a manual job is queued → watch jobs run after it; reorder mid-batch; one job with a Vietnamese override; burn-in the result.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document watch folder, burn-in, and queue controls"
```

- [ ] **Step 4: Update the spec status line**

Change `**Status:** Approved, ready for implementation planning` to `**Status:** Implemented on v2-workflow` in the spec, commit:

```bash
git add docs/superpowers/specs/2026-07-26-v2-workflow-automation-design.md
git commit -m "Mark v2 workflow spec as implemented"
```

---

## Post-plan checklist (for the finishing pass)

- All 22 tasks committed; `./script/run_tests.sh` green (expected ~71 tests).
- Push `v2-workflow` and open a draft PR against master (repo: TungSeven30/WhisperDesk).
- Merge-time reminder recorded in the spec (§3.5): when PR #2 (zero-dependency) lands, reword the ffmpeg diagnostics entry to "optional — needed only for burn-in export".
