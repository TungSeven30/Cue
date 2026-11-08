//! Cloud and local LLM translation over direct HTTPS. Ports
//! `TranslationService`, `TranslationBatchPlanner` and
//! `TranslationReconciliation` from Sources/Services/.

mod planner;
mod provider;
mod reconcile;
mod service;
mod summary;
pub mod wire;

pub use planner::{estimated_tokens, pending_chunks, ChunkMode};
pub use provider::Provider;
pub use reconcile::{aligned_translations, bilingual_segments};
pub use service::{HttpResponse, Progress, TranslateOptions, Translator, Transport, UreqTransport};
pub use summary::{summarize, summary_language, SummaryDetail, SummaryModel, SummaryResult};
pub use wire::{DEFAULT_LOCAL_ENDPOINT, DEFAULT_MODEL, DEFAULT_PROMPT};

#[derive(Debug, Clone, thiserror::Error)]
pub enum TranslationError {
    #[error("Add an {0} API key before using this model.")]
    MissingApiKey(String),
    #[error("The model response could not be parsed.")]
    InvalidResponse,
    #[error("{0}")]
    Api(String),
    /// Retrying cannot fix it: bad key, unknown model, malformed request.
    #[error("{0}")]
    Fatal(String),
    /// The provider declined the content for a policy or safety reason.
    #[error("{0}")]
    ContentRefused(String),
    #[error("{0}")]
    ValidationFailed(String),
    /// Too large for the model's limits; splitting the chunk can succeed.
    #[error("{0}")]
    ResponseTooLarge(String),
    /// The reply was not the JSON we asked for.
    #[error("The model response could not be parsed: {0}")]
    Decode(String),
    /// The request never got an HTTP answer.
    #[error("Network error: {0}")]
    Transport(String),
    #[error("Translation was canceled.")]
    Canceled,
}

impl TranslationError {
    /// Worth halving the chunk: size limits and structurally wrong replies.
    fn is_splittable(&self) -> bool {
        matches!(
            self,
            TranslationError::Decode(_)
                | TranslationError::ValidationFailed(_)
                | TranslationError::ResponseTooLarge(_)
                | TranslationError::InvalidResponse
        )
    }

    /// Retrying the same request cannot help.
    fn is_final(&self) -> bool {
        matches!(self, TranslationError::Fatal(_) | TranslationError::ContentRefused(_) | TranslationError::Canceled)
    }
}
