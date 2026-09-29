import AppKit
import SwiftUI
import Testing

@testable import Cue

private actor EmptySidebarSnapshotDiagnostics: EnvironmentDiagnosing {
    func run(
        translationAPIKey _: String,
        translationProvider _: TranslationProvider,
        selectedBackend _: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        []
    }
}

/// Gated renders of the real sidebar over an isolated model: temp job store,
/// in-memory folder store, temp watch ledger, suite defaults, no diagnostics.
/// Nothing here touches the user's jobs, folders, settings, or Keychain.
///
/// Jobs are saved idle-free of pipeline work: the history is loaded first and
/// the running, queued, and failed statuses are stamped on the in-memory jobs
/// afterwards, so no job can ever reach the transcription pipeline.
///
/// Menus, drag and drop, and hover states cannot be rendered by this harness;
/// the Move to Folder menus and the drop highlight are covered by the model
/// tests and by `rendersFolderHeaderStates`.
@MainActor
struct SidebarFolderSnapshotTests {
    /// The sidebar column's ideal width (see `ContentView`), and a height that
    /// shows every fixture row at Comfortable.
    static let column = CGSize(width: 250, height: 900)

    @MainActor
    struct Fixture {
        let baseURL: URL
        let suiteName: String
        let defaults: UserDefaults
        let model: AppModel
        let jobIDs: [String: UUID]
        let folderIDs: [String: UUID]

        func cleanUp() {
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
        var origin: JobOrigin = .manual
        var source = "auto"
        var target = "English"
        var speechSeconds: Double?
        var hasOverrides = false
        var daysAgo: Double
    }

    private static let interviews = "/Users/demo/Movies/Interviews"
    private static let lectures = "/Users/demo/Movies/Lectures"
    private static let downloads = "/Users/demo/Movies/Downloads"

    /// In queue order. Three folders come from where the files live and the
    /// downloads from the site they came from; "Ideas" is added by hand, empty.
    private static let specs: [Spec] = [
        Spec(
            title: "Interview with the Director", directory: interviews, status: .transcribing, fraction: 0.42,
            source: "ja", daysAgo: 0.2),
        Spec(title: "Behind the Scenes Q&A", directory: interviews, status: .queued, daysAgo: 0.4),
        Spec(
            title: "Cast Roundtable Part 1", directory: interviews, status: .translationComplete, source: "ja",
            speechSeconds: 3725, daysAgo: 0.6),
        Spec(
            title: "Cast Roundtable Part 2 with an extremely long file name that has to truncate",
            directory: interviews, status: .failed, target: "Vietnamese", hasOverrides: true, daysAgo: 0.8),
        Spec(
            title: "Linear Algebra Lecture 12", directory: lectures, status: .transcriptionComplete, source: "en",
            speechSeconds: 2712, daysAgo: 3),
        Spec(title: "Linear Algebra Lecture 13", directory: lectures, status: .idle, source: "en", daysAgo: 3.2),
        Spec(
            title: "Organic Chemistry Review Session", directory: lectures, status: .canceled, source: "en",
            daysAgo: 3.4),
        Spec(
            title: "How Whisper Models Work", directory: downloads, status: .translating, fraction: 0.67,
            origin: .url, source: "ko", speechSeconds: 1210, daysAgo: 8),
        Spec(
            title: "Subtitles 101", directory: downloads, status: .transcriptionComplete, origin: .url, source: "en",
            speechSeconds: 612, daysAgo: 8.5),
    ]

    private static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

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
        let suiteName = "sidebar-folder-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-sidebar-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let settings = AppSettingsStore(defaults: defaults, readSecret: { _ in nil }, writeSecret: { _, _ in true })
        settings.autoStartAddedJobs = false
        settings.autoArchiveDays = 0

        let seedStore = JobStore(baseURL: baseURL)
        var jobIDs: [String: UUID] = [:]
        for (index, spec) in specs.enumerated() {
            var job = try FolderTestJobs.make(
                sourcePath: "\(spec.directory)/\(spec.title).mp4",
                origin: spec.origin,
                createdAt: epoch.addingTimeInterval(-spec.daysAgo * 86_400),
                log: spec.origin == .url ? "Downloaded from https://www.youtube.com/watch?v=dQw4w9WgXcQ.\n" : ""
            )
            job.orderIndex = Double(index)
            job.settings.sourceLanguage = spec.source
            job.settings.translationTargetLanguage = spec.target
            if spec.hasOverrides { job.overrides.translationTargetLanguage = "French" }
            if let end = spec.speechSeconds {
                job.transcriptSegments = [
                    TranscriptionSegment(id: 1, start: 0, end: 4, text: "Sample line."),
                    TranscriptionSegment(id: 2, start: 4, end: end, text: "Last line."),
                ]
            }
            seedStore.saveJob(job)
            jobIDs[spec.title] = job.id
        }
        seedStore.flush()

        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: baseURL),
            folderStore: .inMemory,
            watchLedger: WatchFolderLedger(baseURL: baseURL.appendingPathComponent("ledger", isDirectory: true)),
            diagnosticsService: EmptySidebarSnapshotDiagnostics()
        )
        await model.hydration()

        // Statuses go on the in-memory jobs only, after the queue has already
        // been pumped, so nothing here can start real work.
        for spec in specs {
            guard let id = jobIDs[spec.title], let index = model.index(of: id) else { continue }
            model.jobs[index].status = spec.status
            model.jobs[index].progress = progress(for: spec)
        }
        _ = model.createFolder(named: "Ideas")
        model.selectJob(jobIDs["Linear Algebra Lecture 12"])

        var folderIDs: [String: UUID] = [:]
        for folder in model.folders where folderIDs[folder.name] == nil { folderIDs[folder.name] = folder.id }
        return Fixture(
            baseURL: baseURL, suiteName: suiteName, defaults: defaults, model: model, jobIDs: jobIDs,
            folderIDs: folderIDs)
    }

    // MARK: Rendering

    private struct Shot {
        var name: String
        var density: ListDensity = .comfortable
        var scale: TextScale = .standard
        var scheme: ColorScheme = .light
        var grouping: SidebarGrouping = .folders
        var size = CGSize(width: 250, height: 900)
        /// Folders closed before the render, by name.
        var collapsed: [String] = []
    }

    private func apply(_ shot: Shot, to fixture: Fixture) throws {
        for name in shot.collapsed {
            let id = try #require(fixture.folderIDs[name], "no folder named \(name)")
            fixture.model.setFolderExpanded(false, for: id)
        }
        fixture.defaults.set(shot.grouping.rawValue, forKey: "sidebarGrouping")
        fixture.defaults.set(shot.density.rawValue, forKey: DisplayPreferenceKey.listDensity)
        fixture.defaults.set(shot.scale.rawValue, forKey: DisplayPreferenceKey.textScale)
    }

    @discardableResult
    private func render(_ shot: Shot) async throws -> URL? {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        try apply(shot, to: fixture)
        let view =
            SidebarView(model: fixture.model)
            .cueDisplayPreferences()
            .defaultAppStorage(fixture.defaults)
        return try await ViewSnapshot.capture(view, name: shot.name, size: shot.size, colorScheme: shot.scheme)
    }

    // MARK: Folders

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersEachDensityAtDefaultTextSize() async throws {
        for density in ListDensity.allCases {
            let url = try await render(Shot(name: "folders-\(density.rawValue)-100-light", density: density))
            #expect(url != nil)
        }
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersFoldersAtLargestText() async throws {
        // Taller than the default frame: at 150% the list is longer than the
        // window, and the rest would hide behind the bottom buttons.
        let tall = CGSize(width: 250, height: 1500)
        let comfortable = try await render(
            Shot(name: "folders-comfortable-150-light", scale: .largest, size: tall))
        let detailed = try await render(
            Shot(name: "folders-detailed-150-light", density: .detailed, scale: .largest, size: tall))
        #expect(comfortable != nil)
        #expect(detailed != nil)
    }

    /// The narrowest the sidebar column gets (`ContentView`: min 210, ideal 250).
    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersFoldersAtTheNarrowestWidth() async throws {
        let narrow = CGSize(width: 210, height: 900)
        for density in ListDensity.allCases {
            let url = try await render(Shot(name: "folders-\(density.rawValue)-100-narrow", density: density, size: narrow))
            #expect(url != nil)
        }
        let largest = try await render(
            Shot(
                name: "folders-comfortable-150-narrow", scale: .largest, size: CGSize(width: 210, height: 1500)))
        #expect(largest != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersFoldersInDarkMode() async throws {
        let comfortable = try await render(Shot(name: "folders-comfortable-100-dark", scheme: .dark))
        let detailed = try await render(Shot(name: "folders-detailed-100-dark", density: .detailed, scheme: .dark))
        #expect(comfortable != nil)
        #expect(detailed != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersACollapsedFolderHoldingTheSelection() async throws {
        let url = try await render(Shot(name: "folders-comfortable-100-collapsed", collapsed: ["Lectures"]))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersFoldersSortedByName() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(FolderSortOrder.name.rawValue, forKey: "sidebarFolderSort")
        try apply(Shot(name: "folders-comfortable-100-by-name"), to: fixture)
        let view = SidebarView(model: fixture.model).cueDisplayPreferences().defaultAppStorage(fixture.defaults)
        let url = try await ViewSnapshot.capture(view, name: "folders-comfortable-100-by-name", size: Self.column)
        #expect(url != nil)
    }

    // MARK: Other groupings

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersGroupByStatus() async throws {
        let url = try await render(Shot(name: "status-comfortable-100-light", grouping: .status))
        #expect(url != nil)
    }

    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersGroupByNone() async throws {
        let url = try await render(Shot(name: "none-comfortable-100-light", grouping: .none))
        #expect(url != nil)
    }

    // MARK: Pieces

    /// The header in the three states it can be in, inside a real sidebar List.
    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersFolderHeaderStates() async throws {
        let suiteName = "sidebar-folder-header-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for scale in [TextScale.standard, .largest] {
            defaults.set(scale.rawValue, forKey: DisplayPreferenceKey.textScale)
            let list = List {
                Section {
                    Text("A job row").lineLimit(1)
                } header: {
                    FolderHeaderLabel(name: "Interviews", count: 4, isDropTarget: false)
                }
                Section {
                    Text("A job row").lineLimit(1)
                } header: {
                    FolderHeaderLabel(name: "Lectures (drop here)", count: 3, isDropTarget: true)
                }
                Section {
                    Text("A job row").lineLimit(1)
                } header: {
                    FolderHeaderLabel(
                        name: "A folder with a very long name that cannot possibly fit", count: 1234,
                        isDropTarget: false)
                }
            }
            .listStyle(.sidebar)
            .cueDisplayPreferences()
            .defaultAppStorage(defaults)
            let url = try await ViewSnapshot.capture(
                list, name: "folder-header-\(scale.percentLabel.dropLast())", size: CGSize(width: 250, height: 260))
            #expect(url != nil)
        }
    }

    /// The name prompt for New Folder / Rename, with and without the
    /// duplicate-name error, at the default and the largest text size.
    @Test(.enabled(if: ViewSnapshot.isEnabled))
    func rendersTheFolderNameSheet() async throws {
        let suiteName = "sidebar-folder-sheet-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cases: [(name: String, scale: TextScale, result: FolderNameResult, height: CGFloat)] = [
            ("folder-sheet-new-100", .standard, .accepted("Season 2"), 210),
            ("folder-sheet-duplicate-100", .standard, .duplicate, 230),
            ("folder-sheet-duplicate-150", .largest, .duplicate, 330),
        ]
        for item in cases {
            defaults.set(item.scale.rawValue, forKey: DisplayPreferenceKey.textScale)
            let sheet = FolderNameSheet(
                title: "New Folder",
                note: SidebarFolderText.createNote(movingJobs: 3),
                confirmTitle: "Create",
                initialName: "Season 2",
                validate: { _ in item.result },
                onConfirm: { _ in },
                onCancel: {}
            )
            .cueDisplayPreferences()
            .defaultAppStorage(defaults)
            let url = try await ViewSnapshot.capture(sheet, name: item.name, size: CGSize(width: 380, height: item.height))
            #expect(url != nil)
        }
    }
}
