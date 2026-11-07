//! `cue translate`, `cue pipeline` and `cue keys`. Mirrors the translate
//! stage of the macOS CLI (Sources/CLI/CLIRunner.swift): the same service,
//! model routing, prompts and output names.

use cue_core::credentials::{self, KeySource};
use cue_core::export;
use cue_core::subtitle::{self, Format};
use cue_core::translation::{self, bilingual_segments, ChunkMode, Provider, TranslateOptions, Translator, UreqTransport};
use cue_core::Segment;
use std::io::{BufRead, IsTerminal};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

/// Everything `translate` and `pipeline` share.
pub struct TranslationArgs {
    pub to: String,
    pub from: String,
    pub model: String,
    pub parallelism: usize,
    pub chunk_mode: String,
    pub prompt_file: Option<PathBuf>,
    pub local_endpoint: String,
    pub bilingual: bool,
}

impl TranslationArgs {
    /// Builds options with the key from Credential Manager or the environment.
    pub fn options(&self, transcription_language: &str) -> Result<TranslateOptions, String> {
        let provider = Provider::infer(&self.model);
        let api_key = match credentials::lookup(provider) {
            Some((key, _)) => key,
            None if !provider.needs_api_key() => String::new(),
            None => {
                return Err(format!(
                    "No {} API key. Save one with `cue keys set {}`, set CUE_{}_API_KEY, or pass --translation-model local/<model>.",
                    provider.label(),
                    provider.slug(),
                    provider.slug().to_uppercase()
                ))
            }
        };
        let chunk_mode = ChunkMode::parse(&self.chunk_mode)
            .ok_or_else(|| format!("unknown chunk mode \"{}\" (safer, balanced, faster)", self.chunk_mode))?;
        let prompt = match &self.prompt_file {
            Some(path) => std::fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?,
            None => String::new(),
        };
        let mut options = TranslateOptions::new(self.model.clone(), api_key);
        options.target_language = self.to.clone();
        options.source_language = self.from.clone();
        options.transcription_language = transcription_language.to_string();
        options.chunk_mode = chunk_mode;
        options.parallelism = self.parallelism;
        options.prompt = prompt;
        options.local_endpoint = self.local_endpoint.clone();
        Ok(options)
    }
}

/// Reads SRT, WebVTT, or a JSON segment export.
pub fn read_segments(path: &Path) -> Result<Vec<Segment>, String> {
    let is_json = path.extension().is_some_and(|e| e.eq_ignore_ascii_case("json"));
    if is_json {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        return serde_json::from_str(&text).map_err(|e| format!("{}: not a Cue JSON export ({e})", path.display()));
    }
    let (doc, decoded) = subtitle::read_file(path, subtitle::MAX_FILE_SIZE).map_err(|e| format!("{}: {e}", path.display()))?;
    if decoded.requires_encoding_review {
        eprintln!("note: {} is not Unicode; its encoding was guessed.", path.display());
    }
    Ok(doc.segments)
}

fn partial_path(dir: &Path, base: &str, language: &str) -> PathBuf {
    dir.join(format!("{base}.translated.{}.partial.json", export::language_suffix(language)))
}

/// Translates one document and writes the translated (and optionally
/// bilingual) files. Progress is saved after every chunk to a
/// `.partial.json` beside the output, and a later run picks it up, so an
/// interrupted translation never pays for the same subtitles twice.
pub fn translate_document(
    transcript: &[Segment],
    source: &Path,
    out_dir: &Path,
    formats: &[Format],
    args: &TranslationArgs,
    transcription_language: &str,
    cancel: &AtomicBool,
) -> Result<Vec<PathBuf>, String> {
    if transcript.is_empty() {
        return Err("nothing to translate: the transcript is empty".into());
    }
    let options = args.options(transcription_language)?;
    let base = export::base_name(source);
    let partial = partial_path(out_dir, &base, &args.to);
    let existing: Vec<Segment> =
        std::fs::read_to_string(&partial).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default();
    if !existing.is_empty() {
        eprintln!("Resuming: {} subtitle(s) already translated.", existing.len());
    }

    let transport = UreqTransport;
    let mut progress = crate::Progress::new();
    let mut save_error = None;
    let result = Translator::new(&transport).translate(
        transcript,
        &options,
        &existing,
        cancel,
        &mut |p| progress.show_detail(&p.detail, p.fraction),
        &mut |done| {
            let saved = serde_json::to_string(done).map_err(|e| e.to_string()).and_then(|json| {
                let tmp = partial.with_extension("json.tmp");
                std::fs::write(&tmp, json).and_then(|_| std::fs::rename(&tmp, &partial)).map_err(|e| e.to_string())
            });
            if let Err(e) = saved {
                save_error.get_or_insert(e);
            }
        },
    );
    progress.done();
    if let Some(e) = save_error {
        eprintln!("warning: could not save translation progress to {}: {e}", partial.display());
    }
    let translated = result.map_err(|e| match e {
        translation::TranslationError::Canceled => "canceled; progress was saved and the next run resumes".to_string(),
        other if partial.exists() => format!("{other} (progress saved; run the command again to resume)"),
        other => other.to_string(),
    })?;

    let target = export::language_suffix(&args.to);
    let mut written = Vec::new();
    let mut documents = vec![(format!("translated.{target}"), translated.clone())];
    if args.bilingual {
        documents.push((format!("bilingual.{target}"), bilingual_segments(transcript, &translated)));
    }
    for (suffix, segments) in &documents {
        for &format in formats {
            let path = export::document_path(out_dir, &base, suffix, format);
            subtitle::write_file(segments, format, &path).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
            written.push(path);
        }
    }
    let _ = std::fs::remove_file(&partial);
    eprintln!(
        "Translated {} subtitles into {} with {}.",
        translated.len(),
        if args.to.trim().is_empty() { "English" } else { &args.to },
        args.model
    );
    Ok(written)
}

pub fn translate_files(
    inputs: &[PathBuf],
    formats: &[Format],
    output_dir: Option<&Path>,
    args: &TranslationArgs,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let mut failures = 0;
    for input in inputs {
        let dir = crate::output_dir_for(input, output_dir)?;
        let outcome = read_segments(input).and_then(|segments| translate_document(&segments, input, &dir, formats, args, "auto", cancel));
        match outcome {
            Ok(paths) => paths.iter().for_each(|p| println!("{}", p.display())),
            Err(e) if cancel.load(std::sync::atomic::Ordering::Relaxed) => return Err(e),
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

pub enum KeysAction {
    List,
    Set { provider: String, value: Option<String> },
    Remove { provider: String },
}

fn parse_provider(name: &str) -> Result<Provider, String> {
    let provider = Provider::from_slug(name).ok_or_else(|| {
        let names: Vec<&str> = Provider::ALL.iter().filter(|p| p.needs_api_key()).map(|p| p.slug()).collect();
        format!("unknown provider \"{name}\" (use {})", names.join(", "))
    })?;
    if !provider.needs_api_key() {
        return Err("local servers need no API key".into());
    }
    Ok(provider)
}

pub fn keys(action: KeysAction) -> Result<(), String> {
    match action {
        KeysAction::List => {
            for provider in Provider::ALL.into_iter().filter(|p| p.needs_api_key()) {
                let state = match credentials::lookup(provider) {
                    Some((_, KeySource::CredentialManager)) => "saved in Credential Manager".to_string(),
                    Some((_, KeySource::Environment(name))) => format!("from %{name}%"),
                    None => "not set".to_string(),
                };
                println!("{:<12} {state}", provider.slug());
            }
            Ok(())
        }
        KeysAction::Set { provider, value } => {
            let provider = parse_provider(&provider)?;
            let key = match value {
                Some(v) => v,
                None => {
                    if std::io::stdin().is_terminal() {
                        eprint!("Paste the {} API key and press Enter: ", provider.label());
                    }
                    let mut line = String::new();
                    std::io::stdin().lock().read_line(&mut line).map_err(|e| e.to_string())?;
                    line
                }
            };
            credentials::save(provider, &key)?;
            eprintln!("Saved the {} key to Windows Credential Manager.", provider.label());
            Ok(())
        }
        KeysAction::Remove { provider } => {
            let provider = parse_provider(&provider)?;
            if credentials::remove(provider)? {
                eprintln!("Removed the {} key.", provider.label());
            } else {
                eprintln!("No saved {} key.", provider.label());
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_json_exports_and_subtitles() {
        let dir = tempfile::tempdir().unwrap();
        let segments = vec![Segment::new(1, 0.0, 1.5, "hello")];
        let json = dir.path().join("a.json");
        subtitle::write_file(&segments, Format::Json, &json).unwrap();
        assert_eq!(read_segments(&json).unwrap(), segments);
        let srt = dir.path().join("a.srt");
        subtitle::write_file(&segments, Format::Srt, &srt).unwrap();
        assert_eq!(read_segments(&srt).unwrap()[0].text, "hello");
    }

    #[test]
    fn local_models_need_no_key_and_bad_modes_are_rejected() {
        let mut args = TranslationArgs {
            to: "Vietnamese".into(),
            from: "auto".into(),
            model: "local/qwen3".into(),
            parallelism: 2,
            chunk_mode: "balanced".into(),
            prompt_file: None,
            local_endpoint: translation::DEFAULT_LOCAL_ENDPOINT.into(),
            bilingual: false,
        };
        let options = args.options("ja").unwrap();
        assert_eq!(options.provider, Provider::Local);
        assert_eq!(options.transcription_language, "ja");
        args.chunk_mode = "turbo".into();
        assert!(args.options("ja").is_err());
    }

    #[test]
    fn partial_files_are_named_per_language() {
        assert_eq!(partial_path(Path::new("d"), "movie", "Vietnamese"), Path::new("d").join("movie.translated.vietnamese.partial.json"));
    }
}
