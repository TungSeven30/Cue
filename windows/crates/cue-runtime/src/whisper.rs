//! The built-in engine path, as `transcribe` runs it in the CLI: cached
//! ffmpeg extraction, model download on first use, whisper.cpp with the
//! model kept resident between jobs, and the shared cleanup. Resumes from
//! the job's last finished chunk instead of starting over.

use crate::{Report, TranscribeRequest, Transcriber, Update};
use cue_core::jobs::{JobProgress, JobStage};
use cue_core::models::{ModelProgress, ModelStore};
use cue_core::postprocess::{self, CleanupSettings};
use cue_core::{audio, paths, Segment};
use cue_engine::{Callbacks, Engine, TranscribeOptions};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

pub struct WhisperTranscriber {
    engine: Engine,
}

impl Default for WhisperTranscriber {
    fn default() -> Self {
        Self::new()
    }
}

impl WhisperTranscriber {
    pub fn new() -> Self {
        Self { engine: Engine::new() }
    }
}

impl Transcriber for WhisperTranscriber {
    fn transcribe(&self, request: TranscribeRequest, cancel: Arc<AtomicBool>, report: Report) -> Result<Vec<Segment>, String> {
        if !request.source.is_file() {
            return Err(format!("The video is missing: {}", request.source.display()));
        }
        let say =
            |stage: JobStage, detail: &str, fraction: Option<f64>| report(Update::Progress(JobProgress::new(stage, detail, fraction)));

        say(JobStage::LoadingModel, "Checking the model…", None);
        let model = ModelStore::default_location()
            .ensure_installed(&request.settings.whisper_model, &cancel, &mut |p| match p {
                ModelProgress::Downloading(f) => say(JobStage::LoadingModel, "Downloading the model (first run only)…", Some(f)),
                ModelProgress::Verifying => say(JobStage::LoadingModel, "Verifying the model…", None),
            })
            .map_err(|e| e.to_string())?;

        say(JobStage::ExtractingAudio, "Extracting audio…", None);
        let (wav, _) = audio::extract_cached(&request.source, &paths::audio_cache_dir(), &cancel, &mut |f| {
            say(JobStage::ExtractingAudio, "Extracting audio…", Some(f))
        })
        .map_err(|e| e.to_string())?;
        let samples = audio::load_pcm16_mono(&wav).map_err(|e| e.to_string())?;

        let next_id = request.partial.iter().map(|s| s.id).max().unwrap_or(0) + 1;
        let options = TranscribeOptions {
            language: request.settings.source_language.clone(),
            beam_size: request.settings.beam_size.clamp(1, 16) as i32,
            no_speech_threshold: request.settings.no_speech_threshold as f32,
            resume_through: request.resume_through,
            starting_segment_id: next_id,
            use_gpu: request.use_gpu,
            ..TranscribeOptions::default()
        };
        let cleanup = CleanupSettings::default();
        let window = cleanup.clone();
        let (progress, segments, chunks) = (report.clone(), report.clone(), report.clone());
        let callbacks = Callbacks {
            on_progress: Box::new(move |f| progress(Update::Progress(JobProgress::new(JobStage::Transcribing, "Transcribing…", Some(f))))),
            on_segments: Box::new(move |batch| segments(Update::Segments(postprocess::clean_window(&batch, &window)))),
            on_chunk_complete: Box::new(move |through| chunks(Update::ChunkComplete(through))),
        };
        say(JobStage::Transcribing, "Transcribing…", Some(0.0));
        let raw = self.engine.transcribe(&samples, &model, &options, callbacks, cancel).map_err(|e| e.to_string())?;
        Ok(postprocess::clean_resumed(&request.partial, &raw, &cleanup))
    }
}
pub use cue_engine::compiled_backend;
