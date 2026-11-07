//! `cue`: headless Cue for Windows. Mirrors the macOS CLI's spirit: services
//! driven directly, no queue, no persistence.

mod translate;

use clap::{Args, Parser, Subcommand};
use cue_core::models::{self, ModelProgress, ModelStore};
use cue_core::postprocess::{self, CleanupSettings};
use cue_core::subtitle::{self, Format};
use cue_core::translation::DEFAULT_LOCAL_ENDPOINT;
use cue_core::{audio, export, paths};
use cue_engine::{Callbacks, Engine, TranscribeOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

#[derive(Parser)]
#[command(name = "cue", version, about = "Turn video and audio into subtitles, on-device.")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Args)]
struct TranscribeArgs {
    /// Model name or alias (see `cue models`).
    #[arg(short, long, default_value = models::DEFAULT_MODEL)]
    model: String,
    /// Use a local ggml model file instead of a catalog model.
    #[arg(long, conflicts_with = "model")]
    model_file: Option<PathBuf>,
    /// Spoken language as an ISO code, or "auto".
    #[arg(short, long, default_value = "auto")]
    language: String,
    #[arg(long, default_value_t = 5)]
    beam_size: i32,
    /// Skip repeat/echo cleanup (whitespace and timing repair still run).
    #[arg(long)]
    no_cleanup: bool,
    /// Force CPU even when a GPU backend is compiled in.
    #[arg(long)]
    cpu: bool,
    /// Print each subtitle as it is recognized.
    #[arg(long)]
    stream: bool,
}

#[derive(Args)]
struct OutputArgs {
    /// Comma-separated output formats: srt, vtt, txt, md, json.
    #[arg(short, long, default_value = "srt", value_delimiter = ',')]
    format: Vec<String>,
    /// Output folder. Defaults to next to each input (a sidecar).
    #[arg(short, long)]
    output: Option<PathBuf>,
}

#[derive(Args)]
struct TranslateArgs {
    /// Target language, in plain words ("Vietnamese", "Brazilian Portuguese").
    #[arg(long, default_value = "English")]
    to: String,
    /// Source language override; "auto" uses the transcript's language.
    #[arg(long, default_value = "auto")]
    from: String,
    /// The LLM. Its name picks the provider: claude-*, gemini-*,
    /// local/<model>, openrouter/<id>, groq/<id>, cerebras/<id>, else OpenAI.
    #[arg(short = 't', long, env = "CUE_TRANSLATION_MODEL", default_value = cue_core::translation::DEFAULT_MODEL)]
    translation_model: String,
    /// Concurrent requests (1-4).
    #[arg(long, default_value_t = 2, value_parser = clap::value_parser!(u8).range(1..=4))]
    parallelism: u8,
    /// Request size: safer, balanced or faster.
    #[arg(long, default_value = "balanced")]
    chunk_mode: String,
    /// A file holding a custom translator prompt.
    #[arg(long)]
    prompt_file: Option<PathBuf>,
    /// OpenAI-compatible server for local/ models (LM Studio, Ollama).
    #[arg(long, env = "CUE_LOCAL_ENDPOINT", default_value = DEFAULT_LOCAL_ENDPOINT)]
    local_endpoint: String,
    /// Also write a bilingual file: original line over translation.
    #[arg(long)]
    bilingual: bool,
}

impl TranslateArgs {
    fn shared(&self) -> translate::TranslationArgs {
        translate::TranslationArgs {
            to: self.to.clone(),
            from: self.from.clone(),
            model: self.translation_model.clone(),
            parallelism: self.parallelism as usize,
            chunk_mode: self.chunk_mode.clone(),
            prompt_file: self.prompt_file.clone(),
            local_endpoint: self.local_endpoint.clone(),
            bilingual: self.bilingual,
        }
    }
}

#[derive(Subcommand)]
enum Command {
    /// Transcribe media files into subtitle files.
    Transcribe {
        /// Video or audio files.
        #[arg(required = true)]
        inputs: Vec<PathBuf>,
        #[command(flatten)]
        asr: TranscribeArgs,
        #[command(flatten)]
        out: OutputArgs,
    },
    /// Translate SRT, WebVTT or Cue JSON files with an LLM.
    Translate {
        #[arg(required = true)]
        inputs: Vec<PathBuf>,
        #[command(flatten)]
        translation: TranslateArgs,
        #[command(flatten)]
        out: OutputArgs,
    },
    /// Transcribe, then translate: writes <name>.original.* and
    /// <name>.translated.<language>.*
    Pipeline {
        #[arg(required = true)]
        inputs: Vec<PathBuf>,
        #[command(flatten)]
        asr: TranscribeArgs,
        #[command(flatten)]
        translation: TranslateArgs,
        #[command(flatten)]
        out: OutputArgs,
    },
    /// Manage translation API keys in Windows Credential Manager.
    Keys {
        #[command(subcommand)]
        action: Option<KeysAction>,
    },
    /// List, download or remove Whisper models.
    Models {
        #[command(subcommand)]
        action: Option<ModelsAction>,
    },
    /// Convert an SRT or WebVTT file into another format.
    Convert {
        input: PathBuf,
        /// Target format: srt, vtt, txt, md, json.
        #[arg(long)]
        to: String,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Check that ffmpeg, models and the GPU backend are in place.
    Doctor,
}

#[derive(Subcommand)]
enum KeysAction {
    /// Show which providers have a key, and where it comes from.
    List,
    /// Save a key. Reads it from stdin when --value is omitted.
    Set {
        /// openai, anthropic, google, openrouter, groq or cerebras.
        provider: String,
        #[arg(long)]
        value: Option<String>,
    },
    Remove {
        provider: String,
    },
}

#[derive(Subcommand)]
enum ModelsAction {
    List,
    Download {
        name: String,
    },
    Remove {
        name: String,
    },
    /// Print the models folder.
    Path,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let cancel = Arc::new(AtomicBool::new(false));
    let flag = cancel.clone();
    let _ = ctrlc::set_handler(move || {
        if flag.swap(true, Ordering::SeqCst) {
            std::process::exit(130);
        }
        eprintln!("\nCanceling… (press Ctrl+C again to quit now)");
    });
    let result = match cli.command {
        Command::Transcribe { inputs, asr, out } => run_media(&inputs, &asr, &out, None, &cancel),
        Command::Pipeline { inputs, asr, translation, out } => run_media(&inputs, &asr, &out, Some(&translation.shared()), &cancel),
        Command::Translate { inputs, translation, out } => parse_formats(&out.format)
            .and_then(|formats| translate::translate_files(&inputs, &formats, out.output.as_deref(), &translation.shared(), &cancel)),
        Command::Keys { action } => translate::keys(match action.unwrap_or(KeysAction::List) {
            KeysAction::List => translate::KeysAction::List,
            KeysAction::Set { provider, value } => translate::KeysAction::Set { provider, value },
            KeysAction::Remove { provider } => translate::KeysAction::Remove { provider },
        }),
        Command::Models { action } => models_command(action.unwrap_or(ModelsAction::List), &cancel),
        Command::Convert { input, to, output } => convert(&input, &to, output.as_deref()),
        Command::Doctor => doctor(),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::FAILURE
        }
    }
}

type CliResult = Result<(), String>;

fn parse_formats(names: &[String]) -> Result<Vec<Format>, String> {
    let mut out = Vec::new();
    for n in names {
        let f = Format::parse(n).ok_or_else(|| format!("unknown format \"{n}\" (use srt, vtt, txt, md or json)"))?;
        if !out.contains(&f) {
            out.push(f);
        }
    }
    Ok(out)
}

fn output_path(input: &Path, output_dir: Option<&Path>, format: Format) -> PathBuf {
    let stem = input.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "subtitles".into());
    let dir = output_dir.map(Path::to_path_buf).unwrap_or_else(|| input.parent().map(Path::to_path_buf).unwrap_or_default());
    dir.join(format!("{stem}.{}", format.extension()))
}

/// The folder an input's outputs go to, created if needed.
pub(crate) fn output_dir_for(input: &Path, output_dir: Option<&Path>) -> Result<PathBuf, String> {
    let dir = output_dir.map(Path::to_path_buf).unwrap_or_else(|| input.parent().map(Path::to_path_buf).unwrap_or_default());
    let dir = if dir.as_os_str().is_empty() { PathBuf::from(".") } else { dir };
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    Ok(dir)
}

/// Overwrite the current stderr line. Plain carriage return plus padding
/// works in every Windows console, unlike ANSI erase codes.
fn status_line(text: &str) {
    eprint!("\r{text:<60}\r");
    if !text.is_empty() {
        eprint!("{text}");
    }
    let _ = std::io::stderr().flush();
}

pub(crate) struct Progress {
    last: Instant,
}

impl Progress {
    pub(crate) fn new() -> Self {
        Self { last: Instant::now() }
    }

    /// A detail line with a percentage, throttled like `show`.
    pub(crate) fn show_detail(&mut self, detail: &str, fraction: f64) {
        if self.last.elapsed().as_millis() < 200 && fraction < 1.0 {
            return;
        }
        self.last = Instant::now();
        let mut text = format!("{:>3.0}% {detail}", fraction * 100.0);
        text.truncate(text.char_indices().nth(78).map_or(text.len(), |(i, _)| i));
        status_line(&text);
    }

    fn show(&mut self, label: &str, fraction: Option<f64>) {
        if self.last.elapsed().as_millis() < 200 && fraction.is_some_and(|f| f < 1.0) {
            return;
        }
        self.last = Instant::now();
        match fraction {
            Some(f) => status_line(&format!("{label} {:>3.0}%", f * 100.0)),
            None => status_line(label),
        }
    }

    pub(crate) fn done(&self) {
        status_line("");
    }
}

fn resolve_model(asr: &TranscribeArgs, cancel: &AtomicBool) -> Result<PathBuf, String> {
    let mut progress = Progress::new();
    let path = match asr.model_file.as_deref() {
        Some(file) if file.is_file() => file.to_path_buf(),
        Some(file) => return Err(format!("model file not found: {}", file.display())),
        None => ModelStore::default_location()
            .ensure_installed(&asr.model, cancel, &mut |p| match p {
                ModelProgress::Downloading(f) => progress.show("Downloading model", Some(f)),
                ModelProgress::Verifying => progress.show("Verifying model…", None),
            })
            .map_err(|e| e.to_string())?,
    };
    progress.done();
    Ok(path)
}

/// `transcribe`, and `pipeline` when `translation` is given.
fn run_media(
    inputs: &[PathBuf],
    asr: &TranscribeArgs,
    out: &OutputArgs,
    translation: Option<&translate::TranslationArgs>,
    cancel: &Arc<AtomicBool>,
) -> CliResult {
    let formats = parse_formats(&out.format)?;
    if let Some(args) = translation {
        // Fail on a missing key before spending minutes on transcription.
        args.options(&asr.language)?;
    }
    let model_path = resolve_model(asr, cancel)?;
    let engine = Engine::new();
    let cleanup = if asr.no_cleanup { CleanupSettings::minimal() } else { CleanupSettings::default() };
    let mut failures = 0;
    for input in inputs {
        let started = Instant::now();
        let outcome = transcribe_one(&engine, input, &model_path, &asr.language, asr.beam_size, !asr.cpu, asr.stream, &cleanup, cancel)
            .and_then(|segments| {
                eprintln!("{}: {} subtitles in {}", input.display(), segments.len(), audio::format_duration(started.elapsed()));
                let dir = output_dir_for(input, out.output.as_deref())?;
                let mut written = Vec::new();
                for &f in &formats {
                    // Plain sidecar names for `transcribe`; role suffixes once
                    // a translation sits beside the original (as on the Mac).
                    let path = match translation {
                        None => output_path(input, out.output.as_deref(), f),
                        Some(_) => export::document_path(&dir, &export::base_name(input), "original", f),
                    };
                    subtitle::write_file(&segments, f, &path).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
                    written.push(path);
                }
                if let Some(args) = translation {
                    written.extend(translate::translate_document(&segments, input, &dir, &formats, args, &asr.language, cancel)?);
                }
                Ok(written)
            });
        match outcome {
            Ok(paths) => paths.iter().for_each(|p| println!("{}", p.display())),
            Err(e) if cancel.load(Ordering::Relaxed) => return Err(e),
            Err(e) => {
                failures += 1;
                eprintln!("{}: {e}", input.display());
            }
        }
    }
    if failures > 0 {
        return Err(format!("{failures} of {} file(s) failed", inputs.len()));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn transcribe_one(
    engine: &Engine,
    input: &Path,
    model: &Path,
    language: &str,
    beam_size: i32,
    use_gpu: bool,
    stream: bool,
    cleanup: &CleanupSettings,
    cancel: &Arc<AtomicBool>,
) -> Result<Vec<cue_core::Segment>, String> {
    if !input.is_file() {
        return Err("file not found".into());
    }
    let mut progress = Progress { last: Instant::now() };
    let (wav, _) = audio::extract_cached(input, &paths::audio_cache_dir(), cancel, &mut |f| progress.show("Extracting audio", Some(f)))
        .map_err(|e| e.to_string())?;
    progress.show("Loading audio…", None);
    let samples = audio::load_pcm16_mono(&wav).map_err(|e| e.to_string())?;
    let options = TranscribeOptions { language: language.into(), beam_size, use_gpu, ..TranscribeOptions::default() };
    let window_cleanup = cleanup.clone();
    let callbacks = Callbacks {
        on_progress: Box::new(move |f| {
            status_line(&format!("Transcribing {:>3.0}%", f * 100.0));
        }),
        on_segments: Box::new(move |batch| {
            if stream {
                for s in postprocess::clean_window(&batch, &window_cleanup) {
                    status_line("");
                    eprintln!("[{}] {}", subtitle::format_display_timestamp(s.start), s.text);
                }
            }
        }),
        on_chunk_complete: Box::new(|_| {}),
    };
    let raw = engine.transcribe(&samples, model, &options, callbacks, cancel.clone()).map_err(|e| e.to_string())?;
    status_line("");
    Ok(postprocess::clean_resumed(&[], &raw, cleanup))
}

fn models_command(action: ModelsAction, cancel: &AtomicBool) -> CliResult {
    let store = ModelStore::default_location();
    match action {
        ModelsAction::List => {
            for a in &models::CATALOG {
                let mark = if store.is_installed(a) { "installed" } else { "" };
                let default = if a.name == models::DEFAULT_MODEL { " (default)" } else { "" };
                println!("{:<30} {:>8.0} MB  {:<10} {}{}", a.name, a.byte_count as f64 / 1_048_576.0, mark, a.label, default);
            }
            Ok(())
        }
        ModelsAction::Download { name } => {
            let mut progress = Progress { last: Instant::now() };
            let path = store
                .ensure_installed(&name, cancel, &mut |p| match p {
                    ModelProgress::Downloading(f) => progress.show("Downloading", Some(f)),
                    ModelProgress::Verifying => progress.show("Verifying…", None),
                })
                .map_err(|e| e.to_string())?;
            progress.done();
            println!("{}", path.display());
            Ok(())
        }
        ModelsAction::Remove { name } => {
            let a = models::artifact(&name).ok_or_else(|| format!("unknown model \"{name}\""))?;
            store.remove(a).map_err(|e| e.to_string())
        }
        ModelsAction::Path => {
            println!("{}", store.dir().display());
            Ok(())
        }
    }
}

fn convert(input: &Path, to: &str, output: Option<&Path>) -> CliResult {
    let format = Format::parse(to).ok_or_else(|| format!("unknown format \"{to}\""))?;
    let (doc, decoded) = subtitle::read_file(input, subtitle::MAX_FILE_SIZE).map_err(|e| format!("{}: {e}", input.display()))?;
    if decoded.requires_encoding_review {
        eprintln!("note: {} is not Unicode; its encoding was guessed. Check accented characters in the output.", input.display());
    }
    let path = output.map(Path::to_path_buf).unwrap_or_else(|| input.with_extension(format.extension()));
    if path == input {
        return Err("output would overwrite the input; pass --output".into());
    }
    subtitle::write_file(&doc.segments, format, &path).map_err(|e| e.to_string())?;
    println!("{}", path.display());
    Ok(())
}

fn doctor() -> CliResult {
    let mut ok = true;
    match audio::find_ffmpeg() {
        Some(p) => println!("ffmpeg        ok  {}", p.display()),
        None => {
            ok = false;
            println!("ffmpeg        MISSING  put ffmpeg.exe next to cue.exe or on PATH")
        }
    }
    println!("compute       {}", cue_engine::compiled_backend());
    let store = ModelStore::default_location();
    let installed: Vec<&str> = models::CATALOG.iter().filter(|a| store.is_installed(a)).map(|a| a.name).collect();
    println!(
        "models        {}  ({})",
        if installed.is_empty() { "none yet, downloaded on first use".into() } else { installed.join(", ") },
        store.dir().display()
    );
    println!("data folder   {}", paths::app_data_dir().display());
    if ok {
        Ok(())
    } else {
        Err("some required tools are missing".into())
    }
}
