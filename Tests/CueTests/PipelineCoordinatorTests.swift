import Foundation
import Testing
@testable import Cue

@MainActor
struct PipelineCoordinatorTests {
    @Test func translationHandoffsStayFIFOAndCanBeRemovedByJob() async {
        let coordinator = PipelineCoordinator()
        let first = UUID()
        let second = UUID()
        coordinator.enqueueTranslationWork(jobID: first) {}
        coordinator.enqueueTranslationWork(jobID: second) {}

        #expect(coordinator.dequeueTranslationWork()?.jobID == first)
        coordinator.removeTranslationWork(for: second)
        #expect(!coordinator.hasQueuedTranslationWork)
    }

    @Test func cancelAllReturnsOnlyAffectedJobsAndClearsQueue() {
        let coordinator = PipelineCoordinator()
        let gpu = UUID()
        let translation = UUID()
        let queued = UUID()
        coordinator.gpuJobID = gpu
        coordinator.translationJobID = translation
        coordinator.enqueueTranslationWork(jobID: queued) {}
        coordinator.gpuTask = Task { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        coordinator.translationTask = Task { try? await Task.sleep(nanoseconds: 60_000_000_000) }

        let affected = coordinator.cancelAll()

        #expect(affected == [gpu, translation, queued])
        #expect(!coordinator.hasQueuedTranslationWork)
        #expect(coordinator.gpuTask?.isCancelled == true)
        #expect(coordinator.translationTask?.isCancelled == true)
    }
}
