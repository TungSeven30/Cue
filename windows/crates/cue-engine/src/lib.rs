//! Built-in whisper.cpp engine. Port of `WhisperCppEngine` + `WhisperModelCache`.
//!
//! Same contract as macOS:
//! - audio is planned into silence-aligned chunks; each finished chunk is a
//!   resume point (`resume_through`);
//! - every chunk gets a **fresh whisper state** from a shared, already-loaded
//!   model. A reused state drifts timestamps run to run; a fresh one
//!   reproduces a cold load exactly;
//! - `no_context` is on (Whisper's condition_on_previous_text=False);
//! - segments stream out as whisper emits them, offset to file time.
//!
//! GPU: built with the `vulkan` feature, whisper.cpp offloads to any Vulkan
//! GPU (NVIDIA, AMD, Intel) and falls back to CPU when none is present.

use cue_core::chunk_planner::{self, ChunkPlanning, SpeechChunk};
use cue_core::Segment;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub const SAMPLE_RATE: usize = cue_core::audio::SAMPLE_RATE;

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("Could not load the model {0}. Try re-downloading it with `cue models download`.")]
    ModelLoad(String),
    #[error("Could not allocate memory for transcription. Close other apps and try again.")]
    StateAllocation,
    #[error("Transcription failed unexpectedly: {0}")]
    Inference(String),
    #[error("Canceled.")]
    Canceled,
}

/// Which compute backend this build was compiled with.
pub fn compiled_backend() -> &'static str {
    if cfg!(feature = "cuda") {
        "CUDA"
    } else if cfg!(feature = "vulkan") {
        "Vulkan"
    } else {
        "CPU"
    }
}

#[derive(Debug, Clone)]
pub struct TranscribeOptions {
    /// ISO code, or "auto"/empty for detection.
    pub language: String,
    pub beam_size: i32,
    pub no_speech_threshold: f32,
    /// Seconds already transcribed by an earlier, interrupted run.
    pub resume_through: f64,
    /// First id for new segments (continues after saved partials).
    pub starting_segment_id: i64,
    pub planning: ChunkPlanning,
    pub threads: Option<i32>,
    pub use_gpu: bool,
}

impl Default for TranscribeOptions {
    fn default() -> Self {
        Self {
            language: "auto".into(),
            beam_size: 5,
            no_speech_threshold: 0.6,
            resume_through: 0.0,
            starting_segment_id: 1,
            planning: ChunkPlanning::default(),
            threads: None,
            use_gpu: true,
        }
    }
}

/// Callbacks run on whisper's worker thread; keep them cheap.
pub struct Callbacks {
    /// 0–1 across the whole file.
    pub on_progress: Box<dyn FnMut(f64) + Send>,
    /// Raw segments in file time, as whisper finalizes them.
    pub on_segments: Box<dyn FnMut(Vec<Segment>) + Send>,
    /// Called with the end time of each finished chunk (a resume point).
    pub on_chunk_complete: Box<dyn FnMut(f64) + Send>,
}

impl Default for Callbacks {
    fn default() -> Self {
        Self { on_progress: Box::new(|_| {}), on_segments: Box::new(|_| {}), on_chunk_complete: Box::new(|_| {}) }
    }
}

/// Keeps the most recently used model resident between jobs (capacity one,
/// like macOS), keyed by path, size and mtime so a replaced file reloads.
pub struct Engine {
    loaded: Mutex<Option<(ModelKey, Arc<WhisperContext>)>>,
}

#[derive(Debug, Clone, PartialEq)]
struct ModelKey {
    path: PathBuf,
    len: u64,
    modified: Option<std::time::SystemTime>,
    use_gpu: bool,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    pub fn new() -> Self {
        // Route whisper.cpp/ggml logging away from the console; without a
        // `log` backend the hooks drop it.
        static HOOKS: std::sync::Once = std::sync::Once::new();
        HOOKS.call_once(whisper_rs::install_logging_hooks);
        Self { loaded: Mutex::new(None) }
    }

    fn context(&self, model: &Path, use_gpu: bool) -> Result<Arc<WhisperContext>, EngineError> {
        let meta = std::fs::metadata(model).map_err(|_| EngineError::ModelLoad(model.display().to_string()))?;
        let key = ModelKey { path: model.to_path_buf(), len: meta.len(), modified: meta.modified().ok(), use_gpu };
        let mut slot = self.loaded.lock().unwrap();
        if let Some((k, ctx)) = slot.as_ref() {
            if *k == key {
                return Ok(ctx.clone());
            }
        }
        *slot = None; // free the old model before loading the new one
        let params = WhisperContextParameters { use_gpu, ..WhisperContextParameters::default() };
        let path = model.to_str().ok_or_else(|| EngineError::ModelLoad(model.display().to_string()))?;
        let ctx = Arc::new(WhisperContext::new_with_params(path, params).map_err(|_| EngineError::ModelLoad(model.display().to_string()))?);
        *slot = Some((key, ctx.clone()));
        Ok(ctx)
    }

    /// Drop the resident model (memory pressure, settings change).
    pub fn unload(&self) {
        *self.loaded.lock().unwrap() = None;
    }

    /// Transcribe 16 kHz mono samples. Returns raw (uncleaned) segments for
    /// the pending part of the file; run them through
    /// `cue_core::postprocess::clean_resumed` with any saved partials.
    pub fn transcribe(
        &self,
        samples: &[f32],
        model: &Path,
        options: &TranscribeOptions,
        callbacks: Callbacks,
        cancel: Arc<AtomicBool>,
    ) -> Result<Vec<Segment>, EngineError> {
        let total = samples.len() as f64 / SAMPLE_RATE as f64;
        let planned = chunk_planner::plan_speech_chunks(samples, SAMPLE_RATE, options.planning);
        let pending = chunk_planner::pending_chunks(&planned, options.resume_through);
        if pending.is_empty() {
            return Ok(Vec::new());
        }
        let ctx = self.context(model, options.use_gpu)?;
        let callbacks = Arc::new(Mutex::new(callbacks));
        let completed_before = planned.iter().filter(|c| c.end <= options.resume_through + 0.01).count();
        let planned_count = planned.len().max(1);

        let mut collected = Vec::new();
        let mut next_id = options.starting_segment_id;
        for (index, chunk) in pending.iter().enumerate() {
            if cancel.load(Ordering::Relaxed) {
                return Err(EngineError::Canceled);
            }
            let first = ((chunk.start * SAMPLE_RATE as f64) as usize).min(samples.len());
            let last = ((chunk.end * SAMPLE_RATE as f64) as usize).min(samples.len());
            if last <= first {
                continue;
            }
            let done_chunks = (completed_before + index) as f64;
            let batch = run_chunk(&ctx, &samples[first..last], *chunk, next_id, options, &callbacks, &cancel, move |f| {
                ((done_chunks + f) / planned_count as f64).min(1.0)
            })?;
            next_id += batch.len() as i64;
            collected.extend(batch);
            (callbacks.lock().unwrap().on_chunk_complete)(if pending.len() == 1 && chunk.end >= total - 0.01 { total } else { chunk.end });
        }
        Ok(collected)
    }
}

#[allow(clippy::too_many_arguments)]
fn run_chunk(
    ctx: &WhisperContext,
    samples: &[f32],
    chunk: SpeechChunk,
    starting_id: i64,
    options: &TranscribeOptions,
    callbacks: &Arc<Mutex<Callbacks>>,
    cancel: &Arc<AtomicBool>,
    overall: impl Fn(f64) -> f64 + Send + 'static,
) -> Result<Vec<Segment>, EngineError> {
    // Fresh state per chunk: see the module docs.
    let mut state = ctx.create_state().map_err(|_| EngineError::StateAllocation)?;
    let mut params = FullParams::new(SamplingStrategy::BeamSearch { beam_size: options.beam_size, patience: -1.0 });
    let threads = options.threads.unwrap_or_else(|| {
        let cores = std::thread::available_parallelism().map(|n| n.get() as i32).unwrap_or(4);
        (cores - 2).max(4)
    });
    params.set_n_threads(threads);
    params.set_no_context(true);
    params.set_no_speech_thold(options.no_speech_threshold);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_special(false);
    params.set_print_timestamps(false);
    let language = options.language.trim();
    params.set_language(if language.is_empty() || language == "auto" { Some("auto") } else { Some(language) });

    let progress_cb = callbacks.clone();
    params.set_progress_callback_safe(move |percent: i32| {
        (progress_cb.lock().unwrap().on_progress)(overall(percent as f64 / 100.0));
    });
    let segment_cb = callbacks.clone();
    let offset = chunk.start;
    params.set_segment_callback_safe_lossy(move |data: whisper_rs::SegmentCallbackData| {
        let segment = map_segment(starting_id + data.segment as i64, data.start_timestamp, data.end_timestamp, &data.text, offset);
        (segment_cb.lock().unwrap().on_segments)(vec![segment]);
    });
    let abort = cancel.clone();
    params.set_abort_callback_safe(move || abort.load(Ordering::Relaxed));

    if let Err(e) = state.full(params, samples) {
        if cancel.load(Ordering::Relaxed) {
            return Err(EngineError::Canceled);
        }
        return Err(EngineError::Inference(e.to_string()));
    }
    if cancel.load(Ordering::Relaxed) {
        return Err(EngineError::Canceled);
    }
    let mut out = Vec::new();
    for (i, segment) in state.as_iter().enumerate() {
        let text = segment.to_str_lossy().map(|t| t.into_owned()).unwrap_or_default();
        out.push(map_segment(starting_id + i as i64, segment.start_timestamp(), segment.end_timestamp(), &text, offset));
    }
    Ok(out)
}

/// whisper timestamps are centiseconds relative to the chunk.
pub fn map_segment(id: i64, t0: i64, t1: i64, text: &str, offset: f64) -> Segment {
    Segment::new(id, t0 as f64 / 100.0 + offset, t1 as f64 / 100.0 + offset, text.trim())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_centiseconds_into_file_time() {
        let s = map_segment(3, 150, 300, "  hi ", 90.0);
        assert_eq!((s.id, s.start, s.end, s.text.as_str()), (3, 91.5, 93.0, "hi"));
    }

    /// End-to-end against a real model when CUE_TEST_MODEL points at one
    /// (CI downloads ggml-tiny.bin). Skipped otherwise.
    #[test]
    fn transcribes_speech_with_a_real_model() {
        let (Some(model), Some(wav)) = (std::env::var_os("CUE_TEST_MODEL"), std::env::var_os("CUE_TEST_WAV")) else { return };
        let samples = cue_core::audio::load_pcm16_mono(Path::new(&wav)).unwrap();
        let engine = Engine::new();
        let streamed = Arc::new(Mutex::new(0usize));
        let s2 = streamed.clone();
        let callbacks = Callbacks { on_segments: Box::new(move |b| *s2.lock().unwrap() += b.len()), ..Callbacks::default() };
        let opts = TranscribeOptions { language: "en".into(), ..TranscribeOptions::default() };
        let segments = engine.transcribe(&samples, Path::new(&model), &opts, callbacks, Arc::new(AtomicBool::new(false))).unwrap();
        assert!(!segments.is_empty());
        assert_eq!(*streamed.lock().unwrap(), segments.len());
        let text = segments.iter().map(|s| s.text.to_lowercase()).collect::<Vec<_>>().join(" ");
        assert!(text.contains("country"), "unexpected transcript: {text}");
        // Determinism: a second run on the resident model reproduces the first exactly.
        let again = engine.transcribe(&samples, Path::new(&model), &opts, Callbacks::default(), Arc::new(AtomicBool::new(false))).unwrap();
        assert_eq!(segments, again);
    }
}
