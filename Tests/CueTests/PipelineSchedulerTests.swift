import Foundation
import Testing
@testable import Cue

@Suite struct PipelineSchedulerTests {
    private func job(_ order: Double, status: JobStatus = .queued, hasTranscript: Bool = false) -> PipelineScheduler.JobView {
        PipelineScheduler.JobView(id: UUID(), orderIndex: order, status: status, hasTranscript: hasTranscript)
    }

    @Test func gpuPicksLowestOrderQueuedWithoutTranscript() {
        let a = job(2), b = job(1), c = job(0, hasTranscript: true)
        #expect(PipelineScheduler.nextGPUJob(jobs: [a, b, c], gpuBusy: false, queuePaused: false) == b.id)
    }

    @Test func gpuRespectsBusyAndPause() {
        let a = job(1)
        #expect(PipelineScheduler.nextGPUJob(jobs: [a], gpuBusy: true, queuePaused: false) == nil)
        #expect(PipelineScheduler.nextGPUJob(jobs: [a], gpuBusy: false, queuePaused: true) == nil)
    }

    @Test func translationPicksQueuedWithTranscript() {
        let a = job(1, hasTranscript: true), b = job(0)
        #expect(PipelineScheduler.nextTranslationJob(jobs: [a, b], translationBusy: false, queuePaused: false) == a.id)
        #expect(PipelineScheduler.nextTranslationJob(jobs: [a, b], translationBusy: true, queuePaused: false) == nil)
    }

    @Test func slotsPipelineIndependently() {
        // A translating-adjacent world: one queued job per slot; both fire.
        let forGPU = job(1), forTranslation = job(0, hasTranscript: true)
        let jobs = [forGPU, forTranslation]
        #expect(PipelineScheduler.nextGPUJob(jobs: jobs, gpuBusy: false, queuePaused: false) == forGPU.id)
        #expect(PipelineScheduler.nextTranslationJob(jobs: jobs, translationBusy: false, queuePaused: false) == forTranslation.id)
    }

    @Test func nonQueuedJobsAreInvisible() {
        let running = job(0, status: .transcribing)
        let done = job(1, status: .translationComplete, hasTranscript: true)
        #expect(PipelineScheduler.nextGPUJob(jobs: [running, done], gpuBusy: false, queuePaused: false) == nil)
        #expect(PipelineScheduler.nextTranslationJob(jobs: [running, done], translationBusy: false, queuePaused: false) == nil)
    }
}

@Suite struct PipelineSchedulerVolumeTests {
    private func job(_ order: Double, hasTranscript: Bool = false, available: Bool) -> PipelineScheduler.JobView {
        PipelineScheduler.JobView(id: UUID(), orderIndex: order, status: .queued, hasTranscript: hasTranscript, sourceAvailable: available)
    }

    @Test func unavailableSourceIsSkippedForTheNextRunnableJob() {
        let offline = job(1, available: false)
        let online = job(2, available: true)
        #expect(PipelineScheduler.nextGPUJob(jobs: [offline, online], gpuBusy: false, queuePaused: false) == online.id)
    }

    @Test func nothingRunsWhenEveryQueuedSourceIsOffline() {
        let jobs = [job(1, available: false), job(2, hasTranscript: true, available: false)]
        #expect(PipelineScheduler.nextGPUJob(jobs: jobs, gpuBusy: false, queuePaused: false) == nil)
        #expect(PipelineScheduler.nextTranslationJob(jobs: jobs, translationBusy: false, queuePaused: false) == nil)
    }
}
