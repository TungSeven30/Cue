//! Watch folders, the Windows counterpart of `WatchFolderService` and the
//! ingest half of `AppModel`. One thread per enabled folder: a recursive
//! file-system watcher wakes it, a follow-up scan runs while a file is
//! still settling, and a 60 s rescan backs up anything the watcher missed.
//!
//! Ingest deliberately skips `add_files`: it never clears the queue's pause
//! and ignores "start added jobs automatically", both of which are for
//! interactive adds only. A watched file is always queued.

use super::*;
use cue_core::watch::{observe_media_files, FileObservation, ScanEngine};
use notify::{RecursiveMode, Watcher as _};
use std::collections::HashSet;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::Weak;

/// Rescan while a sighted file waits out the stability gate.
const FOLLOW_UP: Duration = Duration::from_millis(2500);
/// The fallback for a watcher that missed something (network shares).
const RECONCILE: Duration = Duration::from_secs(60);
/// File events come in bursts while a copy runs; gather them first.
const SETTLE: Duration = Duration::from_millis(300);

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchStatus {
    pub id: String,
    pub path: String,
    pub name: String,
    pub enabled: bool,
    pub profile: serde_json::Value,
    /// Why the folder can't be watched right now, if it can't.
    pub error: Option<String>,
}

pub(crate) struct Watcher {
    path: String,
    stop: Arc<AtomicBool>,
    wake: Sender<()>,
    error: Arc<Mutex<Option<String>>>,
}

fn same_path(a: &str, b: &str) -> bool {
    let norm = |p: &str| {
        let p = p.trim_end_matches(['/', '\\']);
        if cfg!(windows) {
            p.replace('/', "\\").to_lowercase()
        } else {
            p.to_string()
        }
    };
    norm(a) == norm(b)
}

impl Runtime {
    pub fn watch_folders(&self) -> Vec<WatchStatus> {
        let folders = self.lock().settings.watch_folders.clone();
        let watchers = locked(&self.inner.watchers);
        folders
            .into_iter()
            .map(|f| {
                let error = watchers.get(&f.id).and_then(|w| locked(&w.error).clone());
                let name = Path::new(&f.path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| f.path.clone());
                WatchStatus { id: f.id, path: f.path, name, enabled: f.enabled, profile: f.profile, error }
            })
            .collect()
    }

    pub fn add_watch_folder(&self, path: &Path) -> Result<String, String> {
        if !path.is_dir() {
            return Err(format!("{} is not a folder.", path.display()));
        }
        let text = path.to_string_lossy().into_owned();
        let id = self.edit_settings(|settings| {
            if settings.watch_folders.iter().any(|f| same_path(&f.path, &text)) {
                return Err("That folder is already watched.".into());
            }
            let id = uuid::Uuid::new_v4().to_string().to_uppercase();
            settings.watch_folders.push(WatchFolder {
                id: id.clone(),
                path: text.clone(),
                enabled: true,
                profile: serde_json::Value::Object(Default::default()),
            });
            Ok(id)
        })?;
        self.sync_watchers();
        Ok(id)
    }

    pub fn remove_watch_folder(&self, id: &str) -> Result<(), String> {
        self.edit_settings(|settings| {
            let before = settings.watch_folders.len();
            settings.watch_folders.retain(|f| f.id != id);
            if settings.watch_folders.len() == before {
                return Err("No such watch folder.".into());
            }
            Ok(())
        })?;
        self.sync_watchers();
        Ok(())
    }

    /// Turns a folder on or off and sets the overrides its jobs get.
    pub fn set_watch_folder(&self, id: &str, enabled: bool, profile: serde_json::Value) -> Result<(), String> {
        let profile = match profile {
            serde_json::Value::Object(map) => {
                serde_json::Value::Object(map.into_iter().filter(|(_, v)| v.as_str().is_some_and(|s| !s.trim().is_empty())).collect())
            }
            _ => serde_json::Value::Object(Default::default()),
        };
        self.edit_settings(|settings| {
            let folder = settings.watch_folders.iter_mut().find(|f| f.id == id).ok_or("No such watch folder.")?;
            folder.enabled = enabled;
            folder.profile = profile;
            Ok(())
        })?;
        self.sync_watchers();
        Ok(())
    }

    /// Forgets which of this folder's files already ran, so they run again
    /// (unless a job for the same file is still in the list).
    pub fn clear_watch_history(&self, id: &str) -> Result<(), String> {
        let path = self.lock().settings.watch_folders.iter().find(|f| f.id == id).map(|f| f.path.clone()).ok_or("No such watch folder.")?;
        locked(&self.inner.ledger).clear_under(Path::new(&path))?;
        if let Some(w) = locked(&self.inner.watchers).get(id) {
            let _ = w.wake.send(());
        }
        Ok(())
    }

    /// Starts a watcher for every enabled folder and stops the rest.
    pub(crate) fn sync_watchers(&self) {
        let wanted: Vec<WatchFolder> = self.lock().settings.watch_folders.iter().filter(|f| f.enabled).cloned().collect();
        {
            let mut watchers = locked(&self.inner.watchers);
            watchers.retain(|id, w| {
                let keep = wanted.iter().any(|f| &f.id == id && f.path == w.path);
                if !keep {
                    w.stop.store(true, Ordering::Relaxed);
                    let _ = w.wake.send(());
                }
                keep
            });
            for folder in &wanted {
                if !watchers.contains_key(&folder.id) {
                    let watcher = self.spawn_watcher(folder);
                    watchers.insert(folder.id.clone(), watcher);
                }
            }
        }
        self.emit_watch_folders();
    }

    pub(crate) fn stop_watchers(&self) {
        for (_, w) in locked(&self.inner.watchers).drain() {
            w.stop.store(true, Ordering::Relaxed);
            let _ = w.wake.send(());
        }
    }

    fn emit_watch_folders(&self) {
        let folders = self.watch_folders();
        self.emit(Event::WatchFolders { folders });
    }

    fn spawn_watcher(&self, folder: &WatchFolder) -> Watcher {
        let (wake, wakes) = channel::<()>();
        let stop = Arc::new(AtomicBool::new(false));
        let error = Arc::new(Mutex::new(None));
        let inner: Weak<Inner> = Arc::downgrade(&self.inner);
        let (id, root) = (folder.id.clone(), PathBuf::from(&folder.path));
        let (thread_stop, thread_error, events) = (stop.clone(), error.clone(), wake.clone());
        let spawned = std::thread::Builder::new().name("cue-watch".into()).spawn(move || {
            let mut engine = ScanEngine::default();
            let mut fs_watcher: Option<notify::RecommendedWatcher> = None;
            loop {
                if thread_stop.load(Ordering::Relaxed) {
                    break;
                }
                let Some(inner) = inner.upgrade() else { break };
                let runtime = Runtime { inner };
                // (Re)attach the file watcher; a folder that was missing at
                // launch may have come back.
                if fs_watcher.is_none() && root.is_dir() {
                    let sender = events.clone();
                    fs_watcher = notify::recommended_watcher(move |_: notify::Result<notify::Event>| {
                        let _ = sender.send(());
                    })
                    .ok()
                    .and_then(|mut w| w.watch(&root, RecursiveMode::Recursive).ok().map(|_| w));
                }
                let problem = runtime.scan_watch_folder(&id, &root, &mut engine);
                if problem.is_some() {
                    fs_watcher = None;
                }
                let changed = {
                    let mut current = locked(&thread_error);
                    let changed = *current != problem;
                    *current = problem;
                    changed
                };
                if changed {
                    runtime.emit_watch_folders();
                }
                let wait = if engine.has_pending() { FOLLOW_UP } else { RECONCILE };
                drop(runtime);
                match wakes.recv_timeout(wait) {
                    Ok(()) => {
                        std::thread::sleep(SETTLE);
                        while wakes.try_recv().is_ok() {}
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }
        });
        if let Err(e) = spawned {
            *locked(&error) = Some(format!("Could not start watching: {e}"));
        }
        Watcher { path: folder.path.clone(), stop, wake, error }
    }

    /// One pass over a folder. Returns why it can't be read, if it can't.
    fn scan_watch_folder(&self, id: &str, root: &Path, engine: &mut ScanEngine) -> Option<String> {
        let Some(observations) = observe_media_files(root) else {
            return Some(if root.exists() {
                "Cue can't read this folder.".into()
            } else {
                "This folder is missing. Reconnect the drive or remove it.".into()
            });
        };
        // Already run (ledger) or already in the list (any job, by
        // fingerprint): a replaced file has a new fingerprint and runs again.
        let mut blocked: HashSet<String> = locked(&self.inner.ledger).fingerprints().cloned().collect();
        blocked.extend(self.lock().jobs.iter().map(|j| j.source_fingerprint.clone()));
        let ready = engine.ready(&observations, Instant::now(), &blocked);

        // Forget history for files that are gone, re-checking the disk for
        // entries the scan skipped (hidden or unreadable) before dropping them.
        let mut existing: HashSet<PathBuf> = observations.iter().map(|o| o.path.clone()).collect();
        {
            let mut ledger = locked(&self.inner.ledger);
            existing.extend(ledger.paths_under(root).into_iter().filter(|p| p.exists()));
            if let Err(e) = ledger.prune_under(root, &existing) {
                self.emit(Event::Notice { message: format!("Could not save watch-folder history: {e}") });
            }
        }
        if !ready.is_empty() {
            self.ingest_watch_files(id, root, &ready);
        }
        None
    }

    fn ingest_watch_files(&self, folder_id: &str, root: &Path, files: &[FileObservation]) {
        let mut added = Vec::new();
        {
            let mut state = self.lock();
            // The folder may have been switched off mid-scan.
            let Some(folder) = state.settings.watch_folders.iter().find(|f| f.id == folder_id && f.enabled).cloned() else { return };
            let snapshot = state.settings.snapshot();
            let mut order = state.jobs.iter().map(|j| j.order_index).filter(|o| o.is_finite()).fold(0.0_f64, f64::max);
            for file in files {
                let fingerprint = file.fingerprint();
                // Same file, or the same path still waiting or running: a
                // late timestamp change must not queue it twice.
                let path = file.path.to_string_lossy();
                let active = |j: &Job| j.source_path == path && (j.status == JobStatus::Queued || j.status.is_running());
                if state.jobs.iter().any(|j| j.source_fingerprint == fingerprint || active(j)) {
                    continue;
                }
                order += 1.0;
                let mut job = Job::new(&file.path, apply_overrides(snapshot.clone(), &folder.profile), Utc::now());
                job.source_fingerprint = fingerprint;
                job.origin = JobOrigin::WatchFolder;
                job.overrides = folder.profile.clone();
                job.order_index = order;
                job.status = JobStatus::Queued;
                job.progress = JobProgress::new(JobStage::Queued, "Waiting in queue.", None);
                job.log = format!("Picked up from the watch folder: {}\n", root.display());
                added.push(job.clone());
                state.jobs.push(job);
            }
        }
        for job in &added {
            self.inner.persister.save(job);
            self.emit(Event::Job { job: Box::new(JobSummary::of(job)) });
        }
        if !added.is_empty() {
            self.pump();
        }
    }
}
