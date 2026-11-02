//! Whisper model catalog and downloader. Mirrors `ModelDownloader`: the same
//! immutable Hugging Face revision, file names, sizes and SHA-256 hashes, so a
//! model file is identical on both platforms.
//!
//! Downloads stream to `<name>.part` and resume with an HTTP Range request
//! after an interruption. A finished file is hashed once; a small
//! `<name>.verified` stamp (hash, size, mtime) lets later runs skip
//! re-hashing a 1.6 GB file.

use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::SystemTime;

pub const MODEL_REVISION: &str = "5359861c739e955e79d9a303bcbc70fb988958b1";
pub const DEFAULT_MODEL: &str = "ggml-large-v3-turbo-q5_0.bin";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelArtifact {
    pub name: &'static str,
    pub label: &'static str,
    pub byte_count: u64,
    pub sha256: &'static str,
}

pub const CATALOG: [ModelArtifact; 6] = [
    ModelArtifact {
        name: "ggml-large-v3-turbo-q5_0.bin",
        label: "Large v3 Turbo (quantized, recommended)",
        byte_count: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
    },
    ModelArtifact {
        name: "ggml-large-v3-turbo.bin",
        label: "Large v3 Turbo",
        byte_count: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    },
    ModelArtifact {
        name: "ggml-medium.bin",
        label: "Medium",
        byte_count: 1_533_763_059,
        sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
    },
    ModelArtifact {
        name: "ggml-small.bin",
        label: "Small",
        byte_count: 487_601_967,
        sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
    },
    ModelArtifact {
        name: "ggml-base.bin",
        label: "Base",
        byte_count: 147_951_465,
        sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
    },
    ModelArtifact {
        name: "ggml-tiny.bin",
        label: "Tiny",
        byte_count: 77_691_713,
        sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
    },
];

/// Find a catalog entry by file name or short alias ("tiny", "large-v3-turbo-q5_0").
pub fn artifact(name: &str) -> Option<&'static ModelArtifact> {
    let wanted = name.trim();
    CATALOG.iter().find(|a| a.name == wanted || a.name.trim_start_matches("ggml-").trim_end_matches(".bin") == wanted)
}

pub fn source_url(artifact: &ModelArtifact) -> String {
    format!("https://huggingface.co/ggerganov/whisper.cpp/resolve/{MODEL_REVISION}/{}", artifact.name)
}

#[derive(Debug, thiserror::Error)]
pub enum ModelError {
    #[error("Unknown model \"{0}\". Run `cue models` to list them.")]
    Unknown(String),
    #[error("Download failed: {0}")]
    Network(String),
    #[error("The downloaded model failed its integrity check; it was deleted. Try again.")]
    ChecksumMismatch,
    #[error("Canceled.")]
    Canceled,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ModelProgress {
    /// 0–1 of the download.
    Downloading(f64),
    Verifying,
}

pub struct ModelStore {
    dir: PathBuf,
}

impl ModelStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    pub fn default_location() -> Self {
        Self::new(crate::paths::models_dir())
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn path_for(&self, artifact: &ModelArtifact) -> PathBuf {
        self.dir.join(artifact.name)
    }

    fn stamp_path(&self, artifact: &ModelArtifact) -> PathBuf {
        self.dir.join(format!("{}.verified", artifact.name))
    }

    /// Installed means present, the right size, and stamped as verified for
    /// its current size and mtime.
    pub fn is_installed(&self, artifact: &ModelArtifact) -> bool {
        let path = self.path_for(artifact);
        let Ok(meta) = std::fs::metadata(&path) else { return false };
        meta.len() == artifact.byte_count
            && std::fs::read_to_string(self.stamp_path(artifact)).ok().as_deref() == Some(stamp(artifact, &meta).as_str())
    }

    /// Return the model's path, downloading and verifying it first if needed.
    pub fn ensure_installed(
        &self,
        name: &str,
        cancel: &AtomicBool,
        on_progress: &mut dyn FnMut(ModelProgress),
    ) -> Result<PathBuf, ModelError> {
        let artifact = artifact(name).ok_or_else(|| ModelError::Unknown(name.to_string()))?;
        let path = self.path_for(artifact);
        if self.is_installed(artifact) {
            return Ok(path);
        }
        std::fs::create_dir_all(&self.dir)?;
        // A present file of the right size (copied in by hand, or from a
        // run that died before stamping) only needs verifying.
        if std::fs::metadata(&path).map(|m| m.len() == artifact.byte_count).unwrap_or(false) {
            on_progress(ModelProgress::Verifying);
            if sha256_file(&path, cancel)? == artifact.sha256 {
                self.write_stamp(artifact, &path)?;
                return Ok(path);
            }
            std::fs::remove_file(&path)?;
        }
        let part = self.dir.join(format!("{}.part", artifact.name));
        // A complete part means an earlier run finished downloading but was
        // stopped while hashing: verify it rather than fetching it again.
        if std::fs::metadata(&part).map(|m| m.len() != artifact.byte_count).unwrap_or(true) {
            download_resumable(&source_url(artifact), &part, artifact.byte_count, cancel, on_progress)?;
        }
        on_progress(ModelProgress::Verifying);
        if sha256_file(&part, cancel)? != artifact.sha256 {
            let _ = std::fs::remove_file(&part);
            return Err(ModelError::ChecksumMismatch);
        }
        std::fs::rename(&part, &path)?;
        self.write_stamp(artifact, &path)?;
        Ok(path)
    }

    fn write_stamp(&self, artifact: &ModelArtifact, path: &Path) -> std::io::Result<()> {
        let meta = std::fs::metadata(path)?;
        std::fs::write(self.stamp_path(artifact), stamp(artifact, &meta))
    }

    pub fn remove(&self, artifact: &ModelArtifact) -> std::io::Result<()> {
        for p in [self.path_for(artifact), self.stamp_path(artifact), self.dir.join(format!("{}.part", artifact.name))] {
            match std::fs::remove_file(p) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
                _ => {}
            }
        }
        Ok(())
    }
}

fn stamp(artifact: &ModelArtifact, meta: &std::fs::Metadata) -> String {
    let mtime = meta.modified().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).map(|d| d.as_nanos()).unwrap_or(0);
    format!("{} {} {}", artifact.sha256, meta.len(), mtime)
}

pub fn sha256_file(path: &Path, cancel: &AtomicBool) -> Result<String, ModelError> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(ModelError::Canceled);
        }
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// HTTP agent that honours HTTPS_PROXY and the OS certificate store, which
/// is what corporate proxies on Windows rely on.
pub fn http_agent() -> ureq::Agent {
    use ureq::tls::{RootCerts, TlsConfig};
    ureq::Agent::config_builder()
        .tls_config(TlsConfig::builder().root_certs(RootCerts::PlatformVerifier).build())
        .http_status_as_error(false)
        .build()
        .into()
}

fn download_resumable(
    url: &str,
    part: &Path,
    expected: u64,
    cancel: &AtomicBool,
    on_progress: &mut dyn FnMut(ModelProgress),
) -> Result<(), ModelError> {
    let mut have = std::fs::metadata(part).map(|m| m.len()).unwrap_or(0);
    if have > expected {
        // An oversized leftover cannot be resumed; start over.
        std::fs::remove_file(part)?;
        have = 0;
    }
    let agent = http_agent();
    let mut request = agent.get(url);
    if have > 0 {
        request = request.header("Range", format!("bytes={have}-"));
    }
    let response = request.call().map_err(|e| ModelError::Network(e.to_string()))?;
    let status = response.status().as_u16();
    let mut file = match status {
        206 => OpenOptions::new().append(true).open(part)?,
        200 => {
            have = 0;
            File::create(part)?
        }
        other => return Err(ModelError::Network(format!("server answered HTTP {other}"))),
    };
    let mut body = response.into_body().into_reader();
    let mut buf = vec![0u8; 1 << 16];
    let mut done = have;
    let mut last_reported = -1.0;
    loop {
        if cancel.load(Ordering::Relaxed) {
            file.flush()?;
            return Err(ModelError::Canceled);
        }
        let n = body.read(&mut buf).map_err(|e| ModelError::Network(e.to_string()))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])?;
        done += n as u64;
        let fraction = (done as f64 / expected as f64).min(1.0);
        if fraction - last_reported >= 0.01 {
            last_reported = fraction;
            on_progress(ModelProgress::Downloading(fraction));
        }
    }
    file.flush()?;
    if done != expected {
        return Err(ModelError::Network(format!("connection closed after {done} of {expected} bytes; run again to resume")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_matches_macos_and_aliases_resolve() {
        assert_eq!(artifact(DEFAULT_MODEL).unwrap().byte_count, 574_041_195);
        assert_eq!(artifact("tiny").unwrap().name, "ggml-tiny.bin");
        assert_eq!(artifact("large-v3-turbo-q5_0").unwrap().name, DEFAULT_MODEL);
        assert!(artifact("nope").is_none());
        assert!(source_url(&CATALOG[0]).contains(MODEL_REVISION));
    }

    #[test]
    fn hand_copied_file_is_verified_then_stamped() {
        let dir = tempfile::tempdir().unwrap();
        let store = ModelStore::new(dir.path());
        // A fake artifact whose bytes we control.
        let fake = ModelArtifact {
            name: "ggml-tiny.bin",
            label: "",
            byte_count: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        };
        std::fs::write(store.path_for(&fake), b"abc").unwrap();
        assert!(!store.is_installed(&fake));
        assert_eq!(sha256_file(&store.path_for(&fake), &AtomicBool::new(false)).unwrap(), fake.sha256);
        store.write_stamp(&fake, &store.path_for(&fake)).unwrap();
        assert!(store.is_installed(&fake));
        store.remove(&fake).unwrap();
        assert!(!store.is_installed(&fake));
    }

    #[test]
    fn complete_part_is_verified_instead_of_redownloaded() {
        let dir = tempfile::tempdir().unwrap();
        let store = ModelStore::new(dir.path());
        // Real catalog entry, but the network would fail in tests: success
        // proves no download was attempted for a complete part.
        let tiny = artifact("tiny").unwrap();
        let part = dir.path().join(format!("{}.part", tiny.name));
        let f = File::create(&part).unwrap();
        f.set_len(tiny.byte_count).unwrap();
        let err = store.ensure_installed("tiny", &AtomicBool::new(false), &mut |_| {}).unwrap_err();
        // Zero bytes do not match the real hash, so it fails the check (and
        // is deleted) rather than reaching the network.
        assert!(matches!(err, ModelError::ChecksumMismatch), "{err}");
        assert!(!part.exists());
    }

    #[test]
    fn unknown_model_is_a_clear_error() {
        let dir = tempfile::tempdir().unwrap();
        let err = ModelStore::new(dir.path()).ensure_installed("huge", &AtomicBool::new(false), &mut |_| {}).unwrap_err();
        assert!(err.to_string().contains("cue models"));
    }
}
