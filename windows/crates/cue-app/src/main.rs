//! Cue for Windows. A thin Tauri shell: every command forwards to
//! `cue_runtime::Runtime`, and every runtime event is re-emitted to the
//! web UI as a `cue` event. The UI lives in `ui/` as plain HTML, CSS and
//! JavaScript with no build step.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use cue_core::credentials::{self, KeySource};
use cue_core::models::{ModelStore, CATALOG};
use cue_core::subtitle::Format;
use cue_core::translation::Provider;
use cue_runtime::{Config, Document, Download, Event, JobSummary, Runtime, Settings, Slot, TextSize, WatchStatus};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, DragDropEvent, Emitter, Manager, RunEvent, State, WindowEvent, Wry};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_notification::NotificationExt;

struct App {
    runtime: Runtime,
    startup_failures: Vec<String>,
}

type Result<T> = std::result::Result<T, String>;

use cue_core::watch::{expand_for_add, is_media, MEDIA_EXTENSIONS};

/// Media files among dropped or picked paths, folders opened up.
fn media_in(paths: &[PathBuf]) -> Vec<PathBuf> {
    expand_for_add(paths).into_iter().filter(|p| is_media(p)).collect()
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
    app.runtime.add_files(&media_in(&paths))
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
    ytdlp: Option<String>,
    data_folder: String,
    downloads_folder: String,
}

#[tauri::command]
fn diagnostics(app: State<App>) -> Diagnostics {
    let text = |p: PathBuf| p.to_string_lossy().into_owned();
    Diagnostics {
        gpu_backend: cue_runtime::whisper::compiled_backend(),
        ffmpeg: app.runtime.ffmpeg_path().map(text),
        ytdlp: app.runtime.ytdlp_path().map(text),
        data_folder: text(cue_core::paths::app_data_dir()),
        downloads_folder: text(app.runtime.settings().downloads_dir()),
    }
}

// MARK: Watch folders

#[tauri::command]
fn watch_folders(app: State<App>) -> Vec<WatchStatus> {
    app.runtime.watch_folders()
}

/// Picks a folder and starts watching it.
#[tauri::command]
async fn add_watch_folder(handle: AppHandle, app: State<'_, App>) -> Result<Option<String>> {
    let picked = handle.dialog().file().set_title("Watch a folder").blocking_pick_folder().and_then(|p| p.into_path().ok());
    match picked {
        Some(path) => app.runtime.add_watch_folder(&path).map(Some),
        None => Ok(None),
    }
}

#[tauri::command]
fn remove_watch_folder(app: State<App>, id: String) -> Result<()> {
    app.runtime.remove_watch_folder(&id)
}

#[tauri::command]
fn set_watch_folder(app: State<App>, id: String, enabled: bool, profile: serde_json::Value) -> Result<()> {
    app.runtime.set_watch_folder(&id, enabled, profile)
}

#[tauri::command]
fn clear_watch_history(app: State<App>, id: String) -> Result<()> {
    app.runtime.clear_watch_history(&id)
}

// MARK: Downloads

#[tauri::command]
fn add_url(app: State<App>, url: String) -> Result<String> {
    app.runtime.add_url(&url)
}

#[tauri::command]
fn list_downloads(app: State<App>) -> Vec<Download> {
    app.runtime.downloads()
}

#[tauri::command]
fn cancel_download(app: State<App>, id: String) -> Result<()> {
    app.runtime.cancel_download(&id)
}

#[tauri::command]
fn dismiss_download(app: State<App>, id: String) -> Result<()> {
    app.runtime.dismiss_download(&id)
}

/// Fetches yt-dlp from its GitHub releases, verified by checksum.
#[tauri::command]
async fn install_ytdlp(app: State<'_, App>) -> Result<String> {
    let runtime = app.runtime.clone();
    tauri::async_runtime::spawn_blocking(move || runtime.install_ytdlp())
        .await
        .map_err(|e| e.to_string())?
        .map(|p| p.to_string_lossy().into_owned())
}

// MARK: Burn-in

#[tauri::command]
async fn burn_in_preflight(app: State<'_, App>) -> Result<()> {
    let runtime = app.runtime.clone();
    tauri::async_runtime::spawn_blocking(move || runtime.burn_in_preflight()).await.map_err(|e| e.to_string())?
}

/// Asks where to save, suggesting `<video>.subtitled.mp4`.
#[tauri::command]
async fn pick_burn_in_output(handle: AppHandle, app: State<'_, App>, id: String) -> Result<Option<String>> {
    let suggested = app.runtime.default_burn_in_output(&id)?;
    let mut dialog = handle.dialog().file().set_title("Save the subtitled video").add_filter("MP4 video", &["mp4"]);
    if let Some(dir) = suggested.parent() {
        dialog = dialog.set_directory(dir);
    }
    if let Some(name) = suggested.file_name() {
        dialog = dialog.set_file_name(name.to_string_lossy());
    }
    Ok(dialog.blocking_save_file().and_then(|p| p.into_path().ok()).map(|p| p.to_string_lossy().into_owned()))
}

#[tauri::command]
fn burn_in(app: State<App>, id: String, document: Document, size: TextSize, output: Option<PathBuf>) -> Result<String> {
    app.runtime.burn_in(&id, document, size, output).map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
fn cancel_burn_in(app: State<App>) -> Result<()> {
    app.runtime.cancel_burn_in()
}

// MARK: Window, tray, notifications, sleep

fn show_main_window(handle: &AppHandle) {
    if let Some(window) = handle.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// The tray's pause item, relabeled as the queue changes.
static PAUSE_ITEM: OnceLock<MenuItem<Wry>> = OnceLock::new();

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Show Cue", true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", "Pause queue", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Cue", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &pause, &quit])?;
    let _ = PAUSE_ITEM.set(pause);
    let mut tray = TrayIconBuilder::with_id("cue").tooltip("Cue").menu(&menu).show_menu_on_left_click(false);
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.on_menu_event(|handle, event| match event.id.as_ref() {
        "show" => show_main_window(handle),
        "pause" => {
            if let Some(app) = handle.try_state::<App>() {
                let paused = matches!(app.runtime.queue_state(), Event::Queue { paused: true, .. });
                app.runtime.set_paused(!paused);
            }
        }
        "quit" => handle.exit(0),
        _ => {}
    })
    .on_tray_icon_event(|tray, event| {
        if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
            show_main_window(tray.app_handle());
        }
    })
    .build(app)?;
    Ok(())
}

/// Side effects of runtime events that live in the shell, not the UI.
fn on_runtime_event(handle: &AppHandle, event: &Event) {
    match event {
        Event::Queue { paused, .. } => {
            if let Some(item) = PAUSE_ITEM.get() {
                let _ = item.set_text(if *paused { "Resume queue" } else { "Pause queue" });
            }
        }
        Event::Finished { title, success, message, .. } => {
            let Some(app) = handle.try_state::<App>() else { return };
            if !app.runtime.settings().notifications {
                return;
            }
            // Only when the person isn't already looking at Cue.
            let looking =
                handle.get_webview_window("main").is_some_and(|w| w.is_visible().unwrap_or(false) && w.is_focused().unwrap_or(false));
            if looking {
                return;
            }
            let heading = if *success { format!("{title} is ready") } else { format!("{title} failed") };
            let _ = handle.notification().builder().title(heading).body(message).show();
        }
        _ => {}
    }
}

/// Holds off sleep while anything runs. The request is per thread, so one
/// thread owns it for the whole session.
fn spawn_keep_awake(runtime: Runtime) {
    let _ = std::thread::Builder::new().name("cue-keep-awake".into()).spawn(move || {
        let mut awake = false;
        loop {
            let want = runtime.settings().keep_awake && runtime.busy();
            if want != awake {
                set_keep_awake(want);
                awake = want;
            }
            std::thread::sleep(Duration::from_secs(3));
        }
    });
}

#[cfg(windows)]
fn set_keep_awake(on: bool) {
    use windows_sys::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED};
    // SAFETY: a plain flag call with no pointers.
    unsafe {
        SetThreadExecutionState(if on { ES_CONTINUOUS | ES_SYSTEM_REQUIRED } else { ES_CONTINUOUS });
    }
}

#[cfg(not(windows))]
fn set_keep_awake(_on: bool) {}

fn main() {
    // The runtime is built in `setup` (it needs the app handle to emit), and
    // the exit handler needs it too.
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            let handle = app.handle().clone();
            let emit = Arc::new(move |event: Event| {
                on_runtime_event(&handle, &event);
                let _ = handle.emit("cue", event);
            });
            let (runtime, startup_failures) = Runtime::launch(Config::standard(emit));
            let _ = RUNTIME.set(runtime.clone());
            spawn_keep_awake(runtime.clone());
            app.manage(App { runtime, startup_failures });
            // No tray is not fatal: the window still works.
            if let Err(e) = build_tray(app) {
                eprintln!("cue: no tray icon: {e}");
            }
            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::DragDrop(DragDropEvent::Drop { paths, .. }) => {
                if let Some(app) = window.try_state::<App>() {
                    app.runtime.add_files(&media_in(paths));
                }
            }
            // With "keep running in the tray", closing only hides.
            WindowEvent::CloseRequested { api, .. } => {
                let keep = window.try_state::<App>().is_some_and(|app| app.runtime.settings().keep_in_tray);
                if keep && window.app_handle().tray_by_id("cue").is_some() {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
            _ => {}
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
            watch_folders,
            add_watch_folder,
            remove_watch_folder,
            set_watch_folder,
            clear_watch_history,
            add_url,
            list_downloads,
            cancel_download,
            dismiss_download,
            install_ytdlp,
            burn_in_preflight,
            pick_burn_in_output,
            burn_in,
            cancel_burn_in,
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
