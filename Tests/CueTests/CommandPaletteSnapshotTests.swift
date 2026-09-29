import AppKit
import Combine
import SwiftUI
import Testing

@testable import Cue

private actor EmptyPaletteSnapshotDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

/// Every `AppModel` listens to the process-wide `persistenceDidFail`
/// notification, so a store failure injected by a test running at the same
/// time would raise the "Could Not Save Data" alert over a render. This clears
/// the alert as it arrives and counts how often it did.
@MainActor
private final class StorageErrorGuard {
    private(set) var sightings = 0
    private var subscription: AnyCancellable?

    init(model: AppModel) {
        subscription = model.$persistenceError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak model] _ in
                self?.sightings += 1
                model?.persistenceError = nil
            }
    }
}

/// Gated renders of the palette over the real main window (`ContentView`:
/// sidebar and detail pane behind a dimmed backdrop) on an isolated model:
/// temp job store, temp watch ledger, suite defaults, no diagnostics run.
/// Nothing here touches the user's jobs, settings, or Keychain.
///
/// Jobs are saved in a state the pipeline ignores; the running, queued, and
/// failed statuses are stamped on the in-memory jobs after hydration, so no
/// job can ever reach the transcription pipeline.
///
/// The harness cannot type, hover, or press keys. Those paths are covered by
/// `CommandPaletteControllerTests`; these renders check what the panel looks
/// like, given a query.
///
/// Run this suite by itself with the test runner's `--filter` (as
/// `script/run_tests.sh` ignores arguments) and with the display awake, or
/// `screencapture` cannot capture the window. In a whole-suite gated run,
/// `AppModelDiagnosticsTests.anOlderDiagnosticsRunCannotOverwriteTheNewestResult`
/// can fail while these renders spin the main run loop (its 500 ms settings
/// debounce fires mid-test). It passes alone and in every ungated run.
@MainActor
@Suite(.serialized)
struct CommandPaletteSnapshotTests {
    /// The app's minimum window (see `CueApp`), where the palette is tightest.
    static let window = CGSize(width: 1080, height: 720)

    @MainActor
    struct Fixture {
        let baseURL: URL
        let suiteName: String
        let defaults: UserDefaults
        let model: AppModel

        func cleanUp() {
            model.isShowingCommandPalette = false
            model.flushPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    // MARK: Fixture history

    private struct Spec {
        var title: String
        var directory: String
        var status: JobStatus = .idle
        var fraction: Double?
        var hoursAgo: Double
        var hasTranscript = false
        var hasTranslation = false
    }

    private static let interviews = "/Users/demo/Movies/Interviews"
    private static let lectures = "/Users/demo/Movies/Lectures"
    private static let downloads = "/Users/demo/Movies/Downloads"

    private static let specs: [Spec] = [
        Spec(
            title: "Interview with the Director", directory: interviews, status: .transcribing, fraction: 0.42,
            hoursAgo: 5),
        Spec(title: "Behind the Scenes Q&A", directory: interviews, status: .queued, hoursAgo: 9),
        Spec(
            title: "Cast Roundtable Part 1", directory: interviews, status: .translationComplete, hoursAgo: 14,
            hasTranscript: true, hasTranslation: true),
        Spec(
            title: "Cast Roundtable Part 2 with an extremely long file name that has to truncate",
            directory: interviews, status: .failed, hoursAgo: 20),
        Spec(
            title: "Linear Algebra Lecture 12", directory: lectures, status: .transcriptionComplete, hoursAgo: 72,
            hasTranscript: true),
        Spec(title: "Linear Algebra Lecture 13", directory: lectures, status: .idle, hoursAgo: 76),
        Spec(title: "Organic Chemistry Review Session", directory: lectures, status: .canceled, hoursAgo: 80),
        Spec(
            title: "How Whisper Models Work", directory: downloads, status: .translating, fraction: 0.67,
            hoursAgo: 190),
        Spec(
            title: "Subtitles 101", directory: downloads, status: .transcriptionComplete, hoursAgo: 200,
            hasTranscript: true),
    ]

    /// The job the main window shows selected behind the palette.
    private static let selectedTitle = "Linear Algebra Lecture 12"

    private static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private static func segments(translated: Bool) -> [TranscriptionSegment] {
        let source = [
            "Today we finish the proof that every finite-dimensional vector space has a basis.",
            "Recall that a set is linearly independent when no member is a combination of the others.",
            "Now pick a maximal independent set and show that it spans.",
            "Suppose it did not span; then some vector lies outside its span.",
        ]
        let target = [
            "本日は、有限次元ベクトル空間には基底が存在することの証明を終えます。",
            "一次独立とは、どの元も他の元の線形結合にならないことでしたね。",
            "極大な独立集合を選び、それが空間を張ることを示しましょう。",
            "張らないと仮定すると、その張る空間の外にベクトルが存在します。",
        ]
        return (source.indices).map { index in
            TranscriptionSegment(
                id: index + 1, start: Double(index) * 4.2, end: Double(index) * 4.2 + 3.8,
                text: translated ? target[index] : source[index])
        }
    }

    private static func progress(for spec: Spec) -> JobProgress {
        switch spec.status {
        case .idle: .idle
        case .queued: JobProgress(stage: .queued, detail: "Waiting in the queue.", fraction: nil)
        case .transcribing: JobProgress(stage: .transcribing, detail: "Transcribing", fraction: spec.fraction)
        case .translating: JobProgress(stage: .translating, detail: "Translating", fraction: spec.fraction)
        case .burningIn: JobProgress(stage: .burningIn, detail: "Burning in", fraction: spec.fraction)
        case .transcriptionComplete, .translationComplete:
            JobProgress(stage: .complete, detail: "Done", fraction: 1)
        case .canceled: JobProgress(stage: .canceled, detail: "Canceled.", fraction: nil)
        case .failed:
            JobProgress(
                stage: .failed, detail: "ffmpeg could not read the audio track.", fraction: nil,
                failedStage: .transcribing)
        }
    }

    static func makeFixture() async throws -> Fixture {
        let suiteName = "palette-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-palette-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = false
        settings.autoArchiveDays = 0
        settings.translationSourceLanguage = "English"
        settings.translationTargetLanguage = "Japanese"
        // A local model needs a server URL and never an API key, so the
        // translation commands are runnable in the render.
        settings.openAIModel = "local/palette-snapshot"

        let seedStore = JobStore(baseURL: baseURL)
        for spec in specs {
            let url = URL(fileURLWithPath: "\(spec.directory)/\(spec.title).mp4")
            var job = TranscriptionJob(sourceURL: url, settings: settings)
            job.createdAt = epoch.addingTimeInterval(-spec.hoursAgo * 3600)
            job.updatedAt = job.createdAt
            if spec.hasTranscript { job.transcriptSegments = segments(translated: false) }
            if spec.hasTranslation { job.translatedSegments = segments(translated: true) }
            seedStore.saveJob(job)
        }
        seedStore.flush()

        let ledger = WatchFolderLedger(baseURL: baseURL.appendingPathComponent("ledger", isDirectory: true))
        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: baseURL),
            watchLedger: ledger,
            diagnosticsService: EmptyPaletteSnapshotDiagnostics()
        )
        await model.hydration()
        for spec in specs {
            let index = try #require(model.jobs.firstIndex { $0.title == spec.title }, "no job \(spec.title)")
            model.jobs[index].status = spec.status
            model.jobs[index].progress = progress(for: spec)
        }
        let selected = try #require(model.jobs.first { $0.title == selectedTitle })
        model.selectJob(selected.id)
        settings.watchFolders = [WatchFolder(path: "/Users/demo/Movies/Inbox")]
        return Fixture(baseURL: baseURL, suiteName: suiteName, defaults: defaults, model: model)
    }

    // MARK: Rendering

    @MainActor
    private struct Shot {
        var name: String
        var query: String
        var scheme: ColorScheme = .light
        var scale: TextScale = .standard
        var size = CommandPaletteSnapshotTests.window
    }

    @discardableResult
    private func render(_ shot: Shot) async throws -> URL? {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        let storageErrors = StorageErrorGuard(model: fixture.model)
        fixture.defaults.set(shot.scale.rawValue, forKey: DisplayPreferenceKey.textScale)
        fixture.model.isShowingCommandPalette = true
        let view =
            ContentView(model: fixture.model, initialPaletteQuery: shot.query)
            .cueDisplayPreferences()
            .defaultAppStorage(fixture.defaults)
        let url = try await ViewSnapshot.capture(view, name: shot.name, size: shot.size, colorScheme: shot.scheme)
        if storageErrors.sightings > 0 {
            print("note: \(shot.name) was rendered while another test reported a storage error; rerun this suite alone")
        }
        return url
    }

    // MARK: Light

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersTheEmptyQuery() async throws {
        let url = try await render(Shot(name: "palette-empty-light", query: ""))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAJobQuery() async throws {
        let url = try await render(Shot(name: "palette-job-query-light", query: "cast"))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAQueryAcrossJobsCommandsAndSettings() async throws {
        let url = try await render(Shot(name: "palette-mixed-light", query: "whisper"))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersCommandsMode() async throws {
        let url = try await render(Shot(name: "palette-commands-light", query: ">"))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersNoResults() async throws {
        let url = try await render(Shot(name: "palette-no-results-light", query: "qzxv"))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAWatchFolderRow() async throws {
        let url = try await render(Shot(name: "palette-watch-folder-light", query: "inbox"))
        #expect(url != nil)
    }

    // MARK: Unavailable rows and notices

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersUnavailableCommands() async throws {
        // The selected job has a transcript and no translation, so the
        // translation exports are listed dimmed with their reasons.
        let light = try await render(Shot(name: "palette-unavailable-light", query: "export"))
        let dark = try await render(Shot(name: "palette-unavailable-dark", query: "export", scheme: .dark))
        #expect(light != nil)
        #expect(dark != nil)
    }

    /// The panel alone (the harness cannot press Return on a disabled row),
    /// with the footer showing the reason a run was refused.
    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersARefusedRunNotice() async throws {
        let light = try await renderPanel(name: "palette-notice-light", scale: .standard)
        let largest = try await renderPanel(name: "palette-notice-largest", scale: .largest)
        #expect(light != nil)
        #expect(largest != nil)
    }

    @discardableResult
    private func renderPanel(name: String, scale: TextScale) async throws -> URL? {
        let suiteName = "palette-panel-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(scale.rawValue, forKey: DisplayPreferenceKey.textScale)
        let controller = PaletteController(
            snapshot: PaletteFixtures.snapshot {
                // A job with a transcript and no translation, so the reasons
                // match the notice: the translation exports cannot run yet.
                $0.selectedJobTitle = "Linear Algebra Lecture 12"
                $0.selectedJobStatus = .transcriptionComplete
                $0.hasTranscript = true
            },
            query: "export",
            announce: { _ in }
        )
        controller.refuse("The selected job has no translation yet")
        let view =
            CommandPalettePanel(
                controller: controller, maxListHeight: 240, onRun: { _ in }, onClose: {}, onResignKey: {}
            )
            .frame(width: 620)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .cueDisplayPreferences()
            .defaultAppStorage(defaults)
        return try await ViewSnapshot.capture(view, name: name, size: CGSize(width: 684, height: 470))
    }

    // MARK: Dark

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersInDarkMode() async throws {
        let mixed = try await render(Shot(name: "palette-mixed-dark", query: "whisper", scheme: .dark))
        let commands = try await render(Shot(name: "palette-commands-dark", query: ">", scheme: .dark))
        #expect(mixed != nil)
        #expect(commands != nil)
    }

    // MARK: Largest text

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersAtLargestText() async throws {
        let empty = try await render(Shot(name: "palette-empty-largest", query: "", scale: .largest))
        let jobs = try await render(Shot(name: "palette-job-query-largest", query: "cast", scale: .largest))
        let watch = try await render(Shot(name: "palette-watch-folder-largest", query: "inbox", scale: .largest))
        #expect(empty != nil)
        #expect(jobs != nil)
        #expect(watch != nil)
    }
}
