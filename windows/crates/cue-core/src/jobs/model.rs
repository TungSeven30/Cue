//! Mirrors `TranscriptionJob`, `JobStatus`, `JobStage`, `JobProgress` and
//! `JobSettingsSnapshot` (Sources/Models/). Field names, enum raw values,
//! date format (ISO-8601 to the second, UTC) and decode defaults match the
//! Mac, so a job file written by either app loads in the other. Fields the
//! Windows app does not use yet (folders, imported subtitle sources, Qwen
//! settings, …) are kept verbatim in `extra` and written back untouched.

use crate::Segment;
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JobStatus {
    Idle,
    Queued,
    Transcribing,
    TranscriptionComplete,
    Translating,
    TranslationComplete,
    BurningIn,
    Canceled,
    Failed,
}

impl JobStatus {
    pub fn label(self) -> &'static str {
        match self {
            JobStatus::Idle => "Idle",
            JobStatus::Queued => "Queued",
            JobStatus::Transcribing => "Transcribing",
            JobStatus::TranscriptionComplete => "Transcript ready",
            JobStatus::Translating => "Translating",
            JobStatus::TranslationComplete => "Translation ready",
            JobStatus::BurningIn => "Burning In",
            JobStatus::Canceled => "Canceled",
            JobStatus::Failed => "Failed",
        }
    }

    pub fn is_running(self) -> bool {
        matches!(self, JobStatus::Transcribing | JobStatus::Translating | JobStatus::BurningIn)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JobStage {
    Idle,
    Queued,
    Preflight,
    ExtractingAudio,
    LoadingModel,
    Transcribing,
    Translating,
    BurningIn,
    Complete,
    Failed,
    Canceled,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobProgress {
    pub stage: JobStage,
    pub detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fraction: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failed_stage: Option<JobStage>,
}

impl JobProgress {
    pub fn new(stage: JobStage, detail: impl Into<String>, fraction: Option<f64>) -> Self {
        Self { stage, detail: detail.into(), fraction, failed_stage: None }
    }

    pub fn idle() -> Self {
        Self::new(JobStage::Idle, "Waiting to start.", None)
    }

    /// Out-of-range or non-finite telemetry shows as indeterminate.
    pub fn display_fraction(&self) -> Option<f64> {
        self.fraction.filter(|f| f.is_finite() && (0.0..=1.0).contains(f))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JobOrigin {
    #[default]
    Manual,
    WatchFolder,
    Url,
}

/// The settings a run used, frozen onto the job. Only the fields the
/// Windows pipeline reads are typed; the rest round-trip through `extra`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobSettings {
    #[serde(default)]
    pub transcription_processing_version: i64,
    pub source_language: String,
    pub whisper_model: String,
    pub whisper_backend: String,
    /// The translation model; the Mac kept the historical key name.
    #[serde(rename = "openAIModel")]
    pub translation_model: String,
    #[serde(default = "auto")]
    pub translation_source_language: String,
    #[serde(default = "english")]
    pub translation_target_language: String,
    #[serde(default = "balanced")]
    pub translation_chunk_mode: String,
    #[serde(default = "two")]
    pub translation_parallelism: i64,
    #[serde(default = "five")]
    pub beam_size: i64,
    #[serde(default = "point_six")]
    pub no_speech_threshold: f64,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

fn auto() -> String {
    "auto".into()
}
fn english() -> String {
    "English".into()
}
fn balanced() -> String {
    "balanced".into()
}
fn two() -> i64 {
    2
}
fn five() -> i64 {
    5
}
fn point_six() -> f64 {
    0.6
}

impl JobSettings {
    /// Matches `JobSettingsSnapshot.currentTranscriptionProcessingVersion`.
    pub const PROCESSING_VERSION: i64 = 4;

    /// Adopts only the translation-facing fields, like the Mac's
    /// `updatingTranslationFields(from:)`, so the record of what produced
    /// the transcript is never overwritten by a translation run.
    pub fn updating_translation_fields(&self, other: &JobSettings) -> JobSettings {
        let mut updated = self.clone();
        updated.translation_model = other.translation_model.clone();
        updated.translation_source_language = other.translation_source_language.clone();
        updated.translation_target_language = other.translation_target_language.clone();
        updated.translation_chunk_mode = other.translation_chunk_mode.clone();
        updated.translation_parallelism = other.translation_parallelism;
        updated
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub source_path: String,
    #[serde(with = "iso")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "iso")]
    pub updated_at: DateTime<Utc>,
    pub status: JobStatus,
    pub progress: JobProgress,
    pub settings: JobSettings,
    pub transcript_segments: Vec<Segment>,
    pub translated_segments: Vec<Segment>,
    #[serde(default)]
    pub partial_translated_segments: Vec<Segment>,
    #[serde(default)]
    pub partial_transcript_segments: Vec<Segment>,
    #[serde(default, deserialize_with = "lenient_f64")]
    pub transcription_resume_through: f64,
    #[serde(default, with = "iso_opt", skip_serializing_if = "Option::is_none")]
    pub transcription_started_at: Option<DateTime<Utc>>,
    #[serde(default, with = "iso_opt", skip_serializing_if = "Option::is_none")]
    pub transcription_finished_at: Option<DateTime<Utc>>,
    #[serde(default, with = "iso_opt", skip_serializing_if = "Option::is_none")]
    pub translation_started_at: Option<DateTime<Utc>>,
    #[serde(default, with = "iso_opt", skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub source_fingerprint: String,
    pub log: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default = "empty_object")]
    pub overrides: Value,
    #[serde(default)]
    pub origin: JobOrigin,
    /// Queue position; lower runs and shows first. Missing in old files,
    /// where it defaults to minus the creation time (see `fill_defaults`).
    #[serde(default = "nan", deserialize_with = "lenient_f64")]
    pub order_index: f64,
    #[serde(default, with = "iso_opt", skip_serializing_if = "Option::is_none")]
    pub archived_at: Option<DateTime<Utc>>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

fn empty_object() -> Value {
    Value::Object(Map::new())
}
fn nan() -> f64 {
    f64::NAN
}

/// The Mac writes non-finite doubles as "nan"/"inf"/"-inf" strings.
fn lenient_f64<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Num {
        F(f64),
        S(String),
    }
    Ok(match Num::deserialize(d)? {
        Num::F(f) => f,
        Num::S(s) => match s.as_str() {
            "inf" => f64::INFINITY,
            "-inf" => f64::NEG_INFINITY,
            _ => f64::NAN,
        },
    })
}

impl Job {
    pub fn new(source: &std::path::Path, settings: JobSettings, now: DateTime<Utc>) -> Self {
        Job {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            source_path: source.to_string_lossy().into_owned(),
            created_at: now,
            updated_at: now,
            status: JobStatus::Idle,
            progress: JobProgress::idle(),
            settings,
            transcript_segments: Vec::new(),
            translated_segments: Vec::new(),
            partial_translated_segments: Vec::new(),
            partial_transcript_segments: Vec::new(),
            transcription_resume_through: 0.0,
            transcription_started_at: None,
            transcription_finished_at: None,
            translation_started_at: None,
            finished_at: None,
            source_fingerprint: fingerprint(source),
            log: "Choose a video to begin.\n".into(),
            summary: None,
            overrides: empty_object(),
            origin: JobOrigin::Manual,
            order_index: -(now.timestamp_millis() as f64 / 1000.0),
            archived_at: None,
            extra: Map::new(),
        }
    }

    /// The file name without its extension, as the job list shows it.
    pub fn title(&self) -> String {
        std::path::Path::new(&self.source_path)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| self.source_path.clone())
    }

    /// A partial transcript never counts: only a finished one may gate the
    /// queue and translation, exactly as on the Mac.
    pub fn has_transcript(&self) -> bool {
        !self.transcript_segments.is_empty()
    }

    pub(crate) fn fill_defaults(&mut self) {
        if !self.order_index.is_finite() {
            self.order_index = -(self.created_at.timestamp() as f64);
        }
        if !self.transcription_resume_through.is_finite() || self.transcription_resume_through < 0.0 {
            self.transcription_resume_through = 0.0;
        }
        self.progress.fraction = self.progress.display_fraction();
        if self.source_fingerprint.is_empty() {
            self.source_fingerprint = fingerprint(std::path::Path::new(&self.source_path));
        }
    }
}

/// `path|size|mtime`, the Mac's format, used to notice a replaced source.
pub fn fingerprint(path: &std::path::Path) -> String {
    let meta = std::fs::metadata(path).ok();
    let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
    let modified = meta
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    format!("{}|{size}|{modified}", path.to_string_lossy())
}

/// Swift's `.iso8601` strategy: whole seconds with a `Z`. It rejects
/// fractional seconds, so they are never written.
pub(crate) fn format_date(date: &DateTime<Utc>) -> String {
    date.to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub(crate) fn parse_date(text: &str) -> Result<DateTime<Utc>, String> {
    DateTime::parse_from_rfc3339(text).map(|d| d.with_timezone(&Utc)).map_err(|e| format!("bad date {text:?}: {e}"))
}

mod iso {
    use super::*;
    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&format_date(date))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(d)?;
        parse_date(&text).map_err(serde::de::Error::custom)
    }
}

mod iso_opt {
    use super::*;
    pub fn serialize<S: Serializer>(date: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match date {
            Some(d) => s.serialize_str(&format_date(d)),
            None => s.serialize_none(),
        }
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        match Option::<String>::deserialize(d)? {
            Some(text) => parse_date(&text).map(Some).map_err(serde::de::Error::custom),
            None => Ok(None),
        }
    }
}
