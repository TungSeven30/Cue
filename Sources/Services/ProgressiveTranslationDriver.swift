import Foundation

/// Accumulates streamed transcript batches and drives incremental
/// translation behind the frontier. Owns no concurrency: `ingest` only
/// buffers and signals; `translateAvailable`/`finish` run inside AppModel's
/// serial translation slot, so calls never overlap.
@MainActor
final class ProgressiveTranslationDriver {
    typealias TranslateCall = (
        _ segments: [TranscriptionSegment],
        _ existing: [TranscriptionSegment],
        _ onPartial: @escaping @MainActor ([TranscriptionSegment]) -> Void
    ) async throws -> [TranscriptionSegment]

    private let chunkSize: Int
    private let overlapAllowed: Bool
    private let translate: TranslateCall
    private let onPartial: ([TranscriptionSegment]) -> Void
    private let onNeedsTranslation: () -> Void

    private(set) var streamed: [TranscriptionSegment] = []
    private(set) var partials: [TranscriptionSegment] = []
    private var requestedThrough = 0
    private var failedMidStream = false

    init(
        chunkSize: Int, overlapAllowed: Bool,
        translate: @escaping TranslateCall,
        onPartial: @escaping ([TranscriptionSegment]) -> Void,
        onNeedsTranslation: @escaping () -> Void
    ) {
        self.chunkSize = max(1, chunkSize)
        self.overlapAllowed = overlapAllowed
        self.translate = translate
        self.onPartial = onPartial
        self.onNeedsTranslation = onNeedsTranslation
    }

    func ingest(_ batch: [TranscriptionSegment]) {
        streamed += batch
        maybeRequest()
    }

    /// One incremental pass over everything streamed so far. TranslationService
    /// skips chunks already covered by `partials`, so repeated calls only do
    /// new work. Mid-stream errors are swallowed (transcription must continue);
    /// `finish` surfaces any real failure.
    func translateAvailable() async {
        guard !failedMidStream else { return }
        let snapshot = streamed
        do {
            _ = try await translate(snapshot, partials) { [weak self] batch in
                self?.recordPartials(batch)
            }
        } catch is CancellationError {
            // Slot canceled: the job's cancel path handles state.
        } catch {
            failedMidStream = true
        }
        maybeRequest()
    }

    /// Reconcile partials onto the final transcript, then translate the tail.
    func finish(finalTranscript: [TranscriptionSegment]) async throws -> [TranscriptionSegment] {
        let reconciled = TranslationReconciliation.remap(partials: partials, streamed: streamed, final: finalTranscript)
        return try await translate(finalTranscript, reconciled) { [weak self] batch in
            self?.recordPartials(batch)
        }
    }

    private func maybeRequest() {
        guard overlapAllowed, !failedMidStream, streamed.count - requestedThrough >= chunkSize else { return }
        requestedThrough = streamed.count
        onNeedsTranslation()
    }

    private func recordPartials(_ batch: [TranscriptionSegment]) {
        partials = batch
        onPartial(batch)
    }
}
