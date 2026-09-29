import AppKit
import SwiftUI
import Testing

@testable import Cue

private actor EmptyDetailSnapshotDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

/// Gated renders of the real detail pane over an isolated model: temp job
/// store, temp watch ledger, suite defaults, no diagnostics run. Nothing here
/// touches the user's jobs, settings, or Keychain.
///
/// Sizes: the app's minimum window is 1080×720 with a 250 pt sidebar and a
/// ~52 pt toolbar, which leaves the detail pane about 830×668.
///
/// The temp folder name is deterministic per scenario so the (middle-truncated)
/// source path in the header card renders identically between runs; that is
/// what lets a before/after pixel comparison prove Preview-off is unchanged.
@MainActor
struct DetailPaneSnapshotTests {
    static let minPane = CGSize(width: 830, height: 668)
    static let largePane = CGSize(width: 1240, height: 900)

    enum Scenario {
        case ready
        case translated
        case failed
    }

    @MainActor
    struct Fixture {
        let baseURL: URL
        let suiteName: String
        let defaults: UserDefaults
        let model: AppModel

        func cleanUp() {
            model.flushPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
            // `isPlayerVisible` persists to the standard domain of the test
            // process (not the app's); leave it as we found it.
            UserDefaults.standard.removeObject(forKey: "isPlayerVisible")
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    static func sampleSegments(translated: Bool = false) -> [TranscriptionSegment] {
        let source: [(Double, Double, String)] = [
            (0.0, 2.4, "こんにちは、今日は特別なゲストをお迎えしています。"),
            (2.6, 5.1, "まずは自己紹介をお願いします。"),
            (5.3, 9.8, "はい、私は十年前からこの映画の制作に関わってきました。"),
            (10.0, 10.9, "ええと…"),
            (11.2, 21.0, "最初の脚本は全く違う物語でしたが、撮影が始まる直前にすべてを書き直すことになりました。それは本当に大変な時間でした。"),
            (21.4, 24.0, "そのとき何が起きたのですか。"),
        ]
        let english: [String] = [
            "Hello, and welcome. Today we have a very special guest.",
            "Let's start with a short introduction.",
            "Yes, I've worked on this film for ten years.",
            "Well…",
            "The first script was a completely different story, but right before shooting began we had to rewrite everything. It was a truly difficult time.",
            "What happened then?",
        ]
        return source.enumerated().map { index, item in
            TranscriptionSegment(id: index + 1, start: item.0, end: item.1, text: translated ? english[index] : item.2)
        }
    }

    static func makeFixture(
        _ name: String,
        scenario: Scenario,
        previewVisible: Bool,
        expanded: Bool = false,
        playerHeight: Double = 280
    ) async throws -> Fixture {
        let suiteName = "detail-snapshot-\(name)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-detail-snapshot-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: baseURL)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = false
        settings.autoArchiveDays = 0
        settings.whisperBackend = .mlxWhisper
        settings.whisperModel = "mlx-community/whisper-large-v3"
        settings.translationSourceLanguage = "Japanese"
        settings.translationTargetLanguage = "English"
        settings.autoTranslateAfterTranscription = true

        let mediaURL = baseURL.appendingPathComponent("Interview with the Director.mp4")
        FileManager.default.createFile(atPath: mediaURL.path, contents: Data())
        var job = TranscriptionJob(sourceURL: mediaURL, settings: settings)
        job.transcriptSegments = sampleSegments()
        switch scenario {
        case .ready:
            job.status = .transcriptionComplete
            job.progress = JobProgress(stage: .complete, detail: "Transcript ready", fraction: 1)
        case .translated:
            job.status = .translationComplete
            job.progress = JobProgress(stage: .complete, detail: "Translation ready", fraction: 1)
            job.translatedSegments = sampleSegments(translated: true)
        case .failed:
            job.status = .failed
            job.progress = JobProgress(
                stage: .failed,
                detail: "ffmpeg could not read the audio track: Invalid data found when processing input.",
                fraction: nil,
                failedStage: .transcribing
            )
        }
        let store = JobStore(baseURL: baseURL)
        store.saveJob(job)
        store.flush()

        let ledger = WatchFolderLedger(baseURL: baseURL.appendingPathComponent("ledger", isDirectory: true))
        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: baseURL),
            watchLedger: ledger,
            diagnosticsService: EmptyDetailSnapshotDiagnostics()
        )
        await model.hydration()
        model.selectJob(job.id)
        model.isPlayerVisible = previewVisible

        defaults.set(playerHeight, forKey: "playerHeight")
        defaults.set(expanded, forKey: JobSettingsLayout.expandedStorageKey)
        return Fixture(baseURL: baseURL, suiteName: suiteName, defaults: defaults, model: model)
    }

    /// The detail pane exactly as the main window builds it: Appearance
    /// preferences applied at the root, read from the fixture's own suite.
    static func detail(
        _ fixture: Fixture,
        textScale: TextScale = .standard,
        density: ListDensity = .comfortable
    ) -> some View {
        fixture.defaults.set(textScale.rawValue, forKey: DisplayPreferenceKey.textScale)
        fixture.defaults.set(density.rawValue, forKey: DisplayPreferenceKey.listDensity)
        return DetailView(model: fixture.model, playerController: fixture.model.playerController)
            .cueDisplayPreferences()
            .defaultAppStorage(fixture.defaults)
    }

    @discardableResult
    static func capture(
        _ name: String,
        scenario: Scenario,
        previewVisible: Bool,
        expanded: Bool = false,
        playerHeight: Double = 280,
        size: CGSize = minPane,
        textScale: TextScale = .standard,
        density: ListDensity = .comfortable,
        colorScheme: ColorScheme = .light
    ) async throws -> URL? {
        let fixture = try await makeFixture(
            name, scenario: scenario, previewVisible: previewVisible, expanded: expanded, playerHeight: playerHeight)
        defer { fixture.cleanUp() }
        return try await ViewSnapshot.capture(
            detail(fixture, textScale: textScale, density: density),
            name: name,
            size: size,
            colorScheme: colorScheme
        )
    }

    // MARK: - Preview off (must not change with the job-settings card)

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOffLayouts() async throws {
        let small = try await Self.capture("detail-preview-off-min", scenario: .ready, previewVisible: false)
        let large = try await Self.capture("detail-preview-off-large", scenario: .ready, previewVisible: false, size: Self.largePane)
        #expect(small != nil)
        #expect(large != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOffTranslatedAndFailed() async throws {
        let translated = try await Self.capture("detail-preview-off-translated-min", scenario: .translated, previewVisible: false)
        let failed = try await Self.capture("detail-preview-off-failed-min", scenario: .failed, previewVisible: false)
        #expect(translated != nil)
        #expect(failed != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOffLargestTextAndDarkMode() async throws {
        let largest = try await Self.capture(
            "detail-preview-off-largest-min", scenario: .ready, previewVisible: false, textScale: .largest)
        let dark = try await Self.capture(
            "detail-preview-off-dark-min", scenario: .ready, previewVisible: false, colorScheme: .dark)
        #expect(largest != nil)
        #expect(dark != nil)
    }

    // MARK: - Preview on

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOnCollapsed() async throws {
        let small = try await Self.capture("detail-preview-on-min", scenario: .ready, previewVisible: true)
        let large = try await Self.capture("detail-preview-on-large", scenario: .ready, previewVisible: true, size: Self.largePane)
        #expect(small != nil)
        #expect(large != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOnExpanded() async throws {
        let small = try await Self.capture(
            "detail-preview-on-expanded-min", scenario: .ready, previewVisible: true, expanded: true)
        let large = try await Self.capture(
            "detail-preview-on-expanded-large", scenario: .ready, previewVisible: true, expanded: true, size: Self.largePane)
        #expect(small != nil)
        #expect(large != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOnFailedJob() async throws {
        let collapsed = try await Self.capture("detail-preview-on-failed-min", scenario: .failed, previewVisible: true)
        let expanded = try await Self.capture(
            "detail-preview-on-failed-expanded-min", scenario: .failed, previewVisible: true, expanded: true)
        #expect(collapsed != nil)
        #expect(expanded != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOnLargestText() async throws {
        let collapsed = try await Self.capture(
            "detail-preview-on-largest-min", scenario: .ready, previewVisible: true, textScale: .largest)
        let expanded = try await Self.capture(
            "detail-preview-on-largest-expanded-min", scenario: .ready, previewVisible: true, expanded: true, textScale: .largest)
        let failed = try await Self.capture(
            "detail-preview-on-largest-failed-min", scenario: .failed, previewVisible: true, textScale: .largest)
        #expect(collapsed != nil)
        #expect(expanded != nil)
        #expect(failed != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOnDarkMode() async throws {
        let collapsed = try await Self.capture(
            "detail-preview-on-dark-min", scenario: .ready, previewVisible: true, colorScheme: .dark)
        let expanded = try await Self.capture(
            "detail-preview-on-dark-expanded-min", scenario: .ready, previewVisible: true, expanded: true, colorScheme: .dark)
        let failed = try await Self.capture(
            "detail-preview-on-dark-failed-min", scenario: .failed, previewVisible: true, colorScheme: .dark)
        #expect(collapsed != nil)
        #expect(expanded != nil)
        #expect(failed != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOnSmallPlayer() async throws {
        let expanded = try await Self.capture(
            "detail-preview-on-small-player-expanded-min", scenario: .ready, previewVisible: true, expanded: true, playerHeight: 140)
        #expect(expanded != nil)
    }

    /// The denser list preferences are how the transcript regains rows at the
    /// minimum window with the preview on (Comfortable is `detail-preview-on-min`).
    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersPreviewOnAtEachDensity() async throws {
        for density in [ListDensity.compact, .detailed] {
            let url = try await Self.capture(
                "detail-preview-on-\(density.rawValue)-min", scenario: .ready, previewVisible: true, density: density)
            #expect(url != nil)
        }
    }

    // MARK: - Transcript rows per density

    static func sampleWarnings(for segments: [TranscriptionSegment]) -> SubtitleWarnings {
        var list: [SubtitleQualityWarning] = []
        var bySegment: [Int: [SubtitleQualityWarning]] = [:]
        for segment in segments {
            let found = SubtitleWarningCache.compute(segment)
            guard !found.isEmpty else { continue }
            list.append(contentsOf: found)
            bySegment[segment.id] = found
        }
        return SubtitleWarnings(list: list, bySegment: bySegment)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersTranscriptRowsInEveryDensity() async throws {
        let segments = Self.sampleSegments()
        let warnings = Self.sampleWarnings(for: segments)
        for density in ListDensity.allCases {
            let rows = ScrollView {
                TranscriptView(
                    segments: segments,
                    warnings: warnings,
                    activeSegmentID: 2,
                    onEdit: { _, _ in },
                    onSeek: { _ in }
                )
                .padding(20)
            }
            .environment(\.cueListDensity, density)
            let url = try await ViewSnapshot.capture(rows, name: "transcript-rows-\(density.rawValue)", size: CGSize(width: 830, height: 640))
            #expect(url != nil)
        }
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersDetailedTranscriptRowsAtLargestText() async throws {
        let segments = Self.sampleSegments()
        let rows = ScrollView {
            TranscriptView(
                segments: segments,
                warnings: Self.sampleWarnings(for: segments),
                activeSegmentID: 5,
                onEdit: { _, _ in },
                onSeek: { _ in }
            )
            .padding(20)
        }
        .environment(\.cueListDensity, .detailed)
        .environment(\.cueTextScale, TextScale.largest.factor)
        let url = try await ViewSnapshot.capture(rows, name: "transcript-rows-detailed-largest", size: CGSize(width: 830, height: 640))
        #expect(url != nil)
    }
}
