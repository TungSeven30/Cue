//! The translation run: plan pending chunks, translate up to four at once,
//! retry and split, and report partial results as chunks land so a stopped
//! run resumes without retranslating. Mirrors `TranslationService.translate`.

use super::planner::{pending_chunks, ChunkMode};
use super::reconcile::aligned_translations;
use super::wire::{self, ContextPair, HttpRequest, TranslatedSegment};
use super::{Provider, TranslationError};
use crate::Segment;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

/// Sends one POST. A trait so tests can stand in for every provider.
pub trait Transport: Sync {
    fn post(&self, request: &HttpRequest) -> Result<HttpResponse, String>;
}

/// The real transport: ureq with the OS certificate store and proxy support.
pub struct UreqTransport;

impl Transport for UreqTransport {
    fn post(&self, request: &HttpRequest) -> Result<HttpResponse, String> {
        use ureq::tls::{RootCerts, TlsConfig};
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .tls_config(TlsConfig::builder().root_certs(RootCerts::PlatformVerifier).build())
            .http_status_as_error(false)
            .timeout_global(Some(request.timeout))
            .build()
            .into();
        let mut builder = agent.post(&request.url);
        for (name, value) in &request.headers {
            builder = builder.header(name, value);
        }
        let response = builder.send(request.body.as_bytes()).map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        let headers =
            response.headers().iter().filter_map(|(k, v)| v.to_str().ok().map(|v| (k.as_str().to_string(), v.to_string()))).collect();
        let body = response.into_body().with_config().limit(64 * 1024 * 1024).read_to_vec().map_err(|e| e.to_string())?;
        Ok(HttpResponse { status, headers, body })
    }
}

#[derive(Debug, Clone)]
pub struct TranslateOptions {
    pub model: String,
    pub provider: Provider,
    pub api_key: String,
    /// Empty means the default prompt.
    pub prompt: String,
    pub local_endpoint: String,
    /// Target language; empty means English.
    pub target_language: String,
    /// Explicit source language, or "auto" / empty to derive it from
    /// `transcription_language`.
    pub source_language: String,
    /// The language code the transcript was made in ("ja", "auto", …).
    pub transcription_language: String,
    pub chunk_mode: ChunkMode,
    /// Concurrent requests, clamped to 1…4.
    pub parallelism: usize,
}

impl TranslateOptions {
    pub fn new(model: impl Into<String>, api_key: impl Into<String>) -> Self {
        let model = model.into();
        Self {
            provider: Provider::infer(&model),
            model,
            api_key: api_key.into(),
            prompt: String::new(),
            local_endpoint: wire::DEFAULT_LOCAL_ENDPOINT.into(),
            target_language: "English".into(),
            source_language: "auto".into(),
            transcription_language: "auto".into(),
            chunk_mode: ChunkMode::Balanced,
            parallelism: 2,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Progress {
    pub fraction: f64,
    pub detail: String,
}

pub struct Translator<'a> {
    transport: &'a dyn Transport,
    /// Retry waits, shortened in tests.
    backoff_unit: Duration,
}

impl<'a> Translator<'a> {
    pub fn new(transport: &'a dyn Transport) -> Self {
        Self { transport, backoff_unit: Duration::from_secs(1) }
    }

    #[doc(hidden)]
    pub fn with_backoff_unit(mut self, unit: Duration) -> Self {
        self.backoff_unit = unit;
        self
    }

    /// Translates `segments`, keeping any `existing` translation that lines
    /// up by timing. `on_partial` receives every translated segment so far
    /// after each chunk, so the caller can persist progress; a failure still
    /// applies the chunks that succeeded before it is returned.
    pub fn translate(
        &self,
        segments: &[Segment],
        options: &TranslateOptions,
        existing: &[Segment],
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(Progress),
        on_partial: &mut dyn FnMut(&[Segment]),
    ) -> Result<Vec<Segment>, TranslationError> {
        if options.provider.needs_api_key() && options.api_key.is_empty() {
            return Err(TranslationError::MissingApiKey(options.provider.label().into()));
        }
        let parallelism = options.parallelism.clamp(1, 4);
        let source_language = wire::source_language_name(&options.source_language, &options.transcription_language);
        let target = options.target_language.trim();
        let target_language = if target.is_empty() { "English" } else { target };
        let prompt = if options.prompt.trim().is_empty() { wire::DEFAULT_PROMPT } else { options.prompt.trim() };

        let target_ids: HashSet<i64> = segments.iter().map(|s| s.id).collect();
        let mut translated: HashMap<i64, String> = HashMap::new();
        for seg in aligned_translations(existing, segments) {
            if target_ids.contains(&seg.id) {
                translated.entry(seg.id).or_insert(seg.text);
            }
        }
        let chunks = pending_chunks(segments, &translated.keys().copied().collect(), options.chunk_mode);
        if !translated.is_empty() {
            report_partial(segments, &translated, progress, on_partial);
        }

        let job = ChunkJob { options, prompt, source_language: &source_language, target_language, total_chunks: chunks.len(), cancel };
        let mut next = 0;
        while next < chunks.len() {
            if cancel.load(Ordering::Relaxed) {
                return Err(TranslationError::Canceled);
            }
            let batch_start = next;
            let batch_end = (next + parallelism).min(chunks.len());
            next = batch_end;
            let batch: Vec<(usize, &Vec<Segment>, Vec<ContextPair>)> =
                (batch_start..batch_end).map(|i| (i, &chunks[i], context_pairs(&chunks[i], segments, &translated, 8))).collect();
            let labels: Vec<String> = batch.iter().map(|(i, _, _)| (i + 1).to_string()).collect();
            progress(Progress {
                fraction: batch_start as f64 / chunks.len().max(1) as f64,
                detail: format!("Translating chunk {} of {}.", labels.join(", "), chunks.len()),
            });

            // Every chunk in the batch finishes before a failure is raised,
            // so successful siblings are kept for the resume.
            let outcomes: Vec<(usize, Result<Vec<TranslatedSegment>, TranslationError>)> = std::thread::scope(|scope| {
                let handles: Vec<_> = batch
                    .iter()
                    .map(|(index, chunk, context)| {
                        let job = &job;
                        let number = index + 1;
                        (*index, scope.spawn(move || self.translate_with_retry(job, chunk, number, context)))
                    })
                    .collect();
                handles
                    .into_iter()
                    .map(|(index, handle)| {
                        (index, handle.join().unwrap_or_else(|_| Err(TranslationError::Api("A translation worker crashed.".into()))))
                    })
                    .collect()
            });

            let mut first_error = None;
            for (_, outcome) in outcomes {
                match outcome {
                    Ok(list) => {
                        for t in list {
                            translated.insert(t.id, t.text);
                        }
                        report_partial(segments, &translated, progress, on_partial);
                    }
                    Err(e) => {
                        first_error.get_or_insert(e);
                    }
                }
            }
            if let Some(error) = first_error {
                return Err(error);
            }
        }
        // A cancel that landed while the last replies were in flight must
        // not be stamped complete.
        if cancel.load(Ordering::Relaxed) {
            return Err(TranslationError::Canceled);
        }
        let untranslated = segments.iter().filter(|s| !translated.contains_key(&s.id)).count();
        progress(Progress {
            fraction: 1.0,
            detail: if untranslated > 0 {
                format!("Translation complete. {untranslated} segment(s) kept their original text.")
            } else {
                "Translation complete.".into()
            },
        });
        Ok(segments
            .iter()
            .map(|s| Segment::new(s.id, s.start, s.end, translated.get(&s.id).cloned().unwrap_or_else(|| s.text.clone())))
            .collect())
    }

    fn translate_with_retry(
        &self,
        job: &ChunkJob,
        segments: &[Segment],
        chunk_number: usize,
        context: &[ContextPair],
    ) -> Result<Vec<TranslatedSegment>, TranslationError> {
        const MAX_ATTEMPTS: u32 = 4;
        let mut last_error = None;
        for attempt in 1..=MAX_ATTEMPTS {
            match self.translate_chunk(job, segments, chunk_number, context) {
                Ok(result) => return Ok(result),
                Err(Attempt::RetryAfter(error, wait)) => {
                    // A 429 that named its own wait: honour it, bounded.
                    last_error = Some(error);
                    if attempt < MAX_ATTEMPTS {
                        sleep_unless_canceled(wait.min(Duration::from_secs(30)), job.cancel)?;
                    }
                }
                Err(Attempt::Failed(error)) => {
                    if error.is_final() {
                        return Err(error);
                    }
                    let too_large = matches!(error, TranslationError::ResponseTooLarge(_));
                    last_error = Some(error);
                    if job.cancel.load(Ordering::Relaxed) {
                        return Err(TranslationError::Canceled);
                    }
                    // An over-limit chunk fails identically at the same size.
                    if too_large {
                        break;
                    }
                    if attempt < MAX_ATTEMPTS {
                        // 1, 2, 4 units: a provider hiccup or short rate-limit window.
                        sleep_unless_canceled(self.backoff_unit * (1 << (attempt - 1)), job.cancel)?;
                    }
                }
            }
        }
        let error = last_error.unwrap_or(TranslationError::InvalidResponse);
        // Too-large chunks and replies with dropped or invented ids usually
        // succeed at half the size.
        if segments.len() >= 2 && error.is_splittable() {
            let mid = segments.len() / 2;
            let mut first = self.translate_with_retry(job, &segments[..mid], chunk_number, context)?;
            first.extend(self.translate_with_retry(job, &segments[mid..], chunk_number, context)?);
            return Ok(first);
        }
        Err(error)
    }

    fn translate_chunk(
        &self,
        job: &ChunkJob,
        segments: &[Segment],
        chunk_number: usize,
        context: &[ContextPair],
    ) -> Result<Vec<TranslatedSegment>, Attempt> {
        let o = job.options;
        let system = wire::system_prompt(job.prompt, job.source_language, job.target_language, chunk_number, job.total_chunks);
        let user = wire::user_text(segments, context);
        let request = wire::make_request(
            o.provider,
            &o.model,
            &o.api_key,
            &system,
            &user,
            "subtitle_translation",
            &wire::segments_schema(),
            &o.local_endpoint,
        )
        .map_err(Attempt::Failed)?;
        let response = self.transport.post(&request).map_err(|e| Attempt::Failed(TranslationError::Transport(e)))?;
        if !(200..300).contains(&response.status) {
            let classified = wire::classify_api_error(o.provider, &response.body, response.status, &o.model);
            if response.status == 429 {
                if let Some(wait) = wire::retry_after(response.header("retry-after"), SystemTime::now()) {
                    return Err(Attempt::RetryAfter(classified, wait));
                }
            }
            return Err(Attempt::Failed(classified));
        }
        let raw = wire::extract_output_text(o.provider, &response.body).map_err(Attempt::Failed)?;
        let translated = wire::parse_translated(&raw).map_err(Attempt::Failed)?;
        wire::validate(&translated, segments).map_err(Attempt::Failed)?;
        // Empty lines fall back to the original text instead of failing the chunk.
        Ok(translated.into_iter().filter(|t| !t.text.trim().is_empty()).collect())
    }
}

struct ChunkJob<'a> {
    options: &'a TranslateOptions,
    prompt: &'a str,
    source_language: &'a str,
    target_language: &'a str,
    total_chunks: usize,
    cancel: &'a AtomicBool,
}

enum Attempt {
    Failed(TranslationError),
    RetryAfter(TranslationError, Duration),
}

fn sleep_unless_canceled(duration: Duration, cancel: &AtomicBool) -> Result<(), TranslationError> {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if cancel.load(Ordering::Relaxed) {
            return Err(TranslationError::Canceled);
        }
        std::thread::sleep((deadline - Instant::now()).min(Duration::from_millis(100)));
    }
    Ok(())
}

/// The most recent translated pairs before a chunk, for consistency.
fn context_pairs(chunk: &[Segment], segments: &[Segment], translated: &HashMap<i64, String>, limit: usize) -> Vec<ContextPair> {
    let Some(first) = chunk.first() else { return Vec::new() };
    let Some(start) = segments.iter().position(|s| s.id == first.id) else { return Vec::new() };
    let pairs: Vec<ContextPair> = segments[..start]
        .iter()
        .filter_map(|s| translated.get(&s.id).map(|t| ContextPair { source: s.text.clone(), translation: t.clone() }))
        .collect();
    pairs[pairs.len().saturating_sub(limit)..].to_vec()
}

fn report_partial(
    segments: &[Segment],
    translated: &HashMap<i64, String>,
    progress: &mut dyn FnMut(Progress),
    on_partial: &mut dyn FnMut(&[Segment]),
) {
    let partial: Vec<Segment> =
        segments.iter().filter_map(|s| translated.get(&s.id).map(|t| Segment::new(s.id, s.start, s.end, t.clone()))).collect();
    on_partial(&partial);
    progress(Progress {
        fraction: partial.len() as f64 / segments.len().max(1) as f64,
        detail: format!("Saved {} of {} translated segment(s).", partial.len(), segments.len()),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    use std::sync::Mutex;

    type Script = Box<dyn Fn(usize, &[i64]) -> HttpResponse + Sync>;

    /// Answers like an OpenAI-compatible server, by a script per call.
    struct Fake {
        calls: Mutex<Vec<HttpRequest>>,
        script: Script,
    }

    impl Fake {
        fn new(script: impl Fn(usize, &[i64]) -> HttpResponse + Sync + 'static) -> Self {
            Self { calls: Mutex::new(Vec::new()), script: Box::new(script) }
        }
        fn count(&self) -> usize {
            self.calls.lock().unwrap().len()
        }
    }

    fn ids_in(request: &HttpRequest) -> Vec<i64> {
        let body: Value = serde_json::from_str(&request.body).unwrap();
        let user = body["messages"][1]["content"].as_str().unwrap();
        let json = user.split("Segments:\n").nth(1).unwrap();
        let segments: Vec<Segment> = serde_json::from_str(json).unwrap();
        segments.iter().map(|s| s.id).collect()
    }

    impl Transport for Fake {
        fn post(&self, request: &HttpRequest) -> Result<HttpResponse, String> {
            let n = {
                let mut calls = self.calls.lock().unwrap();
                calls.push(request.clone());
                calls.len()
            };
            Ok((self.script)(n, &ids_in(request)))
        }
    }

    fn reply(ids: &[i64]) -> HttpResponse {
        let segments: Vec<Value> = ids.iter().map(|id| json!({"id": id, "text": format!("T{id}")})).collect();
        let content = json!({"segments": segments}).to_string();
        let body = json!({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]});
        HttpResponse { status: 200, headers: vec![], body: body.to_string().into_bytes() }
    }

    fn status(code: u16, body: &str) -> HttpResponse {
        HttpResponse { status: code, headers: vec![], body: body.as_bytes().to_vec() }
    }

    fn source(n: i64) -> Vec<Segment> {
        (1..=n).map(|i| Segment::new(i, i as f64, i as f64 + 0.5, format!("line {i}"))).collect()
    }

    fn options() -> TranslateOptions {
        let mut o = TranslateOptions::new("groq/openai/gpt-oss-120b", "KEY");
        o.chunk_mode = ChunkMode::Safer;
        o
    }

    fn run(fake: &Fake, segments: &[Segment], existing: &[Segment]) -> (Result<Vec<Segment>, TranslationError>, Vec<Vec<Segment>>) {
        let mut partials = Vec::new();
        let result = Translator::new(fake).with_backoff_unit(Duration::from_millis(1)).translate(
            segments,
            &options(),
            existing,
            &AtomicBool::new(false),
            &mut |_| {},
            &mut |p| partials.push(p.to_vec()),
        );
        (result, partials)
    }

    #[test]
    fn translates_every_chunk_in_order() {
        let fake = Fake::new(|_, ids| reply(ids));
        let (result, partials) = run(&fake, &source(90), &[]);
        let out = result.unwrap();
        assert_eq!(out.len(), 90);
        assert!(out.iter().all(|s| s.text == format!("T{}", s.id)));
        assert_eq!(fake.count(), 3);
        assert_eq!(partials.last().unwrap().len(), 90);
    }

    #[test]
    fn existing_translations_are_kept_and_not_resent() {
        let fake = Fake::new(|_, ids| reply(ids));
        let existing = vec![Segment::new(99, 1.0, 1.5, "kept")];
        let (result, _) = run(&fake, &source(3), &existing);
        let out = result.unwrap();
        assert_eq!(out[0].text, "kept");
        let sent: Vec<i64> = fake.calls.lock().unwrap().iter().flat_map(ids_in).collect();
        assert_eq!(sent, vec![2, 3]);
    }

    #[test]
    fn later_chunks_carry_earlier_translations_as_context() {
        let fake = Fake::new(|_, ids| reply(ids));
        let mut o = options();
        o.parallelism = 1;
        Translator::new(&fake).translate(&source(50), &o, &[], &AtomicBool::new(false), &mut |_| {}, &mut |_| {}).unwrap();
        let second = &fake.calls.lock().unwrap()[1];
        assert!(second.body.contains("line 40 => T40"));
        assert!(!second.body.contains("line 32 => T32"));
        assert!(second.body.contains("line 33 => T33"));
    }

    #[test]
    fn transient_failures_are_retried() {
        let fake = Fake::new(|n, ids| if n < 3 { status(503, "{}") } else { reply(ids) });
        let (result, _) = run(&fake, &source(2), &[]);
        assert!(result.is_ok());
        assert_eq!(fake.count(), 3);
    }

    #[test]
    fn fatal_errors_stop_immediately() {
        let fake = Fake::new(|_, _| status(401, "{}"));
        let (result, _) = run(&fake, &source(2), &[]);
        assert!(matches!(result, Err(TranslationError::Fatal(_))));
        assert_eq!(fake.count(), 1);
    }

    #[test]
    fn bad_ids_split_the_chunk_until_it_succeeds() {
        // Any request for more than one segment drops the last id.
        let fake = Fake::new(|_, ids| if ids.len() > 1 { reply(&ids[..ids.len() - 1]) } else { reply(ids) });
        let (result, _) = run(&fake, &source(4), &[]);
        let out = result.unwrap();
        assert!(out.iter().all(|s| s.text == format!("T{}", s.id)));
    }

    #[test]
    fn too_large_skips_retries_and_splits() {
        let fake =
            Fake::new(
                |_, ids| {
                    if ids.len() > 2 {
                        status(400, r#"{"error":{"message":"maximum context length exceeded"}}"#)
                    } else {
                        reply(ids)
                    }
                },
            );
        let (result, _) = run(&fake, &source(4), &[]);
        assert!(result.is_ok());
        // One oversized attempt, then two halves.
        assert_eq!(fake.count(), 3);
    }

    #[test]
    fn a_failed_chunk_still_keeps_its_successful_siblings() {
        let fake = Fake::new(|_, ids| if ids.contains(&41) { status(401, "{}") } else { reply(ids) });
        let (result, partials) = run(&fake, &source(80), &[]);
        assert!(result.is_err());
        let saved = partials.last().unwrap();
        assert_eq!(saved.len(), 40);
        assert!(saved.iter().all(|s| s.id <= 40));
    }

    #[test]
    fn missing_key_fails_before_any_request() {
        let fake = Fake::new(|_, ids| reply(ids));
        let o = TranslateOptions::new("gpt-6.1-sol", "");
        let result = Translator::new(&fake).translate(&source(1), &o, &[], &AtomicBool::new(false), &mut |_| {}, &mut |_| {});
        assert!(matches!(result, Err(TranslationError::MissingApiKey(_))));
        assert_eq!(fake.count(), 0);
        // Local servers need no key.
        let o = TranslateOptions::new("local/qwen3", "");
        assert!(Translator::new(&fake).translate(&source(1), &o, &[], &AtomicBool::new(false), &mut |_| {}, &mut |_| {}).is_ok());
    }

    #[test]
    fn cancel_stops_the_run() {
        let fake = Fake::new(|_, ids| reply(ids));
        let result = Translator::new(&fake).translate(&source(5), &options(), &[], &AtomicBool::new(true), &mut |_| {}, &mut |_| {});
        assert!(matches!(result, Err(TranslationError::Canceled)));
        assert_eq!(fake.count(), 0);
    }

    #[test]
    fn empty_translations_keep_the_original_text() {
        let fake = Fake::new(|_, ids| {
            let segments: Vec<Value> = ids.iter().map(|id| json!({"id": id, "text": if *id == 2 { " " } else { "ok" }})).collect();
            let content = json!({"segments": segments}).to_string();
            status(200, &json!({"choices": [{"message": {"content": content}}]}).to_string())
        });
        let (result, _) = run(&fake, &source(2), &[]);
        let out = result.unwrap();
        assert_eq!(out[0].text, "ok");
        assert_eq!(out[1].text, "line 2");
    }
}
