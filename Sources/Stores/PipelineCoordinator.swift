import Foundation

/// Owns the mutable execution state for the two-lane pipeline. Scheduling
/// policy remains in the pure `PipelineScheduler`; AppModel orchestrates domain
/// work while this type enforces one task per lane and owns queued handoffs.
@MainActor
final class PipelineCoordinator {
    typealias TranslationWork = @MainActor () async -> Void

    var gpuTask: Task<Void, Never>?
    var gpuJobID: UUID?
    var translationTask: Task<Void, Never>?
    var translationJobID: UUID?
    private var translationWorkQueue: [(jobID: UUID, work: TranslationWork)] = []

    var hasQueuedTranslationWork: Bool { !translationWorkQueue.isEmpty }
    var queuedTranslationJobIDs: Set<UUID> { Set(translationWorkQueue.map(\.jobID)) }

    func containsQueuedTranslationWork(for id: UUID) -> Bool {
        translationWorkQueue.contains { $0.jobID == id }
    }

    func enqueueTranslationWork(jobID: UUID, work: @escaping TranslationWork) {
        translationWorkQueue.append((jobID: jobID, work: work))
    }

    func dequeueTranslationWork() -> (jobID: UUID, work: TranslationWork)? {
        guard !translationWorkQueue.isEmpty else { return nil }
        return translationWorkQueue.removeFirst()
    }

    func removeTranslationWork(for id: UUID) {
        translationWorkQueue.removeAll { $0.jobID == id }
    }

    /// Cancels both lanes and clears queued handoffs. The returned IDs are the
    /// only jobs whose persisted status AppModel should transition to canceled.
    func cancelAll() -> Set<UUID> {
        gpuTask?.cancel()
        translationTask?.cancel()
        let affected = queuedTranslationJobIDs.union([gpuJobID, translationJobID].compactMap { $0 })
        translationWorkQueue.removeAll()
        return affected
    }
}
