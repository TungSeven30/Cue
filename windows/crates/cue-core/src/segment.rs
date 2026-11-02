//! Mirrors `TranscriptionSegment` (Sources/Models/TranscriptionSegment.swift).
//! Field names and JSON shape match, so job files and JSON exports are
//! interchangeable between the macOS and Windows apps.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    pub id: i64,
    pub start: f64,
    pub end: f64,
    pub text: String,
}

impl Segment {
    pub fn new(id: i64, start: f64, end: f64, text: impl Into<String>) -> Self {
        Self { id, start, end, text: text.into() }
    }

    pub fn duration(&self) -> f64 {
        self.end - self.start
    }
}
