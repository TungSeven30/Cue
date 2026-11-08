//! The desktop app's state and pipeline, with no UI toolkit in it: the
//! Windows counterpart of `AppModel`, `PipelineCoordinator` and
//! `JobRepository`. The Tauri shell is a thin layer of commands over
//! [`Runtime`] plus a forwarder for its [`Event`]s, so everything here is
//! tested on Linux with a fake transcriber and a fake HTTP transport.
//!
//! Two independently serial slots: one transcription (the GPU consumer) and
//! one translation. A job with a finished transcript queues for the
//! translation slot; a partial transcript never counts.

mod burnin;
mod downloads;
mod import;
mod persister;
pub mod python;
mod settings;
mod summary;
mod watch;
pub mod whisper;

pub use burnin::BurnInState;
pub use cue_core::burnin::TextSize;
pub use downloads::{Download, DownloadStatus};
pub use settings::{apply_overrides, Settings, WatchFolder};
pub use watch::WatchStatus;

use chrono::Utc;
use cue_core::export::{self, SidecarSet};
use cue_core::jobs::{self, Job, JobOrigin, JobProgress, JobStage, JobStatus, JobStore};
use cue_core::subtitle::{self, Format};
use cue_core::translation::{ChunkMode, Provider, TranslateOptions, TranslationError, Translator, Transport};
use cue_core::Segment;
use persister::Persister;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// What a transcriber reports while it runs.
pub enum Update {
    Progress(JobProgress),
    /// Raw segments in file time, as they are finalized.
    Segments(Vec<Segment>),
    /// Everything up to this many seconds is final: a resume point.
    ChunkComplete(f64),
}

pub type Report = Arc<dyn Fn(Update) + Send + Sync>;

pub struct TranscribeRequest {
    pub source: PathBuf,
    pub settings: jobs::JobSettings,
    pub use_gpu: bool,
    pub resume_through: f64,
    pub partial: Vec<Segment>,
    /// The Python command from Settings; empty finds one.
    pub python: String,
}

pub trait Transcriber: Send + Sync {
    /// Returns the cleaned, final transcript.
    fn transcribe(&self, request: TranscribeRequest, cancel: Arc<AtomicBool>, report: Report) -> Result<Vec<Segment>, String>;
    /// Stops anything kept running between jobs. Called on quit.
    fn shut_down(&self) {}
}

pub type KeyLookup = Arc<dyn Fn(Provider) -> Option<String> + Send + Sync>;

/// Everything the UI is told. Job updates carry a summary only; the UI
/// fetches segments with [`Runtime::job`] for the job it is showing.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    Job {
        job: Box<JobSummary>,
    },
    JobRemoved {
        id: String,
    },
    /// New streamed transcript segments for a running job.
    PartialSegments {
        id: String,
        segments: Vec<Segment>,
    },
    /// The job's transcript or translation changed wholesale.
    SegmentsChanged {
        id: String,
    },
    Queue {
        paused: bool,
        transcribing: Option<String>,
        translating: Option<String>,
    },
    Notice {
        message: String,
    },
    /// A job reached the end of its run (not a cancel): for notifications.
    Finished {
        id: String,
        title: String,
        success: bool,
        message: String,
    },
    WatchFolders {
        folders: Vec<WatchStatus>,
    },
    Download {
        download: Download,
    },
    DownloadRemoved {
        id: String,
    },
    BurnIn {
        state: BurnInState,
    },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobSummary {
    pub id: String,
    pub title: String,
    pub source_path: String,
    pub status: JobStatus,
    pub status_label: &'static str,
    pub progress: JobProgress,
    pub transcript_count: usize,
    pub translation_count: usize,
    pub partial_count: usize,
    pub order_index: f64,
    pub origin: JobOrigin,
    pub source_language: String,
    pub target_language: String,
    pub translation_model: String,
    pub summary: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl JobSummary {
    fn of(job: &Job) -> Self {
        JobSummary {
            id: job.id.clone(),
            title: job.title(),
            source_path: job.source_path.clone(),
            status: job.status,
            status_label: job.status.label(),
            progress: JobProgress { fraction: job.progress.display_fraction(), ..job.progress.clone() },
            transcript_count: job.transcript_segments.len(),
            translation_count: job.translated_segments.len(),
            partial_count: job.partial_transcript_segments.len(),
            order_index: job.order_index,
            origin: job.origin,
            source_language: job.settings.source_language.clone(),
            target_language: job.settings.translation_target_language.clone(),
            translation_model: job.settings.translation_model.clone(),
            summary: job.summary.clone(),
            created_at: job.created_at.to_rfc3339(),
            updated_at: job.updated_at.to_rfc3339(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Slot {
    Transcript,
    Translation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Document {
    Original,
    Translated,
    Bilingual,
}

pub struct Config {
    pub data_dir: PathBuf,
    pub transcriber: Arc<dyn Transcriber>,
    pub transport: Arc<dyn Transport + Send + Sync>,
    pub keys: KeyLookup,
    pub emit: Arc<dyn Fn(Event) + Send + Sync>,
    pub tools: Tools,
}

/// Explicit tool locations; `None` searches the usual places.
#[derive(Debug, Clone, Default)]
pub struct Tools {
    pub ytdlp: Option<PathBuf>,
    pub ffmpeg: Option<PathBuf>,
}

impl Config {
    /// The real thing: whisper.cpp, HTTPS, Credential Manager.
    pub fn standard(emit: Arc<dyn Fn(Event) + Send + Sync>) -> Self {
        Config {
            data_dir: cue_core::paths::app_data_dir(),
            transcriber: Arc::new(python::BackendRouter {
                built_in: Arc::new(whisper::WhisperTranscriber::new()),
                python: Arc::new(python::PythonTranscriber::new(cue_core::paths::app_data_dir().join("backend"))),
            }),
            transport: Arc::new(cue_core::translation::UreqTransport),
            keys: Arc::new(|p| cue_core::credentials::lookup(p).map(|(k, _)| k)),
            emit,
            tools: Tools::default(),
        }
    }
}

struct Running {
    id: String,
    cancel: Arc<AtomicBool>,
}

struct State {
    jobs: Vec<Job>,
    settings: Settings,
    paused: bool,
    transcribing: Option<Running>,
    translating: Option<Running>,
    /// Last time each running job's progress was pushed to the UI.
    last_emit: Vec<(String, Instant)>,
}

struct Inner {
    state: Mutex<State>,
    persister: Persister,
    settings_path: PathBuf,
    transcriber: Arc<dyn Transcriber>,
    transport: Arc<dyn Transport + Send + Sync>,
    keys: KeyLookup,
    emit: Arc<dyn Fn(Event) + Send + Sync>,
    data_dir: PathBuf,
    tools: Tools,
    ledger: Mutex<cue_core::watch::Ledger>,
    watchers: Mutex<HashMap<String, watch::Watcher>>,
    downloads: Mutex<Vec<downloads::Slot>>,
    burn: Mutex<Option<burnin::Running>>,
}

/// Locks a mutex, carrying on past a panicked holder.
fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Clone)]
pub struct Runtime {
    inner: Arc<Inner>,
}

/// Progress pushes per job are capped at this rate; state changes always go.
const EMIT_INTERVAL: Duration = Duration::from_millis(120);

impl Runtime {
    /// Loads settings and job history. Load failures come back for the UI
    /// to show; they never stop the app from starting.
    pub fn launch(config: Config) -> (Runtime, Vec<String>) {
        let store = JobStore::new(config.data_dir.join("jobs"));
        let snapshot = store.load();
        let settings_path = config.data_dir.join("settings.json");
        let settings = Settings::load(&settings_path);
        let ledger = cue_core::watch::Ledger::open(config.data_dir.join("watch-ledger.json"));
        let mut failures = snapshot.failures;
        failures.extend(ledger.startup_error.clone());
        let runtime = Runtime {
            inner: Arc::new(Inner {
                state: Mutex::new(State {
                    jobs: snapshot.jobs,
                    settings,
                    paused: false,
                    transcribing: None,
                    translating: None,
                    last_emit: Vec::new(),
                }),
                persister: Persister::spawn(store),
                settings_path,
                transcriber: config.transcriber,
                transport: config.transport,
                keys: config.keys,
                emit: config.emit,
                data_dir: config.data_dir,
                tools: config.tools,
                ledger: Mutex::new(ledger),
                watchers: Mutex::new(HashMap::new()),
                downloads: Mutex::new(Vec::new()),
                burn: Mutex::new(None),
            }),
        };
        runtime.pump();
        runtime.sync_watchers();
        (runtime, failures)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.inner.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn emit(&self, event: Event) {
        (self.inner.emit)(event);
    }

    // MARK: Reading

    /// Every job in list order (queue position first).
    pub fn jobs(&self) -> Vec<JobSummary> {
        let state = self.lock();
        let mut jobs: Vec<&Job> = state.jobs.iter().filter(|j| j.archived_at.is_none()).collect();
        jobs.sort_by(|a, b| jobs::list_order(a, b));
        jobs.into_iter().map(JobSummary::of).collect()
    }

    pub fn job(&self, id: &str) -> Option<Job> {
        self.lock().jobs.iter().find(|j| j.id == id).cloned()
    }

    pub fn settings(&self) -> Settings {
        self.lock().settings.clone()
    }

    pub fn queue_state(&self) -> Event {
        let state = self.lock();
        queue_event(&state)
    }

    // MARK: Changing jobs

    /// Adds media files, skipping any already in the list. Interactive adds
    /// honor "start added jobs automatically".
    pub fn add_files(&self, paths: &[PathBuf]) -> Vec<String> {
        self.add_paths(paths, JobOrigin::Manual, None)
    }

    fn add_paths(&self, paths: &[PathBuf], origin: JobOrigin, note: Option<&str>) -> Vec<String> {
        let listed = |state: &State, path: &Path| {
            let key = path.to_string_lossy();
            state.jobs.iter().any(|j| j.source_path == key && j.archived_at.is_none())
        };
        // Subtitles already beside the videos are read before the jobs
        // exist, with no lock held.
        let (settings, fresh): (Settings, Vec<PathBuf>) = {
            let state = self.lock();
            (state.settings.clone(), paths.iter().filter(|p| !listed(&state, p)).cloned().collect())
        };
        let snapshot = settings.snapshot();
        let languages = (snapshot.source_language.clone(), snapshot.translation_target_language.clone());
        let mut sidecars = self.scan_sidecars(&fresh, |_| languages.clone()).into_iter();
        let translate_next = settings.auto_translate && self.translation_ready(&settings.translation_model);
        let mut added = Vec::new();
        {
            let mut state = self.lock();
            let auto_start = state.settings.auto_start_added_jobs;
            let first_order = state.jobs.iter().map(|j| j.order_index).filter(|o| o.is_finite()).fold(0.0_f64, f64::max) + 1.0;
            for (offset, path) in fresh.iter().enumerate() {
                let adopted = sidecars.next().unwrap_or_default();
                if listed(&state, path) {
                    continue;
                }
                let mut job = Job::new(path, snapshot.clone(), Utc::now());
                // New files join the end of the queue in the order given.
                job.order_index = first_order + offset as f64;
                job.origin = origin;
                if let Some(note) = note {
                    job.log = format!("{note}\n");
                }
                if auto_start {
                    queue(&mut job);
                }
                import::adopt(&mut job, adopted, translate_next);
                added.push(job.id.clone());
                self.inner.persister.save(&job);
                self.emit(Event::Job { job: Box::new(JobSummary::of(&job)) });
                state.jobs.push(job);
            }
        }
        self.pump();
        added
    }

    /// Queues a job: transcription if it has no transcript yet, otherwise
    /// translation. Clears the queue's pause, as an interactive start does.
    pub fn start(&self, id: &str) -> Result<(), String> {
        self.change(id, |job| {
            if job.status.is_running() || job.status == JobStatus::Queued {
                return Err("This job is already queued or running.".into());
            }
            queue(job);
            Ok(())
        })?;
        self.set_paused(false);
        Ok(())
    }

    /// Discards the transcript and translation and transcribes again.
    pub fn retranscribe(&self, id: &str) -> Result<(), String> {
        self.change(id, |job| {
            if job.status.is_running() {
                return Err("Stop the job before transcribing it again.".into());
            }
            job.transcript_segments.clear();
            job.translated_segments.clear();
            job.partial_transcript_segments.clear();
            job.partial_translated_segments.clear();
            job.transcription_resume_through = 0.0;
            job.summary = None;
            queue(job);
            Ok(())
        })?;
        self.emit(Event::SegmentsChanged { id: id.into() });
        self.set_paused(false);
        Ok(())
    }

    /// Queues (re)translation of an existing transcript.
    pub fn translate(&self, id: &str) -> Result<(), String> {
        self.change(id, |job| {
            if !job.has_transcript() {
                return Err("Transcribe this video before translating it.".into());
            }
            if job.status.is_running() || job.status == JobStatus::Queued {
                return Err("This job is already queued or running.".into());
            }
            queue(job);
            Ok(())
        })?;
        self.set_paused(false);
        Ok(())
    }

    /// Stops a running job (its partial progress is kept for resume), or
    /// takes a queued one off the queue.
    pub fn cancel(&self, id: &str) -> Result<(), String> {
        let state = self.lock();
        for running in [&state.transcribing, &state.translating].into_iter().flatten() {
            if running.id == id {
                running.cancel.store(true, Ordering::Relaxed);
                return Ok(());
            }
        }
        drop(state);
        self.change(id, |job| {
            if job.status != JobStatus::Queued {
                return Err("Only queued or running jobs can be stopped.".into());
            }
            job.status = if job.has_transcript() { JobStatus::TranscriptionComplete } else { JobStatus::Canceled };
            job.progress = JobProgress::new(JobStage::Canceled, "Removed from the queue.", None);
            Ok(())
        })
    }

    pub fn remove(&self, id: &str) -> Result<(), String> {
        let mut state = self.lock();
        if [&state.transcribing, &state.translating].into_iter().flatten().any(|r| r.id == id) {
            return Err("Stop the job before removing it.".into());
        }
        let before = state.jobs.len();
        state.jobs.retain(|j| j.id != id);
        if state.jobs.len() == before {
            return Err("No such job.".into());
        }
        drop(state);
        self.inner.persister.delete(id);
        self.emit(Event::JobRemoved { id: id.into() });
        Ok(())
    }

    /// Sets the queue order to `ids` (any jobs not named keep their place
    /// after them).
    pub fn reorder(&self, ids: &[String]) {
        let mut state = self.lock();
        let mut changed = Vec::new();
        for (index, id) in ids.iter().enumerate() {
            if let Some(job) = state.jobs.iter_mut().find(|j| &j.id == id) {
                job.order_index = index as f64;
                changed.push(job.clone());
            }
        }
        drop(state);
        for job in changed {
            self.inner.persister.save(&job);
            self.emit(Event::Job { job: Box::new(JobSummary::of(&job)) });
        }
    }

    /// Edits one cue's text.
    pub fn edit_segment(&self, id: &str, slot: Slot, segment_id: i64, text: &str) -> Result<(), String> {
        self.change(id, |job| {
            if job.status.is_running() {
                return Err("Wait for the job to finish before editing.".into());
            }
            let segments = match slot {
                Slot::Transcript => &mut job.transcript_segments,
                Slot::Translation => &mut job.translated_segments,
            };
            let segment = segments.iter_mut().find(|s| s.id == segment_id).ok_or("No such subtitle.")?;
            segment.text = text.to_string();
            Ok(())
        })
    }

    /// Sets (or clears, with `None`) one per-job override.
    pub fn set_override(&self, id: &str, key: &str, value: Option<String>) -> Result<(), String> {
        const KEYS: [&str; 7] = [
            "sourceLanguage",
            "whisperModel",
            "translationSourceLanguage",
            "translationTargetLanguage",
            "openAIModel",
            "generateSummary",
            "summaryDetail",
        ];
        if !KEYS.contains(&key) {
            return Err(format!("unknown setting {key}"));
        }
        // The Mac decodes these as a Bool and an enum: a stray string would
        // make it reject the whole job file.
        let value: Option<serde_json::Value> = match (key, value.as_deref().map(str::trim).filter(|v| !v.is_empty())) {
            (_, None) => None,
            ("generateSummary", Some(v)) => match v {
                "true" => Some(true.into()),
                "false" => Some(false.into()),
                _ => return Err("generateSummary takes true or false.".into()),
            },
            ("summaryDetail", Some(v)) => match cue_core::translation::SummaryDetail::parse(v) {
                Some(detail) => Some(serde_json::to_value(detail).expect("an enum serializes")),
                None => return Err("summaryDetail takes brief or detailed.".into()),
            },
            (_, Some(v)) => Some(v.into()),
        };
        self.change(id, |job| {
            if !job.overrides.is_object() {
                job.overrides = serde_json::Value::Object(Default::default());
            }
            let map = job.overrides.as_object_mut().expect("object");
            match value {
                Some(v) => {
                    map.insert(key.into(), v);
                }
                None => {
                    map.remove(key);
                }
            }
            Ok(())
        })
    }

    /// Writes chosen documents in chosen formats into `dir` (defaults to the
    /// video's folder) and returns the paths written.
    pub fn export(&self, id: &str, documents: &[Document], formats: &[Format], dir: Option<&Path>) -> Result<Vec<PathBuf>, String> {
        let job = self.job(id).ok_or("No such job.")?;
        let source = PathBuf::from(&job.source_path);
        let dir = match dir {
            Some(d) => d.to_path_buf(),
            None => source.parent().map(Path::to_path_buf).unwrap_or_default(),
        };
        let base = export::base_name(&source);
        let target = export::language_suffix(&job.settings.translation_target_language);
        let several = documents.len() > 1;
        let mut written = Vec::new();
        for &document in documents {
            let (suffix, segments) = match document {
                Document::Original => ("original".to_string(), job.transcript_segments.clone()),
                Document::Translated => (format!("translated.{target}"), job.translated_segments.clone()),
                Document::Bilingual => (
                    format!("bilingual.{target}"),
                    cue_core::translation::bilingual_segments(&job.transcript_segments, &job.translated_segments),
                ),
            };
            if segments.is_empty() {
                continue;
            }
            for &format in formats {
                // A lone transcript keeps the plain `<base>.<ext>` name.
                let path = if !several && document == Document::Original {
                    dir.join(format!("{base}.{}", format.extension()))
                } else {
                    export::document_path(&dir, &base, &suffix, format)
                };
                let segments = export::with_intro(&segments, format, job.summary.as_deref());
                subtitle::write_file(&segments, format, &path).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
                written.push(path);
            }
        }
        if written.is_empty() {
            return Err("Nothing to export yet.".into());
        }
        Ok(written)
    }

    // MARK: Queue and settings

    pub fn set_paused(&self, paused: bool) {
        let mut state = self.lock();
        if state.paused == paused {
            return;
        }
        state.paused = paused;
        let event = queue_event(&state);
        drop(state);
        self.emit(event);
        if !paused {
            self.pump();
        }
    }

    /// Saves new global settings. Watch folders are managed by their own
    /// calls, so the list in `settings` is ignored.
    pub fn update_settings(&self, mut settings: Settings) -> Result<(), String> {
        let mut state = self.lock();
        settings.watch_folders = state.settings.watch_folders.clone();
        settings.save(&self.inner.settings_path)?;
        state.settings = settings;
        Ok(())
    }

    /// Changes settings in place and saves them.
    fn edit_settings<T>(&self, f: impl FnOnce(&mut Settings) -> Result<T, String>) -> Result<T, String> {
        let mut state = self.lock();
        let mut settings = state.settings.clone();
        let value = f(&mut settings)?;
        settings.save(&self.inner.settings_path)?;
        state.settings = settings;
        Ok(value)
    }

    /// Whether anything is running that sleep would interrupt.
    pub fn busy(&self) -> bool {
        let state = self.lock();
        let pipeline = state.transcribing.is_some() || state.translating.is_some();
        drop(state);
        pipeline
            || locked(&self.inner.downloads).iter().any(|d| d.info.status == DownloadStatus::Running)
            || locked(&self.inner.burn).is_some()
    }

    /// Stops everything and waits for pending saves. Running jobs keep
    /// their resume point; the next launch shows them as canceled.
    pub fn shutdown(&self) {
        let state = self.lock();
        for running in [&state.transcribing, &state.translating].into_iter().flatten() {
            running.cancel.store(true, Ordering::Relaxed);
        }
        drop(state);
        self.stop_watchers();
        self.cancel_all_downloads();
        let _ = self.cancel_burn_in();
        self.inner.transcriber.shut_down();
        self.inner.persister.flush();
    }

    /// Blocks until queued saves are on disk. For tests and quitting.
    pub fn flush(&self) {
        self.inner.persister.flush();
    }

    // MARK: Internals

    /// Applies `f` to one job, stamps, saves and announces it.
    fn change(&self, id: &str, f: impl FnOnce(&mut Job) -> Result<(), String>) -> Result<(), String> {
        let job = {
            let mut state = self.lock();
            let job = state.jobs.iter_mut().find(|j| j.id == id).ok_or("No such job.")?;
            f(job)?;
            job.updated_at = Utc::now();
            job.clone()
        };
        self.inner.persister.save(&job);
        self.emit(Event::Job { job: Box::new(JobSummary::of(&job)) });
        self.pump();
        Ok(())
    }

    /// Like `change`, for the pipeline threads: never fails, and progress
    /// pushes are rate limited unless `important`.
    fn update(&self, id: &str, important: bool, save: bool, f: impl FnOnce(&mut Job)) {
        let mut state = self.lock();
        let Some(job) = state.jobs.iter_mut().find(|j| j.id == id) else { return };
        f(job);
        job.updated_at = Utc::now();
        let job = job.clone();
        let now = Instant::now();
        let due = match state.last_emit.iter_mut().find(|(i, _)| i == id) {
            Some((_, last)) if !important && now.duration_since(*last) < EMIT_INTERVAL => false,
            Some((_, last)) => {
                *last = now;
                true
            }
            None => {
                state.last_emit.push((id.to_string(), now));
                true
            }
        };
        drop(state);
        if save {
            self.inner.persister.save(&job);
        }
        if due {
            self.emit(Event::Job { job: Box::new(JobSummary::of(&job)) });
        }
    }

    /// Fills any free slot with the next job for it.
    fn pump(&self) {
        let mut started: Vec<(Job, Arc<AtomicBool>, bool)> = Vec::new();
        {
            let mut state = self.lock();
            if state.paused {
                return;
            }
            let settings = state.settings.clone();
            if state.transcribing.is_none() {
                if let Some(id) = jobs::next_gpu_job(&state.jobs, false, false).map(|j| j.id.clone()) {
                    let cancel = Arc::new(AtomicBool::new(false));
                    let job = state.jobs.iter_mut().find(|j| j.id == id).expect("picked from the list");
                    // Keep the fields Windows doesn't manage (Mac-only
                    // settings ride in `extra`) so a re-run doesn't drop them.
                    let mut fresh = apply_overrides(settings.snapshot(), &job.overrides);
                    for (key, value) in std::mem::take(&mut job.settings.extra) {
                        fresh.extra.entry(key).or_insert(value);
                    }
                    job.settings = fresh;
                    job.status = JobStatus::Transcribing;
                    job.progress = JobProgress::new(JobStage::Preflight, "Starting…", None);
                    job.transcription_started_at = Some(Utc::now());
                    job.log.push_str("Transcription started.\n");
                    started.push((job.clone(), cancel.clone(), true));
                    state.transcribing = Some(Running { id, cancel });
                }
            }
            if state.translating.is_none() {
                if let Some(id) = jobs::next_translation_job(&state.jobs, false, false).map(|j| j.id.clone()) {
                    let cancel = Arc::new(AtomicBool::new(false));
                    let job = state.jobs.iter_mut().find(|j| j.id == id).expect("picked from the list");
                    let fresh = apply_overrides(settings.snapshot(), &job.overrides);
                    job.settings = job.settings.updating_translation_fields(&fresh);
                    job.status = JobStatus::Translating;
                    job.progress = JobProgress::new(JobStage::Translating, "Starting translation…", Some(0.0));
                    job.translation_started_at = Some(Utc::now());
                    job.log.push_str("Translation started.\n");
                    started.push((job.clone(), cancel.clone(), false));
                    state.translating = Some(Running { id, cancel });
                }
            }
            if !started.is_empty() {
                let event = queue_event(&state);
                drop(state);
                self.emit(event);
            }
        }
        for (job, cancel, is_transcription) in started {
            self.inner.persister.save(&job);
            self.emit(Event::Job { job: Box::new(JobSummary::of(&job)) });
            let id = job.id.clone();
            let runtime = self.clone();
            let name = if is_transcription { "cue-transcribe" } else { "cue-translate" };
            let spawned = std::thread::Builder::new().name(name.into()).spawn(move || {
                if is_transcription {
                    runtime.run_transcription(job, cancel);
                } else {
                    runtime.run_translation(job, cancel);
                }
            });
            if let Err(e) = spawned {
                // Nothing will run the job, so free its slot rather than wedge the queue.
                let stage = if is_transcription { JobStage::Transcribing } else { JobStage::Translating };
                self.update(&id, true, true, |job| failed_job(job, stage, &format!("Could not start a worker thread: {e}")));
                let event = {
                    let mut state = self.lock();
                    let slot = if is_transcription { &mut state.transcribing } else { &mut state.translating };
                    if slot.as_ref().is_some_and(|r| r.id == id) {
                        *slot = None;
                    }
                    queue_event(&state)
                };
                self.emit(event);
            }
        }
    }

    fn run_transcription(&self, job: Job, cancel: Arc<AtomicBool>) {
        let id = job.id.clone();
        let use_gpu = self.settings().use_gpu;
        let request = TranscribeRequest {
            source: PathBuf::from(&job.source_path),
            settings: job.settings.clone(),
            use_gpu,
            resume_through: job.transcription_resume_through,
            partial: job.partial_transcript_segments.clone(),
            python: self.settings().python_path,
        };
        let reporter = self.clone();
        let report_id = id.clone();
        let report: Report = Arc::new(move |update| match update {
            Update::Progress(progress) => reporter.update(&report_id, false, false, |job| job.progress = progress),
            Update::Segments(batch) => {
                reporter.update(&report_id, false, false, |job| {
                    job.partial_transcript_segments =
                        cue_core::chunk_planner::merge_partial_segments(&job.partial_transcript_segments, &batch);
                });
                reporter.emit(Event::PartialSegments { id: report_id.clone(), segments: batch });
            }
            Update::ChunkComplete(through) => reporter.update(&report_id, false, true, |job| job.transcription_resume_through = through),
        });
        let result = self.inner.transcriber.transcribe(request, cancel.clone(), report);
        let auto_translate = self.settings().auto_translate;
        let canceled = cancel.load(Ordering::Relaxed);
        // When a translation follows, the summary is written from it instead.
        let summary = match &result {
            Ok(segments) if !canceled && !(auto_translate && !segments.is_empty()) => self.auto_summary(&id, segments, false),
            _ => None,
        };
        self.update(&id, true, true, |job| match result {
            Ok(segments) if !canceled => {
                let count = segments.len();
                job.transcript_segments = segments;
                job.summary = summary;
                job.translated_segments.clear();
                job.partial_transcript_segments.clear();
                job.partial_translated_segments.clear();
                job.transcription_resume_through = 0.0;
                job.transcription_finished_at = Some(Utc::now());
                job.log.push_str(&format!("Transcription finished with {count} subtitles.\n"));
                if auto_translate && count > 0 {
                    job.status = JobStatus::Queued;
                    job.progress = JobProgress::new(JobStage::Queued, "Waiting to translate.", None);
                } else {
                    job.status = JobStatus::TranscriptionComplete;
                    job.progress = JobProgress::new(JobStage::Complete, format!("{count} subtitles"), Some(1.0));
                    job.finished_at = Some(Utc::now());
                }
            }
            Ok(_) => canceled_job(job),
            Err(_) if canceled => canceled_job(job),
            Err(error) => failed_job(job, JobStage::Transcribing, &error),
        });
        self.emit(Event::SegmentsChanged { id: id.clone() });
        self.write_sidecars(&id, true);
        let outcome = self.job(&id).and_then(|job| match job.status {
            JobStatus::TranscriptionComplete => Some(true),
            JobStatus::Failed => Some(false),
            _ => None,
        });
        self.lock().transcribing = None;
        if let Some(success) = outcome {
            self.finished(&id, success);
        }
        self.after_run();
    }

    fn run_translation(&self, job: Job, cancel: Arc<AtomicBool>) {
        let id = job.id.clone();
        let outcome = self.translation_options(&job).and_then(|options| {
            let reporter = self.clone();
            let progress_id = id.clone();
            let mut on_progress = move |p: cue_core::translation::Progress| {
                reporter.update(&progress_id, false, false, |job| {
                    job.progress = JobProgress::new(JobStage::Translating, p.detail, Some(p.fraction));
                })
            };
            let saver = self.clone();
            let partial_id = id.clone();
            let mut on_partial = move |done: &[Segment]| {
                saver.update(&partial_id, false, true, |job| job.partial_translated_segments = done.to_vec());
            };
            Translator::new(&*self.inner.transport)
                .translate(&job.transcript_segments, &options, &job.partial_translated_segments, &cancel, &mut on_progress, &mut on_partial)
                .map_err(|e| match e {
                    TranslationError::Canceled => String::new(),
                    other => other.to_string(),
                })
        });
        let canceled = cancel.load(Ordering::Relaxed);
        let summary = match &outcome {
            Ok(translated) if !canceled => self.auto_summary(&id, translated, true),
            _ => None,
        };
        self.update(&id, true, true, |job| match (outcome, canceled) {
            (Ok(translated), false) => {
                job.log.push_str(&format!("Translated {} subtitles with {}.\n", translated.len(), job.settings.translation_model));
                job.translated_segments = translated;
                // The transcript did not change, so a summary it already has
                // (written or edited) stays unless a new one was written.
                if summary.is_some() {
                    job.summary = summary;
                }
                job.partial_translated_segments.clear();
                job.status = JobStatus::TranslationComplete;
                job.progress = JobProgress::new(JobStage::Complete, "Translation ready", Some(1.0));
                job.finished_at = Some(Utc::now());
            }
            (_, true) => {
                job.status = JobStatus::TranscriptionComplete;
                job.progress = JobProgress::new(JobStage::Canceled, "Translation stopped; it resumes where it left off.", None);
                job.log.push_str("Translation was stopped.\n");
            }
            (Err(error), false) => failed_job(job, JobStage::Translating, &error),
        });
        self.emit(Event::SegmentsChanged { id: id.clone() });
        self.write_sidecars(&id, false);
        let outcome = self.job(&id).and_then(|job| match job.status {
            _ if canceled => None,
            JobStatus::TranslationComplete => Some(true),
            JobStatus::Failed => Some(false),
            _ => None,
        });
        self.lock().translating = None;
        if let Some(success) = outcome {
            self.finished(&id, success);
        }
        self.after_run();
    }

    fn translation_options(&self, job: &Job) -> Result<TranslateOptions, String> {
        let settings = &job.settings;
        let provider = Provider::infer(&settings.translation_model);
        let key = match (self.inner.keys)(provider) {
            Some(key) => key,
            None if !provider.needs_api_key() => String::new(),
            None => return Err(format!("Add an {} API key in Settings before using {}.", provider.label(), settings.translation_model)),
        };
        let mut options = TranslateOptions::new(settings.translation_model.clone(), key);
        options.target_language = settings.translation_target_language.clone();
        options.source_language = settings.translation_source_language.clone();
        options.transcription_language = settings.source_language.clone();
        options.chunk_mode = ChunkMode::parse(&settings.translation_chunk_mode).unwrap_or(ChunkMode::Balanced);
        options.parallelism = settings.translation_parallelism.clamp(1, 4) as usize;
        options.local_endpoint = self.settings().local_endpoint;
        Ok(options)
    }

    fn write_sidecars(&self, id: &str, after_transcription: bool) {
        let settings = self.settings();
        let Some(job) = self.job(id) else { return };
        // Watch-folder jobs always leave subtitles next to the video: nobody
        // is there to export them by hand.
        if !settings.auto_export_sidecars && job.origin != JobOrigin::WatchFolder {
            return;
        }
        let done = matches!(
            (after_transcription, job.status),
            (true, JobStatus::TranscriptionComplete | JobStatus::Queued) | (false, JobStatus::TranslationComplete)
        );
        if !done {
            return;
        }
        let set = SidecarSet {
            transcript: &job.transcript_segments,
            translation: &job.translated_segments,
            source_language: &job.settings.source_language,
            target_language: &job.settings.translation_target_language,
            include_original: after_transcription,
            include_translation: !after_transcription,
            include_bilingual: !after_transcription && settings.sidecar_bilingual,
            summary: job.summary.as_deref(),
        };
        match export::write_sidecars(Path::new(&job.source_path), &set) {
            Ok(paths) => {
                let names: Vec<String> = paths.iter().filter_map(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned()).collect();
                if !names.is_empty() {
                    self.update(id, true, true, |job| job.log.push_str(&format!("Saved {}.\n", names.join(", "))));
                }
            }
            Err(e) => self.emit(Event::Notice { message: format!("{}: {e}", job.title()) }),
        }
    }

    /// A run ended on its own: record a watch-folder file's outcome so it
    /// isn't queued again, and tell the UI (for a notification).
    fn finished(&self, id: &str, success: bool) {
        let Some(job) = self.job(id) else { return };
        if job.origin == JobOrigin::WatchFolder && !job.source_fingerprint.is_empty() {
            let outcome = if success { cue_core::watch::Outcome::Success } else { cue_core::watch::Outcome::Failure };
            if let Err(e) = locked(&self.inner.ledger).record(&job.source_fingerprint, outcome) {
                self.emit(Event::Notice { message: format!("Could not save watch-folder history: {e}") });
            }
        }
        self.emit(Event::Finished { id: id.into(), title: job.title(), success, message: job.progress.detail.clone() });
    }

    fn after_run(&self) {
        let event = queue_event(&self.lock());
        self.emit(event);
        self.pump();
    }
}

fn queue(job: &mut Job) {
    job.status = JobStatus::Queued;
    let detail = if job.has_transcript() { "Waiting to translate." } else { "Waiting to transcribe." };
    job.progress = JobProgress::new(JobStage::Queued, detail, None);
    job.finished_at = None;
}

fn canceled_job(job: &mut Job) {
    job.status = JobStatus::Canceled;
    job.progress = JobProgress::new(JobStage::Canceled, "Stopped. Start it again to resume where it left off.", None);
    job.log.push_str("Transcription was stopped.\n");
}

fn failed_job(job: &mut Job, stage: JobStage, error: &str) {
    job.status = JobStatus::Failed;
    job.progress = JobProgress { stage: JobStage::Failed, detail: error.to_string(), fraction: None, failed_stage: Some(stage) };
    job.log.push_str(&format!("Failed: {error}\n"));
}

fn queue_event(state: &State) -> Event {
    Event::Queue {
        paused: state.paused,
        transcribing: state.transcribing.as_ref().map(|r| r.id.clone()),
        translating: state.translating.as_ref().map(|r| r.id.clone()),
    }
}

#[cfg(test)]
mod tests;
