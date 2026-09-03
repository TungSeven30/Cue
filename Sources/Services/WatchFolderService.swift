import AppKit
import Foundation

/// Watches one folder and periodically reports files ready to ingest.
/// Detection strategy (spec §2.2): a kqueue DispatchSource on the folder is
/// the low-latency hint, a 60-second timer plus wake/launch scans are the
/// truth. scan() is idempotent, so redundant triggers are free.
@MainActor
final class WatchFolderService: ObservableObject {
    static let rescanInterval: TimeInterval = 60

    private var engine = WatchFolderScanEngine()
    private var folderDescriptor: CInt = -1
    private var folderSource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private(set) var watchedPath: String?
    /// Set when the folder cannot be read; shown in Settings (spec errors).
    @Published private(set) var lastError: String?

    /// Fingerprints that must not be ingested (ledger + all existing jobs).
    var blockedFingerprints: () -> Set<String> = { [] }
    /// Called with files that passed every scan rule.
    var onFilesReady: ([URL]) -> Void = { _ in }
    /// Ledger entries under the watched folder whose files the scan should
    /// re-verify on disk (off the main thread) before they count as gone.
    var ledgerPathsUnderFolder: (_ folderPath: String) -> [String] = { _ in [] }
    /// A scan in flight; a request arriving meanwhile runs one more pass
    /// afterwards instead of enumerating the same folder twice at once.
    private var isScanning = false
    private var rescanRequested = false
    /// Lets the ledger prune entries for files that vanished. Reports the
    /// folder that was scanned so the caller can scope pruning to it —
    /// entries for other folders must survive a folder switch.
    var onScanCompleted: (_ folderPath: String, _ existingPaths: Set<String>) -> Void = { _, _ in }

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
                Task { @MainActor in self?.scan() }
            }
            source.setCancelHandler { [descriptor = folderDescriptor] in
                close(descriptor)
            }
            source.resume()
            folderSource = source
        } else {
            lastError = "Could not open the watch folder. Check that it exists and is readable."
        }

        let rescanTimer = Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        // Generous tolerance lets macOS coalesce wakeups; the cadence is a
        // safety net, not a deadline.
        rescanTimer.tolerance = 5
        timer = rescanTimer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
    }

    func stop() {
        lastError = nil
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

    /// Snapshot of every media file under the folder, at any depth. `nil`
    /// when the folder itself is unreadable (unmounted volume), so callers
    /// can distinguish "gone" from "empty".
    nonisolated static func observeMediaFiles(underPath path: String) -> [FileObservation]? {
        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        var probeIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &probeIsDirectory), probeIsDirectory.boolValue else {
            return nil
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return nil
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        return MediaFileTypes.collectMediaFiles(under: folderURL).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { return nil }
            return FileObservation(
                path: url.path,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    func scan() {
        guard let watchedPath else { return }
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        let ledgerPaths = ledgerPathsUnderFolder(watchedPath)
        Task { [weak self] in
            // Enumerating a large or network-mounted folder and stat-ing the
            // ledger's entries can take seconds; both stay off the main
            // thread so the sidebar never freezes on the rescan timer.
            let snapshot = await Task.detached(priority: .utility) {
                let observations = Self.observeMediaFiles(underPath: watchedPath)
                let stillPresent = ledgerPaths.filter { FileManager.default.fileExists(atPath: $0) }
                return (observations: observations, stillPresent: stillPresent)
            }.value
            guard let self else { return }
            self.isScanning = false
            // Stopped or re-pointed while enumerating: the result is stale,
            // but a queued rescan request still belongs to the new folder.
            if self.watchedPath == watchedPath {
                self.apply(
                    observations: snapshot.observations,
                    stillPresentLedgerPaths: snapshot.stillPresent,
                    folderPath: watchedPath
                )
            }
            if self.rescanRequested {
                self.rescanRequested = false
                self.scan()
            }
        }
    }

    private func apply(observations: [FileObservation]?, stillPresentLedgerPaths: [String], folderPath: String) {
        guard let observations else {
            // Do not spin or tear down: the folder may be a briefly
            // unmounted volume. The timer keeps trying; Settings shows this.
            lastError = "The watch folder could not be read."
            return
        }
        lastError = nil

        let ready = engine.filesReadyToIngest(
            observations: observations,
            now: Date(),
            blockedFingerprints: blockedFingerprints()
        )
        onScanCompleted(folderPath, Set(observations.map(\.path)).union(stillPresentLedgerPaths))
        if !ready.isEmpty {
            onFilesReady(ready.map { URL(fileURLWithPath: $0.path) })
        }
    }
}
