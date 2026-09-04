import Foundation

/// The persistence boundary used by `JobRepository`. Keeping AppModel behind
/// this protocol makes persistence behavior testable without touching disk.
// Sendable so the repository can hand the store's nonisolated snapshot loader
// to a background task; every conformer is main-actor-isolated (inherited
// from this protocol), which already makes it Sendable.
@MainActor
protocol JobPersisting: AnyObject, Sendable {
    var startupError: String? { get }

    func loadJobs() -> [TranscriptionJob]
    /// The same load, runnable off the main actor; the caller surfaces the
    /// collected failures through `recordStartupFailures(_:)`.
    nonisolated func loadJobsSnapshot() -> JobLoadSnapshot
    func recordStartupFailures(_ failures: [String])
    func saveJob(_ job: TranscriptionJob)
    func deleteJob(_ id: UUID)
    func flush()
}

/// Owns job persistence policy: immutable snapshots, debounce/coalescing, and
/// the termination flush. AppModel only decides *when* a mutation is durable;
/// it no longer manages timers or dirty-id bookkeeping itself.
@MainActor
final class JobRepository {
    private let store: any JobPersisting
    private let debounceNanoseconds: UInt64
    private var pendingJobs: [UUID: TranscriptionJob] = [:]
    private var persistTask: Task<Void, Never>?
    /// How many times pending snapshots were handed to the store as one
    /// group; lets tests prove a batch operation flushed once.
    private(set) var flushCount = 0

    var startupError: String? { store.startupError }

    init(store: any JobPersisting, debounceNanoseconds: UInt64 = 400_000_000) {
        self.store = store
        self.debounceNanoseconds = debounceNanoseconds
    }

    func loadJobs() -> [TranscriptionJob] {
        store.loadJobs()
    }

    /// Loads on the calling thread without touching the main actor, so the
    /// app can hydrate its job list after the window is up.
    nonisolated func loadJobsSnapshot() -> JobLoadSnapshot {
        store.loadJobsSnapshot()
    }

    func recordStartupFailures(_ failures: [String]) {
        store.recordStartupFailures(failures)
    }

    func save(_ job: TranscriptionJob, debounced: Bool = false) {
        pendingJobs[job.id] = job
        guard debounced else {
            flushPendingSnapshots()
            return
        }

        persistTask?.cancel()
        persistTask = Task { [weak self, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.persistTask = nil
            self.flushPendingSnapshots()
        }
    }

    /// Persists a user-initiated batch as one repository operation. Calling
    /// the single-job overload in a loop flushes the pending dictionary once
    /// per element, which needlessly amplifies large queue operations.
    func save(_ jobs: [TranscriptionJob]) {
        guard !jobs.isEmpty else { return }
        for job in jobs {
            pendingJobs[job.id] = job
        }
        flushPendingSnapshots()
    }

    func delete(_ id: UUID) {
        pendingJobs[id] = nil
        store.deleteJob(id)
    }

    /// Guarantees that every snapshot accepted before this call has reached
    /// the underlying store. Used for app termination and explicit test gates.
    func flush() {
        persistTask?.cancel()
        persistTask = nil
        flushPendingSnapshots()
        store.flush()
    }

    private func flushPendingSnapshots() {
        persistTask?.cancel()
        persistTask = nil
        guard !pendingJobs.isEmpty else { return }
        flushCount += 1
        let snapshots = pendingJobs.values.sorted { $0.id.uuidString < $1.id.uuidString }
        pendingJobs.removeAll()
        for job in snapshots {
            store.saveJob(job)
        }
    }
}
