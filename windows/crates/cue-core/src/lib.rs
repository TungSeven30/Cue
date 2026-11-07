//! Platform-neutral core of Cue for Windows.
//!
//! Everything here mirrors a piece of the macOS app (named in each module's
//! docs) so that both apps produce the same transcripts and subtitle files
//! from the same input. Nothing in this crate touches a GPU or a UI.

pub mod audio;
pub mod chunk_planner;
pub mod credentials;
pub mod export;
pub mod jobs;
pub mod models;
pub mod paths;
pub mod postprocess;
pub mod segment;
pub mod subtitle;
pub mod translation;

pub use segment::Segment;
