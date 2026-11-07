//! Global defaults, the Windows counterpart of `AppSettingsStore`. Saved as
//! `settings.json` in the data folder. A job freezes them into its own
//! `JobSettings` when it runs, so editing settings never changes a job that
//! is already running.

use cue_core::jobs::JobSettings;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub whisper_model: String,
    /// ISO code or "auto".
    pub source_language: String,
    pub use_gpu: bool,
    pub beam_size: i64,
    pub translation_model: String,
    pub translation_source_language: String,
    pub translation_target_language: String,
    pub translation_chunk_mode: String,
    pub translation_parallelism: i64,
    pub local_endpoint: String,
    /// Queue a translation as soon as a transcript is ready.
    pub auto_translate: bool,
    /// New files start right away (interactive adds only).
    pub auto_start_added_jobs: bool,
    /// Write SRT sidecars next to the video when a stage finishes.
    pub auto_export_sidecars: bool,
    pub sidecar_bilingual: bool,
    /// Folders whose new media is queued automatically.
    pub watch_folders: Vec<WatchFolder>,
    /// Where "Add from URL" saves; empty means `Videos\Cue Downloads`.
    pub download_folder: String,
    /// Closing the window keeps Cue running in the notification area.
    pub keep_in_tray: bool,
    /// A toast when a job finishes while the window is in the background.
    pub notifications: bool,
    /// Keep the PC from sleeping while jobs, downloads or burn-ins run.
    pub keep_awake: bool,
}

/// One watched folder. `profile` holds per-job overrides (the same keys as
/// a job's own overrides) stamped onto every job it queues.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchFolder {
    pub id: String,
    pub path: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default = "empty_object")]
    pub profile: Value,
}

fn yes() -> bool {
    true
}

fn empty_object() -> Value {
    Value::Object(Default::default())
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            whisper_model: cue_core::models::DEFAULT_MODEL.into(),
            source_language: "auto".into(),
            use_gpu: true,
            beam_size: 5,
            translation_model: cue_core::translation::DEFAULT_MODEL.into(),
            translation_source_language: "auto".into(),
            translation_target_language: "English".into(),
            translation_chunk_mode: "balanced".into(),
            translation_parallelism: 2,
            local_endpoint: cue_core::translation::DEFAULT_LOCAL_ENDPOINT.into(),
            auto_translate: false,
            auto_start_added_jobs: true,
            auto_export_sidecars: true,
            sidecar_bilingual: false,
            watch_folders: Vec::new(),
            download_folder: String::new(),
            keep_in_tray: true,
            notifications: true,
            keep_awake: true,
        }
    }
}

impl Settings {
    pub fn load(path: &Path) -> Settings {
        std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    /// The folder downloads land in.
    pub fn downloads_dir(&self) -> PathBuf {
        if !self.download_folder.trim().is_empty() {
            return PathBuf::from(self.download_folder.trim());
        }
        dirs::video_dir().or_else(dirs::home_dir).unwrap_or_else(std::env::temp_dir).join("Cue Downloads")
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let tmp = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, path)).map_err(|e| e.to_string())
    }

    /// The snapshot a job records. Only the keys the Mac requires are
    /// written beyond what Windows uses, so the file stays readable there.
    pub fn snapshot(&self) -> JobSettings {
        let value = json!({
            "transcriptionProcessingVersion": JobSettings::PROCESSING_VERSION,
            "sourceLanguage": self.source_language,
            "whisperModel": self.whisper_model,
            "whisperBackend": "whisper-cpp",
            "openAIModel": self.translation_model,
            "translationSourceLanguage": self.translation_source_language,
            "translationTargetLanguage": self.translation_target_language,
            "translationChunkMode": self.translation_chunk_mode,
            "translationParallelism": self.translation_parallelism.clamp(1, 4),
            "beamSize": self.beam_size,
            "noSpeechThreshold": 0.6,
        });
        serde_json::from_value(value).expect("snapshot fields are complete")
    }
}

/// Layers a job's overrides (nil = inherit) over a snapshot, for the keys
/// the Windows pipeline understands. Mirrors `JobSettingsSnapshot.applying`.
pub fn apply_overrides(mut settings: JobSettings, overrides: &Value) -> JobSettings {
    let get = |key: &str| overrides.get(key).and_then(Value::as_str).map(str::to_string);
    if let Some(v) = get("sourceLanguage") {
        settings.source_language = v;
    }
    if let Some(v) = get("whisperModel") {
        settings.whisper_model = v;
    }
    if let Some(v) = get("translationSourceLanguage") {
        settings.translation_source_language = v;
    }
    if let Some(v) = get("translationTargetLanguage") {
        settings.translation_target_language = v;
    }
    if let Some(v) = get("openAIModel") {
        settings.translation_model = v;
    }
    settings
}
