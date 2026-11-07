//! Watch-folder ingest rules. Mirrors `WatchFolderScanEngine`,
//! `WatchFolderLedger` and `MediaFileTypes` on the Mac: the scan engine is
//! pure (no I/O, no clock), the ledger remembers files that reached a final
//! outcome so a rescan never queues them again.

use crate::jobs::fingerprint_of;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, UNIX_EPOCH};

/// Media the watch folder picks up. Drag and drop is more lenient; nobody is
/// around to dismiss a junk job here.
pub const MEDIA_EXTENSIONS: [&str; 22] = [
    "mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "mpg", "mpeg", "ts", "mts", "m2ts", "3gp", "flv", "mp3", "m4a", "aac", "wav", "flac",
    "ogg", "opus", "aiff",
];

/// In-progress downloads are never ingested.
pub const PARTIAL_EXTENSIONS: [&str; 3] = ["part", "download", "crdownload"];

/// How long a file's size must hold still before it is ingested.
pub const STABILITY_INTERVAL: Duration = Duration::from_secs(2);

pub fn is_media(path: &Path) -> bool {
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    MEDIA_EXTENSIONS.contains(&ext.as_str()) && !PARTIAL_EXTENSIONS.contains(&ext.as_str())
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

/// One sighting of a file during a scan.
#[derive(Debug, Clone, PartialEq)]
pub struct FileObservation {
    pub path: PathBuf,
    pub size: u64,
    /// Seconds since 1970.
    pub modified: f64,
}

impl FileObservation {
    /// Same string a job built from this file stores as its fingerprint.
    pub fn fingerprint(&self) -> String {
        fingerprint_of(&self.path.to_string_lossy(), self.size, self.modified)
    }
}

/// Every media file under `root` at any depth: hidden entries skipped,
/// symlinked folders not followed, sorted so episodes enqueue in order.
/// `None` when `root` itself can't be read (an unplugged drive), so callers
/// can tell "gone" from "empty".
pub fn observe_media_files(root: &Path) -> Option<Vec<FileObservation>> {
    if !root.is_dir() {
        return None;
    }
    std::fs::read_dir(root).ok()?;
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if is_hidden(&name) {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            let path = entry.path();
            if kind.is_dir() {
                stack.push(path);
            } else if kind.is_file() && is_media(&path) {
                let Ok(meta) = entry.metadata() else { continue };
                let modified = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs_f64()).unwrap_or(0.0);
                found.push(FileObservation { path, size: meta.len(), modified });
            }
        }
    }
    found.sort_by(|a, b| natural_cmp(&a.path.to_string_lossy(), &b.path.to_string_lossy()));
    Some(found)
}

/// Files dropped or picked: files pass through, folders contribute their
/// media in place, so a mixed drop keeps its order.
pub fn expand_for_add(paths: &[PathBuf]) -> Vec<PathBuf> {
    paths
        .iter()
        .flat_map(|p| {
            if p.is_dir() {
                observe_media_files(p).unwrap_or_default().into_iter().map(|o| o.path).collect()
            } else {
                vec![p.clone()]
            }
        })
        .collect()
}

/// Case-insensitive compare that orders digit runs by value, so
/// "Episode 2" sorts before "Episode 10" (Finder's order).
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut na = String::new();
                while let Some(c) = a.peek().copied().filter(char::is_ascii_digit) {
                    na.push(c);
                    a.next();
                }
                let mut nb = String::new();
                while let Some(c) = b.peek().copied().filter(char::is_ascii_digit) {
                    nb.push(c);
                    b.next();
                }
                let (ta, tb) = (na.trim_start_matches('0'), nb.trim_start_matches('0'));
                let order = ta.len().cmp(&tb.len()).then_with(|| ta.cmp(tb));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

/// The stability gate between scans. A file is ready once a later scan
/// sees the same size at least `STABILITY_INTERVAL` after the first.
#[derive(Default)]
pub struct ScanEngine {
    /// Size and modification time when first seen unchanged, and when.
    candidates: HashMap<PathBuf, (u64, f64, Instant)>,
}

impl ScanEngine {
    /// Files sighted but not yet stable; a follow-up scan should decide them.
    pub fn has_pending(&self) -> bool {
        !self.candidates.is_empty()
    }

    pub fn ready(&mut self, observations: &[FileObservation], now: Instant, blocked: &HashSet<String>) -> Vec<FileObservation> {
        let mut ready = Vec::new();
        let mut seen = HashSet::new();
        for file in observations {
            seen.insert(file.path.clone());
            let name = file.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if !is_media(&file.path) || is_hidden(&name) {
                continue;
            }
            if blocked.contains(&file.fingerprint()) {
                self.candidates.remove(&file.path);
                continue;
            }
            match self.candidates.get(&file.path) {
                // Size and time both hold still: a copier that stamps the
                // original mtime at the end must not yield a second fingerprint.
                Some(&(size, modified, first)) if size == file.size && modified == file.modified => {
                    if now.duration_since(first) >= STABILITY_INTERVAL {
                        ready.push(file.clone());
                        self.candidates.remove(&file.path);
                    }
                }
                // New, or still changing: (re)start its clock.
                _ => {
                    self.candidates.insert(file.path.clone(), (file.size, file.modified, now));
                }
            }
        }
        // A file that vanished mid-wait must not linger.
        self.candidates.retain(|path, _| seen.contains(path));
        ready
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Outcome {
    Success,
    Failure,
}

/// Files that already reached success or failure, by fingerprint, so a
/// replaced file (new size or time) runs again. Saved as
/// `watch-ledger.json`, the Mac's format.
pub struct Ledger {
    path: PathBuf,
    entries: BTreeMap<String, Outcome>,
    pub startup_error: Option<String>,
}

impl Ledger {
    pub fn open(path: PathBuf) -> Ledger {
        let mut ledger = Ledger { path, entries: BTreeMap::new(), startup_error: None };
        let Ok(text) = std::fs::read_to_string(&ledger.path) else { return ledger };
        match serde_json::from_str(&text) {
            Ok(entries) => ledger.entries = entries,
            Err(e) => {
                let backup = ledger.path.with_extension("json.corrupt");
                let _ = std::fs::copy(&ledger.path, &backup);
                ledger.startup_error = Some(format!(
                    "Could not read watch-folder history: {e}. The original was kept at {}; files may be queued again.",
                    backup.display()
                ));
            }
        }
        ledger
    }

    pub fn fingerprints(&self) -> impl Iterator<Item = &String> {
        self.entries.keys()
    }

    pub fn contains(&self, fingerprint: &str) -> bool {
        self.entries.contains_key(fingerprint)
    }

    pub fn record(&mut self, fingerprint: &str, outcome: Outcome) -> Result<(), String> {
        self.entries.insert(fingerprint.to_string(), outcome);
        self.save()
    }

    /// Entries whose file lives under `folder`.
    pub fn paths_under(&self, folder: &Path) -> Vec<PathBuf> {
        self.entries.keys().map(|f| PathBuf::from(path_from_fingerprint(f))).filter(|p| p.starts_with(folder)).collect()
    }

    /// Drops entries under `folder` whose file is gone. Other folders'
    /// history is left alone.
    pub fn prune_under(&mut self, folder: &Path, existing: &HashSet<PathBuf>) -> Result<(), String> {
        let before = self.entries.len();
        self.entries.retain(|f, _| {
            let path = PathBuf::from(path_from_fingerprint(f));
            !path.starts_with(folder) || existing.contains(&path)
        });
        if self.entries.len() == before {
            return Ok(());
        }
        self.save()
    }

    /// Forgets one folder's history so its files run again.
    pub fn clear_under(&mut self, folder: &Path) -> Result<(), String> {
        self.entries.retain(|f, _| !PathBuf::from(path_from_fingerprint(f)).starts_with(folder));
        self.save()
    }

    fn save(&self) -> Result<(), String> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let tmp = self.path.with_extension("json.tmp");
        let text = serde_json::to_string(&self.entries).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, &self.path)).map_err(|e| e.to_string())
    }
}

/// The path part of `path|size|mtime`; the path itself may hold pipes.
pub fn path_from_fingerprint(fingerprint: &str) -> &str {
    let mut parts = fingerprint.rsplitn(3, '|');
    let _mtime = parts.next();
    let _size = parts.next();
    parts.next().unwrap_or(fingerprint)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs(path: &str, size: u64) -> FileObservation {
        FileObservation { path: PathBuf::from(path), size, modified: 100.0 }
    }

    #[test]
    fn a_file_is_ready_only_after_holding_its_size() {
        let mut engine = ScanEngine::default();
        let t0 = Instant::now();
        let none = HashSet::new();
        assert!(engine.ready(&[obs("/w/a.mp4", 10)], t0, &none).is_empty());
        assert!(engine.has_pending());
        // Still growing: the clock restarts.
        assert!(engine.ready(&[obs("/w/a.mp4", 20)], t0 + Duration::from_secs(3), &none).is_empty());
        // Same size but too soon.
        assert!(engine.ready(&[obs("/w/a.mp4", 20)], t0 + Duration::from_secs(4), &none).is_empty());
        let ready = engine.ready(&[obs("/w/a.mp4", 20)], t0 + Duration::from_secs(5), &none);
        assert_eq!(ready.len(), 1);
        assert!(!engine.has_pending());
    }

    #[test]
    fn a_changed_modification_time_restarts_the_clock() {
        let mut engine = ScanEngine::default();
        let none = HashSet::new();
        let t0 = Instant::now();
        engine.ready(&[obs("/w/a.mp4", 10)], t0, &none);
        // Same size, but the copier stamped a new time: not settled yet.
        let restamped = FileObservation { modified: 200.0, ..obs("/w/a.mp4", 10) };
        assert!(engine.ready(std::slice::from_ref(&restamped), t0 + Duration::from_secs(3), &none).is_empty());
        let ready = engine.ready(std::slice::from_ref(&restamped), t0 + Duration::from_secs(6), &none);
        assert_eq!(ready, vec![restamped]);
    }

    #[test]
    fn blocked_partial_and_hidden_files_are_skipped_and_vanished_ones_forgotten() {
        let mut engine = ScanEngine::default();
        let t0 = Instant::now();
        let blocked: HashSet<String> = [obs("/w/done.mp4", 5).fingerprint()].into();
        let files = [obs("/w/done.mp4", 5), obs("/w/x.mp4.part", 5), obs("/w/.hidden.mp4", 5), obs("/w/notes.txt", 5)];
        engine.ready(&files, t0, &blocked);
        assert!(!engine.has_pending());
        engine.ready(&[obs("/w/new.mkv", 1)], t0, &blocked);
        assert!(engine.has_pending());
        engine.ready(&[], t0 + Duration::from_secs(1), &blocked);
        assert!(!engine.has_pending());
    }

    #[test]
    fn fingerprint_matches_the_mac_format() {
        assert_eq!(obs("/w/a|b.mp4", 7).fingerprint(), "/w/a|b.mp4|7|100.0");
        assert_eq!(fingerprint_of("/x.mp4", 1, 1.5), "/x.mp4|1|1.5");
        assert_eq!(path_from_fingerprint("/w/a|b.mp4|7|100.0"), "/w/a|b.mp4");
    }

    #[test]
    fn natural_order_puts_episode_2_before_10() {
        let mut names = vec!["Ep 10.mp4", "ep 2.mp4", "Ep 1.mp4"];
        names.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(names, ["Ep 1.mp4", "ep 2.mp4", "Ep 10.mp4"]);
    }

    #[test]
    fn observation_recurses_skips_hidden_and_reports_unreadable_roots() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("Season 1")).unwrap();
        std::fs::create_dir_all(dir.path().join(".cache")).unwrap();
        std::fs::write(dir.path().join("Season 1/ep10.mkv"), b"x").unwrap();
        std::fs::write(dir.path().join("Season 1/ep2.mkv"), b"x").unwrap();
        std::fs::write(dir.path().join(".cache/skip.mp4"), b"x").unwrap();
        std::fs::write(dir.path().join("readme.txt"), b"x").unwrap();
        let found = observe_media_files(dir.path()).unwrap();
        let names: Vec<_> = found.iter().map(|o| o.path.file_name().unwrap().to_string_lossy().into_owned()).collect();
        assert_eq!(names, ["ep2.mkv", "ep10.mkv"]);
        assert!(observe_media_files(&dir.path().join("missing")).is_none());
        let expanded = expand_for_add(&[dir.path().join("readme.txt"), dir.path().to_path_buf()]);
        assert_eq!(expanded.len(), 3);
    }

    #[test]
    fn ledger_persists_prunes_per_folder_and_survives_corruption() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("watch-ledger.json");
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        let mut ledger = Ledger::open(path.clone());
        ledger.record(&fingerprint_of(&a.join("1.mp4").to_string_lossy(), 1, 1.0), Outcome::Success).unwrap();
        ledger.record(&fingerprint_of(&b.join("2.mp4").to_string_lossy(), 1, 1.0), Outcome::Failure).unwrap();
        let reopened = Ledger::open(path.clone());
        assert_eq!(reopened.fingerprints().count(), 2);
        assert_eq!(reopened.paths_under(&a), [a.join("1.mp4")]);

        // Pruning folder a (file gone) leaves folder b's entry alone.
        let mut ledger = reopened;
        ledger.prune_under(&a, &HashSet::new()).unwrap();
        assert_eq!(ledger.fingerprints().count(), 1);
        ledger.clear_under(&b).unwrap();
        assert_eq!(Ledger::open(path.clone()).fingerprints().count(), 0);

        std::fs::write(&path, "{not json").unwrap();
        let broken = Ledger::open(path.clone());
        assert!(broken.startup_error.is_some());
        assert!(path.with_extension("json.corrupt").exists());
    }
}
