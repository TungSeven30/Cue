import Foundation
import Testing

@testable import Cue

/// The pure arrangement of the folder sidebar: which folders show, in what
/// order, holding which jobs.
struct SidebarFolderLayoutTests {
    private let base = FolderTestJobs.epoch

    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private struct Fixture {
        var book: JobFolderBook
        var ids: [String: UUID]
    }

    /// Folders by name, in the order given (which is the book's stored order).
    private func fixture(_ specs: [(name: String, manual: Bool)]) -> Fixture {
        var ids: [String: UUID] = [:]
        var folders: [JobFolder] = []
        for (index, spec) in specs.enumerated() {
            let folder = JobFolder(
                name: spec.name, sourceKeys: spec.manual ? [] : ["dir:/v/\(spec.name)"],
                isExpanded: true, createdAt: at(TimeInterval(index)), isManual: spec.manual)
            ids[spec.name] = folder.id
            folders.append(folder)
        }
        return Fixture(book: JobFolderBook(folders: folders), ids: ids)
    }

    private func entry(_ fixture: Fixture, _ folder: String?) -> SidebarFolderLayout.Entry {
        SidebarFolderLayout.Entry(id: UUID(), folderID: folder.flatMap { fixture.ids[$0] })
    }

    private func layout(
        _ fixture: Fixture,
        displayed: [SidebarFolderLayout.Entry],
        newest: [String: TimeInterval] = [:],
        order: FolderSortOrder = .recentActivity,
        isFiltering: Bool = false,
        query: String = ""
    ) -> SidebarFolderLayout {
        SidebarFolderLayout.make(
            book: fixture.book,
            displayed: displayed,
            newestActivity: Dictionary(
                uniqueKeysWithValues: newest.compactMap { name, seconds in
                    fixture.ids[name].map { ($0, at(seconds)) }
                }),
            order: order,
            isFiltering: isFiltering,
            searchQuery: query
        )
    }

    private func names(_ layout: SidebarFolderLayout) -> [String] {
        layout.groups.map(\.folder.name)
    }

    // MARK: Membership

    @Test func everyDisplayedJobLandsInItsFolderInDisplayOrder() {
        let f = fixture([("A", false), ("B", false)])
        let a1 = entry(f, "A")
        let b1 = entry(f, "B")
        let a2 = entry(f, "A")
        let result = layout(f, displayed: [a1, b1, a2])
        let a = result.groups.first { $0.folder.name == "A" }
        let b = result.groups.first { $0.folder.name == "B" }
        #expect(a?.jobIDs == [a1.id, a2.id])
        #expect(b?.jobIDs == [b1.id])
        #expect(result.unfiledJobIDs.isEmpty)
    }

    @Test func jobsWithoutAFolderAreUnfiledNotHidden() {
        let f = fixture([("A", false)])
        let filed = entry(f, "A")
        let none = entry(f, nil)
        let result = layout(f, displayed: [none, filed])
        #expect(result.unfiledJobIDs == [none.id])
        #expect(result.groups.flatMap(\.jobIDs) == [filed.id])
    }

    @Test func aJobWhoseFolderNoLongerExistsIsUnfiled() {
        let f = fixture([("A", false)])
        let orphan = SidebarFolderLayout.Entry(id: UUID(), folderID: UUID())
        let result = layout(f, displayed: [orphan])
        #expect(result.unfiledJobIDs == [orphan.id])
        #expect(result.groups.isEmpty)
    }

    @Test func noJobsAndNoFoldersIsAnEmptyLayout() {
        let result = layout(fixture([]), displayed: [])
        #expect(result.groups.isEmpty)
        #expect(result.unfiledJobIDs.isEmpty)
    }

    // MARK: Empty folders

    @Test func emptyAutomaticFoldersAreHidden() {
        let f = fixture([("Shown", false), ("Hidden", false)])
        let result = layout(f, displayed: [entry(f, "Shown")])
        #expect(names(result) == ["Shown"])
    }

    @Test func emptyManualFoldersStayVisible() {
        let f = fixture([("Shown", false), ("Mine", true)])
        let result = layout(f, displayed: [entry(f, "Shown")])
        #expect(Set(names(result)) == ["Shown", "Mine"])
        #expect(result.groups.first { $0.folder.name == "Mine" }?.jobIDs == [])
    }

    @Test func aStatusFilterHidesEmptyManualFoldersToo() {
        let f = fixture([("Shown", false), ("Mine", true)])
        let result = layout(f, displayed: [entry(f, "Shown")], isFiltering: true)
        #expect(names(result) == ["Shown"])
    }

    @Test func aFolderWithJobsShowsWhateverTheFilter() {
        let f = fixture([("Mine", true)])
        let result = layout(f, displayed: [entry(f, "Mine")], isFiltering: true, query: "zzz")
        #expect(names(result) == ["Mine"])
    }

    // MARK: Search by folder name

    @Test func searchingAFoldersNameKeepsItsEmptyManualFolderVisible() {
        let f = fixture([("Season 2", true), ("Extras", true)])
        let result = layout(f, displayed: [], isFiltering: true, query: "season")
        #expect(names(result) == ["Season 2"])
    }

    @Test func searchIgnoresCaseAndSurroundingSpaces() {
        let f = fixture([("Season 2", true)])
        #expect(names(layout(f, displayed: [], isFiltering: true, query: "  SEASON  ")) == ["Season 2"])
    }

    @Test func aSearchThatMatchesNoFolderNameShowsNoEmptyFolders() {
        let f = fixture([("Season 2", true), ("Extras", true)])
        #expect(layout(f, displayed: [], isFiltering: true, query: "movie").groups.isEmpty)
    }

    @Test func searchNeverRevealsAnEmptyAutomaticFolder() {
        let f = fixture([("Season 2", false)])
        #expect(layout(f, displayed: [], isFiltering: true, query: "season").groups.isEmpty)
    }

    @Test func aBlankSearchIsNotASearch() {
        let f = fixture([("Season 2", true)])
        #expect(layout(f, displayed: [], isFiltering: true, query: "   ").groups.isEmpty)
        #expect(names(layout(f, displayed: [], isFiltering: false, query: "   ")) == ["Season 2"])
    }

    // MARK: Order

    @Test func newestJobFirstOrdersFoldersByTheirNewestJob() {
        let f = fixture([("Old", false), ("New", false), ("Middle", false)])
        let displayed = [entry(f, "Old"), entry(f, "New"), entry(f, "Middle")]
        let result = layout(
            f, displayed: displayed, newest: ["Old": 10, "New": 300, "Middle": 200], order: .recentActivity)
        #expect(names(result) == ["New", "Middle", "Old"])
    }

    @Test func nameOrderIsNaturalAndIgnoresActivity() {
        let f = fixture([("Season 10", false), ("Season 2", false), ("alpha", false)])
        let displayed = [entry(f, "Season 10"), entry(f, "Season 2"), entry(f, "alpha")]
        let result = layout(
            f, displayed: displayed, newest: ["Season 10": 900, "Season 2": 1, "alpha": 50], order: .name)
        #expect(names(result) == ["alpha", "Season 2", "Season 10"])
    }

    @Test func equalActivityFallsBackToTheNameSoNothingShuffles() {
        let f = fixture([("Bravo", false), ("Alpha", false), ("Charlie", false)])
        let displayed = [entry(f, "Bravo"), entry(f, "Alpha"), entry(f, "Charlie")]
        let same = ["Bravo": 5.0, "Alpha": 5.0, "Charlie": 5.0]
        let first = layout(f, displayed: displayed, newest: same)
        let second = layout(f, displayed: displayed.reversed(), newest: same)
        #expect(names(first) == ["Alpha", "Bravo", "Charlie"])
        #expect(names(second) == names(first))
    }

    @Test func aFolderWithoutARecordedDateUsesItsCreationDate() {
        let f = fixture([("First", true), ("Second", true), ("Third", true)])
        // Created at +0, +1, +2 seconds, all empty: newest created comes first.
        let result = layout(f, displayed: [], order: .recentActivity)
        #expect(names(result) == ["Third", "Second", "First"])
    }

    @Test func emptyManualFoldersSortAmongTheOthers() {
        let f = fixture([("Auto", false), ("Mine", true)])
        let displayed = [entry(f, "Auto")]
        let byName = layout(f, displayed: displayed, newest: ["Auto": 100], order: .name)
        #expect(names(byName) == ["Auto", "Mine"])
        // Mine was created at +1s (base + 1); Auto's newest job is at +100s.
        let byActivity = layout(f, displayed: displayed, newest: ["Auto": 100], order: .recentActivity)
        #expect(names(byActivity) == ["Auto", "Mine"])
        let mineNewer = layout(f, displayed: displayed, newest: ["Auto": -50], order: .recentActivity)
        #expect(names(mineNewer) == ["Mine", "Auto"])
    }

    @Test func filteringDoesNotReorderFolders() {
        let f = fixture([("Old", false), ("New", false)])
        let oldJob = entry(f, "Old")
        let newJob = entry(f, "New")
        let newest = ["Old": 10.0, "New": 500.0]
        let everything = layout(f, displayed: [oldJob, newJob], newest: newest)
        // Only the older folder's job passes the filter; the newest-activity
        // figures still come from all of each folder's jobs.
        let filtered = layout(f, displayed: [oldJob], newest: newest, isFiltering: true)
        #expect(names(everything) == ["New", "Old"])
        #expect(names(filtered) == ["Old"])
        let both = layout(f, displayed: [oldJob, newJob], newest: newest, isFiltering: true)
        #expect(names(both) == names(everything))
    }

    // MARK: Layout equality

    @Test func aLayoutEqualsItselfAndDiffersWhenAJobMoves() {
        let f = fixture([("A", false), ("B", false)])
        let job = UUID()
        let inA = layout(f, displayed: [.init(id: job, folderID: f.ids["A"])])
        let alsoInA = layout(f, displayed: [.init(id: job, folderID: f.ids["A"])])
        let inB = layout(f, displayed: [.init(id: job, folderID: f.ids["B"])])
        #expect(inA == alsoInA)
        #expect(inA != inB)
    }
}
