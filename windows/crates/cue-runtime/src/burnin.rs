//! Burning subtitles into a copy of the video with ffmpeg, one at a time,
//! outside the pipeline slots (the Mac's `BurnInService` plus its
//! `AppModel` section). The partial output is deleted on failure or cancel.

use super::*;
use cue_core::burnin::{self as burn, TextSize};
use std::io::Read;
use std::process::{Child, Stdio};

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BurnInState {
    pub job_id: String,
    pub running: bool,
    pub fraction: Option<f64>,
    pub detail: String,
    pub output: String,
    pub error: Option<String>,
}

pub(crate) struct Running {
    child: Arc<Mutex<Option<Child>>>,
    cancel: Arc<AtomicBool>,
}

impl Runtime {
    pub fn ffmpeg_path(&self) -> Option<PathBuf> {
        self.inner.tools.ffmpeg.clone().filter(|p| p.is_file()).or_else(cue_core::audio::find_ffmpeg)
    }

    /// Whether burn-in can run here: ffmpeg exists and was built with
    /// libass. The message says what to fix when it can't.
    pub fn burn_in_preflight(&self) -> Result<(), String> {
        let ffmpeg = self.ffmpeg_path().ok_or("ffmpeg wasn't found. Put ffmpeg.exe next to Cue or on your PATH.")?;
        let output = cue_core::audio::background_command(&ffmpeg)
            .args(["-hide_banner", "-filters"])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .map_err(|e| format!("Could not run ffmpeg: {e}"))?;
        if !burn::has_subtitles_filter(&String::from_utf8_lossy(&output.stdout)) {
            return Err(
                "This ffmpeg build lacks the subtitles filter (libass). Install a full build, such as the one from gyan.dev.".into()
            );
        }
        Ok(())
    }

    /// Where a burn-in of this job lands by default.
    pub fn default_burn_in_output(&self, id: &str) -> Result<PathBuf, String> {
        let job = self.job(id).ok_or("No such job.")?;
        Ok(burn::default_output(Path::new(&job.source_path)))
    }

    /// Starts rendering `document` onto a copy of the job's video.
    pub fn burn_in(&self, id: &str, document: Document, size: TextSize, output: Option<PathBuf>) -> Result<PathBuf, String> {
        let job = self.job(id).ok_or("No such job.")?;
        let segments = match document {
            Document::Original => job.transcript_segments.clone(),
            Document::Translated => job.translated_segments.clone(),
            Document::Bilingual => cue_core::translation::bilingual_segments(&job.transcript_segments, &job.translated_segments),
        };
        if segments.is_empty() {
            return Err("There are no subtitles of that kind to burn in yet.".into());
        }
        let source = PathBuf::from(&job.source_path);
        if !source.is_file() {
            return Err(format!("The video is missing: {}", source.display()));
        }
        let output = output.unwrap_or_else(|| burn::default_output(&source));
        burn::validate_output(&source, &output)?;
        let ffmpeg = self.ffmpeg_path().ok_or("ffmpeg wasn't found. Put ffmpeg.exe next to Cue or on your PATH.")?;

        let child = Arc::new(Mutex::new(None));
        let cancel = Arc::new(AtomicBool::new(false));
        {
            let mut burn = locked(&self.inner.burn);
            if burn.is_some() {
                return Err("Another burn-in is running. Wait for it or cancel it.".into());
            }
            *burn = Some(Running { child: child.clone(), cancel: cancel.clone() });
        }
        let mut state = BurnInState {
            job_id: id.into(),
            running: true,
            fraction: None,
            detail: "Starting…".into(),
            output: output.to_string_lossy().into_owned(),
            error: None,
        };
        self.emit(Event::BurnIn { state: state.clone() });

        let runtime = self.clone();
        let out = output.clone();
        let spawned = std::thread::Builder::new().name("cue-burnin".into()).spawn(move || {
            let result = runtime.render(&ffmpeg, &source, &segments, size, &out, &mut state, &child, &cancel);
            let canceled = cancel.load(Ordering::Relaxed);
            if result.is_err() || canceled {
                let _ = std::fs::remove_file(&out);
            }
            *locked(&runtime.inner.burn) = None;
            state.running = false;
            match (result, canceled) {
                (_, true) => state.detail = "Canceled.".into(),
                (Ok(()), false) => {
                    state.fraction = Some(1.0);
                    state.detail = "Done.".into();
                    runtime
                        .update(&state.job_id, true, true, |job| job.log.push_str(&format!("Burned subtitles into {}.\n", out.display())));
                }
                (Err(e), false) => {
                    state.detail = "Failed.".into();
                    state.error = Some(e);
                }
            }
            runtime.emit(Event::BurnIn { state });
        });
        if let Err(e) = spawned {
            *locked(&self.inner.burn) = None;
            return Err(format!("Could not start the burn-in: {e}"));
        }
        Ok(output)
    }

    #[allow(clippy::too_many_arguments)]
    fn render(
        &self,
        ffmpeg: &Path,
        source: &Path,
        segments: &[Segment],
        size: TextSize,
        output: &Path,
        state: &mut BurnInState,
        child: &Mutex<Option<Child>>,
        cancel: &AtomicBool,
    ) -> Result<(), String> {
        // A fresh folder holding only subs.srt is ffmpeg's working
        // directory, so the filter names a fixed relative file.
        let work = std::env::temp_dir().join(format!("cue-burnin-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;
        let result = (|| {
            subtitle::write_file(segments, Format::Srt, &work.join(burn::SUBTITLE_FILE)).map_err(|e| e.to_string())?;
            let mut process = cue_core::audio::background_command(ffmpeg)
                .current_dir(&work)
                .args(burn::ffmpeg_arguments(source, size, output))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|e| format!("Could not run ffmpeg: {e}"))?;
            let stderr = process.stderr.take();
            *locked(child) = Some(process);
            if cancel.load(Ordering::Relaxed) {
                if let Some(c) = locked(child).as_mut() {
                    let _ = c.kill();
                }
            }
            let mut duration = None;
            let mut tail: Vec<String> = Vec::new();
            let mut last_emit = Instant::now();
            if let Some(mut err) = stderr {
                // ffmpeg repaints its stats line with \r, so split on both.
                let mut buf = [0u8; 4096];
                let mut line = Vec::new();
                loop {
                    let n = match err.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    for &b in &buf[..n] {
                        if b != b'\n' && b != b'\r' {
                            line.push(b);
                            continue;
                        }
                        let text = String::from_utf8_lossy(&line).into_owned();
                        line.clear();
                        if text.trim().is_empty() {
                            continue;
                        }
                        if duration.is_none() {
                            duration = burn::parse_duration(&text);
                        }
                        if let Some(at) = burn::parse_time(&text) {
                            state.fraction = duration.map(|d| (at / d).clamp(0.0, 1.0));
                            state.detail = match state.fraction {
                                Some(f) => format!("Rendering… {}%", (f * 100.0) as i64),
                                None => "Rendering…".into(),
                            };
                            if last_emit.elapsed() >= EMIT_INTERVAL {
                                last_emit = Instant::now();
                                self.emit(Event::BurnIn { state: state.clone() });
                            }
                        } else {
                            tail.push(text);
                            if tail.len() > 20 {
                                tail.remove(0);
                            }
                        }
                    }
                }
            }
            let status = locked(child).take().map(|mut c| c.wait());
            match status {
                Some(Ok(s)) if s.success() => Ok(()),
                Some(Ok(_)) => Err(tail.last().cloned().unwrap_or_else(|| "ffmpeg exited with an error.".into())),
                Some(Err(e)) => Err(format!("ffmpeg failed: {e}")),
                None => Err("ffmpeg stopped unexpectedly.".into()),
            }
        })();
        let _ = std::fs::remove_dir_all(&work);
        result
    }

    pub fn cancel_burn_in(&self) -> Result<(), String> {
        let burn = locked(&self.inner.burn);
        let running = burn.as_ref().ok_or("No burn-in is running.")?;
        running.cancel.store(true, Ordering::Relaxed);
        if let Some(child) = locked(&running.child).as_mut() {
            let _ = child.kill();
        }
        Ok(())
    }
}
