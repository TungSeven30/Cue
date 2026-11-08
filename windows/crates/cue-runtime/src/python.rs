//! The optional Python backend (faster-whisper), run through the shared
//! helper in `--serve` mode. The helper is the repository's `transcribe.py`,
//! generated from the Mac's `BackendScript.source`, embedded unchanged.
//! Mirrors `PythonWorkerPool.swift`: one resident worker per (backend,
//! model, script, launcher), one job at a time, cancel kills the worker, a
//! crash fails only the job in flight and the next job respawns, and an
//! idle worker exits after ten minutes.
//!
//! The Mac's Qwen3-ASR path runs on MLX, which is Apple-only, so Windows
//! offers faster-whisper alone.

use crate::{Report, TranscribeRequest, Transcriber, Update};
use cue_core::jobs::{JobProgress, JobStage};
use cue_core::postprocess::{self, CleanupSettings};
use cue_core::{audio, paths, Segment};
use serde::Serialize;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The helper, byte for byte the root `transcribe.py`.
pub const SCRIPT: &str = include_str!("../../../../transcribe.py");
/// The name the Mac writes it under, so tooling that looks for it agrees.
const SCRIPT_NAME: &str = "cue_backend.py";
pub const FASTER_WHISPER: &str = "faster-whisper";
pub const BUILT_IN: &str = "whisper-cpp";
const IDLE_TIMEOUT: Duration = Duration::from_secs(600);
const KILL_GRACE: Duration = Duration::from_secs(3);
const MAX_ERROR_LINES: usize = 200;

/// Writes the helper into `dir` unless an identical copy is already there.
pub fn ensure_script(dir: &Path) -> Result<PathBuf, String> {
    let path = dir.join(SCRIPT_NAME);
    if std::fs::read_to_string(&path).is_ok_and(|current| current == SCRIPT) {
        return Ok(path);
    }
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("py.tmp");
    std::fs::write(&tmp, SCRIPT)
        .and_then(|_| std::fs::rename(&tmp, &path))
        .map_err(|e| format!("Could not write the Python helper: {e}"))?;
    Ok(path)
}

/// The commands tried to start Python, best first. A path set in Settings
/// is the only candidate; otherwise the `py` launcher a python.org install
/// puts on PATH, then plain `python`.
pub fn launchers(setting: &str) -> Vec<Vec<String>> {
    let setting = setting.trim();
    if !setting.is_empty() {
        return vec![vec![setting.to_string()]];
    }
    if cfg!(windows) {
        vec![vec!["py".into(), "-3".into()], vec!["python".into()]]
    } else {
        vec![vec!["python3".into()]]
    }
}

/// faster-whisper's name for a catalog model: the ggml file name without
/// its prefix, extension or quantization ("large-v3-turbo-q5_0" →
/// "large-v3-turbo"). Names the helper maps itself pass through.
pub fn faster_whisper_model(name: &str) -> String {
    let base = name.trim().trim_start_matches("ggml-").trim_end_matches(".bin");
    let base = ["-q5_0", "-q5_1", "-q8_0"].iter().fold(base, |b, q| b.strip_suffix(q).unwrap_or(b));
    if base.is_empty() {
        "large-v3-turbo".into()
    } else {
        base.to_string()
    }
}

/// One `{"event":"job",…}` line, field for field the Mac's `PythonJobRequest`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct JobRequest {
    pub event: &'static str,
    pub id: String,
    pub input_path: String,
    pub language: String,
    pub qwen_context: String,
    pub model: String,
    pub backend: String,
    pub preprocess_audio: bool,
    pub vad_filter: bool,
    pub beam_size: i64,
    pub best_of: i64,
    pub temperature: f64,
    pub no_speech_threshold: f64,
    pub stream_segments: bool,
    pub resume_through_seconds: f64,
    pub starting_segment_id: i64,
    pub audio_wav: Option<String>,
}

impl JobRequest {
    /// A faster-whisper job on audio Cue already extracted. It always runs
    /// the whole file (the backend cannot resume), so it starts at id 1.
    pub fn faster_whisper(id: &str, source: &Path, wav: &Path, settings: &cue_core::jobs::JobSettings) -> Self {
        let extra = |key: &str| settings.extra.get(key);
        JobRequest {
            event: "job",
            id: id.into(),
            input_path: source.to_string_lossy().into_owned(),
            language: settings.source_language.clone(),
            qwen_context: String::new(),
            model: faster_whisper_model(&settings.whisper_model),
            backend: FASTER_WHISPER.into(),
            preprocess_audio: false,
            vad_filter: extra("vadFilter").and_then(Value::as_bool).unwrap_or(true),
            beam_size: settings.beam_size.max(1),
            best_of: extra("bestOf").and_then(Value::as_i64).unwrap_or(5).max(1),
            temperature: extra("temperature").and_then(Value::as_f64).unwrap_or(0.0),
            no_speech_threshold: settings.no_speech_threshold,
            stream_segments: true,
            resume_through_seconds: 0.0,
            starting_segment_id: 1,
            audio_wav: Some(wav.to_string_lossy().into_owned()),
        }
    }
}

/// One line of the helper's stderr.
#[derive(Debug, Clone, PartialEq)]
pub enum Line {
    Progress(JobProgress),
    Segments(Vec<Segment>),
    ChunkComplete(f64),
    Result {
        id: String,
        backend: String,
        segments: Vec<Segment>,
    },
    Error {
        id: String,
        message: String,
    },
    /// Metrics, or anything else the helper prints as JSON.
    Ignored,
    /// Plain text: a traceback or a library's warning, kept for the error.
    Text(String),
}

pub fn parse_line(line: &str) -> Line {
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(line) else {
        return Line::Text(line.to_string());
    };
    let text = |key: &str| object.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let segments = || object.get("segments").cloned().and_then(|s| serde_json::from_value::<Vec<Segment>>(s).ok()).unwrap_or_default();
    match object.get("event").and_then(Value::as_str) {
        Some("segments") => Line::Segments(segments()),
        Some("chunk_complete") => object.get("through").and_then(Value::as_f64).map_or(Line::Ignored, Line::ChunkComplete),
        Some("result") => Line::Result { id: text("id"), backend: text("backend"), segments: segments() },
        Some("error") => Line::Error { id: text("id"), message: text("message") },
        Some(_) => Line::Ignored,
        None if object.contains_key("stage") => {
            let stage = object.get("stage").cloned().and_then(|s| serde_json::from_value::<JobStage>(s).ok());
            // The helper's own "complete" is not the job's: cleanup and
            // saving still follow.
            let stage = match stage {
                Some(JobStage::Complete) | None => JobStage::Transcribing,
                Some(stage) => stage,
            };
            Line::Progress(JobProgress::new(stage, text("detail"), object.get("fraction").and_then(Value::as_f64)))
        }
        None => Line::Ignored,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Key {
    launcher: Vec<String>,
    script: PathBuf,
    backend: String,
    model: String,
}

struct Worker {
    key: Key,
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl Worker {
    fn spawn(key: Key) -> Result<Worker, std::io::Error> {
        let mut command = Command::new(&key.launcher[0]);
        command
            .args(&key.launcher[1..])
            .arg("-u")
            .arg(&key.script)
            .arg("--serve")
            // Paths and subtitles are UTF-8 on the wire whatever the code page.
            .env("PYTHONUTF8", "1")
            .env("PYTHONIOENCODING", "utf-8")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let mut child = command.spawn()?;
        let stdin = child.stdin.take().expect("stdin is piped");
        let stderr = child.stderr.take().expect("stderr is piped");
        let (sender, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Ok(Worker { key, child, stdin, lines })
    }

    fn alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    fn kill(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }

    /// Asks the helper to exit, and kills it if it does not in time.
    fn shut_down(mut self) {
        let _ = self.stdin.write_all(b"{\"event\":\"shutdown\"}\n");
        let _ = self.stdin.flush();
        let deadline = Instant::now() + KILL_GRACE;
        while Instant::now() < deadline {
            if !self.alive() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        self.kill();
    }
}

#[derive(Default)]
struct PoolState {
    worker: Option<Worker>,
    /// Bumped by every job, so an idle timer only stops a worker that has
    /// stayed idle since it was set.
    generation: u64,
}

/// Keeps one helper process alive between jobs.
#[derive(Clone)]
pub struct PythonPool {
    state: Arc<Mutex<PoolState>>,
    idle_timeout: Duration,
}

impl Default for PythonPool {
    fn default() -> Self {
        Self::new(IDLE_TIMEOUT)
    }
}

#[derive(Debug)]
pub struct Outcome {
    pub backend: String,
    pub segments: Vec<Segment>,
}

impl PythonPool {
    pub fn new(idle_timeout: Duration) -> Self {
        PythonPool { state: Arc::default(), idle_timeout }
    }

    /// Whether a worker is running now (for tests).
    pub fn has_worker(&self) -> bool {
        crate::locked(&self.state).worker.as_mut().is_some_and(Worker::alive)
    }

    /// Stops the worker, if any. Called on quit.
    pub fn shut_down(&self) {
        if let Some(worker) = crate::locked(&self.state).worker.take() {
            worker.shut_down();
        }
    }

    /// Runs one job, passing each event to `on_line` as it arrives.
    pub fn run(
        &self,
        launchers: &[Vec<String>],
        script: &Path,
        request: &JobRequest,
        cancel: &AtomicBool,
        on_line: &mut dyn FnMut(Line),
    ) -> Result<Outcome, String> {
        let mut state = crate::locked(&self.state);
        state.generation += 1;
        let mut payload = serde_json::to_vec(request).map_err(|e| e.to_string())?;
        payload.push(b'\n');
        let mut worker = Self::checkout(&mut state, launchers, script, request)?;
        if worker.stdin.write_all(&payload).and_then(|_| worker.stdin.flush()).is_err() {
            // It died between jobs: one fresh start.
            worker.kill();
            worker = Self::checkout(&mut state, launchers, script, request)?;
            worker
                .stdin
                .write_all(&payload)
                .and_then(|_| worker.stdin.flush())
                .map_err(|e| format!("Could not reach the Python helper: {e}"))?;
        }
        let mut text: Vec<String> = Vec::new();
        loop {
            match worker.lines.recv_timeout(Duration::from_millis(100)) {
                Ok(line) => match parse_line(&line) {
                    Line::Result { id, backend, segments } if id == request.id => {
                        state.worker = Some(worker);
                        self.arm_idle_timer(state.generation);
                        return Ok(Outcome { backend, segments });
                    }
                    Line::Error { id, message } if id == request.id => {
                        state.worker = Some(worker);
                        self.arm_idle_timer(state.generation);
                        return Err(message);
                    }
                    Line::Text(line) => {
                        text.push(line);
                        if text.len() > MAX_ERROR_LINES {
                            text.remove(0);
                        }
                    }
                    Line::Result { .. } | Line::Error { .. } | Line::Ignored => {}
                    event => on_line(event),
                },
                Err(RecvTimeoutError::Timeout) => {
                    if cancel.load(Ordering::Relaxed) {
                        worker.kill();
                        return Err("Canceled.".into());
                    }
                }
                Err(RecvTimeoutError::Disconnected) => {
                    worker.kill();
                    let detail = text.join("\n");
                    let detail = detail.trim();
                    return Err(if detail.is_empty() {
                        "The Python helper stopped unexpectedly. Check that Python 3 and faster-whisper are installed (Settings → Transcription).".into()
                    } else {
                        format!("The Python helper stopped unexpectedly:\n{detail}")
                    });
                }
            }
        }
    }

    /// The live worker for this key, starting one if needed. A worker for
    /// another backend or model is stopped first: one resident model.
    fn checkout(state: &mut PoolState, launchers: &[Vec<String>], script: &Path, request: &JobRequest) -> Result<Worker, String> {
        if let Some(mut worker) = state.worker.take() {
            let wanted = launchers.contains(&worker.key.launcher)
                && worker.key.script == script
                && worker.key.backend == request.backend
                && worker.key.model == request.model;
            if wanted && worker.alive() {
                // Drop anything a finished job left behind.
                while worker.lines.try_recv().is_ok() {}
                return Ok(worker);
            }
            worker.shut_down();
        }
        let mut last = String::from("no Python command to try");
        for launcher in launchers {
            let key =
                Key { launcher: launcher.clone(), script: script.into(), backend: request.backend.clone(), model: request.model.clone() };
            match Worker::spawn(key) {
                Ok(worker) => return Ok(worker),
                Err(e) => last = format!("{}: {e}", launcher.join(" ")),
            }
        }
        Err(format!("Could not start Python ({last}). Install Python 3, or set its path in Settings → Transcription."))
    }

    fn arm_idle_timer(&self, generation: u64) {
        let state = Arc::downgrade(&self.state);
        let timeout = self.idle_timeout;
        std::thread::spawn(move || {
            std::thread::sleep(timeout);
            let Some(state) = state.upgrade() else { return };
            let mut state = crate::locked(&state);
            if state.generation == generation {
                if let Some(worker) = state.worker.take() {
                    worker.shut_down();
                }
            }
        });
    }
}

/// What `check` found.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Check {
    pub ok: bool,
    pub detail: String,
}

const CHECK_CODE: &str = "import sys\n\
try:\n    import faster_whisper\nexcept ModuleNotFoundError:\n    print('python', sys.version.split()[0], 'missing'); raise SystemExit\n\
import ctranslate2\n\
print('python', sys.version.split()[0], getattr(faster_whisper, '__version__', '?'), ctranslate2.get_cuda_device_count())";

/// Whether Python and faster-whisper are there, and if CUDA is visible.
/// Blocks for the probe.
pub fn check(setting: &str) -> Check {
    let mut last = String::new();
    for launcher in launchers(setting) {
        let mut command = Command::new(&launcher[0]);
        command.args(&launcher[1..]).arg("-c").arg(CHECK_CODE).env("PYTHONUTF8", "1").stdin(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        let output = match command.output() {
            Ok(output) => output,
            Err(e) => {
                last = format!("{}: {e}", launcher.join(" "));
                continue;
            }
        };
        let stdout = String::from_utf8_lossy(&output.stdout);
        let words: Vec<&str> = stdout.split_whitespace().collect();
        let pip = format!("{} -m pip install faster-whisper", launcher.join(" "));
        return match words.as_slice() {
            ["python", version, "missing"] => {
                Check { ok: false, detail: format!("Python {version} works, but faster-whisper is not installed. Run: {pip}") }
            }
            ["python", version, fw, gpus] => {
                let device = match gpus.parse::<u32>() {
                    Ok(0) | Err(_) => "no CUDA GPU found, so it runs on the CPU".to_string(),
                    Ok(n) => format!("{n} CUDA GPU{} found", if n == 1 { "" } else { "s" }),
                };
                Check { ok: true, detail: format!("Python {version}, faster-whisper {fw}: {device}.") }
            }
            _ => {
                let stderr = String::from_utf8_lossy(&output.stderr);
                last = format!("{}: {}", launcher.join(" "), stderr.lines().last().unwrap_or("did not run").trim());
                continue;
            }
        };
    }
    Check { ok: false, detail: format!("Python 3 was not found ({last}). Install it from python.org, or set its path.") }
}

/// The faster-whisper path: Cue extracts and caches the audio, the helper
/// transcribes it, and the shared cleanup runs on the result.
pub struct PythonTranscriber {
    pool: PythonPool,
    script_dir: PathBuf,
    jobs: std::sync::atomic::AtomicU64,
}

impl PythonTranscriber {
    pub fn new(script_dir: PathBuf) -> Self {
        Self::with_pool(script_dir, PythonPool::default())
    }

    pub fn with_pool(script_dir: PathBuf, pool: PythonPool) -> Self {
        PythonTranscriber { pool, script_dir, jobs: Default::default() }
    }

    pub fn pool(&self) -> &PythonPool {
        &self.pool
    }
}

impl Transcriber for PythonTranscriber {
    fn transcribe(&self, request: TranscribeRequest, cancel: Arc<AtomicBool>, report: Report) -> Result<Vec<Segment>, String> {
        if !request.source.is_file() {
            return Err(format!("The video is missing: {}", request.source.display()));
        }
        let say =
            |detail: &str, fraction: Option<f64>| report(Update::Progress(JobProgress::new(JobStage::ExtractingAudio, detail, fraction)));
        say("Extracting audio…", None);
        let (wav, _) =
            audio::extract_cached(&request.source, &paths::audio_cache_dir(), &cancel, &mut |f| say("Extracting audio…", Some(f)))
                .map_err(|e| e.to_string())?;
        let script = ensure_script(&self.script_dir)?;
        let id = format!("job-{}", self.jobs.fetch_add(1, Ordering::Relaxed) + 1);
        let job = JobRequest::faster_whisper(&id, &request.source, &wav, &request.settings);
        let cleanup = CleanupSettings::default();
        let outcome = self.pool.run(&launchers(&request.python), &script, &job, &cancel, &mut |line| match line {
            Line::Progress(progress) => report(Update::Progress(progress)),
            Line::Segments(batch) => report(Update::Segments(postprocess::clean_window(&batch, &cleanup))),
            Line::ChunkComplete(through) => report(Update::ChunkComplete(through)),
            _ => {}
        })?;
        Ok(postprocess::clean_resumed(&[], &outcome.segments, &cleanup))
    }
}

/// Sends each job to the backend its settings name.
pub struct BackendRouter {
    pub built_in: Arc<dyn Transcriber>,
    pub python: Arc<PythonTranscriber>,
}

impl Transcriber for BackendRouter {
    fn transcribe(&self, request: TranscribeRequest, cancel: Arc<AtomicBool>, report: Report) -> Result<Vec<Segment>, String> {
        if request.settings.whisper_backend == FASTER_WHISPER {
            self.python.transcribe(request, cancel, report)
        } else {
            self.built_in.transcribe(request, cancel, report)
        }
    }

    fn shut_down(&self) {
        self.python.pool().shut_down();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_names_map_onto_faster_whisper() {
        assert_eq!(faster_whisper_model("large-v3-turbo-q5_0"), "large-v3-turbo");
        assert_eq!(faster_whisper_model("ggml-medium.bin"), "medium");
        assert_eq!(faster_whisper_model("small"), "small");
        assert_eq!(faster_whisper_model("mlx-community/whisper-large-v3"), "mlx-community/whisper-large-v3");
        assert_eq!(faster_whisper_model(""), "large-v3-turbo");
    }

    #[test]
    fn jobs_record_the_backend_they_run_on() {
        let mut settings = crate::Settings::default();
        assert_eq!(settings.snapshot().whisper_backend, BUILT_IN);
        settings.whisper_backend = FASTER_WHISPER.into();
        assert_eq!(settings.snapshot().whisper_backend, FASTER_WHISPER);
        settings.whisper_backend = "qwen3-asr".into();
        assert_eq!(settings.snapshot().whisper_backend, BUILT_IN, "Apple-only backends fall back to the built-in one");
    }

    #[test]
    fn helper_lines_parse() {
        assert_eq!(
            parse_line(r#"{"stage": "loadingModel", "detail": "Loading.", "fraction": 0.18}"#),
            Line::Progress(JobProgress::new(JobStage::LoadingModel, "Loading.", Some(0.18)))
        );
        assert!(
            matches!(parse_line(r#"{"stage": "complete", "detail": "Done.", "fraction": 1.0}"#), Line::Progress(p) if p.stage == JobStage::Transcribing)
        );
        assert_eq!(parse_line(r#"{"event": "chunk_complete", "through": 30.5}"#), Line::ChunkComplete(30.5));
        assert_eq!(
            parse_line(
                r#"{"event": "result", "id": "j", "backend": "faster-whisper", "segments": [{"id": 1, "start": 0.0, "end": 1.0, "text": "hi"}]}"#
            ),
            Line::Result { id: "j".into(), backend: "faster-whisper".into(), segments: vec![Segment::new(1, 0.0, 1.0, "hi")] }
        );
        assert_eq!(parse_line(r#"{"event": "metrics", "metrics": {}}"#), Line::Ignored);
        assert_eq!(parse_line("Traceback (most recent call last):"), Line::Text("Traceback (most recent call last):".into()));
    }

    #[test]
    fn the_request_matches_the_mac_wire_format() {
        let mut settings = crate::Settings::default().snapshot();
        settings.extra.insert("vadFilter".into(), Value::Bool(false));
        let request = JobRequest::faster_whisper("a", Path::new("/v/m.mkv"), Path::new("/c/m.wav"), &settings);
        let wire: Value = serde_json::to_value(&request).unwrap();
        assert_eq!(wire["event"], "job");
        assert_eq!(wire["backend"], "faster-whisper");
        assert_eq!(wire["model"], "large-v3-turbo");
        assert_eq!(wire["audio_wav"], "/c/m.wav");
        assert_eq!(wire["vad_filter"], false);
        assert_eq!(wire["best_of"], 5);
        let keys: Vec<&String> = wire.as_object().unwrap().keys().collect();
        assert_eq!(keys.len(), 17);
    }

    /// A stand-in helper speaking the serve protocol: "crash" in the path
    /// dies with a traceback, "slow" never answers.
    const FAKE: &str = r#"
import json, sys, time
for line in sys.stdin:
    job = json.loads(line)
    if job.get("event") == "shutdown":
        break
    path = job["input_path"]
    if "crash" in path:
        print("Traceback (most recent call last):", file=sys.stderr, flush=True)
        print("RuntimeError: boom", file=sys.stderr, flush=True)
        sys.exit(3)
    if "slow" in path:
        time.sleep(60)
    print(json.dumps({"stage": "transcribing", "detail": "Working.", "fraction": 0.5}), file=sys.stderr, flush=True)
    print(json.dumps({"event": "segments", "segments": [{"id": 1, "start": 0.0, "end": 1.0, "text": path}]}), file=sys.stderr, flush=True)
    print(json.dumps({"event": "result", "id": job["id"], "backend": job["backend"],
        "segments": [{"id": 1, "start": 0.0, "end": 1.0, "text": "こんにちは " + job["model"]}]}, ensure_ascii=False), file=sys.stderr, flush=True)
"#;

    fn job(id: &str, path: &str) -> JobRequest {
        let settings = crate::Settings::default().snapshot();
        JobRequest::faster_whisper(id, Path::new(path), Path::new("/none.wav"), &settings)
    }

    #[test]
    fn a_resident_worker_runs_jobs_and_survives_between_them() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("fake.py");
        std::fs::write(&script, FAKE).unwrap();
        let pool = PythonPool::new(Duration::from_millis(400));
        let cancel = AtomicBool::new(false);
        let mut seen = Vec::new();
        let outcome = pool.run(&launchers(""), &script, &job("1", "/v/a.mkv"), &cancel, &mut |line| seen.push(line)).unwrap();
        assert_eq!(outcome.backend, "faster-whisper");
        assert_eq!(outcome.segments[0].text, "こんにちは large-v3-turbo");
        assert!(matches!(&seen[0], Line::Progress(p) if p.fraction == Some(0.5)));
        assert!(matches!(&seen[1], Line::Segments(s) if s[0].text == "/v/a.mkv"));
        assert!(pool.has_worker());
        pool.run(&launchers(""), &script, &job("2", "/v/b.mkv"), &cancel, &mut |_| {}).unwrap();

        // A crash fails that job with its own words, and the next one respawns.
        let err = pool.run(&launchers(""), &script, &job("3", "/v/crash.mkv"), &cancel, &mut |_| {}).unwrap_err();
        assert!(err.contains("RuntimeError: boom"), "{err}");
        assert!(pool.run(&launchers(""), &script, &job("4", "/v/c.mkv"), &cancel, &mut |_| {}).is_ok());

        // Idle workers exit on their own.
        std::thread::sleep(Duration::from_millis(1_500));
        assert!(!pool.has_worker());
    }

    #[test]
    fn cancel_kills_the_worker() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("fake.py");
        std::fs::write(&script, FAKE).unwrap();
        let pool = PythonPool::default();
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(500));
            flag.store(true, Ordering::Relaxed);
        });
        let started = Instant::now();
        let err = pool.run(&launchers(""), &script, &job("1", "/v/slow.mkv"), &cancel, &mut |_| {}).unwrap_err();
        assert_eq!(err, "Canceled.");
        assert!(started.elapsed() < Duration::from_secs(10));
        assert!(!pool.has_worker());
    }

    #[test]
    fn the_real_helper_answers_over_the_serve_protocol() {
        let dir = tempfile::tempdir().unwrap();
        let script = ensure_script(dir.path()).unwrap();
        let wav = dir.path().join("a.wav");
        let mut bytes = b"RIFF".to_vec();
        bytes.extend_from_slice(&36u32.to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&[1, 0, 1, 0]);
        bytes.extend_from_slice(&16_000u32.to_le_bytes());
        bytes.extend_from_slice(&32_000u32.to_le_bytes());
        bytes.extend_from_slice(&[2, 0, 16, 0]);
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&0u32.to_le_bytes());
        std::fs::write(&wav, bytes).unwrap();
        let source = dir.path().join("a.mkv");
        std::fs::write(&source, b"x").unwrap();
        let settings = crate::Settings::default().snapshot();
        let mut request = JobRequest::faster_whisper("r", &source, &wav, &settings);
        // MLX is Apple-only, so this backend is never installed here: the
        // helper must still answer with its own error line.
        request.backend = "mlx-whisper".into();
        let pool = PythonPool::default();
        let mut stages = Vec::new();
        let err = pool
            .run(&launchers(""), &script, &request, &AtomicBool::new(false), &mut |line| {
                if let Line::Progress(p) = line {
                    stages.push(p.stage)
                }
            })
            .unwrap_err();
        assert!(err.contains("mlx-whisper is not installed"), "{err}");
        assert_eq!(stages.first(), Some(&JobStage::Preflight));
        assert!(stages.contains(&JobStage::ExtractingAudio));
        assert!(pool.has_worker(), "an error line leaves the worker running");
        pool.shut_down();
        assert!(!pool.has_worker());
    }

    #[test]
    fn the_embedded_helper_is_written_once() {
        let dir = tempfile::tempdir().unwrap();
        let path = ensure_script(dir.path()).unwrap();
        assert!(SCRIPT.contains("def serve(parser"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), SCRIPT);
        std::fs::write(&path, "stale").unwrap();
        ensure_script(dir.path()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), SCRIPT);
    }
}
