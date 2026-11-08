//! Existing subtitles: adopted from files beside a new video, or loaded
//! by hand into a job's transcript or translation (the Mac's subtitle
//! import section of `AppModel`). Edits are not written back to the file;
//! the file only seeds the job.

use super::*;
use cue_core::subtitle::{folder_contents, import_file, import_sidecars, Adopted};
use cue_core::translation::aligned_translations;

impl Runtime {
    /// A translation can run without asking anyone: a key, or a provider
    /// that needs none.
    pub(crate) fn translation_ready(&self, model: &str) -> bool {
        let provider = Provider::infer(model);
        !provider.needs_api_key() || (self.inner.keys)(provider).is_some()
    }

    /// Reads the sidecars of each video, listing each folder once. Runs
    /// before the jobs exist, so no lock is held while files are read.
    pub(crate) fn scan_sidecars(&self, paths: &[PathBuf], languages: impl Fn(&Path) -> (String, String)) -> Vec<Adopted> {
        let mut listings: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        paths
            .iter()
            .map(|path| {
                let folder = path.parent().map(Path::to_path_buf).unwrap_or_default();
                let candidates = listings.entry(folder.clone()).or_insert_with(|| folder_contents(&folder));
                let (source, target) = languages(path);
                import_sidecars(path, candidates, &source, &target)
            })
            .collect()
    }

    /// Loads a subtitle file into one slot of a job that isn't running.
    /// The UI confirms replacing what is there first.
    pub fn load_subtitles(&self, id: &str, path: &Path, slot: Slot) -> Result<(), String> {
        let segments = import_file(path)?;
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let ready = self.settings().auto_translate && self.job(id).is_some_and(|j| self.translation_ready(&j.settings.translation_model));
        self.change(id, |job| {
            if job.status.is_running() {
                return Err("Stop this video before loading subtitles into it.".into());
            }
            match slot {
                Slot::Transcript => {
                    let queued = job.status == JobStatus::Queued;
                    job.transcript_segments = segments.clone();
                    job.translated_segments.clear();
                    job.partial_transcript_segments.clear();
                    job.partial_translated_segments.clear();
                    job.transcription_resume_through = 0.0;
                    job.summary = None;
                    job.status = if queued && ready { JobStatus::Queued } else { JobStatus::TranscriptionComplete };
                    job.progress = JobProgress::new(JobStage::Complete, "Loaded existing subtitles.", Some(1.0));
                }
                Slot::Translation => {
                    if job.transcript_segments.is_empty() {
                        return Err("Load or make a transcript before adding its translation.".into());
                    }
                    let aligned = aligned_translations(&segments, &job.transcript_segments);
                    if aligned.len() != segments.len() {
                        return Err("The translation's cue timings don't match this transcript. Nothing was changed.".into());
                    }
                    job.translated_segments = aligned;
                    job.partial_translated_segments.clear();
                    job.status = JobStatus::TranslationComplete;
                    job.progress = JobProgress::new(JobStage::Complete, "Loaded existing subtitles.", Some(1.0));
                }
            }
            job.log.push_str(&format!("Loaded subtitles from {name} ({} cues).\n", segments.len()));
            Ok(())
        })?;
        self.emit(Event::SegmentsChanged { id: id.into() });
        Ok(())
    }
}

/// Fills a brand-new job from its sidecars. A queued job stays queued
/// (for translation) only when that will happen without asking.
pub(crate) fn adopt(job: &mut Job, adopted: Adopted, translate_next: bool) {
    for line in &adopted.log {
        job.log.push_str(line);
        job.log.push('\n');
    }
    let Some((_, transcript)) = adopted.transcript else { return };
    let queued = job.status == JobStatus::Queued;
    job.transcript_segments = transcript;
    job.status = if queued && translate_next { JobStatus::Queued } else { JobStatus::TranscriptionComplete };
    job.progress = JobProgress::new(JobStage::Complete, "Loaded existing subtitles.", Some(1.0));
    if let Some((path, translation)) = adopted.translation {
        let aligned = aligned_translations(&translation, &job.transcript_segments);
        if aligned.len() != translation.len() {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            job.log.push_str(&format!(
                "Could not pair {name} with the transcript: the cue timings differ or are ambiguous. The file was left as it is.\n"
            ));
            return;
        }
        job.translated_segments = aligned;
        // Nothing is left to do, so it leaves the queue.
        job.status = JobStatus::TranslationComplete;
    }
}
