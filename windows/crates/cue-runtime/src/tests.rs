use super::*;
use cue_core::translation::wire::HttpRequest;
use cue_core::translation::HttpResponse;
use std::sync::mpsc::{channel, Receiver};

/// Emits two streamed batches and a resume point, then returns the
/// transcript; or waits for cancel when `block` is set.
struct FakeTranscriber {
    block: AtomicBool,
    calls: Mutex<Vec<TranscribeRequest>>,
}

impl Transcriber for FakeTranscriber {
    fn transcribe(&self, request: TranscribeRequest, cancel: Arc<AtomicBool>, report: Report) -> Result<Vec<Segment>, String> {
        let partial_len = request.partial.len();
        self.calls.lock().unwrap().push(request);
        report(Update::Progress(JobProgress::new(JobStage::Transcribing, "Transcribing…", Some(0.5))));
        report(Update::Segments(vec![Segment::new(1, 0.0, 1.0, "one")]));
        report(Update::ChunkComplete(1.0));
        while self.block.load(Ordering::Relaxed) {
            if cancel.load(Ordering::Relaxed) {
                return Err("canceled".into());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        report(Update::Segments(vec![Segment::new(2, 1.0, 2.0, "two")]));
        let _ = partial_len;
        Ok(vec![Segment::new(1, 0.0, 1.0, "one"), Segment::new(2, 1.0, 2.0, "two")])
    }
}

/// An OpenAI-compatible server in-process: "[target] text" per cue.
struct FakeLlm;

impl Transport for FakeLlm {
    fn post(&self, request: &HttpRequest) -> Result<HttpResponse, String> {
        let body: serde_json::Value = serde_json::from_str(&request.body).unwrap();
        let system = body["messages"][0]["content"].as_str().unwrap();
        let user = body["messages"][1]["content"].as_str().unwrap();
        let target = system.split("Target language: ").nth(1).unwrap().split(".\n").next().unwrap();
        let segments: serde_json::Value = serde_json::from_str(user.split("Segments:\n").nth(1).unwrap()).unwrap();
        let out: Vec<_> = segments
            .as_array()
            .unwrap()
            .iter()
            .map(|s| serde_json::json!({"id": s["id"], "text": format!("[{target}] {}", s["text"].as_str().unwrap())}))
            .collect();
        let content = serde_json::json!({ "segments": out }).to_string();
        let reply = serde_json::json!({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]});
        Ok(HttpResponse { status: 200, headers: vec![], body: reply.to_string().into_bytes() })
    }
}

struct Harness {
    runtime: Runtime,
    events: Receiver<Event>,
    transcriber: Arc<FakeTranscriber>,
    dir: tempfile::TempDir,
    media: PathBuf,
}

fn harness_in(dir: tempfile::TempDir, settings: Settings) -> Harness {
    settings.save(&dir.path().join("settings.json")).unwrap();
    let media = dir.path().join("Movie.mp4");
    std::fs::write(&media, b"video").unwrap();
    let transcriber = Arc::new(FakeTranscriber { block: AtomicBool::new(false), calls: Mutex::new(Vec::new()) });
    let (tx, events) = channel();
    let tx = Mutex::new(tx);
    let (runtime, failures) = Runtime::launch(Config {
        data_dir: dir.path().to_path_buf(),
        transcriber: transcriber.clone(),
        transport: Arc::new(FakeLlm),
        keys: Arc::new(|_| None),
        emit: Arc::new(move |e| {
            let _ = tx.lock().unwrap().send(e);
        }),
    });
    assert!(failures.is_empty(), "{failures:?}");
    Harness { runtime, events, transcriber, dir, media }
}

fn harness(settings: Settings) -> Harness {
    harness_in(tempfile::tempdir().unwrap(), settings)
}

fn local_settings() -> Settings {
    Settings { translation_model: "local/fake".into(), translation_target_language: "Vietnamese".into(), ..Settings::default() }
}

/// Waits until the job reaches `status` (events are drained as it goes).
fn wait_for(h: &Harness, id: &str, status: JobStatus) -> Job {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        while h.events.try_recv().is_ok() {}
        let job = h.runtime.job(id).unwrap();
        if job.status == status {
            return job;
        }
        assert!(Instant::now() < deadline, "job stuck at {:?}: {}", job.status, job.progress.detail);
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn added_file_is_transcribed_translated_and_saved() {
    let h = harness(Settings { auto_translate: true, sidecar_bilingual: true, ..local_settings() });
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    let job = wait_for(&h, &id, JobStatus::TranslationComplete);
    assert_eq!(job.transcript_segments.len(), 2);
    assert_eq!(job.translated_segments[1].text, "[Vietnamese] two");
    assert!(job.partial_transcript_segments.is_empty() && job.partial_translated_segments.is_empty());
    assert_eq!(job.settings.translation_model, "local/fake");

    // Mac-named sidecars next to the video. They are written just after the
    // status flips, so give a slow runner a moment.
    let deadline = Instant::now() + Duration::from_secs(10);
    for name in ["Movie.original.srt", "Movie.vi.srt", "Movie.bilingual.srt"] {
        while !h.dir.path().join(name).exists() {
            assert!(Instant::now() < deadline, "{name} missing");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    // A relaunch over the same folder sees the finished job.
    h.runtime.flush();
    let (again, failures) = Runtime::launch(Config {
        data_dir: h.dir.path().to_path_buf(),
        transcriber: h.transcriber.clone(),
        transport: Arc::new(FakeLlm),
        keys: Arc::new(|_| None),
        emit: Arc::new(|_| {}),
    });
    assert!(failures.is_empty());
    assert_eq!(again.job(&id).unwrap().translated_segments.len(), 2);
}

#[test]
fn duplicate_adds_are_skipped_and_auto_start_off_leaves_jobs_idle() {
    let h = harness(Settings { auto_start_added_jobs: false, ..Settings::default() });
    let ids = h.runtime.add_files(&[h.media.clone(), h.media.clone()]);
    assert_eq!(ids.len(), 1);
    assert_eq!(h.runtime.job(&ids[0]).unwrap().status, JobStatus::Idle);
    assert!(h.runtime.add_files(std::slice::from_ref(&h.media)).is_empty());
}

#[test]
fn transcription_slot_is_serial_and_cancel_keeps_the_resume_point() {
    let h = harness(Settings::default());
    h.transcriber.block.store(true, Ordering::Relaxed);
    let second = h.dir.path().join("Second.mp4");
    std::fs::write(&second, b"v").unwrap();
    let ids = h.runtime.add_files(&[h.media.clone(), second]);
    wait_for(&h, &ids[0], JobStatus::Transcribing);
    // Wait for the first streamed batch and resume point to land.
    let deadline = Instant::now() + Duration::from_secs(5);
    while h.runtime.job(&ids[0]).unwrap().transcription_resume_through < 1.0 {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(h.runtime.job(&ids[1]).unwrap().status, JobStatus::Queued, "one GPU job at a time");
    // A partial transcript must not count as a transcript.
    assert!(!h.runtime.job(&ids[0]).unwrap().has_transcript());

    h.runtime.cancel(&ids[0]).unwrap();
    let canceled = wait_for(&h, &ids[0], JobStatus::Canceled);
    assert_eq!(canceled.partial_transcript_segments.len(), 1);
    assert_eq!(canceled.transcription_resume_through, 1.0);
    wait_for(&h, &ids[1], JobStatus::Transcribing);
    h.transcriber.block.store(false, Ordering::Relaxed);
    wait_for(&h, &ids[1], JobStatus::TranscriptionComplete);

    // Starting again resumes from the saved point with the saved partials.
    h.runtime.start(&ids[0]).unwrap();
    wait_for(&h, &ids[0], JobStatus::TranscriptionComplete);
    let calls = h.transcriber.calls.lock().unwrap();
    let resumed = calls.iter().rev().find(|c| c.source == h.media).unwrap();
    assert_eq!(resumed.resume_through, 1.0);
    assert_eq!(resumed.partial.len(), 1);
}

#[test]
fn paused_queue_holds_jobs_until_resumed() {
    let h = harness(Settings::default());
    h.runtime.set_paused(true);
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(h.runtime.job(&id).unwrap().status, JobStatus::Queued);
    h.runtime.set_paused(false);
    wait_for(&h, &id, JobStatus::TranscriptionComplete);
}

#[test]
fn missing_key_fails_translation_but_keeps_the_transcript() {
    let h = harness(Settings { auto_translate: true, translation_model: "gpt-6.1-sol".into(), ..Settings::default() });
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    let job = wait_for(&h, &id, JobStatus::Failed);
    assert_eq!(job.progress.failed_stage, Some(JobStage::Translating));
    assert!(job.progress.detail.contains("API key"), "{}", job.progress.detail);
    assert_eq!(job.transcript_segments.len(), 2);

    // Retrying goes straight to the translation slot.
    h.runtime.update_settings(local_settings()).unwrap();
    h.runtime.start(&id).unwrap();
    let job = wait_for(&h, &id, JobStatus::TranslationComplete);
    assert_eq!(job.translated_segments[0].text, "[Vietnamese] one");
    assert_eq!(h.transcriber.calls.lock().unwrap().len(), 1, "no second transcription");
}

#[test]
fn edits_overrides_reorder_and_export() {
    let h = harness(Settings { auto_export_sidecars: false, ..local_settings() });
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    wait_for(&h, &id, JobStatus::TranscriptionComplete);
    h.runtime.edit_segment(&id, Slot::Transcript, 2, "deux").unwrap();
    assert!(h.runtime.edit_segment(&id, Slot::Transcript, 99, "x").is_err());
    h.runtime.set_override(&id, "translationTargetLanguage", Some("German".into())).unwrap();
    h.runtime.translate(&id).unwrap();
    let job = wait_for(&h, &id, JobStatus::TranslationComplete);
    assert_eq!(job.translated_segments[1].text, "[German] deux");
    assert!(!h.dir.path().join("Movie.original.srt").exists(), "sidecars were off");

    let out = tempfile::tempdir().unwrap();
    let paths = h.runtime.export(&id, &[Document::Original], &[Format::Srt, Format::Vtt], Some(out.path())).unwrap();
    let names: Vec<_> = paths.iter().map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
    assert_eq!(names, ["Movie.srt", "Movie.vtt"]);
    let paths = h.runtime.export(&id, &[Document::Original, Document::Translated], &[Format::Srt], Some(out.path())).unwrap();
    let names: Vec<_> = paths.iter().map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
    assert_eq!(names, ["Movie.original.srt", "Movie.translated.german.srt"]);

    let other = h.dir.path().join("Other.mp4");
    std::fs::write(&other, b"v").unwrap();
    let second = h.runtime.add_files(&[other]).remove(0);
    wait_for(&h, &second, JobStatus::TranscriptionComplete);
    h.runtime.reorder(&[second.clone(), id.clone()]);
    let order: Vec<String> = h.runtime.jobs().into_iter().map(|j| j.id).collect();
    assert_eq!(order, [second.clone(), id.clone()]);
    h.runtime.remove(&second).unwrap();
    h.runtime.flush();
    assert!(!h.dir.path().join("jobs").join(format!("{second}.json")).exists());
}

#[test]
fn jobs_running_at_quit_load_as_canceled() {
    let dir = tempfile::tempdir().unwrap();
    let id = {
        let h = harness_in(tempfile::TempDir::new_in(dir.path()).unwrap(), Settings::default());
        h.transcriber.block.store(true, Ordering::Relaxed);
        let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
        wait_for(&h, &id, JobStatus::Transcribing);
        h.runtime.flush();
        let jobs = h.dir.path().to_path_buf();
        // Simulate a crash: copy the on-disk state before shutdown.
        let copy = dir.path().join("crashed");
        std::fs::create_dir_all(copy.join("jobs")).unwrap();
        // The saver may be mid-rename of a temp file; copy finished job files only.
        for entry in std::fs::read_dir(jobs.join("jobs")).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().is_some_and(|e| e == "json") {
                match std::fs::copy(&path, copy.join("jobs").join(path.file_name().unwrap())) {
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    other => {
                        other.unwrap();
                    }
                }
            }
        }
        assert!(copy.join("jobs").join(format!("{id}.json")).exists());
        h.runtime.shutdown();
        id
    };
    let (runtime, _) = Runtime::launch(Config {
        data_dir: dir.path().join("crashed"),
        transcriber: Arc::new(FakeTranscriber { block: AtomicBool::new(false), calls: Mutex::new(Vec::new()) }),
        transport: Arc::new(FakeLlm),
        keys: Arc::new(|_| None),
        emit: Arc::new(|_| {}),
    });
    assert_eq!(runtime.job(&id).unwrap().status, JobStatus::Canceled);
}

#[test]
fn transcribing_a_mac_job_keeps_its_mac_only_settings() {
    // A queued job from the Mac, carrying settings Windows doesn't manage.
    let dir = tempfile::tempdir().unwrap();
    let media = dir.path().join("Movie.mp4");
    std::fs::write(&media, b"video").unwrap();
    let mut job = Job::new(&media, Settings::default().snapshot(), Utc::now());
    job.settings.extra.insert("vadFilter".into(), serde_json::json!(true));
    job.status = JobStatus::Queued;
    JobStore::new(dir.path().join("jobs")).save(&job).unwrap();

    let h = harness_in(dir, Settings::default());
    let done = wait_for(&h, &job.id, JobStatus::TranscriptionComplete);
    assert_eq!(done.settings.extra.get("vadFilter"), Some(&serde_json::json!(true)));
    assert_eq!(done.settings.whisper_backend, "whisper-cpp");
}
