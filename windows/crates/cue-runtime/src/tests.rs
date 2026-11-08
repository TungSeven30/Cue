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
        if system.contains("spoiler-free introductions") {
            let language = system.split("Write the introduction in ").nth(1).unwrap().split('.').next().unwrap();
            let first = user.strip_prefix("Subtitles:\n").unwrap().lines().next().unwrap();
            let content = serde_json::json!({ "summary": format!("Intro ({language}) from {first}") }).to_string();
            let reply = serde_json::json!({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]});
            return Ok(HttpResponse { status: 200, headers: vec![], body: reply.to_string().into_bytes() });
        }
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
    harness_with(dir, settings, Tools::default())
}

fn harness_with(dir: tempfile::TempDir, settings: Settings, tools: Tools) -> Harness {
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
        tools,
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
        tools: Tools::default(),
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
        tools: Tools::default(),
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

/// Polls `check` for up to `seconds`.
fn eventually<T>(seconds: u64, what: &str, mut check: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(value) = check() {
            return value;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn watched_files_queue_once_settled_and_run_once() {
    let h = harness(Settings { auto_export_sidecars: false, auto_start_added_jobs: false, ..local_settings() });
    let folder = h.dir.path().join("Inbox");
    std::fs::create_dir_all(folder.join("Season 1")).unwrap();
    h.runtime.set_paused(true);
    let id = h.runtime.add_watch_folder(&folder).unwrap();
    assert!(h.runtime.add_watch_folder(&folder).is_err(), "a folder is watched once");
    h.runtime.set_watch_folder(&id, true, serde_json::json!({"translationTargetLanguage": "French", "sourceLanguage": ""})).unwrap();

    let clip = folder.join("Season 1").join("Episode.mkv");
    std::fs::write(&clip, b"video").unwrap();
    let job =
        eventually(15, "the watched file to queue", || h.runtime.jobs().into_iter().find(|j| j.source_path == clip.to_string_lossy()));
    let job = h.runtime.job(&job.id).unwrap();
    assert_eq!(job.origin, JobOrigin::WatchFolder);
    assert_eq!(job.status, JobStatus::Queued, "ingest never clears the pause");
    assert!(job.log.starts_with("Picked up from the watch folder: "));
    assert_eq!(job.overrides, serde_json::json!({"translationTargetLanguage": "French"}));
    assert!(matches!(h.runtime.queue_state(), Event::Queue { paused: true, .. }));

    h.runtime.set_paused(false);
    let done = wait_for(&h, &job.id, JobStatus::TranscriptionComplete);
    // Watch jobs always leave sidecars, whatever the global setting says.
    let sidecar = folder.join("Season 1").join("Episode.original.srt");
    eventually(10, "the sidecar", || sidecar.exists().then_some(()));
    let ledger = h.dir.path().join("watch-ledger.json");
    eventually(10, "the ledger entry", || {
        let text = std::fs::read_to_string(&ledger).ok()?;
        text.contains(&serde_json::to_string(&done.source_fingerprint).unwrap()).then_some(())
    });
    assert!(std::fs::read_to_string(&ledger).unwrap().contains("success"));

    // Removed from the list, the file stays done: the ledger blocks it.
    h.runtime.remove(&job.id).unwrap();
    std::fs::write(folder.join("notes.txt"), b"wake the watcher").unwrap();
    std::thread::sleep(Duration::from_secs(4));
    assert!(h.runtime.jobs().is_empty(), "a finished file must not queue again");

    // Clearing the folder's history runs it again.
    h.runtime.clear_watch_history(&id).unwrap();
    eventually(15, "the file to queue again", || h.runtime.jobs().into_iter().next());

    h.runtime.remove_watch_folder(&id).unwrap();
    assert!(h.runtime.watch_folders().is_empty());
    assert!(h.runtime.settings().watch_folders.is_empty());
}

#[test]
fn update_settings_keeps_the_watch_folders() {
    let h = harness(local_settings());
    let folder = h.dir.path().join("Inbox");
    std::fs::create_dir_all(&folder).unwrap();
    h.runtime.add_watch_folder(&folder).unwrap();
    h.runtime.update_settings(Settings { auto_translate: true, ..h.runtime.settings() }.clone_without_folders()).unwrap();
    assert_eq!(h.runtime.settings().watch_folders.len(), 1);
    assert!(h.runtime.settings().auto_translate);
}

impl Settings {
    fn clone_without_folders(mut self) -> Settings {
        self.watch_folders.clear();
        self
    }
}

#[cfg(unix)]
fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// A stand-in yt-dlp: the output template is its second-to-last argument.
#[cfg(unix)]
const FAKE_YTDLP: &str = r#"
for last; do :; done
out=""; prev=""
for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; done
dir=$(dirname "$out")
case "$last" in
  *fail*) echo "ERROR: Unsupported URL: $last" >&2; exit 1 ;;
  *slow*) sleep 30 ;;
esac
echo "[download] Destination: $dir/Clip.f1.mp4"
echo "[download]  50.0% of 1.00MiB"
printf 'a' > "$dir/Clip.f1.mp4"
printf 'merged' > "$dir/Clip.mp4"
echo "[Merger] Merging formats into \"$dir/Clip.mp4\""
"#;

#[cfg(unix)]
#[test]
fn urls_download_into_jobs_and_failures_say_why() {
    let dir = tempfile::tempdir().unwrap();
    let ytdlp = script(dir.path(), "yt-dlp", FAKE_YTDLP);
    let downloads = dir.path().join("Downloads");
    let settings = Settings { download_folder: downloads.to_string_lossy().into(), auto_start_added_jobs: false, ..local_settings() };
    let h = harness_with(dir, settings, Tools { ytdlp: Some(ytdlp), ffmpeg: None });

    assert!(h.runtime.add_url("mailto:me@example.com").is_err());
    let id = h.runtime.add_url(" <https://example.com/watch?v=1> ").unwrap();
    let done =
        eventually(10, "the download", || h.runtime.downloads().into_iter().find(|d| d.id == id && d.status != DownloadStatus::Running));
    assert_eq!(done.status, DownloadStatus::Done, "{}", done.detail);
    let job = h.runtime.job(done.job_id.as_deref().unwrap()).unwrap();
    assert_eq!(job.origin, JobOrigin::Url);
    assert_eq!(PathBuf::from(&job.source_path), downloads.join("Clip.mp4"));
    assert_eq!(std::fs::read(&job.source_path).unwrap(), b"merged");
    assert!(job.log.contains("Downloaded from https://example.com/watch?v=1"));
    let leftovers: Vec<_> = std::fs::read_dir(&downloads).unwrap().flatten().map(|e| e.file_name()).collect();
    assert_eq!(leftovers.len(), 1, "staging folders are removed: {leftovers:?}");

    // The same page again never overwrites the first file.
    let again = h.runtime.add_url("https://example.com/watch?v=1").unwrap();
    let second = eventually(10, "the second download", || {
        h.runtime.downloads().into_iter().find(|d| d.id == again && d.status != DownloadStatus::Running)
    });
    assert_eq!(h.runtime.job(second.job_id.as_deref().unwrap()).unwrap().source_path, downloads.join("Clip-2.mp4").to_string_lossy());

    let failing = h.runtime.add_url("https://example.com/fail").unwrap();
    let failed = eventually(10, "the failure", || {
        h.runtime.downloads().into_iter().find(|d| d.id == failing && d.status != DownloadStatus::Running)
    });
    assert_eq!(failed.status, DownloadStatus::Failed);
    assert_eq!(failed.detail, "ERROR: Unsupported URL: https://example.com/fail");
    h.runtime.dismiss_download(&failing).unwrap();

    let slow = h.runtime.add_url("https://example.com/slow").unwrap();
    assert!(h.runtime.busy());
    assert!(h.runtime.dismiss_download(&slow).is_err());
    h.runtime.cancel_download(&slow).unwrap();
    let canceled =
        eventually(10, "the cancel", || h.runtime.downloads().into_iter().find(|d| d.id == slow && d.status != DownloadStatus::Running));
    assert_eq!(canceled.status, DownloadStatus::Canceled);
    assert_eq!(std::fs::read_dir(&downloads).unwrap().count(), 2);
}

/// A stand-in ffmpeg that checks it was given subs.srt in its working
/// folder and writes the output (its last argument).
#[cfg(unix)]
const FAKE_FFMPEG: &str = r#"
for last; do :; done
[ -f subs.srt ] || { echo "no subs.srt" >&2; exit 1; }
grep -q "$CUE_FAKE_EXPECT" subs.srt || { echo "wrong subtitles" >&2; exit 1; }
echo "  Duration: 00:00:10.00, start: 0.000000, bitrate: 1 kb/s" >&2
printf 'frame=1 time=00:00:05.00 bitrate=1\r' >&2
printf 'partial' > "$last"
case "$last" in *broken*) echo "Error opening output" >&2; exit 1 ;; esac
printf 'burned' > "$last"
"#;

#[cfg(unix)]
#[test]
fn burn_in_renders_a_copy_and_cleans_up_failures() {
    let dir = tempfile::tempdir().unwrap();
    let ffmpeg = script(dir.path(), "ffmpeg", FAKE_FFMPEG);
    std::env::set_var("CUE_FAKE_EXPECT", "two");
    let h = harness_with(dir, local_settings(), Tools { ytdlp: None, ffmpeg: Some(ffmpeg) });
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    wait_for(&h, &id, JobStatus::TranscriptionComplete);
    assert!(h.runtime.burn_in(&id, Document::Translated, TextSize::Medium, None).is_err(), "nothing translated yet");
    assert!(h.runtime.burn_in(&id, Document::Original, TextSize::Small, Some(h.dir.path().join("movie.MP4"))).is_err());

    let finish = |h: &Harness| -> BurnInState {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match h.events.recv_timeout(left) {
                Ok(Event::BurnIn { state }) if !state.running => return state,
                Ok(_) => {}
                Err(_) => panic!("burn-in never finished"),
            }
        }
    };
    while h.events.try_recv().is_ok() {}
    let output = h.runtime.burn_in(&id, Document::Original, TextSize::Large, None).unwrap();
    assert_eq!(output, h.dir.path().join("Movie.subtitled.mp4"));
    let state = finish(&h);
    assert_eq!(state.error, None);
    assert_eq!(std::fs::read(&output).unwrap(), b"burned");

    let broken = h.dir.path().join("broken.mp4");
    h.runtime.burn_in(&id, Document::Original, TextSize::Large, Some(broken.clone())).unwrap();
    let state = finish(&h);
    assert_eq!(state.error.as_deref(), Some("Error opening output"));
    assert!(!broken.exists(), "partial output is deleted");
}

#[test]
fn a_finished_translation_gets_an_intro_in_the_target_language() {
    let h = harness(Settings { auto_translate: true, generate_summary: true, ..local_settings() });
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    let job = wait_for(&h, &id, JobStatus::TranslationComplete);
    assert_eq!(job.summary.as_deref(), Some("Intro (Vietnamese) from [Vietnamese] one"));
    assert!(job.log.contains("Wrote the intro summary with local/fake"));
    assert_eq!(h.runtime.jobs()[0].summary, job.summary);

    // The intro opens SRT and VTT exports, never text.
    let out = h.dir.path().join("out");
    std::fs::create_dir_all(&out).unwrap();
    h.runtime.export(&id, &[Document::Translated], &[Format::Srt, Format::Text], Some(&out)).unwrap();
    let srt = std::fs::read_to_string(out.join("Movie.translated.vietnamese.srt")).unwrap();
    assert!(srt.starts_with("1\n00:00:00,000 --> 00:00:03,000\nIntro (Vietnamese)"), "{srt}");
    assert!(srt.contains("\n3\n"), "the subtitles are renumbered after the intro");
    let txt = std::fs::read_to_string(out.join("Movie.translated.vietnamese.txt")).unwrap();
    assert!(!txt.contains("Intro"));
}

#[test]
fn a_transcript_only_job_is_summarized_in_its_own_language() {
    let h = harness(Settings { generate_summary: true, ..local_settings() });
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    let job = wait_for(&h, &id, JobStatus::TranscriptionComplete);
    assert_eq!(job.summary.as_deref(), Some("Intro (the same language as the subtitles) from one"));
}

#[test]
fn summaries_can_be_written_edited_and_cleared_on_demand() {
    let h = harness(local_settings());
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    let job = wait_for(&h, &id, JobStatus::TranscriptionComplete);
    assert_eq!(job.summary, None, "summaries are off by default");
    assert_eq!(h.runtime.generate_summary(&id).unwrap(), "Intro (the same language as the subtitles) from one");
    h.runtime.set_summary(&id, Some("  Mine.  ")).unwrap();
    assert_eq!(h.runtime.job(&id).unwrap().summary.as_deref(), Some("Mine."));
    h.runtime.set_summary(&id, Some(" ")).unwrap();
    assert_eq!(h.runtime.job(&id).unwrap().summary, None);
}

#[test]
fn a_missing_key_skips_the_summary_without_failing_the_job() {
    let h = harness(Settings { generate_summary: true, summary_model: "gpt-5.5".into(), ..local_settings() });
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    let job = wait_for(&h, &id, JobStatus::TranscriptionComplete);
    assert_eq!(job.summary, None);
    assert!(job.log.contains("Skipped the intro summary because there is no OpenAI API key"), "{}", job.log);
    assert!(h.runtime.generate_summary(&id).unwrap_err().contains("no OpenAI API key"));
}

#[test]
fn summary_overrides_are_stored_as_the_mac_types() {
    let h = harness(Settings { auto_start_added_jobs: false, ..local_settings() });
    let id = h.runtime.add_files(std::slice::from_ref(&h.media)).remove(0);
    h.runtime.set_override(&id, "generateSummary", Some("true".into())).unwrap();
    h.runtime.set_override(&id, "summaryDetail", Some("Detailed".into())).unwrap();
    let overrides = h.runtime.job(&id).unwrap().overrides;
    assert_eq!(overrides["generateSummary"], serde_json::json!(true));
    assert_eq!(overrides["summaryDetail"], serde_json::json!("detailed"));
    assert!(h.runtime.set_override(&id, "generateSummary", Some("yes".into())).is_err());
    h.runtime.set_override(&id, "generateSummary", None).unwrap();
    assert!(h.runtime.job(&id).unwrap().overrides.get("generateSummary").is_none());
}
