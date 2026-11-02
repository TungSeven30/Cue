//! Where Cue keeps its data. On Windows that is `%LOCALAPPDATA%\Cue`
//! (models and the audio cache are large and machine-specific, so they do not
//! belong in the roaming profile). `CUE_HOME` overrides it for tests and
//! portable installs.

use std::path::PathBuf;

pub fn app_data_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("CUE_HOME").filter(|v| !v.is_empty()) {
        return PathBuf::from(home);
    }
    dirs::data_local_dir().unwrap_or_else(std::env::temp_dir).join("Cue")
}

pub fn models_dir() -> PathBuf {
    app_data_dir().join("models")
}

pub fn audio_cache_dir() -> PathBuf {
    app_data_dir().join("audio-cache")
}

pub fn jobs_dir() -> PathBuf {
    app_data_dir().join("jobs")
}
