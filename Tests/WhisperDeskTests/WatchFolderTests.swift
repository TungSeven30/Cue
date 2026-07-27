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

    @Test func fingerprintMatchesTranscriptionJobFormat() {
        let file = observation("/w/movie.mp4", size: 7, mtime: 99)
        #expect(WatchFolderScanEngine.fingerprint(for: file) == "/w/movie.mp4|7|99.0")
    }
}
