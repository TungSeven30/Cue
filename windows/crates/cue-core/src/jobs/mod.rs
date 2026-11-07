//! Job records, their on-disk store and the queue's scheduling rules.

mod model;
mod scheduler;
mod store;

pub use model::{fingerprint, fingerprint_of, Job, JobOrigin, JobProgress, JobSettings, JobStage, JobStatus};
pub use scheduler::{list_order, next_gpu_job, next_translation_job, store_order};
pub use store::{sanitized_after_relaunch, JobStore, LoadSnapshot};

#[cfg(test)]
mod tests;
