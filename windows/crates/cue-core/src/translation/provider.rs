//! Mirrors `TranslationProvider` (Sources/Services/TranslationService.swift):
//! the provider is inferred from the model name, so one "model" setting picks
//! both the model and the API.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Provider {
    OpenAi,
    Anthropic,
    Google,
    /// An OpenAI-compatible server on localhost or the LAN (LM Studio,
    /// Ollama, llama.cpp server). Selected by the "local/" prefix; no key.
    Local,
    /// OpenRouter's gateway. "openrouter/<catalog id>".
    OpenRouter,
    /// GroqCloud. "groq/<model id>".
    Groq,
    /// Cerebras Inference. "cerebras/<model id>".
    Cerebras,
}

impl Provider {
    pub const ALL: [Provider; 7] = [
        Provider::OpenAi,
        Provider::Anthropic,
        Provider::Google,
        Provider::Local,
        Provider::OpenRouter,
        Provider::Groq,
        Provider::Cerebras,
    ];

    pub fn infer(model: &str) -> Provider {
        let normalized = model.trim().to_lowercase();
        if normalized.starts_with("claude") {
            Provider::Anthropic
        } else if normalized.starts_with("gemini") || normalized.starts_with("models/gemini") {
            Provider::Google
        } else if normalized.starts_with("local/") {
            Provider::Local
        } else if normalized.starts_with("openrouter/") {
            Provider::OpenRouter
        } else if normalized.starts_with("groq/") {
            Provider::Groq
        } else if normalized.starts_with("cerebras/") {
            Provider::Cerebras
        } else {
            Provider::OpenAi
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Provider::OpenAi => "OpenAI",
            Provider::Anthropic => "Anthropic",
            Provider::Google => "Google",
            Provider::Local => "Local server",
            Provider::OpenRouter => "OpenRouter",
            Provider::Groq => "Groq",
            Provider::Cerebras => "Cerebras",
        }
    }

    /// Short, stable name used on the command line and as the credential id.
    pub fn slug(self) -> &'static str {
        match self {
            Provider::OpenAi => "openai",
            Provider::Anthropic => "anthropic",
            Provider::Google => "google",
            Provider::Local => "local",
            Provider::OpenRouter => "openrouter",
            Provider::Groq => "groq",
            Provider::Cerebras => "cerebras",
        }
    }

    pub fn from_slug(slug: &str) -> Option<Provider> {
        Provider::ALL.into_iter().find(|p| p.slug().eq_ignore_ascii_case(slug.trim()))
    }

    pub fn needs_api_key(self) -> bool {
        self != Provider::Local
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn infers_provider_from_model_name() {
        assert_eq!(Provider::infer("gpt-6.1-sol"), Provider::OpenAi);
        assert_eq!(Provider::infer(" Claude-sonnet-5 "), Provider::Anthropic);
        assert_eq!(Provider::infer("gemini-3-pro"), Provider::Google);
        assert_eq!(Provider::infer("models/gemini-3-flash"), Provider::Google);
        assert_eq!(Provider::infer("local/qwen3"), Provider::Local);
        assert_eq!(Provider::infer("openrouter/qwen/qwen3.8-max"), Provider::OpenRouter);
        assert_eq!(Provider::infer("groq/openai/gpt-oss-120b"), Provider::Groq);
        assert_eq!(Provider::infer("cerebras/gpt-oss-120b"), Provider::Cerebras);
    }

    #[test]
    fn slugs_round_trip() {
        for p in Provider::ALL {
            assert_eq!(Provider::from_slug(p.slug()), Some(p));
        }
        assert_eq!(Provider::from_slug("OpenAI"), Some(Provider::OpenAi));
        assert_eq!(Provider::from_slug("nope"), None);
    }
}
