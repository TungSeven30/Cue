//! Cue for Windows. A thin Tauri shell: every command forwards to
//! `cue_runtime::Runtime`, and every runtime event is re-emitted to the
//! web UI as a `cue` event. The UI lives in `ui/` as plain HTML, CSS and
//! JavaScript with no build step.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use cue_core::credentials::{self, KeySource};
use cue_core::models::{ModelStore, CATALOG};
use cue_core::subtitle::Format;
use cue_core::translation::Provider;
use cue_runtime::{Config, Document, Event, JobSummary, Runtime, Settings, Slot};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use tauri::{DragDropEvent, Emitter, Manager, RunEvent, State, WindowEvent};
use tauri_plugin_dialog::DialogExt;

struct App {
    runtime: Runtime,
    startup_failures: Vec<String>,
}

type Result<T> = std::result::Result<T, String>;

const MEDIA_EXTENSIONS: [&str; 16] =
    ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "ts", "mts", "m2ts", "mpg", "mpeg", "mp3", "m4a", "wav"];

fn is_media(path: &std::path::Path) -> bool {
    path.extension().map(|e| e.to_string_lossy().to_lowercase()).is_some_and(|e| MEDIA_EXTENSIONS.contains(&e.as_str()))
}

// MARK: Jobs

#[tauri::command]
fn list_jobs(app: State<App>) -> Vec<JobSummary> {
    app.runtime.jobs()
}

#[tauri::command]
fn get_job(app: State<App>, id: String) -> Result<cue_core::jobs::Job> {
    app.runtime.job(&id).ok_or_else(|| "No such job.".into())
}

#[tauri::command]
fn startup_failures(app: State<App>) -> Vec<String> {
    app.startup_failures.clone()
}

#[tauri::command]
fn add_files(app: State<App>, paths: Vec<PathBuf>) -> Vec<String> {
    let media: Vec<PathBuf> = paths.into_iter().filter(|p| is_media(p)).collect();
    app.runtime.add_files(&media)
}

/// Opens the native picker off the main thread (async command) and adds
/// whatever was chosen.
#[tauri::command]
async fn pick_files(handle: tauri::AppHandle, app: State<'_, App>) -> Result<Vec<String>> {
    let picked = handle
        .dialog()
        .file()
        .set_title("Add videos")
        .add_filter("Video and audio", &MEDIA_EXTENSIONS)
        .blocking_pick_files()
        .unwrap_or_default();
    let paths: Vec<PathBuf> = picked.into_iter().filter_map(|p| p.into_path().ok()).collect();
    Ok(app.runtime.add_files(&paths))
}

#[tauri::command]
async fn pick_folder(handle: tauri::AppHandle) -> Option<String> {
    handle
        .dialog()
        .file()
        .set_title("Choose a folder")
        .blocking_pick_folder()
        .and_then(|p| p.into_path().ok())
        .map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
fn start_job(app: State<App>, id: String) -> Result<()> {
    app.runtime.start(&id)
}

#[tauri::command]
fn retranscribe_job(app: State<App>, id: String) -> Result<()> {
    app.runtime.retranscribe(&id)
}

#[tauri::command]
fn translate_job(app: State<App>, id: String) -> Result<()> {
    app.runtime.translate(&id)
}

#[tauri::command]
fn cancel_job(app: State<App>, id: String) -> Result<()> {
    app.runtime.cancel(&id)
}

#[tauri::command]
fn remove_job(app: State<App>, id: String) -> Result<()> {
    app.runtime.remove(&id)
}

#[tauri::command]
fn reorder_jobs(app: State<App>, ids: Vec<String>) {
    app.runtime.reorder(&ids)
}

#[tauri::command]
fn edit_segment(app: State<App>, id: String, slot: Slot, segment_id: i64, text: String) -> Result<()> {
    app.runtime.edit_segment(&id, slot, segment_id, &text)
}

#[tauri::command]
fn set_override(app: State<App>, id: String, key: String, value: Option<String>) -> Result<()> {
    app.runtime.set_override(&id, &key, value)
}

#[tauri::command]
fn export_job(app: State<App>, id: String, documents: Vec<Document>, formats: Vec<String>, folder: Option<PathBuf>) -> Result<Vec<String>> {
    let formats: Vec<Format> =
        formats.iter().map(|f| Format::parse(f).ok_or_else(|| format!("unknown format {f}"))).collect::<Result<_>>()?;
    let paths = app.runtime.export(&id, &documents, &formats, folder.as_deref())?;
    Ok(paths.into_iter().map(|p| p.to_string_lossy().into_owned()).collect())
}

/// Shows a file selected in Explorer (or its folder elsewhere).
#[tauri::command]
fn reveal(path: PathBuf) -> Result<()> {
    #[cfg(windows)]
    let status = std::process::Command::new("explorer").arg(format!("/select,{}", path.display())).spawn();
    #[cfg(not(windows))]
    let status = std::process::Command::new("xdg-open").arg(path.parent().unwrap_or(&path)).spawn();
    status.map(|_| ()).map_err(|e| e.to_string())
}

// MARK: Queue and settings

#[tauri::command]
fn set_paused(app: State<App>, paused: bool) {
    app.runtime.set_paused(paused)
}

#[tauri::command]
fn queue_state(app: State<App>) -> Event {
    app.runtime.queue_state()
}

#[tauri::command]
fn get_settings(app: State<App>) -> Settings {
    app.runtime.settings()
}

#[tauri::command]
fn save_settings(app: State<App>, settings: Settings) -> Result<()> {
    app.runtime.update_settings(settings)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelInfo {
    name: &'static str,
    label: &'static str,
    size_mb: u64,
    installed: bool,
}

#[tauri::command]
fn list_models() -> Vec<ModelInfo> {
    let store = ModelStore::default_location();
    CATALOG
        .iter()
        .map(|m| ModelInfo { name: m.name, label: m.label, size_mb: m.byte_count / 1_000_000, installed: store.is_installed(m) })
        .collect()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct KeyInfo {
    provider: &'static str,
    label: &'static str,
    /// "saved", "environment" or "missing".
    state: &'static str,
    variable: Option<&'static str>,
}

#[tauri::command]
fn list_keys() -> Vec<KeyInfo> {
    Provider::ALL
        .into_iter()
        .filter(|p| p.needs_api_key())
        .map(|p| {
            let (state, variable) = match credentials::lookup(p) {
                Some((_, KeySource::CredentialManager)) => ("saved", None),
                Some((_, KeySource::Environment(name))) => ("environment", Some(name)),
                None => ("missing", None),
            };
            KeyInfo { provider: p.slug(), label: p.label(), state, variable }
        })
        .collect()
}

#[tauri::command]
fn save_key(provider: String, key: String) -> Result<()> {
    let provider = Provider::from_slug(&provider).ok_or("unknown provider")?;
    credentials::save(provider, &key)
}

#[tauri::command]
fn remove_key(provider: String) -> Result<()> {
    let provider = Provider::from_slug(&provider).ok_or("unknown provider")?;
    credentials::remove(provider).map(|_| ())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Diagnostics {
    gpu_backend: &'static str,
    ffmpeg: Option<String>,
    data_folder: String,
}

#[tauri::command]
fn diagnostics() -> Diagnostics {
    Diagnostics {
        gpu_backend: cue_runtime::whisper::compiled_backend(),
        ffmpeg: cue_core::audio::find_ffmpeg().map(|p| p.to_string_lossy().into_owned()),
        data_folder: cue_core::paths::app_data_dir().to_string_lossy().into_owned(),
    }
}

fn main() {
    // The runtime is built in `setup` (it needs the app handle to emit), and
    // the exit handler needs it too.
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let handle = app.handle().clone();
            let emit = Arc::new(move |event: Event| {
                let _ = handle.emit("cue", event);
            });
            let (runtime, startup_failures) = Runtime::launch(Config::standard(emit));
            let _ = RUNTIME.set(runtime.clone());
            app.manage(App { runtime, startup_failures });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::DragDrop(DragDropEvent::Drop { paths, .. }) = event {
                let media: Vec<PathBuf> = paths.iter().filter(|p| is_media(p)).cloned().collect();
                if let Some(app) = window.try_state::<App>() {
                    app.runtime.add_files(&media);
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            list_jobs,
            get_job,
            startup_failures,
            add_files,
            pick_files,
            pick_folder,
            start_job,
            retranscribe_job,
            translate_job,
            cancel_job,
            remove_job,
            reorder_jobs,
            edit_segment,
            set_override,
            export_job,
            reveal,
            set_paused,
            queue_state,
            get_settings,
            save_settings,
            list_models,
            list_keys,
            save_key,
            remove_key,
            diagnostics,
        ])
        .build(tauri::generate_context!())
        .expect("failed to start Cue");

    app.run(|_, event| {
        if let RunEvent::Exit = event {
            if let Some(runtime) = RUNTIME.get() {
                runtime.shutdown();
            }
        }
    });
}
