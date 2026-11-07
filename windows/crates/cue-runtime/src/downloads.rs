//! "Add from URL", the Windows counterpart of `AppModel`'s downloads
//! section. A fetch lives here, not in the job list, until its file lands
//! (a job's identity is a file that doesn't exist yet); it holds no
//! pipeline slot and runs alongside the queue.

use super::*;
use cue_core::download::{self as dl, DownloadUpdate};
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Stdio};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DownloadStatus {
    Running,
    Done,
    Failed,
    Canceled,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Download {
    pub id: String,
    pub url: String,
    pub status: DownloadStatus,
    pub fraction: Option<f64>,
    pub detail: String,
    /// The job the finished file became.
    pub job_id: Option<String>,
}

pub(crate) struct Slot {
    pub(crate) info: Download,
    child: Arc<Mutex<Option<Child>>>,
    cancel: Arc<AtomicBool>,
    last_emit: Instant,
}

/// Keeps a failure readable: yt-dlp prints whole tracebacks.
const ERROR_TAIL: usize = 4000;

impl Runtime {
    pub fn downloads(&self) -> Vec<Download> {
        locked(&self.inner.downloads).iter().map(|d| d.info.clone()).collect()
    }

    /// Where yt-dlp is, if anywhere: the configured path, `CUE_YTDLP`,
    /// next to Cue, Cue's tools folder, then PATH.
    pub fn ytdlp_path(&self) -> Option<PathBuf> {
        let name = if cfg!(windows) { "yt-dlp.exe" } else { "yt-dlp" };
        let candidates = [
            self.inner.tools.ytdlp.clone(),
            std::env::var_os("CUE_YTDLP").map(PathBuf::from),
            std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join(name))),
            Some(self.tools_dir().join(name)),
        ];
        candidates.into_iter().flatten().find(|p| p.is_file()).or_else(|| {
            std::env::var_os("PATH").and_then(|paths| std::env::split_paths(&paths).map(|d| d.join(name)).find(|p| p.is_file()))
        })
    }

    pub(crate) fn tools_dir(&self) -> PathBuf {
        self.inner.data_dir.join("tools")
    }

    /// Starts fetching a pasted address. The id names the download.
    pub fn add_url(&self, text: &str) -> Result<String, String> {
        let url = dl::normalize_url(text).ok_or_else(|| format!("{} is not an http(s) address.", text.trim()))?;
        let ytdlp = self.ytdlp_path().ok_or("yt-dlp isn't installed yet. Install it from Settings, then try again.")?;
        let dir = self.settings().downloads_dir();
        std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        let staging = dir.join(format!(".cue-download-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&staging).map_err(|e| format!("cannot create {}: {e}", staging.display()))?;

        let id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let info = Download {
            id: id.clone(),
            url: url.clone(),
            status: DownloadStatus::Running,
            fraction: None,
            detail: "Resolving link…".into(),
            job_id: None,
        };
        let child = Arc::new(Mutex::new(None));
        let cancel = Arc::new(AtomicBool::new(false));
        locked(&self.inner.downloads).push(Slot {
            info: info.clone(),
            child: child.clone(),
            cancel: cancel.clone(),
            last_emit: Instant::now(),
        });
        self.emit(Event::Download { download: info });

        let ffmpeg = self.inner.tools.ffmpeg.clone().or_else(cue_core::audio::find_ffmpeg);
        let runtime = self.clone();
        let thread_id = id.clone();
        let spawned = std::thread::Builder::new().name("cue-download".into()).spawn(move || {
            let result = runtime.fetch(&thread_id, &ytdlp, ffmpeg.as_deref(), &url, &staging, &dir, &child, &cancel);
            let _ = std::fs::remove_dir_all(&staging);
            runtime.finish_download(&thread_id, &url, result, cancel.load(Ordering::Relaxed));
        });
        if let Err(e) = spawned {
            self.finish_download(&id, "", Err(format!("Could not start the download: {e}")), false);
        }
        Ok(id)
    }

    #[allow(clippy::too_many_arguments)]
    fn fetch(
        &self,
        id: &str,
        ytdlp: &Path,
        ffmpeg: Option<&Path>,
        url: &str,
        staging: &Path,
        dir: &Path,
        child: &Mutex<Option<Child>>,
        cancel: &AtomicBool,
    ) -> Result<PathBuf, String> {
        let mut process = cue_core::audio::background_command(ytdlp)
            .args(dl::ytdlp_arguments(url, staging, ffmpeg))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Could not run yt-dlp: {e}"))?;
        let stdout = process.stdout.take();
        let stderr = process.stderr.take();
        *locked(child) = Some(process);
        // A cancel that landed before the child was stored.
        if cancel.load(Ordering::Relaxed) {
            if let Some(c) = locked(child).as_mut() {
                let _ = c.kill();
            }
        }
        let tail = std::thread::spawn(move || {
            let mut text = String::new();
            if let Some(mut err) = stderr {
                let mut buf = Vec::new();
                let _ = err.read_to_end(&mut buf);
                text = String::from_utf8_lossy(&buf).into_owned();
            }
            text
        });
        if let Some(out) = stdout {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if let Some(update) = dl::parse_progress(&line) {
                    self.download_progress(id, update);
                }
            }
        }
        let status = locked(child).take().map(|mut c| c.wait());
        let errors = tail.join().unwrap_or_default();
        if cancel.load(Ordering::Relaxed) {
            return Err(String::new());
        }
        match status {
            Some(Ok(s)) if s.success() => {}
            Some(Ok(_)) => {
                let lines: Vec<&str> = errors.lines().filter(|l| !l.trim().is_empty()).collect();
                let message =
                    lines.iter().rev().find(|l| l.contains("ERROR")).copied().unwrap_or_else(|| lines.last().copied().unwrap_or(""));
                let message: String = message.chars().take(ERROR_TAIL).collect();
                return Err(if message.is_empty() { "yt-dlp exited with an error.".into() } else { message });
            }
            Some(Err(e)) => return Err(format!("yt-dlp failed: {e}")),
            None => return Err("yt-dlp stopped unexpectedly.".into()),
        }
        let produced = dl::finished_media(staging).ok_or("yt-dlp finished but produced no media file.")?;
        let name = produced.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "download.mp4".into());
        let destination = dl::unique_destination(&name, dir);
        std::fs::rename(&produced, &destination).map_err(|e| format!("cannot move the download into {}: {e}", dir.display()))?;
        Ok(destination)
    }

    fn download_progress(&self, id: &str, update: DownloadUpdate) {
        let mut downloads = locked(&self.inner.downloads);
        let Some(slot) = downloads.iter_mut().find(|d| d.info.id == id) else { return };
        let phase_changed = slot.info.fraction.is_none() != update.fraction.is_none();
        slot.info.fraction = update.fraction;
        slot.info.detail = update.detail;
        let now = Instant::now();
        if !phase_changed && now.duration_since(slot.last_emit) < EMIT_INTERVAL {
            return;
        }
        slot.last_emit = now;
        let info = slot.info.clone();
        drop(downloads);
        self.emit(Event::Download { download: info });
    }

    fn finish_download(&self, id: &str, url: &str, result: Result<PathBuf, String>, canceled: bool) {
        let job_id = match &result {
            Ok(path) if !canceled => {
                self.add_paths(std::slice::from_ref(path), JobOrigin::Url, Some(&format!("Downloaded from {url}"))).into_iter().next()
            }
            _ => None,
        };
        let info = {
            let mut downloads = locked(&self.inner.downloads);
            let Some(slot) = downloads.iter_mut().find(|d| d.info.id == id) else { return };
            match (&result, canceled) {
                (_, true) => {
                    slot.info.status = DownloadStatus::Canceled;
                    slot.info.detail = "Canceled.".into();
                }
                (Ok(path), false) => {
                    slot.info.status = DownloadStatus::Done;
                    slot.info.fraction = Some(1.0);
                    slot.info.detail = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    slot.info.job_id = job_id;
                }
                (Err(e), false) => {
                    slot.info.status = DownloadStatus::Failed;
                    slot.info.detail = e.clone();
                }
            }
            slot.info.clone()
        };
        self.emit(Event::Download { download: info });
    }

    pub fn cancel_download(&self, id: &str) -> Result<(), String> {
        let downloads = locked(&self.inner.downloads);
        let slot = downloads.iter().find(|d| d.info.id == id).ok_or("No such download.")?;
        slot.cancel.store(true, Ordering::Relaxed);
        if let Some(child) = locked(&slot.child).as_mut() {
            let _ = child.kill();
        }
        Ok(())
    }

    /// Clears a finished, failed or canceled download from the list.
    pub fn dismiss_download(&self, id: &str) -> Result<(), String> {
        let mut downloads = locked(&self.inner.downloads);
        let index = downloads.iter().position(|d| d.info.id == id).ok_or("No such download.")?;
        if downloads[index].info.status == DownloadStatus::Running {
            return Err("Cancel the download first.".into());
        }
        downloads.remove(index);
        drop(downloads);
        self.emit(Event::DownloadRemoved { id: id.into() });
        Ok(())
    }

    pub(crate) fn cancel_all_downloads(&self) {
        let ids: Vec<String> =
            locked(&self.inner.downloads).iter().filter(|d| d.info.status == DownloadStatus::Running).map(|d| d.info.id.clone()).collect();
        for id in ids {
            let _ = self.cancel_download(&id);
        }
    }

    /// Downloads the latest yt-dlp release into Cue's tools folder, checked
    /// against the release's published SHA-256 sums. Blocks; run it off the
    /// UI thread.
    pub fn install_ytdlp(&self) -> Result<PathBuf, String> {
        const BASE: &str = "https://github.com/yt-dlp/yt-dlp/releases/latest/download";
        let asset = dl::ytdlp_asset_name();
        let agent = cue_core::models::http_agent();
        let fetch = |url: &str| -> Result<Vec<u8>, String> {
            let mut response = agent.get(url).call().map_err(|e| format!("cannot download {url}: {e}"))?;
            response.body_mut().with_config().limit(64 * 1024 * 1024).read_to_vec().map_err(|e| format!("cannot download {url}: {e}"))
        };
        let sums = String::from_utf8_lossy(&fetch(&format!("{BASE}/SHA2-256SUMS"))?).into_owned();
        let expected = dl::checksum_for(&sums, asset).ok_or("The yt-dlp release has no checksum for this platform.")?;
        let bytes = fetch(&format!("{BASE}/{asset}"))?;
        use sha2::Digest;
        let actual = hex::encode(sha2::Sha256::digest(&bytes));
        if actual != expected {
            return Err("The downloaded yt-dlp didn't match its published checksum, so it wasn't installed.".into());
        }
        let dir = self.tools_dir();
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let path = dir.join(if cfg!(windows) { "yt-dlp.exe" } else { "yt-dlp" });
        let tmp = path.with_extension("download");
        std::fs::write(&tmp, &bytes).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
        }
        std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
        Ok(path)
    }
}
