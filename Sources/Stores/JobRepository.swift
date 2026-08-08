import Foundation

/// The persistence boundary used by `JobRepository`. Keeping AppModel behind
/// this protocol makes persistence behavior testable without touching disk.
@MainActor
protocol JobPersisting: AnyObject {
    var startupError: String? { get }

    func loadJobs() -> [TranscriptionJob]
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

    var startupError: String? { store.startupError }

    init(store: any JobPersisting, debounceNanoseconds: UInt64 = 400_000_000) {
        self.store = store
        self.debounceNanoseconds = debounceNanoseconds
    }

    func loadJobs() -> [TranscriptionJob] {
        store.loadJobs()
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
        let snapshots = pendingJobs.values.sorted { $0.id.uuidString < $1.id.uuidString }
        pendingJobs.removeAll()
        for job in snapshots {
            store.saveJob(job)
        }
    }
}
