import Foundation
import Testing

@testable import Cue

/// The words the folder sidebar shows, tested without rendering anything.
struct SidebarFolderTextTests {
    @Test func jobCountsAreSingularOrPlural() {
        #expect(SidebarFolderText.jobCount(0) == "0 jobs")
        #expect(SidebarFolderText.jobCount(1) == "1 job")
        #expect(SidebarFolderText.jobCount(2) == "2 jobs")
        #expect(SidebarFolderText.jobCount(589) == "589 jobs")
    }

    @Test func headerAccessibilityLabelNamesTheFolderAndItsSize() {
        #expect(SidebarFolderText.headerAccessibilityLabel(name: "Season 2", count: 1) == "Season 2, 1 job")
        #expect(SidebarFolderText.headerAccessibilityLabel(name: "Season 2", count: 12) == "Season 2, 12 jobs")
        #expect(SidebarFolderText.headerAccessibilityLabel(name: "Empty", count: 0) == "Empty, 0 jobs")
    }

    @Test func emptyFolderHintDependsOnWhetherAFilterIsNarrowingTheList() {
        #expect(SidebarFolderText.emptyFolderHint(isFiltering: false) == "Drag jobs here, or use Move to Folder.")
        #expect(SidebarFolderText.emptyFolderHint(isFiltering: true) == "No jobs here match the current filter.")
    }

    @Test func createNoteCountsTheJobsThatWillMove() {
        #expect(SidebarFolderText.createNote(movingJobs: 0).contains("Move to Folder"))
        #expect(SidebarFolderText.createNote(movingJobs: 1) == "1 job will move into the new folder.")
        #expect(SidebarFolderText.createNote(movingJobs: 3) == "3 jobs will move into the new folder.")
    }

    @Test func theDuplicateNoteQuotesTheName() {
        #expect(SidebarFolderText.duplicateNote(for: "Season 2") == "A folder named “Season 2” already exists.")
    }

    @Test func theRenameNoteSaysFutureVideosStillLandInTheFolder() {
        #expect(SidebarFolderText.renameNote.contains("New videos from the same place"))
    }

    private func change(_ kind: FolderChange.Kind, name: String = "Season 2", moved: Int) -> FolderChange {
        FolderChange(kind: kind, folderID: UUID(), folderName: name, movedCount: moved, undo: FolderUndoRecord())
    }

    @Test func undoMessagesDescribeEachKindOfChange() {
        #expect(SidebarFolderText.undoMessage(for: change(.created, moved: 0)) == "Created folder “Season 2”")
        #expect(
            SidebarFolderText.undoMessage(for: change(.created, moved: 1)) == "Created “Season 2” with 1 job")
        #expect(
            SidebarFolderText.undoMessage(for: change(.created, moved: 4)) == "Created “Season 2” with 4 jobs")
        #expect(SidebarFolderText.undoMessage(for: change(.moved, moved: 1)) == "Moved 1 job to “Season 2”")
        #expect(SidebarFolderText.undoMessage(for: change(.moved, moved: 5)) == "Moved 5 jobs to “Season 2”")
        #expect(
            SidebarFolderText.undoMessage(for: change(.merged(sourceName: "Extras"), moved: 3))
                == "Merged “Extras” into “Season 2”")
        #expect(SidebarFolderText.undoMessage(for: change(.deleted, moved: 0)) == "Deleted folder “Season 2”")
        #expect(
            SidebarFolderText.undoMessage(for: change(.deleted, moved: 1))
                == "Deleted folder “Season 2”. 1 job returned to automatic placement.")
        #expect(
            SidebarFolderText.undoMessage(for: change(.deleted, moved: 7))
                == "Deleted folder “Season 2”. 7 jobs returned to automatic placement.")
    }
}

/// The per-row strings each list density shows.
struct SidebarRowTextTests {
    // MARK: Compact status

    @Test func runningJobsShowTheirPercent() {
        #expect(SidebarRowText.compactStatus(for: .transcribing, progressPercent: 42, queuePosition: nil) == "42%")
        #expect(SidebarRowText.compactStatus(for: .translating, progressPercent: 100, queuePosition: nil) == "100%")
        #expect(SidebarRowText.compactStatus(for: .burningIn, progressPercent: 0, queuePosition: nil) == "0%")
    }

    @Test func aRunningJobWithoutProgressShowsItsStage() {
        #expect(SidebarRowText.compactStatus(for: .transcribing, progressPercent: nil, queuePosition: nil) == "Transcribing")
        #expect(SidebarRowText.compactStatus(for: .translating, progressPercent: nil, queuePosition: nil) == "Translating")
        #expect(SidebarRowText.compactStatus(for: .burningIn, progressPercent: nil, queuePosition: nil) == "Burning In")
    }

    @Test func queuedJobsShowTheirPlaceInLine() {
        #expect(SidebarRowText.compactStatus(for: .queued, progressPercent: nil, queuePosition: 3) == "#3")
        #expect(SidebarRowText.compactStatus(for: .queued, progressPercent: nil, queuePosition: nil) == "Queued")
    }

    @Test func aPercentOnlyAppliesToRunningJobs() {
        #expect(SidebarRowText.compactStatus(for: .idle, progressPercent: 50, queuePosition: nil) == "Idle")
        #expect(SidebarRowText.compactStatus(for: .failed, progressPercent: 50, queuePosition: nil) == "Failed")
        #expect(SidebarRowText.compactStatus(for: .transcriptionComplete, progressPercent: 100, queuePosition: 1) == "Transcript")
        #expect(SidebarRowText.compactStatus(for: .translationComplete, progressPercent: 100, queuePosition: 1) == "Translated")
    }

    @Test func everyStatusHasAShortCompactLabel() {
        for status in JobStatus.allCases {
            let text = SidebarRowText.compactStatus(for: status, progressPercent: nil, queuePosition: nil)
            #expect(!text.isEmpty, "\(status) needs a label")
            #expect(text.count <= 12, "\(status) label “\(text)” is too long for a compact row")
        }
        #expect(SidebarRowText.compactStatus(for: .canceled, progressPercent: nil, queuePosition: nil) == "Canceled")
    }

    // MARK: Length

    @Test func lengthReadsAsMinutesAndSecondsUnderAnHour() {
        #expect(SidebarRowText.lengthText(seconds: 1) == "0:01")
        #expect(SidebarRowText.lengthText(seconds: 59.4) == "0:59")
        #expect(SidebarRowText.lengthText(seconds: 60) == "1:00")
        #expect(SidebarRowText.lengthText(seconds: 754) == "12:34")
        #expect(SidebarRowText.lengthText(seconds: 3599) == "59:59")
    }

    @Test func lengthReadsAsHoursFromAnHour() {
        #expect(SidebarRowText.lengthText(seconds: 3600) == "1:00:00")
        #expect(SidebarRowText.lengthText(seconds: 3725) == "1:02:05")
        #expect(SidebarRowText.lengthText(seconds: 36_000) == "10:00:00")
    }

    @Test func lengthIsOmittedWhenThereIsNoTranscriptYet() {
        #expect(SidebarRowText.lengthText(seconds: nil) == nil)
        #expect(SidebarRowText.lengthText(seconds: 0) == nil)
        #expect(SidebarRowText.lengthText(seconds: 0.4) == nil)
        #expect(SidebarRowText.lengthText(seconds: -30) == nil)
    }

    @Test func aDamagedLengthShowsNothingInsteadOfTrapping() {
        #expect(SidebarRowText.lengthText(seconds: .nan) == nil)
        #expect(SidebarRowText.lengthText(seconds: .infinity) == nil)
        #expect(SidebarRowText.lengthText(seconds: -.infinity) == nil)
        #expect(SidebarRowText.lengthText(seconds: 1e300) == nil)
        #expect(SidebarRowText.lengthText(seconds: Double.greatestFiniteMagnitude) == nil)
        #expect(SidebarRowText.lengthText(seconds: SidebarRowText.maximumLengthSeconds + 1) == nil)
        #expect(SidebarRowText.lengthText(seconds: SidebarRowText.maximumLengthSeconds) != nil)
    }

    // MARK: Languages

    private func job(
        source: String = "auto",
        target: String = "English",
        overrideSource: String? = nil,
        overrideTarget: String? = nil
    ) throws -> TranscriptionJob {
        var job = try FolderTestJobs.make(sourcePath: "/v/a.mp4")
        job.settings.sourceLanguage = source
        job.settings.translationTargetLanguage = target
        job.overrides.sourceLanguage = overrideSource
        job.overrides.translationTargetLanguage = overrideTarget
        return job
    }

    @Test func languagesNameTheSourceAndTheTranslationTarget() throws {
        #expect(SidebarRowText.languageText(for: try job(source: "ja", target: "English")) == "Japanese → English")
        #expect(SidebarRowText.languageText(for: try job(source: "auto", target: "Vietnamese")) == "Auto → Vietnamese")
        #expect(SidebarRowText.languageText(for: try job(source: "KO", target: "English")) == "Korean → English")
    }

    @Test func aJobsOwnSettingsOverrideTheDefaults() throws {
        let overridden = try job(source: "ja", target: "English", overrideSource: "zh", overrideTarget: "French")
        #expect(SidebarRowText.languageText(for: overridden) == "Chinese → French")
        let partly = try job(source: "ja", target: "English", overrideTarget: "German")
        #expect(SidebarRowText.languageText(for: partly) == "Japanese → German")
    }

    @Test func withoutATargetOnlyTheSourceShows() throws {
        #expect(SidebarRowText.languageText(for: try job(source: "ja", target: "")) == "Japanese")
        #expect(SidebarRowText.languageText(for: try job(source: "ja", target: "  \n")) == "Japanese")
    }

    @Test func anUnlistedOrBlankLanguageStaysReadable() throws {
        #expect(SidebarRowText.languageText(for: try job(source: "pt", target: "English")) == "pt → English")
        #expect(SidebarRowText.languageText(for: try job(source: "", target: "English")) == "Auto → English")
        #expect(SidebarRowText.languageText(for: try job(source: "  ", target: "")) == "Auto")
    }

    // MARK: Detail line

    @Test func theDetailLineJoinsLanguagesLengthAndDateAdded() {
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        let line = SidebarRowText.detailLine(languages: "Japanese → English", speechSeconds: 754, addedAt: added)
        let date = added.formatted(date: .abbreviated, time: .omitted)
        #expect(line == "Japanese → English · 12:34 · Added \(date)")
    }

    @Test func theDetailLineSkipsALengthThatIsNotKnown() {
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        let date = added.formatted(date: .abbreviated, time: .omitted)
        #expect(
            SidebarRowText.detailLine(languages: "Auto", speechSeconds: nil, addedAt: added) == "Auto · Added \(date)")
        #expect(
            SidebarRowText.detailLine(languages: "Auto", speechSeconds: .nan, addedAt: added) == "Auto · Added \(date)")
    }

    // MARK: Row detail

    @Test func detailTiersGiveUpTheDateThenTheLength() {
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        let tiers = SidebarRowText.detailTiers(
            languages: "Japanese → English", speechSeconds: 3725, addedAt: added, now: added)
        let date = SidebarRowText.shortDate(added, now: added)
        #expect(tiers.complete == "Japanese → English · 1:02:05 · Added \(date)")
        #expect(tiers.withoutDate == "Japanese → English · 1:02:05")
        #expect(tiers.languagesOnly == "Japanese → English")
    }

    @Test func detailTiersWithoutALengthCollapseTheMiddleOne() {
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        let tiers = SidebarRowText.detailTiers(languages: "Auto → English", speechSeconds: nil, addedAt: added, now: added)
        #expect(tiers.withoutDate == "Auto → English")
        #expect(tiers.withoutDate == tiers.languagesOnly)
        #expect(tiers.complete.hasPrefix("Auto → English · Added "))
    }

    @Test func aDateInTheCurrentYearOmitsTheYear() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 29)))
        let sameYear = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20)))
        let earlier = try #require(calendar.date(from: DateComponents(year: 2025, month: 9, day: 20)))
        let recent = SidebarRowText.shortDate(sameYear, now: now, calendar: calendar)
        let old = SidebarRowText.shortDate(earlier, now: now, calendar: calendar)
        #expect(!recent.contains("2026"), "“\(recent)” should not repeat the year")
        #expect(old.contains("2025"), "“\(old)” must keep the year once it is not this year")
        #expect(recent.count < old.count)
    }

    @Test func rowDetailTiersAreTheSameWordingAsTheFullText() throws {
        var job = try FolderTestJobs.make(sourcePath: "/v/a.mp4", createdAt: Date())
        job.settings.sourceLanguage = "ja"
        job.settings.translationTargetLanguage = "English"
        job.transcriptSegments = [TranscriptionSegment(id: 0, start: 0, end: 125, text: "a")]
        let detail = SidebarRowDetail(job: job)
        #expect(detail.tiers.withoutDate == "Japanese → English · 2:05")
        #expect(detail.tiers.languagesOnly == "Japanese → English")
        // The full text keeps the unabridged date for VoiceOver and hover.
        #expect(detail.text.hasPrefix(detail.tiers.withoutDate))
        #expect(detail.text.contains("Added "))
    }

    @Test func rowDetailReadsWhatIsAlreadyInMemory() throws {
        var job = try FolderTestJobs.make(sourcePath: "/v/a.mp4", createdAt: FolderTestJobs.epoch)
        job.settings.sourceLanguage = "ko"
        job.settings.translationTargetLanguage = "English"
        job.transcriptSegments = [
            TranscriptionSegment(id: 0, start: 0, end: 5, text: "a"),
            TranscriptionSegment(id: 1, start: 5, end: 125, text: "b"),
        ]
        let detail = SidebarRowDetail(job: job)
        #expect(detail.languages == "Korean → English")
        #expect(detail.speechSeconds == 125)
        #expect(detail.addedAt == FolderTestJobs.epoch)
        #expect(detail.text.hasPrefix("Korean → English · 2:05 · Added "))
    }

    @Test func rowDetailForAJobWithoutATranscriptHasNoLength() throws {
        let job = try FolderTestJobs.make(sourcePath: "/v/a.mp4")
        let detail = SidebarRowDetail(job: job)
        #expect(detail.speechSeconds == nil)
        #expect(!detail.text.contains(":"), "no length, so no clock text in “\(detail.text)”")
    }

    @Test func rowDetailsAreEqualOnlyWhenTheyShowTheSameThing() throws {
        let job = try FolderTestJobs.make(sourcePath: "/v/a.mp4")
        var changed = job
        changed.transcriptSegments = [TranscriptionSegment(id: 0, start: 0, end: 30, text: "x")]
        #expect(SidebarRowDetail(job: job) == SidebarRowDetail(job: job))
        #expect(SidebarRowDetail(job: job) != SidebarRowDetail(job: changed))
    }
}

/// Which grouping the sidebar shows, given the old and the new setting.
struct SidebarGroupingTests {
    @Test func anExplicitChoiceWinsOverTheLegacySetting() {
        #expect(SidebarGrouping.resolve(stored: "folders", legacyGroupByStatus: true) == .folders)
        #expect(SidebarGrouping.resolve(stored: "none", legacyGroupByStatus: true) == .none)
        #expect(SidebarGrouping.resolve(stored: "status", legacyGroupByStatus: false) == .status)
    }

    @Test func aSidebarGroupedByStatusStaysGroupedByStatus() {
        #expect(SidebarGrouping.resolve(stored: "", legacyGroupByStatus: true) == .status)
    }

    @Test func everyoneElseStartsInFolders() {
        #expect(SidebarGrouping.resolve(stored: "", legacyGroupByStatus: false) == .folders)
    }

    @Test func anUnknownStoredValueFallsBackTheSameWay() {
        #expect(SidebarGrouping.resolve(stored: "sideways", legacyGroupByStatus: false) == .folders)
        #expect(SidebarGrouping.resolve(stored: "sideways", legacyGroupByStatus: true) == .status)
    }
}
