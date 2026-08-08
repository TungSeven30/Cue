import Foundation

/// Pure slot-assignment decisions for the two-slot pipeline. AppModel owns
/// the slots; this owns only the "who runs next" math so it stays testable.
enum PipelineScheduler {
    struct JobView: Equatable {
        let id: UUID
        let orderIndex: Double
        let status: JobStatus
        let hasTranscript: Bool
        /// False while the job's source volume is unmounted; such jobs stay
        /// queued but are skipped, so a runnable job behind them can start.
        let sourceAvailable: Bool

        init(id: UUID, orderIndex: Double, status: JobStatus, hasTranscript: Bool, sourceAvailable: Bool = true) {
            self.id = id
            self.orderIndex = orderIndex
            self.status = status
            self.hasTranscript = hasTranscript
            self.sourceAvailable = sourceAvailable
        }
    }

    static func nextGPUJob(jobs: [JobView], gpuBusy: Bool, queuePaused: Bool) -> UUID? {
        guard !gpuBusy, !queuePaused else { return nil }
        return jobs
            .filter { $0.status == .queued && !$0.hasTranscript && $0.sourceAvailable }
            .min { $0.orderIndex < $1.orderIndex }?
            .id
    }

    static func nextTranslationJob(jobs: [JobView], translationBusy: Bool, queuePaused: Bool) -> UUID? {
        guard !translationBusy, !queuePaused else { return nil }
        return jobs
            .filter { $0.status == .queued && $0.hasTranscript && $0.sourceAvailable }
            .min { $0.orderIndex < $1.orderIndex }?
            .id
    }
}
