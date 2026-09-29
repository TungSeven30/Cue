import Foundation
import Testing
@testable import Cue

/// The pure folder rules: where a job lands by default, what a rename keeps,
/// how merges and deletes move keys, how the list is ordered and searched.
struct JobFolderTests {
    private func input(
        _ path: String,
        at seconds: TimeInterval = 0,
        id: UUID = UUID(),
        origin: JobOrigin = .manual,
        folderID: UUID? = nil,
        logHead: String = ""
    ) -> FolderPlacementInput {
        FolderPlacementInput(
            jobID: id,
            sourcePath: path,
            origin: origin,
            createdAt: FolderTestJobs.epoch.addingTimeInterval(seconds),
            folderID: folderID,
            logHead: logHead
        )
    }

    // MARK: Placement keys

    @Test func directoryKeyUsesTheParentFolderName() {
        let key = FolderPlacement.directoryKey(forFileAt: "/Users/me/Movies/Actress A/clip.mp4")
        #expect(key.key == "dir:/Users/me/Movies/Actress A")
        #expect(key.name == "Actress A")
        #expect(key.qualifier == "Movies")
    }

    @Test func filesInTheRootGetAFilesFolder() {
        let key = FolderPlacement.directoryKey(forFileAt: "/clip.mp4")
        #expect(key.key == "dir:/")
        #expect(key.name == "Files")
        #expect(key.qualifier == nil)
    }

    @Test func pathsAreNormalisedLexically() {
        #expect(FolderPlacement.normalizedPath("/a//b/./c/../d") == "/a/b/d")
        #expect(FolderPlacement.normalizedPath("/private/tmp/a/../b//c") == "/tmp/b/c")
        #expect(FolderPlacement.normalizedPath("/private/var/folders/x") == "/var/folders/x")
        #expect(FolderPlacement.normalizedPath("/private/Users/x") == "/private/Users/x")
        let viaEnumerator = FolderPlacement.directoryKey(forFileAt: "/private/var/folders/x/Show/clip.mp4")
        let viaDrop = FolderPlacement.directoryKey(forFileAt: "/var/folders/x/Show/clip.mp4")
        #expect(viaEnumerator.key == viaDrop.key)
    }

    @Test func watchFolderSubfoldersBecomeTheirOwnFolders() {
        let studio = FolderPlacement.key(sourcePath: "/Watch/Studio X/2025/clip.mp4", origin: .watchFolder)
        let actress = FolderPlacement.key(sourcePath: "/Watch/Actress Y/clip.mp4", origin: .watchFolder)
        #expect(studio.name == "2025")
        #expect(studio.qualifier == "Studio X")
        #expect(actress.name == "Actress Y")
        #expect(studio.key != actress.key)
    }

    @Test func downloadsPlaceBySiteWhenTheHostIsKnown() {
        let log = "Downloaded from https://www.YouTube.com/watch?v=abc123.\nQueued."
        let key = FolderPlacement.key(sourcePath: "/Users/me/Downloads/clip.mp4", origin: .url, logHead: log)
        #expect(key.key == "site:youtube.com")
        #expect(key.name == "youtube.com")
        #expect(key.qualifier == nil)
    }

    @Test func siteAliasesCollapse() {
        func host(_ page: String) -> String? {
            FolderPlacement.downloadHost(inLogHead: "Downloaded from \(page).")
        }
        #expect(host("https://youtu.be/xyz") == "youtube.com")
        #expect(host("https://m.youtube.com/watch?v=1") == "youtube.com")
        #expect(host("https://mobile.example.org/a") == "example.org")
        #expect(host("https://www.example.org:8080/a") == "example.org")
    }

    @Test func unknownDownloadHostFallsBackToTheDirectory() {
        let noNote = FolderPlacement.key(sourcePath: "/Users/me/Downloads/clip.mp4", origin: .url, logHead: "")
        #expect(noNote.key == "dir:/Users/me/Downloads")
        let garbage = FolderPlacement.key(
            sourcePath: "/Users/me/Downloads/clip.mp4", origin: .url, logHead: "Downloaded from not a url at all.")
        #expect(garbage.key == "dir:/Users/me/Downloads")
    }

    @Test func onlyDownloadsLookAtTheLog() {
        let log = "Downloaded from https://example.com/a."
        let manual = FolderPlacement.key(sourcePath: "/Users/me/Movies/clip.mp4", origin: .manual, logHead: log)
        #expect(manual.key == "dir:/Users/me/Movies")
    }

    @Test func inputFromAJobReadsTheLogHeadOnlyForDownloads() throws {
        let longLog = "Downloaded from https://example.com/a.\n" + String(repeating: "x", count: 5_000)
        let download = try FolderTestJobs.make(sourcePath: "/d/clip.mp4", origin: .url, log: longLog)
        let manual = try FolderTestJobs.make(sourcePath: "/d/clip.mp4", origin: .manual, log: longLog)
        #expect(FolderPlacementInput(download).logHead.count == 512)
        #expect(FolderPlacementInput(manual).logHead.isEmpty)
        #expect(FolderPlacement.key(for: FolderPlacementInput(download)).key == "site:example.com")
    }

    // MARK: Automatic placement

    @Test func jobsFromTheSameDirectoryShareOneAutomaticFolder() {
        var book = JobFolderBook()
        let ids = FolderIDSequence()
        let a = input("/v/Show/a.mp4", at: 1)
        let b = input("/v/Show/b.mp4", at: 2)
        let c = input("/v/Other/c.mp4", at: 3)
        let assigned = book.place([c, b, a], makeID: ids.make)

        #expect(book.folders.map(\.name) == ["Show", "Other"])
        #expect(assigned[a.jobID] == assigned[b.jobID])
        #expect(assigned[a.jobID] != assigned[c.jobID])
        #expect(book.folders.allSatisfy { !$0.isManual && $0.isExpanded })
        #expect(book.folders[0].sourceKeys == ["dir:/v/Show"])
    }

    @Test func downloadsFromOneSiteShareAFolder() {
        var book = JobFolderBook()
        let note = "Downloaded from https://vimeo.com/1."
        let a = input("/dl/a.mp4", origin: .url, logHead: note)
        let b = input("/other/b.mp4", origin: .url, logHead: "Downloaded from https://www.vimeo.com/2.")
        let assigned = book.place([a, b])
        #expect(assigned[a.jobID] == assigned[b.jobID])
        #expect(book.folders.map(\.name) == ["vimeo.com"])
        #expect(book.folders[0].sourceKeys == ["site:vimeo.com"])
    }

    @Test func existingAssignmentsAreKeptAndUnknownOnesReplaced() {
        var book = JobFolderBook()
        let keep = book.createManualFolder(named: "Keepers")!
        let kept = input("/v/Show/a.mp4", folderID: keep)
        let orphan = input("/v/Show/b.mp4", folderID: UUID())
        let assigned = book.place([kept, orphan])
        #expect(assigned[kept.jobID] == nil)
        #expect(assigned[orphan.jobID] != nil)
        #expect(assigned[orphan.jobID] != keep)
    }

    @Test func placementIsIdempotent() {
        var book = JobFolderBook()
        let first = input("/v/Show/a.mp4")
        let assigned = book.place([first])
        let placed = input("/v/Show/a.mp4", id: first.jobID, folderID: assigned[first.jobID])
        let snapshot = book
        #expect(book.place([placed]).isEmpty)
        #expect(book == snapshot)
    }

    @Test func newFoldersCollidingInABatchAreBothQualified() {
        var book = JobFolderBook()
        let one = input("/tv/Season 1/Extras/a.mp4", at: 1)
        let two = input("/tv/Season 2/Extras/b.mp4", at: 2)
        _ = book.place([one, two])
        #expect(book.folders.map(\.name) == ["Extras (Season 1)", "Extras (Season 2)"])
    }

    @Test func aNewFolderCollidingWithAnExistingOneIsQualified() {
        var book = JobFolderBook()
        book.createManualFolder(named: "extras")
        let job = input("/tv/Season 1/Extras/a.mp4")
        let assigned = book.place([job])
        let created = book.folder(withID: assigned[job.jobID]!)
        #expect(created?.name == "Extras (Season 1)")
        #expect(book.folders.map(\.name) == ["extras", "Extras (Season 1)"])
    }

    @Test func collisionsWithoutAQualifierAreNumbered() {
        var book = JobFolderBook()
        book.createManualFolder(named: "Show")
        book.createManualFolder(named: "Show 2")
        let job = input("/Show/a.mp4")
        let assigned = book.place([job])
        #expect(book.folder(withID: assigned[job.jobID]!)?.name == "Show 3")
    }

    @Test func placementOrderDoesNotDependOnInputOrder() {
        let inputs = (0..<6).map { input("/v/Dir\($0 % 3)/clip\($0).mp4", at: TimeInterval($0)) }
        var forward = JobFolderBook()
        var backward = JobFolderBook()
        let forwardIDs = FolderIDSequence()
        let backwardIDs = FolderIDSequence()
        _ = forward.place(inputs, makeID: forwardIDs.make)
        _ = backward.place(inputs.reversed(), makeID: backwardIDs.make)
        #expect(forward.folders.map(\.name) == backward.folders.map(\.name))
        #expect(forward.folders.map(\.id) == backward.folders.map(\.id))
    }

    // MARK: Names, rename, create

    @Test func namesAreTrimmedSingleLineAndCapped() {
        #expect(JobFolderBook.sanitizedName("  Show\nTwo  ") == "Show Two")
        #expect(JobFolderBook.sanitizedName("Show\r\nTwo") == "Show Two")
        #expect(JobFolderBook.sanitizedName("   \n ") == nil)
        #expect(JobFolderBook.sanitizedName(String(repeating: "a", count: 500))?.count == JobFolderBook.maximumNameLength)
    }

    @Test func renameKeepsSourceKeysSoFutureJobsLandInTheRenamedFolder() {
        var book = JobFolderBook()
        let first = input("/v/Show/a.mp4")
        let folderID = book.place([first])[first.jobID]!

        #expect(book.rename(folderID, to: "  My Show  ") == .accepted("My Show"))
        #expect(book.folder(withID: folderID)?.sourceKeys == ["dir:/v/Show"])

        let later = input("/v/Show/b.mp4")
        #expect(book.place([later])[later.jobID] == folderID)
        #expect(book.folders.count == 1)
    }

    @Test func renameRejectsEmptyAndDuplicateNamesButAllowsRecasing() {
        var book = JobFolderBook()
        let a = book.createManualFolder(named: "Alpha")!
        let b = book.createManualFolder(named: "Beta")!
        #expect(book.rename(b, to: "   ") == .empty)
        #expect(book.rename(b, to: "ALPHA") == .duplicate)
        #expect(book.rename(b, to: "alpha") == .duplicate)
        #expect(book.rename(a, to: "ALPHA") == .accepted("ALPHA"))
        #expect(book.folder(withID: b)?.name == "Beta")
        #expect(book.rename(UUID(), to: "Gamma") == .empty)
    }

    @Test func duplicateDetectionIgnoresCaseAndDiacritics() {
        var book = JobFolderBook()
        book.createManualFolder(named: "Café")
        #expect(book.isNameTaken("cafe"))
        #expect(book.createManualFolder(named: "CAFE") == nil)
        #expect(book.validatedName("cafe") == .duplicate)
    }

    @Test func manualFoldersStartEmptyExpandedAndKeyless() {
        var book = JobFolderBook()
        let id = book.createManualFolder(named: "Favourites")!
        let folder = book.folder(withID: id)
        #expect(folder?.isManual == true)
        #expect(folder?.isExpanded == true)
        #expect(folder?.sourceKeys.isEmpty == true)
        #expect(book.createManualFolder(named: "  ") == nil)
    }

    @Test func suggestedNamesCountUp() {
        var book = JobFolderBook()
        #expect(book.suggestedNewFolderName() == "New Folder")
        book.createManualFolder(named: "New Folder")
        #expect(book.suggestedNewFolderName() == "New Folder 2")
        book.createManualFolder(named: "New Folder 2")
        #expect(book.suggestedNewFolderName() == "New Folder 3")
    }

    // MARK: Expansion

    @Test func expansionIsPerFolderAndBulk() {
        var book = JobFolderBook()
        let a = book.createManualFolder(named: "A")!
        let b = book.createManualFolder(named: "B")!
        book.setExpanded(false, for: a)
        #expect(book.folder(withID: a)?.isExpanded == false)
        #expect(book.folder(withID: b)?.isExpanded == true)
        book.setAllExpanded(false)
        #expect(book.folders.allSatisfy { !$0.isExpanded })
        book.setAllExpanded(true)
        #expect(book.folders.allSatisfy { $0.isExpanded })
    }

    // MARK: Merge, delete, restore

    @Test func adoptingKeysSendsFutureJobsToTheSurvivingFolder() {
        var book = JobFolderBook()
        let ids = FolderIDSequence()
        let a = input("/v/A/a.mp4", at: 1)
        let b = input("/v/B/b.mp4", at: 2)
        let assigned = book.place([a, b], makeID: ids.make)
        let target = assigned[a.jobID]!
        let source = assigned[b.jobID]!

        let sourceKeys = book.folder(withID: source)!.sourceKeys
        book.adopt(keys: sourceKeys, into: target)
        _ = book.remove(source)

        #expect(book.folders.map(\.id) == [target])
        #expect(Set(book.folder(withID: target)!.sourceKeys) == ["dir:/v/A", "dir:/v/B"])
        let later = input("/v/B/next.mp4")
        #expect(book.place([later])[later.jobID] == target)
    }

    @Test func adoptTakesAKeyFromItsPreviousOwner() {
        var book = JobFolderBook()
        let a = input("/v/A/a.mp4", at: 1)
        let b = input("/v/B/b.mp4", at: 2)
        let assigned = book.place([a, b])
        let first = assigned[a.jobID]!
        let second = assigned[b.jobID]!
        book.adopt(keys: ["dir:/v/B"], into: first)
        #expect(book.folder(withID: second)?.sourceKeys.isEmpty == true)
        #expect(book.folderID(forKey: "dir:/v/B") == first)
    }

    @Test func removedFoldersLoseTheirKeysUntilRestored() {
        var book = JobFolderBook()
        let job = input("/v/Show/a.mp4")
        let folderID = book.place([job])[job.jobID]!
        let removed = book.remove(folderID)!
        #expect(book.folders.isEmpty)
        #expect(book.folderID(forKey: "dir:/v/Show") == nil)
        #expect(book.remove(folderID) == nil)

        book.restore(removed)
        #expect(book.folder(withID: folderID) == removed)
        #expect(book.folderID(forKey: "dir:/v/Show") == folderID)
    }

    @Test func restoreDoesNotStealKeysAnotherFolderClaimedMeanwhile() {
        var book = JobFolderBook()
        let job = input("/v/Show/a.mp4")
        let folderID = book.place([job])[job.jobID]!
        let removed = book.remove(folderID)!

        let replacement = input("/v/Show/b.mp4")
        let replacementFolder = book.place([replacement])[replacement.jobID]!
        book.restore(removed)

        #expect(book.folderID(forKey: "dir:/v/Show") == replacementFolder)
        #expect(book.folder(withID: folderID)?.sourceKeys.isEmpty == true)
    }

    @Test func restoreReplacesTheFolderWithTheSameID() {
        var book = JobFolderBook()
        let id = book.createManualFolder(named: "Old")!
        var edited = book.folder(withID: id)!
        edited.name = "Older"
        book.restore(edited)
        #expect(book.folders.count == 1)
        #expect(book.folder(withID: id)?.name == "Older")
    }

    // MARK: Repairing what was on disk

    @Test func initRepairsDuplicatesAndBlankNames() {
        let id = UUID()
        let first = JobFolder(id: id, name: "One", sourceKeys: ["dir:/a", "dir:/a", "dir:/b"])
        let sameID = JobFolder(id: id, name: "Impostor", sourceKeys: ["dir:/z"])
        let claimsKey = JobFolder(name: "  ", sourceKeys: ["dir:/b", "dir:/c"])
        let book = JobFolderBook(folders: [first, sameID, claimsKey])

        #expect(book.folders.count == 2)
        #expect(book.folders[0].sourceKeys == ["dir:/a", "dir:/b"])
        #expect(book.folders[1].name == "Folder")
        #expect(book.folders[1].sourceKeys == ["dir:/c"])
        #expect(book.folderID(forKey: "dir:/b") == id)
        #expect(book.folder(withID: id)?.name == "One")
    }

    @Test func aFolderDecodesFromMinimalJSON() throws {
        let id = UUID()
        let data = Data(#"{"id": "\#(id.uuidString)"}"#.utf8)
        let folder = try JSONDecoder().decode(JobFolder.self, from: data)
        #expect(folder.id == id)
        #expect(folder.name.isEmpty)
        #expect(folder.sourceKeys.isEmpty)
        #expect(folder.isExpanded)
        #expect(!folder.isManual)
    }

    // MARK: Display order and search

    @Test func recentActivityOrdersNewestFirstThenByNaturalName() {
        struct Item {
            var name: String
            var newest: Date
        }
        let base = FolderTestJobs.epoch
        let items = [
            Item(name: "Folder 10", newest: base),
            Item(name: "Folder 2", newest: base),
            Item(name: "Fresh", newest: base.addingTimeInterval(100)),
            Item(name: "Old", newest: base.addingTimeInterval(-100)),
        ]
        let recent = FolderSortOrder.recentActivity.sorted(items, name: \.name, newestActivity: \.newest)
        #expect(recent.map(\.name) == ["Fresh", "Folder 2", "Folder 10", "Old"])
        let byName = FolderSortOrder.name.sorted(items, name: \.name, newestActivity: \.newest)
        #expect(byName.map(\.name) == ["Folder 2", "Folder 10", "Fresh", "Old"])
    }

    @Test func groupingAndSortRawValuesAreStable() {
        #expect(SidebarGrouping.allCases.map(\.rawValue) == ["folders", "status", "none"])
        #expect(SidebarGrouping.allCases.map(\.label) == ["Folders", "Status", "None"])
        #expect(FolderSortOrder.allCases.map(\.rawValue) == ["recentActivity", "name"])
    }

    @Test func searchMatchesTitlesAndFolderNames() {
        #expect(JobSearch.matches(title: "Episode 4", folderName: "Season 2", query: ""))
        #expect(JobSearch.matches(title: "Episode 4", folderName: nil, query: "   "))
        #expect(JobSearch.matches(title: "Episode 4", folderName: "Season 2", query: "episode"))
        #expect(JobSearch.matches(title: "Episode 4", folderName: "Season 2", query: "season"))
        #expect(JobSearch.matches(title: "Episode 4", folderName: "Season 2", query: "  SEASON  "))
        #expect(!JobSearch.matches(title: "Episode 4", folderName: "Season 2", query: "movie"))
        #expect(!JobSearch.matches(title: "Episode 4", folderName: nil, query: "season"))
    }
}
