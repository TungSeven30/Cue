//! The intro summary, the `AppModel` summary section on the Mac: written
//! at the end of a run when it is switched on (best effort, never failing
//! the job), or on demand for any finished job.

use super::*;
use cue_core::translation::{summarize, summary_language, SummaryDetail, SummaryModel, SummaryResult};
use serde_json::Value;

impl Runtime {
    fn summary_model(&self, model: &str) -> Result<SummaryModel, String> {
        let provider = Provider::infer(model);
        let api_key = match (self.inner.keys)(provider) {
            Some(key) => key,
            None if !provider.needs_api_key() => String::new(),
            None => return Err(format!("there is no {} API key for {model}", provider.label())),
        };
        Ok(SummaryModel { model: model.into(), provider, api_key, local_endpoint: self.settings().local_endpoint })
    }

    fn summary_detail(&self, job: &Job) -> SummaryDetail {
        job.overrides
            .get("summaryDetail")
            .and_then(Value::as_str)
            .and_then(SummaryDetail::parse)
            .unwrap_or_else(|| self.settings().summary_detail)
    }

    /// `Err` says why the primary model can't run.
    fn summary_models(&self) -> Result<(SummaryModel, Option<SummaryModel>), String> {
        let settings = self.settings();
        let primary = self.summary_model(&settings.resolved_summary_model())?;
        let fallback = settings.resolved_summary_fallback_model().and_then(|m| self.summary_model(&m).ok());
        Ok((primary, fallback))
    }

    fn write_summary(
        &self,
        job: &Job,
        segments: &[Segment],
        from_translation: bool,
        models: &(SummaryModel, Option<SummaryModel>),
    ) -> Result<SummaryResult, String> {
        let language = summary_language(from_translation, &job.settings.translation_target_language);
        summarize(&*self.inner.transport, segments, &language, &models.0, models.1.as_ref(), self.summary_detail(job))
            .map_err(|e| e.to_string())
    }

    fn log_summary(&self, id: &str, primary: &str, result: &SummaryResult) {
        self.update(id, false, false, |job| {
            if result.used_fallback {
                job.log.push_str(&format!("The summary model {primary} declined the content; the fallback {} wrote it.\n", result.model));
            }
            job.log.push_str(&format!("Wrote the intro summary with {}: {}\n", result.model, result.summary));
        });
    }

    /// The end-of-run summary, if this job wants one. Never fails the job.
    pub(crate) fn auto_summary(&self, id: &str, segments: &[Segment], from_translation: bool) -> Option<String> {
        let job = self.job(id)?;
        let wanted = job.overrides.get("generateSummary").and_then(Value::as_bool).unwrap_or_else(|| self.settings().generate_summary);
        if !wanted || segments.is_empty() {
            return None;
        }
        let models = match self.summary_models() {
            Ok(models) => models,
            Err(reason) => {
                self.update(id, false, false, |job| job.log.push_str(&format!("Skipped the intro summary because {reason}.\n")));
                return None;
            }
        };
        self.update(id, false, false, |job| {
            job.progress = JobProgress::new(job.progress.stage, "Writing intro summary.", job.progress.fraction);
        });
        match self.write_summary(&job, segments, from_translation, &models) {
            Ok(result) => {
                self.log_summary(id, &models.0.model, &result);
                Some(result.summary)
            }
            Err(e) => {
                self.update(id, false, false, |job| job.log.push_str(&format!("Intro summary failed (the job still finished): {e}\n")));
                None
            }
        }
    }

    /// Writes (or rewrites) a job's summary now, from its translation if it
    /// has one. Blocks for the request; call it off the UI thread.
    pub fn generate_summary(&self, id: &str) -> Result<String, String> {
        let job = self.job(id).ok_or("No such job.")?;
        let from_translation = !job.translated_segments.is_empty();
        let segments = if from_translation { &job.translated_segments } else { &job.transcript_segments };
        if segments.is_empty() {
            return Err("There are no subtitles to summarize yet.".into());
        }
        let models = self.summary_models().map_err(|reason| format!("The intro summary can't be written: {reason}."))?;
        match self.write_summary(&job, segments, from_translation, &models) {
            Ok(result) => {
                self.log_summary(id, &models.0.model, &result);
                let summary = result.summary.clone();
                self.update(id, true, true, |job| job.summary = Some(result.summary));
                Ok(summary)
            }
            Err(e) => {
                self.update(id, false, true, |job| job.log.push_str(&format!("Intro summary failed: {e}\n")));
                Err(e)
            }
        }
    }

    /// Replaces the summary with edited text, or removes it.
    pub fn set_summary(&self, id: &str, text: Option<&str>) -> Result<(), String> {
        let text = text.map(str::trim).filter(|t| !t.is_empty()).map(str::to_string);
        self.change(id, |job| {
            job.summary = text;
            Ok(())
        })
    }
}
