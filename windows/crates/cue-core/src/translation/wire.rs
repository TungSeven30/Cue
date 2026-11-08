//! Provider wire formats: request building, reply parsing, and error
//! classification. Mirrors `TranslationService.makeRequest`,
//! `extractOutputText` and `classifyAPIError` in
//! Sources/Services/TranslationService.swift; the prompts, schema and error
//! sentences are the Mac app's, word for word.

use super::planner::estimated_tokens;
use super::{Provider, TranslationError};
use crate::Segment;
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const DEFAULT_PROMPT: &str = "You are a professional subtitle translator. Translate faithfully and naturally for the target audience.
Preserve meaning, tone, names, numbers, and cultural context. Keep each subtitle concise, readable, and aligned to the original timing.
Do not add explanations, notes, censorship, markdown, or extra segments.";

pub const DEFAULT_MODEL: &str = "gpt-6.1-sol";
pub const DEFAULT_LOCAL_ENDPOINT: &str = "http://localhost:1234/v1";

/// One outgoing call, independent of the HTTP library.
#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub timeout: Duration,
}

impl HttpRequest {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

/// `{"segments":[{"id":Int,"text":String}]}`, nothing else.
pub fn segments_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "segments": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "integer"},
                        "text": {"type": "string"}
                    },
                    "required": ["id", "text"],
                    "additionalProperties": false
                }
            }
        },
        "required": ["segments"],
        "additionalProperties": false
    })
}

/// A previously translated pair sent with a chunk for consistency.
#[derive(Debug, Clone, PartialEq)]
pub struct ContextPair {
    pub source: String,
    pub translation: String,
}

pub fn system_prompt(prompt: &str, source_language: &str, target_language: &str, chunk_number: usize, total_chunks: usize) -> String {
    format!(
        "{prompt}\n\n\
         Source language: {source_language}.\n\
         Target language: {target_language}.\n\
         Preserve segment count, ordering, ids, and timing alignment.\n\
         Keep lines concise for subtitles.\n\
         When earlier translated context is provided, keep terminology, names, tone, speaker register, and pronouns consistent with it. Never re-output context lines.\n\
         This is chunk {chunk_number} of {total_chunks}; do not mention chunking.\n\
         Return JSON only in the shape {{\"segments\":[{{\"id\":1,\"text\":\"...\"}}]}}."
    )
}

pub fn user_text(segments: &[Segment], context: &[ContextPair]) -> String {
    let mut text = String::new();
    if !context.is_empty() {
        let lines: Vec<String> = context.iter().map(|p| format!("{} => {}", p.source, p.translation)).collect();
        text.push_str("Already translated context from the preceding subtitles (for consistency only; do not include in the output):\n");
        text.push_str(&lines.join("\n"));
        text.push_str("\n\n\n");
    }
    text.push_str("Segments:\n");
    text.push_str(&serde_json::to_string(segments).unwrap_or_else(|_| "[]".into()));
    text
}

/// Three times the input estimate covers expansive target languages plus
/// JSON overhead; Chat Completions providers otherwise default to tiny
/// `max_tokens` values that truncate every chunk.
pub fn output_token_budget(user_text: &str) -> usize {
    (estimated_tokens(user_text) * 3).clamp(1_024, 16_000)
}

fn removing_routing_prefix(prefix: &str, model: &str) -> String {
    let trimmed = model.trim();
    if trimmed.to_lowercase().starts_with(prefix) {
        trimmed[prefix.len()..].to_string()
    } else {
        trimmed.to_string()
    }
}

/// `scheme://host[:port][/path]` with an http(s) scheme and a host. Returns
/// the base with `/v1` appended when no path was given (LM Studio shows the
/// address without it).
fn local_base(endpoint: &str) -> Option<String> {
    let mut base = endpoint.trim().to_string();
    if base.ends_with('/') {
        base.pop();
    }
    let (scheme, rest) = base.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("http") && !scheme.eq_ignore_ascii_case("https") {
        return None;
    }
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let host = authority.rsplit('@').next().unwrap_or("");
    let host = host.split(':').next().unwrap_or("");
    if host.is_empty() || host.contains(char::is_whitespace) {
        return None;
    }
    if authority_end == rest.len() {
        base.push_str("/v1");
    }
    Some(base)
}

fn chat_completions_body(model: &str, system: &str, user: &str, schema_name: &str, schema: &Value, max_tokens: usize) -> Value {
    json!({
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
        ],
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": schema_name, "strict": true, "schema": schema}
        },
        "max_tokens": max_tokens,
        "stream": false
    })
}

#[allow(clippy::too_many_arguments)]
pub fn make_request(
    provider: Provider,
    model: &str,
    api_key: &str,
    system: &str,
    user: &str,
    schema_name: &str,
    schema: &Value,
    local_endpoint: &str,
) -> Result<HttpRequest, TranslationError> {
    make_request_with_budget(provider, model, api_key, system, user, schema_name, schema, local_endpoint, None)
}

/// `make_request` with an explicit output cap; `None` sizes it from the
/// input like a translation chunk.
#[allow(clippy::too_many_arguments)]
pub fn make_request_with_budget(
    provider: Provider,
    model: &str,
    api_key: &str,
    system: &str,
    user: &str,
    schema_name: &str,
    schema: &Value,
    local_endpoint: &str,
    max_output_tokens: Option<usize>,
) -> Result<HttpRequest, TranslationError> {
    let budget = max_output_tokens.unwrap_or_else(|| output_token_budget(user));
    let mut headers: Vec<(String, String)> = Vec::new();
    let (url, body) = match provider {
        Provider::OpenAi => {
            headers.push(("Authorization".into(), format!("Bearer {api_key}")));
            let body = json!({
                "model": model,
                "input": [
                    {"role": "system", "content": [{"type": "input_text", "text": system}]},
                    {"role": "user", "content": [{"type": "input_text", "text": user}]}
                ],
                "text": {
                    "verbosity": "low",
                    "format": {"type": "json_schema", "name": schema_name, "strict": true, "schema": schema}
                }
            });
            ("https://api.openai.com/v1/responses".to_string(), body)
        }
        Provider::Anthropic => {
            headers.push(("x-api-key".into(), api_key.to_string()));
            headers.push(("anthropic-version".into(), "2023-06-01".into()));
            let body = json!({
                "model": model,
                "max_tokens": budget,
                "system": system,
                "messages": [{"role": "user", "content": user}],
                "output_config": {"format": {"type": "json_schema", "schema": schema}}
            });
            ("https://api.anthropic.com/v1/messages".to_string(), body)
        }
        Provider::Google => {
            // The endpoint already names "models/"; a pasted "models/gemini-…"
            // must not double it.
            let id = removing_routing_prefix("models/", model);
            if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || "-._".contains(c)) {
                return Err(TranslationError::Fatal(format!("The Gemini model name \"{model}\" is not a valid model id.")));
            }
            headers.push(("x-goog-api-key".into(), api_key.to_string()));
            let body = json!({
                "systemInstruction": {"parts": [{"text": system}]},
                "contents": [{"role": "user", "parts": [{"text": user}]}],
                "generationConfig": {"responseMimeType": "application/json", "responseJsonSchema": schema}
            });
            (format!("https://generativelanguage.googleapis.com/v1beta/models/{id}:generateContent"), body)
        }
        Provider::Local => {
            let Some(base) = local_base(local_endpoint) else {
                return Err(TranslationError::Fatal(format!(
                    "The local server URL \"{local_endpoint}\" is not a valid URL. Set it in Settings (e.g. http://localhost:1234/v1)."
                )));
            };
            // "local/" is routing only; an empty remainder is fine (LM Studio
            // ignores the model when one is loaded).
            let wire = removing_routing_prefix("local/", model);
            (format!("{base}/chat/completions"), chat_completions_body(&wire, system, user, schema_name, schema, budget))
        }
        Provider::OpenRouter | Provider::Groq | Provider::Cerebras => {
            let (url, prefix, example) = match provider {
                Provider::OpenRouter => {
                    headers.push(("HTTP-Referer".into(), "https://github.com/TungSeven30/Cue".into()));
                    headers.push(("X-Title".into(), "Cue".into()));
                    ("https://openrouter.ai/api/v1/chat/completions", "openrouter/", "openrouter/qwen/qwen3.8-max")
                }
                Provider::Groq => ("https://api.groq.com/openai/v1/chat/completions", "groq/", "groq/openai/gpt-oss-120b"),
                _ => ("https://api.cerebras.ai/v1/chat/completions", "cerebras/", "cerebras/gpt-oss-120b"),
            };
            headers.insert(0, ("Authorization".into(), format!("Bearer {api_key}")));
            let wire = removing_routing_prefix(prefix, model);
            if wire.is_empty() {
                return Err(TranslationError::Fatal(format!(
                    "Set a {} model id after the {prefix} prefix (e.g. {example}).",
                    provider.label()
                )));
            }
            (url.to_string(), chat_completions_body(&wire, system, user, schema_name, schema, budget))
        }
    };
    headers.push(("Content-Type".into(), "application/json".into()));
    // Large chunks on slow models outlast short timeouts; big local models
    // on big chunks outlast even the cloud ceiling.
    let timeout = Duration::from_secs(if provider == Provider::Local { 600 } else { 300 });
    Ok(HttpRequest { url, headers, body: body.to_string(), timeout })
}

#[derive(Deserialize)]
struct OpenAiEnvelope {
    output: Vec<OpenAiItem>,
    status: Option<String>,
    incomplete_details: Option<OpenAiIncomplete>,
}
#[derive(Deserialize)]
struct OpenAiIncomplete {
    reason: Option<String>,
}
#[derive(Deserialize)]
struct OpenAiItem {
    // Reasoning items carry no content key.
    content: Option<Vec<OpenAiContent>>,
}
#[derive(Deserialize)]
struct OpenAiContent {
    text: Option<String>,
    refusal: Option<String>,
}

#[derive(Deserialize)]
struct AnthropicEnvelope {
    content: Vec<AnthropicBlock>,
    stop_reason: Option<String>,
}
#[derive(Deserialize)]
struct AnthropicBlock {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiEnvelope {
    candidates: Option<Vec<GeminiCandidate>>,
    prompt_feedback: Option<GeminiFeedback>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiFeedback {
    block_reason: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiCandidate {
    content: Option<GeminiContent>,
    finish_reason: Option<String>,
}
#[derive(Deserialize)]
struct GeminiContent {
    parts: Option<Vec<GeminiPart>>,
}
#[derive(Deserialize)]
struct GeminiPart {
    text: Option<String>,
}

#[derive(Deserialize)]
struct ChatEnvelope {
    choices: Option<Vec<ChatChoice>>,
}
#[derive(Deserialize)]
struct ChatChoice {
    message: Option<ChatMessage>,
    finish_reason: Option<String>,
}
#[derive(Deserialize)]
struct ChatMessage {
    content: Option<String>,
    refusal: Option<String>,
    // Reasoning models in LM Studio can put the whole constrained answer here.
    reasoning_content: Option<String>,
}

fn decode<'a, T: Deserialize<'a>>(data: &'a [u8]) -> Result<T, TranslationError> {
    serde_json::from_slice(data).map_err(|e| TranslationError::Decode(e.to_string()))
}

const CUT_OFF: &str = "The model's reply was cut off at its output-token limit.";

fn is_gemini_policy_reason(reason: &str) -> bool {
    matches!(reason.to_uppercase().as_str(), "SAFETY" | "RECITATION" | "BLOCKLIST" | "PROHIBITED_CONTENT" | "SPII")
}

/// Pulls the model's text out of the provider envelope.
pub fn extract_output_text(provider: Provider, data: &[u8]) -> Result<String, TranslationError> {
    match provider {
        Provider::OpenAi => {
            let decoded: OpenAiEnvelope = decode(data)?;
            if decoded.status.as_deref() == Some("incomplete")
                && decoded.incomplete_details.as_ref().and_then(|d| d.reason.as_deref()) == Some("max_output_tokens")
            {
                return Err(TranslationError::ResponseTooLarge(CUT_OFF.into()));
            }
            let contents: Vec<&OpenAiContent> = decoded.output.iter().flat_map(|i| i.content.iter().flatten()).collect();
            if let Some(refusal) = contents.iter().filter_map(|c| c.refusal.as_deref()).find(|r| !r.trim().is_empty()) {
                return Err(TranslationError::ContentRefused(format!("OpenAI declined the content: {refusal}")));
            }
            Ok(contents.iter().filter_map(|c| c.text.as_deref()).collect())
        }
        Provider::Anthropic => {
            let decoded: AnthropicEnvelope = decode(data)?;
            match decoded.stop_reason.as_deref() {
                Some("max_tokens") => return Err(TranslationError::ResponseTooLarge(CUT_OFF.into())),
                Some("refusal") => {
                    return Err(TranslationError::ContentRefused(
                        "Anthropic declined the content for a policy or safety reason. Try a different model.".into(),
                    ))
                }
                _ => {}
            }
            Ok(decoded.content.iter().filter(|b| b.kind == "text").filter_map(|b| b.text.as_deref()).collect())
        }
        Provider::Google => {
            let decoded: GeminiEnvelope = decode(data)?;
            let candidates = decoded.candidates.unwrap_or_default();
            let first_finish = candidates.first().and_then(|c| c.finish_reason.clone());
            if first_finish.as_deref() == Some("MAX_TOKENS") {
                return Err(TranslationError::ResponseTooLarge(CUT_OFF.into()));
            }
            let block =
                decoded.prompt_feedback.and_then(|f| f.block_reason).or_else(|| first_finish.filter(|r| is_gemini_policy_reason(r)));
            if let Some(reason) = block {
                return Err(TranslationError::ContentRefused(format!(
                    "Google blocked the content for a policy or safety reason ({reason}). Try a different model."
                )));
            }
            Ok(candidates
                .iter()
                .filter_map(|c| c.content.as_ref().and_then(|c| c.parts.as_ref()))
                .flatten()
                .filter_map(|p| p.text.as_deref())
                .collect())
        }
        Provider::Local | Provider::OpenRouter | Provider::Groq | Provider::Cerebras => {
            let decoded: ChatEnvelope = decode(data)?;
            let Some(choice) = decoded.choices.and_then(|c| c.into_iter().next()) else {
                // Some local servers report errors as a 200 with an "error" body.
                let body: Value = serde_json::from_slice(data).unwrap_or(Value::Null);
                let message = body
                    .get("error")
                    .and_then(|e| e.as_str().map(str::to_string).or_else(|| e.get("message")?.as_str().map(str::to_string)));
                return Err(match message {
                    Some(m) => TranslationError::Api(format!("Local server error: {m}")),
                    None => TranslationError::InvalidResponse,
                });
            };
            if choice.finish_reason.as_deref() == Some("length") {
                return Err(TranslationError::ResponseTooLarge(CUT_OFF.into()));
            }
            let message = choice.message.unwrap_or(ChatMessage { content: None, refusal: None, reasoning_content: None });
            if let Some(refusal) = message.refusal.as_deref().map(str::trim).filter(|r| !r.is_empty()) {
                return Err(TranslationError::ContentRefused(format!("The model declined the content: {refusal}")));
            }
            [message.content, message.reasoning_content]
                .into_iter()
                .flatten()
                .map(|s| s.trim().to_string())
                .find(|s| !s.is_empty())
                .ok_or(TranslationError::InvalidResponse)
        }
    }
}

fn is_policy_refusal(message: Option<&str>, code: Option<&str>) -> bool {
    let policy_codes = ["content_filter", "content_policy_violation", "prohibited_content", "safety", "blocklist"];
    if let Some(code) = code {
        if policy_codes.contains(&code.trim().to_lowercase().as_str()) {
            return true;
        }
    }
    let text = [message, code].into_iter().flatten().collect::<Vec<_>>().join(" ").to_lowercase();
    [
        "content policy",
        "content_policy",
        "policy violation",
        "safety policy",
        "safety violation",
        "blocked for safety",
        "refusal",
        "refused",
        "blocked content",
        "prohibited_content",
        "blocklist",
    ]
    .iter()
    .any(|hint| text.contains(hint))
}

/// One actionable sentence per provider failure, with errors retrying
/// cannot fix marked fatal.
pub fn classify_api_error(provider: Provider, data: &[u8], status: u16, model: &str) -> TranslationError {
    let body: Value = serde_json::from_slice(data).unwrap_or(Value::Null);
    let error = body.get("error");
    let message = error.and_then(|e| e.get("message")).and_then(Value::as_str);
    let code = error.and_then(|e| e.get("code").and_then(Value::as_str).or_else(|| e.get("status").and_then(Value::as_str)));
    let name = provider.label();

    if is_policy_refusal(message, code) {
        return TranslationError::ContentRefused(format!(
            "{name} declined the content for a policy or safety reason: {}.",
            message.or(code).unwrap_or("request blocked")
        ));
    }
    match status {
        401 | 403 => return TranslationError::Fatal(format!("{name} rejected the API key ({status}). Check the key in Settings.")),
        402 => return TranslationError::Fatal(format!("{name} reports insufficient credits (402). Top up the account and try again.")),
        429 => {
            return TranslationError::Api(
                message
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("{name} rate limit or quota exceeded (429). Try again later or check billing.")),
            )
        }
        _ => {}
    }
    if status == 404 || code == Some("model_not_found") || code == Some("NOT_FOUND") {
        return TranslationError::Fatal(format!("{name} does not recognize the model \"{model}\". Set a valid model in Settings."));
    }
    if status == 400 {
        let lowered = message.unwrap_or("").to_lowercase();
        if ["token", "too long", "length", "exceed", "context"].iter().any(|h| lowered.contains(h)) {
            return TranslationError::ResponseTooLarge(format!(
                "{name} rejected the request as too large (400): {}.",
                message.unwrap_or("request too large")
            ));
        }
        return TranslationError::Fatal(format!(
            "{name} rejected the request (400): {}. Check the model in Settings supports structured JSON output.",
            message.unwrap_or("invalid request")
        ));
    }
    match message {
        Some(m) => TranslationError::Api(format!("{name} error ({status}): {m}")),
        None => TranslationError::Api(format!("{name} returned status {status}.")),
    }
}

/// `Retry-After` as a delay: either seconds or an IMF-fixdate. Only
/// positive, finite values count.
pub fn retry_after(value: Option<&str>, now: SystemTime) -> Option<Duration> {
    let raw = value?.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(seconds) = raw.parse::<f64>() {
        return (seconds.is_finite() && seconds > 0.0).then(|| Duration::from_secs_f64(seconds));
    }
    let target = parse_imf_fixdate(raw)?;
    let now = now.duration_since(UNIX_EPOCH).ok()?.as_secs() as i64;
    (target > now).then(|| Duration::from_secs((target - now) as u64))
}

/// "Sun, 06 Nov 1994 08:49:37 GMT" → Unix seconds.
fn parse_imf_fixdate(raw: &str) -> Option<i64> {
    let parts: Vec<&str> = raw.split_whitespace().collect();
    if parts.len() != 6 || !parts[5].eq_ignore_ascii_case("GMT") {
        return None;
    }
    let day: i64 = parts[1].parse().ok()?;
    let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        .iter()
        .position(|m| parts[2].eq_ignore_ascii_case(m))? as i64
        + 1;
    let year: i64 = parts[3].parse().ok()?;
    let hms: Vec<i64> = parts[4].split(':').map(|p| p.parse().ok()).collect::<Option<_>>()?;
    if hms.len() != 3 || !(1..=31).contains(&day) {
        return None;
    }
    // Days from civil (Howard Hinnant).
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hms[0] * 3600 + hms[1] * 60 + hms[2])
}

/// Strips code fences and any prose around the outermost JSON object.
pub fn extract_json_object(text: &str) -> &str {
    let mut trimmed = text.trim();
    if trimmed.starts_with("```") {
        trimmed = trimmed.trim_start_matches("```json").trim_start_matches("```JSON").trim_start_matches("```");
        trimmed = trimmed.trim_end_matches("```").trim();
    }
    match (trimmed.find('{'), trimmed.rfind('}')) {
        (Some(start), Some(end)) if start <= end => &trimmed[start..=end],
        _ => trimmed,
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct TranslatedSegment {
    pub id: i64,
    pub text: String,
}

#[derive(Deserialize)]
struct TranslatedPayload {
    segments: Vec<TranslatedSegment>,
}

pub fn parse_translated(raw: &str) -> Result<Vec<TranslatedSegment>, TranslationError> {
    let payload: TranslatedPayload = decode(extract_json_object(raw).as_bytes())?;
    Ok(payload.segments)
}

/// Ids must match exactly, and a duplicate may not mask a dropped one.
pub fn validate(translated: &[TranslatedSegment], expected: &[Segment]) -> Result<(), TranslationError> {
    use std::collections::BTreeSet;
    let want: BTreeSet<i64> = expected.iter().map(|s| s.id).collect();
    let got: BTreeSet<i64> = translated.iter().map(|s| s.id).collect();
    if want != got {
        let missing: Vec<i64> = want.difference(&got).copied().collect();
        let extra: Vec<i64> = got.difference(&want).copied().collect();
        return Err(TranslationError::ValidationFailed(format!(
            "Translation returned mismatched segment ids. Missing: {missing:?}. Extra: {extra:?}."
        )));
    }
    if translated.len() != expected.len() {
        return Err(TranslationError::ValidationFailed(format!(
            "Translation returned {} segment(s) for {} input segment(s) (duplicate ids).",
            translated.len(),
            expected.len()
        )));
    }
    Ok(())
}

/// The language named in the prompt: an explicit setting wins, otherwise
/// the transcription language code is spelled out.
pub fn source_language_name(translation_setting: &str, transcription_setting: &str) -> String {
    let explicit = translation_setting.trim();
    if !explicit.is_empty() && !explicit.eq_ignore_ascii_case("auto") {
        return explicit.to_string();
    }
    match transcription_setting.trim().to_lowercase().as_str() {
        "en" => "English".into(),
        "ja" => "Japanese".into(),
        "zh" => "Chinese".into(),
        "ko" => "Korean".into(),
        "es" => "Spanish".into(),
        "fr" => "French".into(),
        "de" => "German".into(),
        "id" => "Indonesian".into(),
        "th" => "Thai".into(),
        "vi" => "Vietnamese".into(),
        "" | "auto" => "the source language detected in the transcript".into(),
        _ => transcription_setting.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(req: &HttpRequest) -> Value {
        serde_json::from_str(&req.body).unwrap()
    }

    fn build(provider: Provider, model: &str) -> HttpRequest {
        make_request(provider, model, "KEY", "sys", "usr", "subtitle_translation", &segments_schema(), DEFAULT_LOCAL_ENDPOINT).unwrap()
    }

    #[test]
    fn openai_uses_the_responses_api_with_a_strict_schema() {
        let req = build(Provider::OpenAi, "gpt-6.1-sol");
        assert_eq!(req.url, "https://api.openai.com/v1/responses");
        assert_eq!(req.header("authorization"), Some("Bearer KEY"));
        let b = body(&req);
        assert_eq!(b["text"]["format"]["type"], "json_schema");
        assert_eq!(b["text"]["format"]["strict"], true);
        assert_eq!(b["input"][0]["content"][0]["text"], "sys");
        assert_eq!(req.timeout, Duration::from_secs(300));
    }

    #[test]
    fn anthropic_sends_version_and_output_budget() {
        let req = build(Provider::Anthropic, "claude-sonnet-5");
        assert_eq!(req.url, "https://api.anthropic.com/v1/messages");
        assert_eq!(req.header("x-api-key"), Some("KEY"));
        assert_eq!(req.header("anthropic-version"), Some("2023-06-01"));
        let b = body(&req);
        assert_eq!(b["max_tokens"], 1024);
        assert_eq!(b["output_config"]["format"]["type"], "json_schema");
    }

    #[test]
    fn gemini_strips_a_pasted_models_prefix() {
        let req = build(Provider::Google, "models/gemini-3-flash");
        assert_eq!(req.url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:generateContent");
        assert_eq!(body(&req)["generationConfig"]["responseMimeType"], "application/json");
        assert!(matches!(
            make_request(Provider::Google, "gemini 3", "k", "s", "u", "n", &segments_schema(), ""),
            Err(TranslationError::Fatal(_))
        ));
    }

    #[test]
    fn local_endpoint_gets_v1_only_when_no_path_is_given() {
        let mk = |endpoint: &str| {
            make_request(Provider::Local, "local/qwen3", "", "s", "u", "n", &segments_schema(), endpoint).map(|r| (r.url.clone(), r))
        };
        assert_eq!(mk("http://localhost:1234").unwrap().0, "http://localhost:1234/v1/chat/completions");
        assert_eq!(mk("http://localhost:1234/").unwrap().0, "http://localhost:1234/v1/chat/completions");
        assert_eq!(mk("http://10.0.0.5:8080/api/v1").unwrap().0, "http://10.0.0.5:8080/api/v1/chat/completions");
        let (_, req) = mk("http://localhost:1234/v1").unwrap();
        assert_eq!(body(&req)["model"], "qwen3");
        assert!(req.header("authorization").is_none());
        assert_eq!(req.timeout, Duration::from_secs(600));
        assert!(matches!(mk("ftp://x"), Err(TranslationError::Fatal(_))));
        assert!(matches!(mk("not a url"), Err(TranslationError::Fatal(_))));
    }

    #[test]
    fn gateways_strip_their_routing_prefix() {
        let req = build(Provider::OpenRouter, "openrouter/qwen/qwen3.8-max");
        assert_eq!(req.url, "https://openrouter.ai/api/v1/chat/completions");
        assert_eq!(req.header("x-title"), Some("Cue"));
        assert_eq!(body(&req)["model"], "qwen/qwen3.8-max");
        assert_eq!(body(&build(Provider::Groq, "groq/openai/gpt-oss-120b"))["model"], "openai/gpt-oss-120b");
        assert_eq!(build(Provider::Cerebras, "cerebras/gpt-oss-120b").url, "https://api.cerebras.ai/v1/chat/completions");
        assert!(matches!(
            make_request(Provider::Groq, "groq/", "k", "s", "u", "n", &segments_schema(), ""),
            Err(TranslationError::Fatal(_))
        ));
    }

    #[test]
    fn extracts_text_from_every_envelope() {
        let openai = br#"{"output":[{"type":"reasoning"},{"content":[{"text":"{\"a\":"},{"text":"1}"}]}],"status":"completed"}"#;
        assert_eq!(extract_output_text(Provider::OpenAi, openai).unwrap(), "{\"a\":1}");
        let anthropic = br#"{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}"#;
        assert_eq!(extract_output_text(Provider::Anthropic, anthropic).unwrap(), "hi");
        let gemini = br#"{"candidates":[{"content":{"parts":[{"text":"g"}]},"finishReason":"STOP"}]}"#;
        assert_eq!(extract_output_text(Provider::Google, gemini).unwrap(), "g");
        let chat = br#"{"choices":[{"message":{"content":"","reasoning_content":" r "},"finish_reason":"stop"}]}"#;
        assert_eq!(extract_output_text(Provider::Local, chat).unwrap(), "r");
    }

    #[test]
    fn truncation_and_refusals_are_classified() {
        let cut = br#"{"output":[],"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#;
        assert!(matches!(extract_output_text(Provider::OpenAi, cut), Err(TranslationError::ResponseTooLarge(_))));
        let refused = br#"{"content":[],"stop_reason":"refusal"}"#;
        assert!(matches!(extract_output_text(Provider::Anthropic, refused), Err(TranslationError::ContentRefused(_))));
        let blocked = br#"{"promptFeedback":{"blockReason":"SAFETY"}}"#;
        assert!(matches!(extract_output_text(Provider::Google, blocked), Err(TranslationError::ContentRefused(_))));
        let length = br#"{"choices":[{"message":{"content":"x"},"finish_reason":"length"}]}"#;
        assert!(matches!(extract_output_text(Provider::Groq, length), Err(TranslationError::ResponseTooLarge(_))));
        let lm_error = br#"{"error":"model not loaded"}"#;
        match extract_output_text(Provider::Local, lm_error) {
            Err(TranslationError::Api(m)) => assert_eq!(m, "Local server error: model not loaded"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn api_errors_map_to_actionable_kinds() {
        let p = Provider::OpenAi;
        assert!(matches!(classify_api_error(p, b"{}", 401, "m"), TranslationError::Fatal(_)));
        assert!(matches!(classify_api_error(p, b"{}", 402, "m"), TranslationError::Fatal(_)));
        assert!(matches!(classify_api_error(p, b"{}", 429, "m"), TranslationError::Api(_)));
        assert!(matches!(classify_api_error(p, b"{}", 404, "m"), TranslationError::Fatal(_)));
        let too_big = br#"{"error":{"message":"maximum context length exceeded"}}"#;
        assert!(matches!(classify_api_error(p, too_big, 400, "m"), TranslationError::ResponseTooLarge(_)));
        assert!(matches!(classify_api_error(p, br#"{"error":{"message":"bad"}}"#, 400, "m"), TranslationError::Fatal(_)));
        let policy = br#"{"error":{"message":"x","code":"content_filter"}}"#;
        assert!(matches!(classify_api_error(p, policy, 403, "m"), TranslationError::ContentRefused(_)));
        match classify_api_error(p, br#"{"error":{"message":"boom"}}"#, 503, "m") {
            TranslationError::Api(m) => assert_eq!(m, "OpenAI error (503): boom"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn retry_after_accepts_seconds_and_http_dates() {
        let now = UNIX_EPOCH + Duration::from_secs(784_111_777); // Sun, 06 Nov 1994 08:49:37 GMT
        assert_eq!(retry_after(Some("7"), now), Some(Duration::from_secs(7)));
        assert_eq!(retry_after(Some("0"), now), None);
        assert_eq!(retry_after(Some("-3"), now), None);
        assert_eq!(retry_after(Some("Sun, 06 Nov 1994 08:49:47 GMT"), now), Some(Duration::from_secs(10)));
        assert_eq!(retry_after(Some("Sun, 06 Nov 1994 08:49:30 GMT"), now), None);
        assert_eq!(retry_after(Some("soon"), now), None);
        assert_eq!(retry_after(None, now), None);
    }

    #[test]
    fn json_is_pulled_out_of_fences_and_prose() {
        assert_eq!(extract_json_object("```json\n{\"a\":1}\n```"), "{\"a\":1}");
        assert_eq!(extract_json_object("Sure! {\"a\":{\"b\":2}} done"), "{\"a\":{\"b\":2}}");
        assert_eq!(extract_json_object("nothing"), "nothing");
    }

    #[test]
    fn validation_rejects_missing_extra_and_duplicate_ids() {
        let expected = vec![Segment::new(1, 0.0, 1.0, "a"), Segment::new(2, 1.0, 2.0, "b")];
        let t = |ids: &[i64]| ids.iter().map(|&id| TranslatedSegment { id, text: "x".into() }).collect::<Vec<_>>();
        assert!(validate(&t(&[1, 2]), &expected).is_ok());
        assert!(validate(&t(&[1]), &expected).is_err());
        assert!(validate(&t(&[1, 2, 3]), &expected).is_err());
        assert!(validate(&t(&[1, 2, 2]), &expected).is_err());
    }

    #[test]
    fn prompt_carries_languages_chunk_and_context() {
        let system = system_prompt(DEFAULT_PROMPT, "Japanese", "Vietnamese", 2, 5);
        assert!(system.starts_with("You are a professional subtitle translator."));
        assert!(system.contains("Source language: Japanese.\nTarget language: Vietnamese."));
        assert!(system.contains("This is chunk 2 of 5; do not mention chunking."));
        assert!(system.ends_with(r#"{"segments":[{"id":1,"text":"..."}]}."#));
        let user =
            user_text(&[Segment::new(3, 0.0, 1.0, "やあ")], &[ContextPair { source: "こんにちは".into(), translation: "Xin chào".into() }]);
        assert!(user.contains("こんにちは => Xin chào\n\n\nSegments:\n[{\"id\":3,"));
        assert_eq!(source_language_name("auto", "ja"), "Japanese");
        assert_eq!(source_language_name("Thai", "ja"), "Thai");
        assert_eq!(source_language_name("", ""), "the source language detected in the transcript");
    }
}
