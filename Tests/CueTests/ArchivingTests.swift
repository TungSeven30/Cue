import Foundation
import Testing
@testable import Cue

@Suite struct ArchivingTests {
    private let old = Date(timeIntervalSinceNow: -40 * 86_400)
    private let recent = Date(timeIntervalSinceNow: -5 * 86_400)

    @Test func archivesOldTerminalJobs() {
        #expect(TranscriptionJob.shouldAutoArchive(
            status: .translationComplete, finishedAt: old, updatedAt: old, olderThanDays: 30))
        #expect(TranscriptionJob.shouldAutoArchive(
            status: .transcriptionComplete, finishedAt: old, updatedAt: old, olderThanDays: 30))
        #expect(TranscriptionJob.shouldAutoArchive(
            status: .canceled, finishedAt: nil, updatedAt: old, olderThanDays: 30))
        #expect(TranscriptionJob.shouldAutoArchive(
            status: .failed, finishedAt: nil, updatedAt: old, olderThanDays: 30))
    }

    @Test func keepsRecentJobs() {
        #expect(!TranscriptionJob.shouldAutoArchive(
            status: .translationComplete, finishedAt: recent, updatedAt: recent, olderThanDays: 30))
    }

    @Test func finishedAtWinsOverUpdatedAt() {
        // A recent unrelated touch (e.g. re-save) must not keep an old job alive.
        #expect(TranscriptionJob.shouldAutoArchive(
            status: .translationComplete, finishedAt: old, updatedAt: recent, olderThanDays: 30))
    }

    @Test func neverArchivesActiveOrPendingJobs() {
        for status in [JobStatus.idle, .queued, .transcribing, .translating, .burningIn] {
            #expect(!TranscriptionJob.shouldAutoArchive(
                status: status, finishedAt: old, updatedAt: old, olderThanDays: 30))
        }
    }

    @Test func zeroDaysDisablesArchiving() {
        #expect(!TranscriptionJob.shouldAutoArchive(
            status: .translationComplete, finishedAt: old, updatedAt: old, olderThanDays: 0))
    }
}
