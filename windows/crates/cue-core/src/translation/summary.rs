//! The spoiler-free intro summary, written by any translation model. Ports
//! `TranslationService.summarize` from Sources/Services/: one request with
//! a JSON-schema reply, and a fallback model tried only when the first one
//! declines the content.

use super::service::Transport;
use super::wire;
use super::{Provider, TranslationError};
use crate::Segment;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// How thorough the summary is. Stored as "brief"/"detailed", like the Mac.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SummaryDetail {
    #[default]
    Brief,
    Detailed,
}

impl SummaryDetail {
    pub fn parse(name: &str) -> Option<SummaryDetail> {
        match name.trim().to_ascii_lowercase().as_str() {
            "brief" => Some(SummaryDetail::Brief),
            "detailed" => Some(SummaryDetail::Detailed),
            _ => None,
        }
    }
}

/// One model with its own key and route, so a summary model that differs
/// from the translation model never borrows the wrong key.
#[derive(Debug, Clone)]
pub struct SummaryModel {
    pub model: String,
    pub provider: Provider,
    pub api_key: String,
    pub local_endpoint: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SummaryResult {
    pub summary: String,
    pub model: String,
    pub used_fallback: bool,
}

/// The output cap: a detailed summary is under 900 characters.
const MAX_OUTPUT_TOKENS: usize = 2_048;
/// Even a three-hour film fits; this only guards against absurd input.
const MAX_INPUT_CHARS: usize = 200_000;

pub fn instructions(detail: SummaryDetail, language: &str) -> String {
    match detail {
        SummaryDetail::Brief => format!(
            "You write spoiler-free introductions for films based on their subtitles.\n\
             Write 1-3 short sentences introducing the setting, main characters, and premise — like the blurb on the back of a DVD box.\n\
             Do not reveal plot developments beyond the opening act, twists, or the ending.\n\
             Write the introduction in {language}.\n\
             Keep it under 280 characters so it fits on screen as a subtitle.\n\
             Return JSON only in the shape {{\"summary\":\"...\"}}."
        ),
        SummaryDetail::Detailed => format!(
            "You write spoiler-free introductions for films based on their subtitles.\n\
             Write a detailed introduction of 5-8 sentences: the setting and era, the main characters and how they relate to each other, the premise that sets the story in motion, and the film's tone or genre — like the opening of a thoughtful review that gives nothing away.\n\
             Do not reveal plot developments beyond the opening act, twists, or the ending.\n\
             Write the introduction in {language}. Plain sentences only — no markdown, no headings, no lists.\n\
             Keep it under 900 characters; it will be shown as a sequence of subtitles.\n\
             Return JSON only in the shape {{\"summary\":\"...\"}}."
        ),
    }
}

pub fn summary_schema() -> Value {
    json!({
        "type": "object",
        "properties": {"summary": {"type": "string"}},
        "required": ["summary"],
        "additionalProperties": false
    })
}

pub fn parse_summary(raw: &str) -> Result<String, TranslationError> {
    #[derive(Deserialize)]
    struct Payload {
        summary: String,
    }
    let payload: Payload =
        serde_json::from_str(wire::extract_json_object(raw.trim())).map_err(|e| TranslationError::Decode(e.to_string()))?;
    let summary = payload.summary.trim();
    if summary.is_empty() {
        return Err(TranslationError::InvalidResponse);
    }
    Ok(summary.to_string())
}

/// The language a summary is written in: the translation's target when it
/// summarizes a translation, otherwise the subtitles' own.
pub fn summary_language(from_translation: bool, target_language: &str) -> String {
    let target = target_language.trim();
    match (from_translation, target.is_empty()) {
        (true, false) => target.to_string(),
        (true, true) => "English".into(),
        (false, _) => "the same language as the subtitles".into(),
    }
}

/// Writes the summary with `primary`, and with `fallback` only if `primary`
/// declined the content for a policy or safety reason.
pub fn summarize(
    transport: &dyn Transport,
    segments: &[Segment],
    language: &str,
    primary: &SummaryModel,
    fallback: Option<&SummaryModel>,
    detail: SummaryDetail,
) -> Result<SummaryResult, TranslationError> {
    match summarize_once(transport, segments, language, primary, detail) {
        Ok(summary) => Ok(SummaryResult { summary, model: primary.model.clone(), used_fallback: false }),
        Err(TranslationError::ContentRefused(_)) => {
            let fallback = fallback.filter(|f| f.model != primary.model || f.provider != primary.provider).ok_or_else(|| {
                TranslationError::ContentRefused(
                    "The summary model declined this film for a policy or safety reason. Choose a different summary fallback model in Settings."
                        .into(),
                )
            })?;
            let summary = summarize_once(transport, segments, language, fallback, detail)?;
            Ok(SummaryResult { summary, model: fallback.model.clone(), used_fallback: true })
        }
        Err(e) => Err(e),
    }
}

fn summarize_once(
    transport: &dyn Transport,
    segments: &[Segment],
    language: &str,
    model: &SummaryModel,
    detail: SummaryDetail,
) -> Result<String, TranslationError> {
    if model.provider.needs_api_key() && model.api_key.is_empty() {
        return Err(TranslationError::MissingApiKey(model.provider.label().into()));
    }
    let text: String = segments.iter().map(|s| s.text.as_str()).collect::<Vec<_>>().join("\n").chars().take(MAX_INPUT_CHARS).collect();
    let request = wire::make_request_with_budget(
        model.provider,
        &model.model,
        &model.api_key,
        &instructions(detail, language),
        &format!("Subtitles:\n{text}"),
        "movie_intro_summary",
        &summary_schema(),
        &model.local_endpoint,
        Some(MAX_OUTPUT_TOKENS),
    )?;
    let response = transport.post(&request).map_err(TranslationError::Transport)?;
    if !(200..300).contains(&response.status) {
        return Err(wire::classify_api_error(model.provider, &response.body, response.status, &model.model));
    }
    parse_summary(&wire::extract_output_text(model.provider, &response.body)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::translation::service::HttpResponse;
    use crate::translation::wire::HttpRequest;
    use std::sync::Mutex;

    struct Script {
        replies: Mutex<Vec<(u16, String)>>,
        seen: Mutex<Vec<HttpRequest>>,
    }

    impl Script {
        fn new(replies: &[(u16, &str)]) -> Self {
            Script { replies: Mutex::new(replies.iter().rev().map(|(s, b)| (*s, b.to_string())).collect()), seen: Mutex::new(Vec::new()) }
        }
    }

    impl Transport for Script {
        fn post(&self, request: &HttpRequest) -> Result<HttpResponse, String> {
            self.seen.lock().unwrap().push(request.clone());
            let (status, body) = self.replies.lock().unwrap().pop().expect("an unexpected request");
            Ok(HttpResponse { status, headers: Vec::new(), body: body.into_bytes() })
        }
    }

    fn model(name: &str, key: &str) -> SummaryModel {
        SummaryModel {
            model: name.into(),
            provider: Provider::infer(name),
            api_key: key.into(),
            local_endpoint: wire::DEFAULT_LOCAL_ENDPOINT.into(),
        }
    }

    fn chat(content: &str) -> String {
        json!({"choices": [{"message": {"content": content}}]}).to_string()
    }

    fn segments() -> Vec<Segment> {
        vec![Segment::new(1, 1.0, 2.0, "Hello there."), Segment::new(2, 3.0, 4.0, "Who are you?")]
    }

    #[test]
    fn prompts_match_the_mac() {
        let brief = instructions(SummaryDetail::Brief, "French");
        assert!(brief.contains("1-3 short sentences"));
        assert!(brief.contains("Write the introduction in French."));
        assert!(brief.ends_with("Return JSON only in the shape {\"summary\":\"...\"}."));
        assert!(instructions(SummaryDetail::Detailed, "English").contains("Keep it under 900 characters"));
        assert_eq!(SummaryDetail::parse(" Detailed "), Some(SummaryDetail::Detailed));
        assert_eq!(serde_json::to_string(&SummaryDetail::Brief).unwrap(), "\"brief\"");
    }

    #[test]
    fn replies_are_parsed_and_blank_ones_rejected() {
        assert_eq!(parse_summary("```json\n{\"summary\":\"  A tale. \"}\n```").unwrap(), "A tale.");
        assert!(parse_summary("{\"summary\":\"  \"}").is_err());
        assert!(parse_summary("no json").is_err());
    }

    #[test]
    fn languages_follow_the_document() {
        assert_eq!(summary_language(true, " Vietnamese "), "Vietnamese");
        assert_eq!(summary_language(true, ""), "English");
        assert_eq!(summary_language(false, "Vietnamese"), "the same language as the subtitles");
    }

    #[test]
    fn one_request_with_a_capped_budget() {
        let script = Script::new(&[(200, &chat("{\"summary\":\"Two strangers meet.\"}"))]);
        let result =
            summarize(&script, &segments(), "English", &model("groq/openai/gpt-oss-120b", "k"), None, SummaryDetail::Brief).unwrap();
        assert_eq!(
            result,
            SummaryResult { summary: "Two strangers meet.".into(), model: "groq/openai/gpt-oss-120b".into(), used_fallback: false }
        );
        let seen = script.seen.lock().unwrap();
        let body: Value = serde_json::from_str(&seen[0].body).unwrap();
        assert_eq!(body["max_tokens"], 2048);
        assert_eq!(body["response_format"]["json_schema"]["name"], "movie_intro_summary");
        assert!(body["messages"][1]["content"].as_str().unwrap().starts_with("Subtitles:\nHello there.\nWho are you?"));
    }

    #[test]
    fn a_refusal_falls_back_once_and_other_errors_do_not() {
        let refusal = json!({"choices": [{"message": {"refusal": "no"}}]}).to_string();
        let script = Script::new(&[(200, &refusal), (200, &chat("{\"summary\":\"Fine.\"}"))]);
        let result =
            summarize(&script, &segments(), "English", &model("groq/a", "k"), Some(&model("cerebras/b", "k2")), SummaryDetail::Brief)
                .unwrap();
        assert!(result.used_fallback);
        assert_eq!(result.model, "cerebras/b");

        // Same model as the fallback: nothing to try.
        let script = Script::new(&[(200, &refusal)]);
        let err = summarize(&script, &segments(), "English", &model("groq/a", "k"), Some(&model("groq/a", "k")), SummaryDetail::Brief)
            .unwrap_err();
        assert!(matches!(err, TranslationError::ContentRefused(m) if m.contains("summary fallback")));

        // A server error is not a refusal.
        let script = Script::new(&[(500, "oops")]);
        assert!(summarize(&script, &segments(), "English", &model("groq/a", "k"), Some(&model("cerebras/b", "k")), SummaryDetail::Brief)
            .is_err());
        assert_eq!(script.seen.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_missing_key_is_caught_before_any_request() {
        let script = Script::new(&[]);
        let err = summarize(&script, &segments(), "English", &model("gpt-5.5", ""), None, SummaryDetail::Brief).unwrap_err();
        assert!(matches!(err, TranslationError::MissingApiKey(_)));
    }
}
