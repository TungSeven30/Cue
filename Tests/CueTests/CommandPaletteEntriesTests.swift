import Foundation
import SwiftUI
import Testing

@testable import Cue

/// The rows the palette draws: what is searchable, how a row reads, what an
/// empty query suggests, and how a disabled row explains itself. All values;
/// no AppModel and no window.
struct CommandPaletteEntriesTests {
    private typealias Fixtures = PaletteFixtures

    private func makeIndex(
        jobs: [PaletteJobSummary] = [],
        selected: UUID? = nil,
        watch: [PaletteWatchFolderSummary] = [],
        downloads: [PaletteDownloadSummary] = [],
        _ configure: (inout PaletteContext) -> Void = { _ in }
    ) -> PaletteIndex {
        PaletteIndex.build(
            from: Fixtures.snapshot(jobs: jobs, selected: selected, watch: watch, downloads: downloads, configure)
        )
    }

    private func row(_ id: String, in results: PaletteResults) -> PaletteRowModel? {
        results.entryRows.first { $0.id == id }
    }

    private func headers(_ results: PaletteResults) -> [PaletteHeader] {
        results.rows.compactMap { row in
            if case .header(let header) = row { return header }
            return nil
        }
    }

    private func folder(_ name: String, path: String, enabled: Bool = true) -> PaletteWatchFolderSummary {
        PaletteWatchFolderSummary(id: UUID(), name: name, path: path, isEnabled: enabled)
    }

    // MARK: - Index

    @Test func indexHoldsOneEntryPerJobCommandSettingFolderAndFailedDownload() {
        let download = PaletteDownloadSummary(id: UUID(), title: "clip", message: "Timed out")
        let idx = makeIndex(
            jobs: [Fixtures.job("Interview"), Fixtures.job("Keynote")],
            watch: [folder("Inbox", path: "/Users/me/Inbox")],
            downloads: [download]
        )
        let bySection = Dictionary(grouping: idx.entries, by: \.section)
        #expect(bySection[.jobs]?.count == 2)
        // "Check for Updates…" is hidden, not disabled, without an updater.
        #expect(bySection[.commands]?.count == PaletteCommandID.allCases.count - 1)
        #expect(bySection[.settings]?.count == SettingsPane.allCases.count)
        #expect(bySection[.watchFolders]?.count == 1)
        #expect(bySection[.downloads]?.count == 1)
        #expect(idx.items.count == idx.entries.count)
        #expect(Set(idx.entries.map(\.id)).count == idx.entries.count)
    }

    @Test func entryIDsAreNamespacedAndEveryTargetMatchesItsSection() {
        let job = Fixtures.job("Interview")
        let watched = folder("Inbox", path: "/Users/me/Inbox")
        let download = PaletteDownloadSummary(id: UUID(), title: "clip", message: "Timed out")
        let idx = makeIndex(jobs: [job], watch: [watched], downloads: [download])
        let ids = Set(idx.entries.map(\.id))
        #expect(ids.contains("job:\(job.id.uuidString)"))
        #expect(ids.contains("command:addFiles"))
        #expect(ids.contains("setting:apiKeys"))
        #expect(ids.contains("watch:\(watched.id.uuidString)"))
        #expect(ids.contains("download:\(download.id.uuidString)"))
        for entry in idx.entries {
            switch (entry.section, entry.target) {
            case (.jobs, .job), (.commands, .command), (.settings, .setting),
                (.watchFolders, .watchFolder), (.downloads, .download):
                break
            default:
                Issue.record("\(entry.id) has a target that does not belong to its section: \(entry.target)")
            }
        }
    }

    @Test func updatesAppearOnlyWhenAnUpdaterExists() {
        let without = makeIndex()
        #expect(!without.entries.contains { $0.id == "command:checkForUpdates" })
        let with = makeIndex { $0.canCheckForUpdates = true }
        #expect(with.entries.contains { $0.id == "command:checkForUpdates" })
    }

    // MARK: - Job rows

    @Test func jobSubtitlesShowStatusAndFolder() {
        let job = Fixtures.job("Interview", status: .transcriptionComplete, folder: "/Volumes/Media/Shows")
        #expect(PaletteIndex.jobSubtitle(job) == "Transcript ready · /Volumes/Media/Shows")

        let archived = Fixtures.job("Interview", folder: "/Volumes/Media/Shows", archived: true)
        #expect(PaletteIndex.jobSubtitle(archived) == "Archived · Idle · /Volumes/Media/Shows")

        // A path with no folder part contributes nothing rather than an empty segment.
        let bare = PaletteJobSummary(
            id: UUID(), title: "clip", fileName: "clip.mov", path: "clip.mov",
            status: .failed, isArchived: false, updatedAt: Fixtures.epoch
        )
        #expect(PaletteIndex.jobSubtitle(bare) == "Failed")
        #expect(PaletteIndex.abbreviatedPath(NSHomeDirectory() + "/Movies/Shows") == "~/Movies/Shows")
    }

    @Test func jobRowsCarryTheirStatusAndAreFoundByFileName() throws {
        let job = Fixtures.job("Interview", status: .failed)
        let idx = makeIndex(jobs: [job])
        let entry = try #require(idx.entries.first { $0.id == "job:\(job.id.uuidString)" })
        #expect(entry.symbol == JobStatus.failed.systemImage)
        #expect(entry.jobStatus == .failed)
        #expect(entry.isEnabled)
        #expect(entry.shortcut == nil)

        // The file name differs from the title, so it is searchable too.
        let results = idx.results(for: "interview.mov")
        let found = try #require(row(entry.id, in: results))
        #expect(found.subtitle.hasSuffix("matches “Interview.mov”"))
    }

    @Test func archivedJobsSinkBelowLiveOnesAtEqualQuality() {
        let archived = Fixtures.job("Standup", archived: true, age: 0)
        let live = Fixtures.job("Standup", age: 500)
        let results = makeIndex(jobs: [archived, live]).results(for: "standup")
        let rows = Fixtures.rows(results, in: .jobs)
        #expect(rows.map(\.id) == ["job:\(live.id.uuidString)", "job:\(archived.id.uuidString)"])
        #expect(rows.last?.subtitle.hasPrefix("Archived") == true)
    }

    // MARK: - Empty query

    @Test func emptyQueryOffersSelectedThenRunningThenRecentJobsButNeverArchived() throws {
        let selected = Fixtures.job("Selected", age: 4000)
        let running = Fixtures.job("Running", status: .transcribing, age: 3000)
        let queued = Fixtures.job("Queued", status: .queued, age: 9000)
        let fresh = Fixtures.job("Fresh", age: 10)
        let older = Fixtures.job("Older", age: 5000)
        let archived = Fixtures.job("Archived", archived: true, age: 1)
        let oldest = Fixtures.job("Oldest", age: 9999)
        let idx = makeIndex(jobs: [older, selected, running, fresh, archived, queued, oldest], selected: selected.id)

        let results = idx.results(for: "")
        #expect(results.isSuggestions)
        #expect(Fixtures.titles(results, in: .jobs) == ["Selected", "Running", "Queued", "Fresh", "Older"])
        let jobsHeader = try #require(headers(results).first { $0.section == .jobs })
        #expect(jobsHeader.title == "Recent Jobs")
        #expect(!jobsHeader.isCapped)
    }

    @Test func emptyQuerySuggestsTheCommonCommandsInOrderWhenTheyCanRun() throws {
        let idx = makeIndex {
            $0.canPerformPrimaryAction = true
            $0.primaryActionTitle = "Translate to Japanese"
            $0.hasPendingWork = true
            $0.canCancel = true
            $0.hasTranscript = true
        }
        let results = idx.results(for: "")
        #expect(
            Fixtures.titles(results, in: .commands)
                == ["Next Step: Translate to Japanese", "Add Files…", "Add from URL…", "Start All", "Stop All Jobs", "Export…"]
        )
        let header = try #require(headers(results).first { $0.section == .commands })
        #expect(header.title == "Suggested Commands")
    }

    @Test func emptyQueryLeavesOutSuggestedCommandsThatCannotRun() {
        let results = makeIndex().results(for: "")
        #expect(Fixtures.titles(results, in: .commands) == ["Add Files…", "Add from URL…"])
        #expect(results.entryRows.allSatisfy { $0.isSelectable })
        #expect(Fixtures.rows(results, in: .jobs).isEmpty)
    }

    @Test func anEmptyIndexHasAnEmptyState() {
        let results = PaletteIndex.empty.results(for: "")
        #expect(results.rows.isEmpty)
        #expect(results.selectableIDs.isEmpty)
        #expect(results.summary == "No results")
        #expect(
            results.emptyState
                == PaletteEmptyState(
                    title: "Nothing to show yet", message: "Type to search jobs, commands, and settings."
                )
        )
    }

    // MARK: - Scope

    @Test func greaterThanListsEveryCommandRunnableFirst() throws {
        let idx = makeIndex(jobs: [Fixtures.job("Stop Motion Reel")])
        let results = idx.results(for: ">")
        #expect(!results.isSuggestions)
        #expect(Set(results.entryRows.map(\.entry.section)) == [.commands])
        #expect(results.entryCount == PaletteCommandID.allCases.count - 1)
        #expect(
            Array(results.entryRows.prefix(5).map(\.id))
                == [
                    "command:addFiles", "command:addFromURL", "command:runDiagnostics", "command:openSetupGuide",
                    "command:openSettings",
                ]
        )
        #expect(results.entryRows.dropFirst(5).allSatisfy { !$0.isSelectable })
        let header = try #require(headers(results).first)
        #expect(header.title == "Commands")
        #expect(!header.isCapped)
    }

    @Test func greaterThanWithTextSearchesOnlyCommands() {
        let idx = makeIndex(jobs: [Fixtures.job("Stop Motion Reel")]) { $0.canCancel = true }
        let scoped = idx.results(for: ">stop")
        #expect(Set(scoped.entryRows.map(\.entry.section)) == [.commands])
        #expect(scoped.entryRows.first?.id == "command:stopAll")
        #expect(scoped.query.scope == .commands)
        // The same text without the scope also finds the job.
        let everything = idx.results(for: "stop")
        #expect(everything.entryRows.contains { $0.entry.section == .jobs })
    }

    @Test func plainTextMixesSectionsAndPutsRunnableRowsFirst() throws {
        let motion = Fixtures.job("Stop Motion Reel")
        let results = makeIndex(jobs: [motion]).results(for: "stop")
        // "Stop All Jobs" cannot run (nothing is running), so the runnable job leads.
        #expect(results.entryRows.first?.entry.section == .jobs)
        #expect(results.selectableIDs.first == "job:\(motion.id.uuidString)")
        let stop = try #require(row("command:stopAll", in: results))
        #expect(!stop.isSelectable)
        #expect(results.selectableIDs.allSatisfy { !$0.hasPrefix("command:stop") })
    }

    @Test func noResultsExplainThemselvesPerScope() {
        let idx = makeIndex()
        let open = idx.results(for: "qzxv")
        #expect(open.entryCount == 0)
        #expect(!open.isSuggestions)
        #expect(open.summary == "No results")
        #expect(
            open.emptyState
                == PaletteEmptyState(
                    title: "No results for “qzxv”", message: "Check the spelling, or type > to browse every command."
                )
        )
        let scoped = idx.results(for: ">qzxv")
        #expect(
            scoped.emptyState
                == PaletteEmptyState(
                    title: "No commands match “qzxv”", message: "Delete the > to search jobs and settings too."
                )
        )
    }

    // MARK: - Command rows

    @Test func disabledCommandsShowTheirReasonAndCannotBeSelected() throws {
        let results = makeIndex().results(for: "stop all")
        let stop = try #require(row("command:stopAll", in: results))
        #expect(!stop.isSelectable)
        #expect(stop.subtitle == "Nothing is running")
        #expect(stop.subtitleRanges.isEmpty)
        #expect(!stop.titleRanges.isEmpty)
        #expect(
            stop.accessibilityLabel == "Stop All Jobs, Nothing is running, Command, Shortcut Command Period, Unavailable"
        )
        #expect(!results.selectableIDs.contains(stop.id))
    }

    @Test func runnableCommandsShowTheirMenuPathAndShortcut() throws {
        let results = makeIndex().results(for: "add files")
        let add = try #require(row("command:addFiles", in: results))
        #expect(add.isSelectable)
        #expect(add.subtitle == "File menu")
        #expect(add.entry.shortcut?.glyphs == "⌘O")
        #expect(add.accessibilityLabel == "Add Files…, File menu, Command, Shortcut Command O")
        #expect(results.selectableIDs.first == add.id)
    }

    @Test func aKeywordOnlyMatchNamesTheWordThatMatched() throws {
        let results = makeIndex().results(for: "ffmpeg")
        let diagnostics = try #require(row("command:runDiagnostics", in: results))
        #expect(diagnostics.subtitle == "Setup · matches “ffmpeg”")
        #expect(diagnostics.titleRanges.isEmpty)
    }

    @Test func aVisibleSubtitleMatchNeedsNoKeywordHint() throws {
        let results = makeIndex().results(for: "whisper")
        let models = try #require(row("setting:models", in: results))
        #expect(models.subtitle == "Settings · Whisper and translation models")
        #expect(!models.subtitleRanges.isEmpty)
        #expect(!models.subtitle.contains("matches"))
    }

    @Test func matchRangesLandOnTheRowTitle() throws {
        let results = makeIndex().results(for: "sett")
        let open = try #require(row("command:openSettings", in: results))
        let emphasized = PaletteHighlight.segments(for: open.entry.title, ranges: open.titleRanges)
            .filter(\.isEmphasized).map(\.text)
        #expect(emphasized == ["Sett"])
    }

    // MARK: - Other sections

    @Test func settingRowsSummarizeThePane() throws {
        let results = makeIndex().results(for: "text size")
        let appearance = try #require(row("setting:appearance", in: results))
        #expect(appearance.entry.title == "Appearance")
        #expect(appearance.entry.symbol == "textformat.size")
        #expect(appearance.subtitle == "Settings · Text size, font, list density")
        #expect(appearance.accessibilityLabel == "Appearance, Settings · Text size, font, list density, Setting")
        for pane in SettingsPane.allCases {
            #expect(pane.paletteSummary != nil, "\(pane) has no palette summary")
        }
    }

    @Test func watchFolderAndDownloadRowsNameWhatReturnDoes() throws {
        let active = folder("Inbox", path: NSHomeDirectory() + "/Inbox")
        let paused = folder("Archive", path: "/Volumes/Media/Archive", enabled: false)
        let download = PaletteDownloadSummary(id: UUID(), title: "keynote-clip", message: "Timed out")
        let idx = makeIndex(watch: [active, paused], downloads: [download])

        let inbox = try #require(row("watch:\(active.id.uuidString)", in: idx.results(for: "inbox")))
        #expect(inbox.subtitle == "~/Inbox")
        #expect(inbox.entry.symbol == "eye")
        #expect(inbox.entry.actionLabel == "Reveal in Finder")
        #expect(inbox.accessibilityLabel == "Inbox, ~/Inbox, Watch folder, Return to Reveal in Finder")

        let archive = try #require(row("watch:\(paused.id.uuidString)", in: idx.results(for: "archive")))
        #expect(archive.subtitle == "Paused · /Volumes/Media/Archive")
        #expect(archive.entry.symbol == "eye.slash")
        #expect(archive.isSelectable)

        let failed = try #require(row("download:\(download.id.uuidString)", in: idx.results(for: "keynote-clip")))
        #expect(failed.subtitle == "Failed · Timed out")
        #expect(failed.entry.actionLabel == "Try Again")
        #expect(failed.accessibilityLabel == "keynote-clip, Failed · Timed out, Download, Return to Try Again")
    }

    // MARK: - Headers and summaries

    @Test func cappedSectionsReportShownOfTotal() throws {
        let jobs = (0..<12).map { Fixtures.job("Demo \($0)", age: TimeInterval($0)) }
        let results = makeIndex(jobs: jobs).results(for: "demo")
        let header = try #require(headers(results).first { $0.section == .jobs })
        #expect(header.shown == 8)
        #expect(header.total == 12)
        #expect(header.isCapped)
        #expect(Fixtures.rows(results, in: .jobs).count == 8)
    }

    @Test func resultSummariesAreSpokenAsCounts() {
        let idx = makeIndex(jobs: [Fixtures.job("Zebra Migration")])
        let one = idx.results(for: "zebra")
        #expect(one.entryCount == 1)
        #expect(one.summary == "1 result")
        let many = idx.results(for: ">")
        #expect(many.summary == "\(many.entryCount) results")
        #expect(idx.results(for: "qzxv").summary == "No results")
    }

    // MARK: - Performance smoke

    @Test func sixHundredJobsBuildAndSearchQuickly() {
        let subjects = ["Interview", "Lecture", "Standup", "Podcast", "Keynote", "Webinar", "Rehearsal", "Demo"]
        let people = ["Sam", "Priya", "Ünal", "José", "Mei", "Olga", "Tariq", "Noor"]
        let statuses: [JobStatus] = [.idle, .queued, .transcribing, .transcriptionComplete, .failed]
        let jobs = (0..<600).map { index in
            Fixtures.job(
                "\(subjects[index % subjects.count]) \(index) with \(people[(index / 3) % people.count])",
                status: statuses[index % statuses.count],
                folder: "\(NSHomeDirectory())/Movies/Season \(index % 12)/Episodes",
                archived: index % 17 == 0,
                age: TimeInterval(index * 60)
            )
        }
        let snapshot = Fixtures.snapshot(jobs: jobs, selected: jobs[3].id) { $0.canPerformPrimaryAction = true }
        let clock = ContinuousClock()

        var built = PaletteIndex.empty
        let buildTime = clock.measure { built = PaletteIndex.build(from: snapshot) }
        #expect(buildTime < .seconds(1), "building the index for 600 jobs took \(buildTime)")
        #expect(built.entries.count >= 600)

        var slowest: (query: String, time: Duration) = ("", .zero)
        let queries = ["", ">", "i", "int", "interview", "interview 5", "ünal", "season 7", "sam priya", ">stop", "xqzv"]
        for text in queries {
            var best = Duration.seconds(10)
            for _ in 0..<3 {
                best = min(best, clock.measure { _ = built.results(for: text) })
            }
            if best > slowest.time { slowest = (text, best) }
        }
        // A debug build on a busy machine is far slower than release; the bound
        // only has to catch an accidental quadratic blow-up.
        #expect(slowest.time < .milliseconds(250), "slowest query \"\(slowest.query)\" took \(slowest.time)")
    }
}

/// How the engine's match ranges become emphasized text.
struct PaletteHighlightTests {
    private func segments(_ text: String, _ ranges: [Range<Int>]) -> [PaletteTextSegment] {
        PaletteHighlight.segments(for: text, ranges: ranges)
    }

    private func plain(_ text: String) -> PaletteTextSegment { PaletteTextSegment(text: text, isEmphasized: false) }
    private func bold(_ text: String) -> PaletteTextSegment { PaletteTextSegment(text: text, isEmphasized: true) }

    @Test func splitsAtTheRanges() {
        #expect(segments("Open Settings…", [0..<4]) == [bold("Open"), plain(" Settings…")])
        #expect(segments("Open Settings…", [5..<9]) == [plain("Open "), bold("Sett"), plain("ings…")])
        #expect(segments("abc", [0..<3]) == [bold("abc")])
    }

    @Test func noRangesOrNoTextIsPlain() {
        #expect(segments("Add Files…", []) == [plain("Add Files…")])
        #expect(segments("", [0..<3]).isEmpty)
        #expect(segments("abc", [1..<1]) == [plain("abc")])
    }

    @Test func unsortedOverlappingRangesAreMerged() {
        #expect(
            segments("abcdefghij", [5..<8, 0..<3, 2..<4])
                == [bold("abcd"), plain("e"), bold("fgh"), plain("ij")]
        )
        // Touching ranges join into one run instead of two adjacent ones.
        #expect(segments("abcdef", [0..<2, 2..<4]) == [bold("abcd"), plain("ef")])
    }

    @Test func staleRangesAreClampedNotTrusted() {
        #expect(segments("abcdefghij", [8..<20, -3..<1]) == [bold("a"), plain("bcdefgh"), bold("ij")])
        #expect(segments("abc", [7..<9]) == [plain("abc")])
    }

    @Test func rangesCountCharactersNotScalars() {
        // "é" as e + combining acute is one Character.
        #expect(
            segments("cafe\u{301} au lait", [3..<4])
                == [plain("caf"), bold("e\u{301}"), plain(" au lait")]
        )
        #expect(segments("🇯🇵 会議", [2..<4]) == [plain("🇯🇵 "), bold("会議")])
    }

    @Test func attributedTextEmphasizesOnlyTheMatch() {
        let attributed = PaletteAttributed.string(for: "Open Settings…", ranges: [0..<4])
        #expect(String(attributed.characters) == "Open Settings…")
        let emphasized = attributed.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
        #expect(emphasized == ["Open"])

        let plainText = PaletteAttributed.string(for: "Add Files…", ranges: [])
        #expect(plainText.runs.allSatisfy { $0.inlinePresentationIntent == nil })
        #expect(String(PaletteAttributed.string(for: "", ranges: [0..<2]).characters).isEmpty)
    }
}
