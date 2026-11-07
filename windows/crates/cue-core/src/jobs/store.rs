//! Ports `JobStore`: one atomic JSON file per job under `jobs/`, so one
//! corrupt file can only lose one job. Loading decodes every file, keeps a
//! `.corrupt.json` copy of anything unreadable instead of overwriting it
//! later, marks jobs caught mid-run as canceled, and returns a total order.
//! Files are written with sorted keys, like the Mac's encoder.

use super::model::Job;
use super::scheduler::store_order;
use super::{JobProgress, JobStage, JobStatus};
use crate::subtitle::MAX_TIMESTAMP_SECONDS;
use std::path::{Path, PathBuf};

pub struct LoadSnapshot {
    pub jobs: Vec<Job>,
    /// Messages to surface to the user, in listing order.
    pub failures: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct JobStore {
    dir: PathBuf,
}

impl JobStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    pub fn default_location() -> Self {
        Self::new(crate::paths::jobs_dir())
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn file_for(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    pub fn load(&self) -> LoadSnapshot {
        let mut failures = Vec::new();
        if let Err(e) = std::fs::create_dir_all(&self.dir) {
            failures.push(format!("Could not create the job-history folder at {}: {e}", self.dir.display()));
            return LoadSnapshot { jobs: Vec::new(), failures };
        }
        let mut files: Vec<PathBuf> = match std::fs::read_dir(&self.dir) {
            Ok(entries) => entries
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    p.extension().is_some_and(|x| x == "json") && !p.file_name().is_some_and(|n| n.to_string_lossy().contains("corrupt"))
                })
                .collect(),
            Err(e) => {
                failures.push(format!("Could not read job history at {}: {e}. Existing jobs may be hidden.", self.dir.display()));
                return LoadSnapshot { jobs: Vec::new(), failures };
            }
        };
        files.sort();

        let decoded = decode_all(&files);
        let mut jobs: Vec<Job> = Vec::with_capacity(files.len());
        for (file, result) in files.iter().zip(decoded) {
            match result {
                Ok(job) => {
                    jobs.retain(|j| j.id != job.id);
                    jobs.push(job);
                }
                Err(error) => {
                    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    let backup = file.with_extension("corrupt.json");
                    let _ = std::fs::remove_file(&backup);
                    match std::fs::copy(file, &backup) {
                        Ok(_) => failures.push(format!(
                            "Could not read job file {name}: {error}. It was preserved at {}.",
                            backup.display()
                        )),
                        Err(copy) => failures.push(format!(
                            "Could not read job file {name}: {error}. The original remains at {}, but a recovery copy could not be created: {copy}.",
                            file.display()
                        )),
                    }
                }
            }
        }
        let mut jobs: Vec<Job> = jobs.into_iter().map(sanitized_after_relaunch).collect();
        jobs.sort_by(store_order);
        LoadSnapshot { jobs, failures }
    }

    /// Writes one job atomically (temp file, then rename).
    pub fn save(&self, job: &Job) -> Result<(), String> {
        std::fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        let path = self.file_for(&job.id);
        let mut job = job.clone();
        job.fill_defaults();
        // A Value round trip sorts keys (serde_json's map is ordered).
        let value = serde_json::to_value(&job).map_err(|e| e.to_string())?;
        let text = serde_json::to_string(&value).map_err(|e| e.to_string())?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, text)
            .and_then(|_| std::fs::rename(&tmp, &path))
            .map_err(|e| format!("Could not save job {}: {e}. Its latest state is still in memory.", job.id))
    }

    pub fn delete(&self, id: &str) -> Result<(), String> {
        match std::fs::remove_file(self.file_for(id)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("Could not delete job history {id}: {e}")),
        }
    }
}

/// Decodes on a few threads, then returns results in input order, so the
/// outcome never depends on which thread finished first.
fn decode_all(files: &[PathBuf]) -> Vec<Result<Job, String>> {
    let workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, 8);
    let chunk = files.len().div_ceil(workers).max(1);
    std::thread::scope(|scope| {
        let handles: Vec<_> =
            files.chunks(chunk).map(|part| scope.spawn(move || part.iter().map(|f| decode(f)).collect::<Vec<_>>())).collect();
        handles.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
    })
}

fn decode(file: &Path) -> Result<Job, String> {
    let text = std::fs::read_to_string(file).map_err(|e| e.to_string())?;
    let mut job: Job = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    validate(&job)?;
    job.fill_defaults();
    Ok(job)
}

fn validate(job: &Job) -> Result<(), String> {
    for (name, segments) in [
        ("transcript", &job.transcript_segments),
        ("translation", &job.translated_segments),
        ("partial transcript", &job.partial_transcript_segments),
        ("partial translation", &job.partial_translated_segments),
    ] {
        let mut ids: Vec<i64> = segments.iter().map(|s| s.id).collect();
        ids.sort_unstable();
        ids.dedup();
        if ids.len() != segments.len() {
            return Err(format!("The {name} contains duplicate cue IDs."));
        }
        let valid = segments
            .iter()
            .all(|s| s.start.is_finite() && s.end.is_finite() && s.start >= 0.0 && s.end >= s.start && s.end < MAX_TIMESTAMP_SECONDS);
        if !valid {
            return Err(format!("The {name} contains invalid cue timestamps."));
        }
    }
    Ok(())
}

/// A job saved mid-run would stay "Transcribing" forever after a crash.
/// Mark it canceled so it can be re-run, keeping what it produced.
pub fn sanitized_after_relaunch(mut job: Job) -> Job {
    if job.status.is_running() {
        job.status = JobStatus::Canceled;
        job.progress = JobProgress::new(JobStage::Canceled, "Interrupted — the app quit while this job was running.", None);
        job.log.push_str("This job was interrupted by an app quit and marked as canceled.\n");
    }
    job
}
