import Foundation

/// One file sighting during a scan.
struct FileObservation: Hashable {
    let path: String
    let size: Int64
    let modifiedAt: Date
}

/// Pure ingestion logic for the watch folder (spec §2.3). Holds the
/// stability-gate state between scans; owns no I/O, timers, or file events,
/// so every rule is unit-testable.
struct WatchFolderScanEngine {
    /// How long a file's size must hold still before it is ingested.
    static let stabilityInterval: TimeInterval = 2.0

    private struct Candidate {
        var size: Int64
        var firstSeenAt: Date
    }

    private var candidates: [String: Candidate] = [:]

    /// Files sighted but not yet stable: a follow-up scan after the
    /// stability interval will decide them.
    var hasPendingCandidates: Bool {
        !candidates.isEmpty
    }

    /// Must match TranscriptionJob.fingerprint(for:) byte for byte, since
    /// ledger entries and job fingerprints are compared against it.
    static func fingerprint(for file: FileObservation) -> String {
        "\(file.path)|\(file.size)|\(file.modifiedAt.timeIntervalSince1970)"
    }

    mutating func filesReadyToIngest(
        observations: [FileObservation],
        now: Date,
        blockedFingerprints: Set<String>
    ) -> [FileObservation] {
        var ready: [FileObservation] = []
        var seenPaths = Set<String>()

        for file in observations {
            seenPaths.insert(file.path)
            let url = URL(fileURLWithPath: file.path)
            let ext = url.pathExtension.lowercased()
            guard MediaFileTypes.extensions.contains(ext) else { continue }
            guard !MediaFileTypes.partialDownloadExtensions.contains(ext) else { continue }
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            guard !blockedFingerprints.contains(Self.fingerprint(for: file)) else {
                candidates[file.path] = nil
                continue
            }

            if let candidate = candidates[file.path], candidate.size == file.size {
                if now.timeIntervalSince(candidate.firstSeenAt) >= Self.stabilityInterval {
                    ready.append(file)
                    candidates[file.path] = nil
                }
                // else: stable but too soon; keep waiting on the same entry.
            } else {
                // New file, or its size moved: (re)start the stability clock.
                candidates[file.path] = Candidate(size: file.size, firstSeenAt: now)
            }
        }

        // A file that vanished mid-wait must not linger as a candidate.
        candidates = candidates.filter { seenPaths.contains($0.key) }
        return ready
    }
}
