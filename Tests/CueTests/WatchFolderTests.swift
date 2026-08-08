import Foundation
import Testing
@testable import Cue

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

    // Spec §2.3 rules 3+4: ledger fingerprints and existing-job fingerprints
    // both block, regardless of job status.
    @Test func blockedFingerprintsAreSkipped() {
        var engine = WatchFolderScanEngine()
        let file = observation("/w/movie.mp4", size: 7, mtime: 99)
        let fingerprint = WatchFolderScanEngine.fingerprint(for: file)
        _ = engine.filesReadyToIngest(observations: [file], now: base, blockedFingerprints: [])
        let ready = engine.filesReadyToIngest(observations: [file], now: base.addingTimeInterval(3), blockedFingerprints: [fingerprint])
        #expect(ready.isEmpty)
    }

    // A file that vanishes mid-wait and is later re-copied at the same
    // path/size must restart the stability clock, or a scan could catch the
    // new copy passing through the old byte count and ingest a partial file.
    @Test func vanishedCandidateRestartsTheClock() {
        var engine = WatchFolderScanEngine()
        _ = engine.filesReadyToIngest(observations: [observation("/w/movie.mkv", size: 1000)], now: base, blockedFingerprints: [])
        // File disappears from the folder entirely.
        _ = engine.filesReadyToIngest(observations: [], now: base.addingTimeInterval(1), blockedFingerprints: [])
        // Re-copied at the same size: first sighting again, never ingested.
        let tooSoon = engine.filesReadyToIngest(observations: [observation("/w/movie.mkv", size: 1000)], now: base.addingTimeInterval(3), blockedFingerprints: [])
        #expect(tooSoon.isEmpty)
        let ready = engine.filesReadyToIngest(observations: [observation("/w/movie.mkv", size: 1000)], now: base.addingTimeInterval(6), blockedFingerprints: [])
        #expect(ready.map(\.path) == ["/w/movie.mkv"])
    }

    // Unblocking (e.g. deleting a canceled job) must not inherit a stale
    // stability clock from scans made while the file was blocked.
    @Test func unblockedFileNeedsTwoFreshSightings() {
        var engine = WatchFolderScanEngine()
        let file = observation("/w/movie.mp4", size: 7, mtime: 99)
        let fingerprint = WatchFolderScanEngine.fingerprint(for: file)
        _ = engine.filesReadyToIngest(observations: [file], now: base, blockedFingerprints: [fingerprint])
        // Unblocked now, but the first blocked pass must not count as a sighting.
        let first = engine.filesReadyToIngest(observations: [file], now: base.addingTimeInterval(3), blockedFingerprints: [])
        #expect(first.isEmpty)
        let ready = engine.filesReadyToIngest(observations: [file], now: base.addingTimeInterval(6), blockedFingerprints: [])
        #expect(ready.map(\.path) == ["/w/movie.mp4"])
    }

    @Test func fingerprintMatchesTranscriptionJobFormat() {
        let file = observation("/w/movie.mp4", size: 7, mtime: 99)
        #expect(WatchFolderScanEngine.fingerprint(for: file) == "/w/movie.mp4|7|99.0")
    }
}

@MainActor
struct WatchFolderLedgerTests {
    private func makeBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-ledger-\(UUID().uuidString)")
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

    // Mirrors AppModel's onScanCompleted prune predicate: a subfolder that's
    // transiently unreadable/unmounted drops its files from existingPaths,
    // but the file is still on disk, so its ledger entry must survive —
    // otherwise it re-ingests as a duplicate once the subfolder is readable
    // again. A truly deleted file (missing from existingPaths AND disk) is
    // still pruned.
    @Test func pruneKeepsEntriesForTransientlyUnreadableSubfolders() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let ledger = WatchFolderLedger(baseURL: base)

        let survivingFile = base.appendingPathComponent("subfolder/survives.mp4")
        try FileManager.default.createDirectory(at: survivingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: survivingFile)
        let goneFile = base.appendingPathComponent("subfolder/gone.mp4") // never created

        let survivingFingerprint = "\(survivingFile.path)|1|2.0"
        let goneFingerprint = "\(goneFile.path)|1|2.0"
        ledger.record(survivingFingerprint, outcome: .success)
        ledger.record(goneFingerprint, outcome: .success)

        // Scan came back empty this pass (e.g. the subfolder was unreadable).
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let existingPaths: Set<String> = []
        ledger.prune(fileExists: { path in
            !path.hasPrefix(prefix) || existingPaths.contains(path) || FileManager.default.fileExists(atPath: path)
        })

        #expect(ledger.contains(survivingFingerprint), "still on disk, must survive a scan miss")
        #expect(!ledger.contains(goneFingerprint), "truly deleted, must be pruned")
    }

    @Test func pathExtractionSurvivesPipesInNames() {
        #expect(WatchFolderLedger.path(fromFingerprint: "/w/we|ird.mp4|1|2.0") == "/w/we|ird.mp4")
    }

    @Test func scopedClearLeavesOtherFolders() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let ledger = WatchFolderLedger(baseURL: base)
        ledger.record("/inbox-a/movie.mp4|1|2.0", outcome: .success)
        ledger.record("/inbox-b/movie.mp4|1|2.0", outcome: .success)
        // A path that merely shares the prefix string must not match.
        ledger.record("/inbox-a-archive/movie.mp4|1|2.0", outcome: .success)
        ledger.clear(underPath: "/inbox-a")
        #expect(!ledger.contains("/inbox-a/movie.mp4|1|2.0"))
        #expect(ledger.contains("/inbox-b/movie.mp4|1|2.0"))
        #expect(ledger.contains("/inbox-a-archive/movie.mp4|1|2.0"))
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


@MainActor
struct WatchFolderServiceTests {
    @Test func observesMediaFilesInSubfolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-recursive-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("season1", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("top.mp4").path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: sub.appendingPathComponent("ep1.mkv").path, contents: Data("xx".utf8))
        FileManager.default.createFile(atPath: sub.appendingPathComponent("notes.txt").path, contents: Data())

        let observations = try #require(WatchFolderService.observeMediaFiles(underPath: root.path))
        let names = Set(observations.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        #expect(names == ["top.mp4", "ep1.mkv"])
        let sizes = Dictionary(uniqueKeysWithValues: observations.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.size) })
        #expect(sizes["ep1.mkv"] == 2)
    }

    @Test func observeMediaFilesReturnsNilForMissingFolder() {
        #expect(WatchFolderService.observeMediaFiles(underPath: "/nonexistent/\(UUID().uuidString)") == nil)
    }

    @Test func observeMediaFilesReturnsNilForUnreadableFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            // Restore permissions before cleanup, or removeItem fails on the
            // still-locked-down directory.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)

        #expect(WatchFolderService.observeMediaFiles(underPath: root.path) == nil)
    }
}

struct WatchFolderModelTests {
    @Test func legacySingleFolderFieldsDecodeWithDefaults() throws {
        // Only path is required; id/enabled/profile default, so a settings
        // blob from an older build (or a hand-edited one) still loads.
        let folder = try JSONDecoder().decode(WatchFolder.self, from: Data(#"{"path":"/w/inbox"}"#.utf8))
        #expect(folder.enabled)
        #expect(folder.profile.isEmpty)
        #expect(folder.name == "inbox")
    }

    @Test func roundTripsWithProfile() throws {
        var folder = WatchFolder(path: "/w/dramas")
        folder.profile.translationTargetLanguage = "Vietnamese"
        folder.enabled = false
        let back = try JSONDecoder().decode(WatchFolder.self, from: JSONEncoder().encode(folder))
        #expect(back == folder)
    }
}
