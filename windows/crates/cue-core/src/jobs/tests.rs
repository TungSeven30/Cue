use super::*;
use chrono::{TimeZone, Utc};
use serde_json::{json, Value};

/// Shaped exactly like a file the Mac's JobStore writes: sorted keys,
/// whole-second ISO dates, nil optionals omitted, plus fields Windows does
/// not model yet (folders, imported sources, Qwen settings).
fn mac_job(id: &str, status: &str, order: f64) -> Value {
    json!({
        "createdAt": "2026-10-01T08:00:00Z",
        "folderID": "6F1D2C1B-0000-4000-8000-000000000001",
        "id": id,
        "importedTranscriptSource": {
            "didBackup": false, "fileSize": 120, "format": "srt",
            "importedAt": "2026-10-01T08:01:00Z", "modifiedAt": "2026-10-01T07:59:00Z",
            "modifiedAtReferenceSeconds": 781_001_940.25, "path": "/Users/a/movie.srt", "syncPaused": false
        },
        "log": "Choose a video to begin.\n",
        "orderIndex": order,
        "origin": "watchFolder",
        "overrides": {"translationTargetLanguage": "Vietnamese"},
        "partialTranscriptSegments": [],
        "partialTranslatedSegments": [],
        "progress": {"detail": "Transcribing", "fraction": 0.5, "stage": "transcribing"},
        "settings": {
            "beamSize": 5, "bestOf": 5, "maxMergeGap": 0.45, "mergeShortSegments": true,
            "minSegmentDuration": 0.7, "noSpeechThreshold": 0.6, "openAIModel": "gpt-6.1-sol",
            "preprocessAudio": true, "qwenContext": "", "qwenProcessingVersion": 1,
            "removeEmptySegments": true, "removeRepeatedText": true, "sourceLanguage": "ja",
            "temperature": 0, "transcriptionPreset": "builtIn", "transcriptionProcessingVersion": 4,
            "transcriptionQualityPreset": "balanced", "translationChunkMode": "balanced",
            "translationParallelism": 2, "translationSourceLanguage": "auto",
            "translationTargetLanguage": "English", "vadFilter": true,
            "whisperBackend": "whisper-cpp", "whisperModel": "large-v3-turbo-q5_0"
        },
        "sourceFingerprint": "/Users/a/movie.mkv|10|1.0",
        "sourcePath": "/Users/a/movie.mkv",
        "status": status,
        "transcriptSegments": [{"end": 1.5, "id": 1, "start": 0, "text": "こんにちは"}],
        "transcriptionResumeThrough": 0,
        "translatedSegments": [],
        "updatedAt": "2026-10-02T09:30:00Z"
    })
}

fn numbers_as_f64(v: Value) -> Value {
    match v {
        Value::Number(n) => json!(n.as_f64().unwrap()),
        Value::Array(a) => Value::Array(a.into_iter().map(numbers_as_f64).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, numbers_as_f64(v))).collect()),
        other => other,
    }
}

fn write(store: &JobStore, name: &str, value: &Value) {
    std::fs::create_dir_all(store.dir()).unwrap();
    std::fs::write(store.dir().join(name), serde_json::to_string(value).unwrap()).unwrap();
}

#[test]
fn mac_job_files_load_and_save_back_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let store = JobStore::new(dir.path());
    let original = mac_job("A1B2C3D4-0000-4000-8000-000000000001", "transcriptionComplete", -1.0);
    write(&store, "A1B2C3D4-0000-4000-8000-000000000001.json", &original);

    let snapshot = store.load();
    assert!(snapshot.failures.is_empty(), "{:?}", snapshot.failures);
    let job = &snapshot.jobs[0];
    assert_eq!(job.status, JobStatus::TranscriptionComplete);
    assert_eq!(job.origin, JobOrigin::WatchFolder);
    assert_eq!(job.settings.translation_model, "gpt-6.1-sol");
    assert_eq!(job.transcript_segments[0].text, "こんにちは");
    assert!(job.extra.contains_key("folderID"));
    assert!(job.settings.extra.contains_key("qwenContext"));

    store.save(job).unwrap();
    let written: Value = serde_json::from_str(&std::fs::read_to_string(store.file_for(&job.id)).unwrap()).unwrap();
    // Swift writes 0.0 as `0`; both spellings decode on either side.
    assert_eq!(numbers_as_f64(written), numbers_as_f64(original), "every Mac field must survive a Windows save");
}

#[test]
fn dates_are_whole_seconds_and_keys_sorted() {
    let dir = tempfile::tempdir().unwrap();
    let store = JobStore::new(dir.path());
    let now = Utc.with_ymd_and_hms(2026, 11, 7, 6, 2, 59).unwrap() + chrono::Duration::milliseconds(750);
    let settings: JobSettings = serde_json::from_value(mac_job("X", "idle", 0.0)["settings"].clone()).unwrap();
    let job = Job::new(std::path::Path::new("C:/videos/a.mp4"), settings, now);
    store.save(&job).unwrap();
    let text = std::fs::read_to_string(store.file_for(&job.id)).unwrap();
    assert!(text.contains("\"createdAt\":\"2026-11-07T06:02:59Z\""), "{text}");
    assert!(text.find("\"createdAt\"").unwrap() < text.find("\"id\"").unwrap());
    assert_eq!(job.id, job.id.to_uppercase());
    assert_eq!(job.title(), "a");
}

#[test]
fn running_jobs_are_canceled_and_corrupt_files_preserved() {
    let dir = tempfile::tempdir().unwrap();
    let store = JobStore::new(dir.path());
    write(&store, "A.json", &mac_job("A", "transcribing", 0.0));
    std::fs::write(store.dir().join("B.json"), "{ not json").unwrap();
    let mut duplicate = mac_job("C", "idle", 0.0);
    duplicate["transcriptSegments"] = json!([{"id": 1, "start": 0, "end": 1, "text": "a"}, {"id": 1, "start": 1, "end": 2, "text": "b"}]);
    write(&store, "C.json", &duplicate);

    let snapshot = store.load();
    assert_eq!(snapshot.jobs.len(), 1);
    assert_eq!(snapshot.jobs[0].status, JobStatus::Canceled);
    assert!(snapshot.jobs[0].log.ends_with("marked as canceled.\n"));
    assert_eq!(snapshot.failures.len(), 2);
    assert!(store.dir().join("B.corrupt.json").exists());
    assert!(snapshot.failures[1].contains("duplicate cue IDs"));
    // A second load ignores the quarantined copies.
    assert_eq!(store.load().failures.len(), 2);
}

#[test]
fn old_files_without_order_index_or_partials_still_load() {
    let dir = tempfile::tempdir().unwrap();
    let store = JobStore::new(dir.path());
    let mut old = mac_job("OLD", "idle", 0.0);
    for key in ["orderIndex", "partialTranscriptSegments", "partialTranslatedSegments", "origin", "overrides", "sourceFingerprint"] {
        old.as_object_mut().unwrap().remove(key);
    }
    old["orderIndex"] = json!("nan");
    write(&store, "OLD.json", &old);
    let job = store.load().jobs.remove(0);
    assert_eq!(job.order_index, -(Utc.with_ymd_and_hms(2026, 10, 1, 8, 0, 0).unwrap().timestamp() as f64));
    assert_eq!(job.origin, JobOrigin::Manual);
}

#[test]
fn scheduler_picks_by_slot_and_queue_position() {
    let job = |id: &str, status: &str, order: f64, transcript: bool| {
        let mut v = mac_job(id, status, order);
        if !transcript {
            v["transcriptSegments"] = json!([]);
        }
        serde_json::from_value::<Job>(v).unwrap()
    };
    let mut archived = job("Z", "queued", -10.0, false);
    archived.archived_at = Some(Utc::now());
    let jobs = vec![
        job("A", "queued", 3.0, false),
        job("B", "queued", 1.0, false),
        job("C", "queued", 0.0, true),
        job("D", "idle", -5.0, false),
        archived,
    ];
    assert_eq!(next_gpu_job(&jobs, false, false).map(|j| j.id.as_str()), Some("B"));
    assert_eq!(next_translation_job(&jobs, false, false).map(|j| j.id.as_str()), Some("C"));
    assert!(next_gpu_job(&jobs, true, false).is_none());
    assert!(next_translation_job(&jobs, false, true).is_none());
}

#[test]
fn translation_runs_never_overwrite_transcript_settings() {
    let base: JobSettings = serde_json::from_value(mac_job("X", "idle", 0.0)["settings"].clone()).unwrap();
    let mut other = base.clone();
    other.whisper_model = "tiny".into();
    other.translation_model = "claude-sonnet-5".into();
    other.translation_target_language = "German".into();
    let merged = base.updating_translation_fields(&other);
    assert_eq!(merged.whisper_model, base.whisper_model);
    assert_eq!(merged.translation_model, "claude-sonnet-5");
    assert_eq!(merged.translation_target_language, "German");
}
