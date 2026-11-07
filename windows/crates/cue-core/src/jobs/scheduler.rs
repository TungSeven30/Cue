//! Ports `PipelineScheduler` and `JobLoadOrdering`: the pure "who runs
//! next" decisions for the two pipeline slots, and the total orders used
//! for loading and listing. One GPU consumer at a time (transcription), one
//! translation at a time, each slot strictly serial.

use super::{Job, JobStatus};
use std::cmp::Ordering;

/// The queued job with the lowest `order_index` that still needs a
/// transcript, unless the GPU slot is busy or the queue is paused.
pub fn next_gpu_job<'a>(jobs: impl IntoIterator<Item = &'a Job>, gpu_busy: bool, paused: bool) -> Option<&'a Job> {
    if gpu_busy || paused {
        return None;
    }
    first_queued(jobs, false)
}

/// The queued job with the lowest `order_index` that already has a finished
/// transcript and only needs translating.
pub fn next_translation_job<'a>(jobs: impl IntoIterator<Item = &'a Job>, translation_busy: bool, paused: bool) -> Option<&'a Job> {
    if translation_busy || paused {
        return None;
    }
    first_queued(jobs, true)
}

fn first_queued<'a>(jobs: impl IntoIterator<Item = &'a Job>, has_transcript: bool) -> Option<&'a Job> {
    jobs.into_iter()
        .filter(|j| j.status == JobStatus::Queued && j.has_transcript() == has_transcript && j.archived_at.is_none())
        .min_by(|a, b| a.order_index.total_cmp(&b.order_index).then_with(|| store_order(a, b)))
}

/// The store's order: most recently updated first, ties on id.
pub fn store_order(a: &Job, b: &Job) -> Ordering {
    b.updated_at.cmp(&a.updated_at).then_with(|| a.id.cmp(&b.id))
}

/// The list's order: queue position, then most recently updated, then id.
pub fn list_order(a: &Job, b: &Job) -> Ordering {
    a.order_index.total_cmp(&b.order_index).then_with(|| store_order(a, b))
}
