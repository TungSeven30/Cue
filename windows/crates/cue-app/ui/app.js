"use strict";

const { invoke, convertFileSrc } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, ...children) => {
  const node = Object.assign(document.createElement(tag), props);
  for (const child of children) node.append(child);
  return node;
};

const LANGUAGES = [
  ["auto", "Detect automatically"], ["en", "English"], ["ja", "Japanese"], ["zh", "Chinese"],
  ["ko", "Korean"], ["es", "Spanish"], ["fr", "French"], ["de", "German"], ["it", "Italian"],
  ["pt", "Portuguese"], ["ru", "Russian"], ["vi", "Vietnamese"], ["th", "Thai"], ["id", "Indonesian"],
  ["ar", "Arabic"], ["hi", "Hindi"], ["nl", "Dutch"], ["pl", "Polish"], ["tr", "Turkish"],
  ["uk", "Ukrainian"], ["sv", "Swedish"], ["he", "Hebrew"], ["ms", "Malay"], ["tl", "Tagalog"],
];
const TARGETS = ["English", "Vietnamese", "Japanese", "Chinese", "Korean", "Spanish", "French", "German",
  "Portuguese", "Brazilian Portuguese", "Italian", "Russian", "Thai", "Indonesian", "Arabic", "Hindi"];
const MODELS = ["gpt-6.1-sol", "claude-sonnet-5", "gemini-3-flash", "openrouter/", "groq/", "cerebras/", "local/"];

const state = {
  jobs: new Map(),      // id -> summary
  order: [],            // ids in list order
  selected: null,       // id
  job: null,            // full job for the selected id
  partial: [],          // live streamed cues for the selected job
  queue: { paused: false, transcribing: null, translating: null },
  exportFolder: null,
  downloads: new Map(), // id -> download
  watch: [],            // watch-folder statuses
  burn: null,           // the running or last burn-in
  burnOutput: null,     // chosen output path for the burn dialog
  collapsed: new Set(readCollapsed()),
};

function readCollapsed() {
  try { return JSON.parse(localStorage.getItem("cue.collapsedFolders") || "[]"); } catch { return []; }
}

function saveCollapsed() {
  try { localStorage.setItem("cue.collapsedFolders", JSON.stringify([...state.collapsed])); } catch { /* storage off */ }
}

const folderOf = (path) => {
  const i = Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/"));
  return i > 0 ? path.slice(0, i) : path;
};
const baseName = (path) => path.split(/[\\/]/).filter(Boolean).pop() || path;

// MARK: Helpers

function toast(message, kind = "info") {
  const node = el("div", { className: `toast ${kind}`, textContent: message });
  $("toasts").append(node);
  setTimeout(() => node.remove(), kind === "error" ? 9000 : 5000);
}

async function call(command, args) {
  try {
    return await invoke(command, args);
  } catch (error) {
    toast(String(error), "error");
    throw error;
  }
}

function timestamp(seconds) {
  const s = Math.max(0, seconds || 0);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60);
  const mm = String(m).padStart(2, "0"), ss = String(sec).padStart(2, "0");
  return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

function chipClass(status) {
  if (["transcribing", "translating", "burningIn"].includes(status)) return "running";
  if (["transcriptionComplete", "translationComplete"].includes(status)) return "done";
  if (status === "failed") return "failed";
  if (status === "queued") return "queued";
  return "";
}

const isRunning = (s) => ["transcribing", "translating", "burningIn"].includes(s);

function fillSelect(select, options, value) {
  select.replaceChildren(...options.map(([v, label]) => el("option", { value: v, textContent: label })));
  if (value !== undefined) select.value = value;
}

function fillDatalist(list, values) {
  list.replaceChildren(...values.map((v) => el("option", { value: v })));
}

// MARK: Job list

function sortOrder() {
  state.order = [...state.jobs.values()]
    .sort((a, b) => a.orderIndex - b.orderIndex || b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id))
    .map((j) => j.id);
}

/// Jobs grouped by the folder their video is in, groups in queue order.
/// Headers only appear once there is more than one folder.
function renderList() {
  const filter = $("filter").value.trim().toLowerCase();
  const items = state.order
    .map((id) => state.jobs.get(id))
    .filter((j) => !filter || j.title.toLowerCase().includes(filter));
  $("jobs-empty").hidden = state.jobs.size > 0;
  const groups = new Map();
  for (const job of items) {
    const folder = folderOf(job.sourcePath);
    if (!groups.has(folder)) groups.set(folder, []);
    groups.get(folder).push(job);
  }
  if (groups.size <= 1) {
    $("jobs").replaceChildren(...items.map(jobRow));
    return;
  }
  const rows = [];
  for (const [folder, jobs] of groups) {
    const collapsed = state.collapsed.has(folder) && !filter;
    const header = el("li", { className: "group" + (collapsed ? " collapsed" : ""), title: folder },
      el("span", { className: "caret", textContent: "▾" }),
      el("span", { className: "label", textContent: baseName(folder) }),
      el("span", { className: "count", textContent: String(jobs.length) }));
    header.setAttribute("role", "button");
    header.setAttribute("aria-expanded", String(!collapsed));
    header.addEventListener("click", () => {
      if (state.collapsed.has(folder)) state.collapsed.delete(folder); else state.collapsed.add(folder);
      saveCollapsed();
      renderList();
    });
    rows.push(header);
    if (!collapsed) rows.push(...jobs.map(jobRow));
  }
  $("jobs").replaceChildren(...rows);
}

function jobRow(job) {
  const fraction = job.progress.fraction;
  const bar = el("div", { className: "bar" + (isRunning(job.status) && fraction == null ? " indeterminate" : "") }, el("div"));
  bar.firstChild.style.width = fraction != null ? `${Math.round(fraction * 100)}%` : "";
  bar.hidden = !isRunning(job.status);
  const detail = isRunning(job.status) || job.status === "failed" ? job.progress.detail : summaryLine(job);
  const origin = job.origin === "watchFolder" ? "Watch" : job.origin === "url" ? "URL" : null;
  const name = el("span", { className: "name", textContent: job.title });
  const row = el("li", { className: job.id === state.selected ? "selected" : "", title: job.sourcePath },
    name,
    el("span", { className: "meta" },
      el("span", { className: `chip ${chipClass(job.status)}`, textContent: job.statusLabel }),
      el("span", { textContent: detail })),
    bar);
  if (origin) row.querySelector(".meta").prepend(el("span", { className: "tag", textContent: origin }));
  row.dataset.id = job.id;
  row.addEventListener("click", () => select(job.id));
  return row;
}

function summaryLine(job) {
  const parts = [];
  if (job.transcriptCount) parts.push(`${job.transcriptCount} subtitles`);
  if (job.translationCount) parts.push(job.targetLanguage);
  return parts.join(" · ");
}

function updateQueueStatus() {
  const { paused, transcribing, translating } = state.queue;
  const queued = [...state.jobs.values()].filter((j) => j.status === "queued").length;
  const busy = [transcribing, translating].filter(Boolean).length;
  let text = "";
  if (busy) text = `${busy} running`;
  if (queued) text += `${text ? ", " : ""}${queued} waiting`;
  if (paused) text = `Queue paused${queued ? ` (${queued} waiting)` : ""}`;
  $("queue-status").textContent = text;
  $("pause").textContent = paused ? "Resume queue" : "Pause queue";
}

// MARK: Selected job

async function select(id) {
  state.selected = id;
  state.partial = [];
  renderList();
  if (!id) {
    state.job = null;
    $("welcome").hidden = false;
    $("job").hidden = true;
    return;
  }
  state.job = await call("get_job", { id });
  $("welcome").hidden = true;
  $("job").hidden = false;
  loadVideo();
  renderJob();
  renderCues();
}

async function refreshSelected() {
  if (!state.selected) return;
  state.job = await invoke("get_job", { id: state.selected }).catch(() => null);
  if (!state.job) return select(null);
  state.partial = [];
  renderJob();
  renderCues();
}

function loadVideo() {
  const video = $("video");
  $("video-note").hidden = true;
  video.src = convertFileSrc(state.job.sourcePath);
  video.load();
}

function renderJob() {
  const job = state.job;
  const summary = state.jobs.get(job.id);
  $("job-title").textContent = summary ? summary.title : job.sourcePath;
  $("job-path").textContent = job.sourcePath;
  const status = summary ? summary.status : job.status;
  const chip = $("job-status");
  chip.className = `chip ${chipClass(status)}`;
  chip.textContent = summary ? summary.statusLabel : status;
  const progress = summary ? summary.progress : job.progress;
  const label = summary ? summary.statusLabel : status;
  $("job-detail").textContent = progress.detail === label ? "" : progress.detail;
  const bar = $("job-bar").parentElement;
  bar.hidden = !isRunning(status);
  bar.classList.toggle("indeterminate", isRunning(status) && progress.fraction == null);
  $("job-bar").style.width = progress.fraction != null ? `${Math.round(progress.fraction * 100)}%` : "";
  $("job-log").textContent = job.log;

  const overrides = job.overrides || {};
  $("ov-source").value = overrides.sourceLanguage || "";
  $("ov-target").value = overrides.translationTargetLanguage || "";
  $("ov-model").value = overrides.openAIModel || "";
  $("ov-summary").value = overrides.generateSummary == null ? "" : String(overrides.generateSummary);
  $("ov-summary-detail").value = overrides.summaryDetail || "";
  for (const id of ["ov-source", "ov-target", "ov-model", "ov-summary"]) $(id).disabled = isRunning(status);
  renderIntro(summary, status);

  renderActions(status, summary);
}

// The intro box keeps what the user is typing: only a summary that
// changed on the job (a new one was written) replaces the text.
function renderIntro(summary, status) {
  const text = (summary ? summary.summary : state.job.summary) || "";
  const box = $("intro-text");
  if (state.introShown !== text || state.introJob !== state.selected) {
    if (state.introJob !== state.selected || box.value === (state.introShown ?? "")) box.value = text;
    state.introShown = text;
    state.introJob = state.selected;
  }
  const hasSubtitles = (summary ? summary.transcriptCount : state.job.transcriptSegments.length) > 0;
  $("intro").hidden = !hasSubtitles && !text;
  $("intro-state").textContent = state.writingIntro ? "Writing…" : text ? "" : "None yet";
  $("intro-generate").disabled = state.writingIntro || !hasSubtitles || isRunning(status);
  $("intro-generate").textContent = text ? "Rewrite with AI" : "Write with AI";
  $("intro-clear").disabled = !text;
}

async function writeIntro() {
  const id = state.selected;
  state.writingIntro = true;
  renderJob();
  try {
    await invoke("generate_summary", { id });
    toast("Intro summary written.");
  } catch (e) {
    toast(String(e), "error");
  } finally {
    state.writingIntro = false;
    if (state.selected === id) refreshSelected();
  }
}

async function saveIntro(text) {
  await call("set_summary", { id: state.selected, text });
  state.introShown = null;
  refreshSelected();
}

function renderActions(status, summary) {
  const id = state.selected;
  const hasTranscript = (summary ? summary.transcriptCount : state.job.transcriptSegments.length) > 0;
  const hasTranslation = (summary ? summary.translationCount : state.job.translatedSegments.length) > 0;
  const buttons = [];
  const add = (label, fn, cls = "") => buttons.push(el("button", { textContent: label, className: cls, onclick: fn }));
  if (isRunning(status) || status === "queued") {
    add(status === "queued" ? "Remove from queue" : "Stop", () => call("cancel_job", { id }));
  } else {
    if (!hasTranscript) add(status === "canceled" ? "Resume" : "Transcribe", () => call("start_job", { id }), "primary");
    if (hasTranscript) add(hasTranslation ? "Translate again" : "Translate", () => call("translate_job", { id }), hasTranslation ? "" : "primary");
    if (hasTranscript) add("Transcribe again", () => {
      if (confirmAction("Transcribe again? This replaces the transcript and any translation, including your edits.")) call("retranscribe_job", { id });
    });
  }
  if (hasTranscript) add("Export…", openExport);
  if (hasTranscript) add("Burn in…", openBurn);
  add("Move up", () => move(-1), "ghost");
  add("Move down", () => move(1), "ghost");
  if (!isRunning(status)) add("Remove", () => {
    if (confirmAction("Remove this video from Cue? Exported subtitle files are not deleted.")) call("remove_job", { id }).then(() => select(null));
  }, "ghost danger");
  $("job-actions").replaceChildren(...buttons);
}

function confirmAction(message) {
  return window.confirm(message);
}

function move(delta) {
  const index = state.order.indexOf(state.selected);
  const target = index + delta;
  if (index < 0 || target < 0 || target >= state.order.length) return;
  const ids = [...state.order];
  [ids[index], ids[target]] = [ids[target], ids[index]];
  call("reorder_jobs", { ids });
}

// MARK: Cues

function renderCues() {
  const job = state.job;
  const translated = new Map(job.translatedSegments.map((s) => [s.id, s]));
  const partialTranslation = new Map(job.partialTranslatedSegments.map((s) => [s.id, s]));
  const running = isRunning(state.jobs.get(job.id)?.status ?? job.status);
  let rows = job.transcriptSegments;
  let partial = false;
  if (!rows.length) {
    rows = mergeById(job.partialTranscriptSegments, state.partial);
    partial = rows.length > 0;
  }
  const query = $("search").value.trim().toLowerCase();
  const hasTranslation = translated.size > 0 || partialTranslation.size > 0;
  const list = $("cues");
  list.classList.toggle("single", !hasTranslation);
  const visible = query
    ? rows.filter((s) => s.text.toLowerCase().includes(query) || (translated.get(s.id)?.text || "").toLowerCase().includes(query))
    : rows;
  list.replaceChildren(...visible.map((segment) => cueRow(segment, translated.get(segment.id) || partialTranslation.get(segment.id), hasTranslation, partial || running)));
  const empty = $("cues-empty");
  empty.hidden = rows.length > 0;
  empty.textContent = running ? "Subtitles appear here as they are transcribed." : "No subtitles yet. Click Transcribe to start.";
  const counts = [];
  if (rows.length) counts.push(`${rows.length} subtitles${partial ? " so far" : ""}`);
  if (translated.size) counts.push(`${translated.size} translated`);
  $("counts").textContent = counts.join(" · ");
}

function mergeById(a, b) {
  const map = new Map();
  for (const s of a) map.set(s.id, s);
  for (const s of b) map.set(s.id, s);
  return [...map.values()].sort((x, y) => x.start - y.start);
}

function cueRow(segment, translation, showTranslation, readOnly) {
  const time = el("button", { className: "time", textContent: timestamp(segment.start), title: "Play from here" });
  time.addEventListener("click", () => {
    const video = $("video");
    video.currentTime = segment.start;
    video.play().catch(() => {});
  });
  const row = el("div", { className: "cue" + (readOnly && !state.job.transcriptSegments.length ? " partial" : ""), role: "row" }, time,
    editor(segment, "transcript", readOnly));
  if (showTranslation) {
    row.append(translation ? editor(translation, "translation", readOnly) : el("textarea", { className: "missing", value: "Not translated yet", disabled: true, rows: 1 }));
  }
  row.dataset.start = segment.start;
  row.dataset.end = segment.end;
  return row;
}

function editor(segment, slot, readOnly) {
  const area = el("textarea", { value: segment.text, rows: 1, disabled: readOnly, spellcheck: true });
  area.setAttribute("aria-label", slot === "transcript" ? "Original" : "Translation");
  area.addEventListener("change", async () => {
    try {
      await call("edit_segment", { id: state.selected, slot, segmentId: segment.id, text: area.value });
      segment.text = area.value;
    } catch {
      area.value = segment.text;
    }
  });
  return area;
}

// MARK: Playback captions

function cueAt(segments, t) {
  let lo = 0, hi = segments.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const s = segments[mid];
    if (t < s.start) hi = mid - 1;
    else if (t >= s.end) lo = mid + 1;
    else return s;
  }
  return null;
}

let activeRow = null;
function onTimeUpdate() {
  if (!state.job) return;
  const t = $("video").currentTime;
  const source = state.job.transcriptSegments.length ? state.job.transcriptSegments : mergeById(state.job.partialTranscriptSegments, state.partial);
  const original = cueAt(source, t);
  const translated = original ? (state.job.translatedSegments.find((s) => s.id === original.id) ?? cueAt(state.job.translatedSegments, t)) : cueAt(state.job.translatedSegments, t);
  const mode = $("caption-mode").value;
  const lines = [];
  if ((mode === "both" || mode === "original") && original) lines.push(el("span", { textContent: original.text }));
  if ((mode === "both" || mode === "translation") && translated) lines.push(el("span", { className: mode === "both" ? "secondary" : "", textContent: translated.text }));
  $("caption").replaceChildren(...lines);

  const rows = $("cues").children;
  let match = null;
  for (const row of rows) {
    if (t >= Number(row.dataset.start) && t < Number(row.dataset.end)) { match = row; break; }
  }
  if (match !== activeRow) {
    activeRow?.classList.remove("active");
    match?.classList.add("active");
    activeRow = match;
    if (match && $("follow").checked && !$("video").paused && !match.contains(document.activeElement)) {
      match.scrollIntoView({ block: "nearest" });
    }
  }
}

// MARK: Overrides

function bindOverride(inputId, key) {
  $(inputId).addEventListener("change", () => {
    const value = $(inputId).value.trim();
    call("set_override", { id: state.selected, key, value: value || null }).then(refreshSelected);
  });
}

// MARK: Settings

async function openSettings() {
  const [settings, models, keys, diag] = await Promise.all([call("get_settings"), call("list_models"), call("list_keys"), call("diagnostics")]);
  state.settings = settings;
  fillSelect($("s-model"), models.map((m) => [m.name, `${m.label}, ${m.sizeMb >= 1000 ? (m.sizeMb / 1000).toFixed(1) + " GB" : m.sizeMb + " MB"}${m.installed ? ", installed" : ""}`]), settings.whisperModel);
  fillSelect($("s-source"), LANGUAGES, settings.sourceLanguage);
  $("s-gpu").checked = settings.useGpu;
  $("s-beam").value = settings.beamSize;
  $("s-tmodel").value = settings.translationModel;
  $("s-target").value = settings.translationTargetLanguage;
  $("s-tsource").value = settings.translationSourceLanguage === "auto" ? "" : settings.translationSourceLanguage;
  $("s-chunk").value = settings.translationChunkMode;
  $("s-parallel").value = settings.translationParallelism;
  $("s-endpoint").value = settings.localEndpoint;
  $("s-auto-translate").checked = settings.autoTranslate;
  $("s-summary").checked = settings.generateSummary;
  $("s-summary-detail").value = settings.summaryDetail;
  $("s-summary-model").value = settings.summaryModel;
  $("s-summary-fallback").value = settings.summaryFallbackModel;
  $("s-auto-start").checked = settings.autoStartAddedJobs;
  $("s-sidecars").checked = settings.autoExportSidecars;
  $("s-bilingual").checked = settings.sidecarBilingual;
  $("s-tray").checked = settings.keepInTray;
  $("s-notify").checked = settings.notifications;
  $("s-awake").checked = settings.keepAwake;
  state.downloadFolder = settings.downloadFolder;
  $("s-download-folder").textContent = diag.downloadsFolder;
  renderYtdlp(diag.ytdlp);
  state.watch = await call("watch_folders");
  renderWatch();
  renderKeys(keys);
  $("diag").replaceChildren(
    el("dt", { textContent: "GPU backend" }), el("dd", { textContent: diag.gpuBackend }),
    el("dt", { textContent: "ffmpeg" }), el("dd", { textContent: diag.ffmpeg || "Not found. Install ffmpeg or put ffmpeg.exe next to Cue." }),
    el("dt", { textContent: "yt-dlp" }), el("dd", { textContent: diag.ytdlp || "Not installed" }),
    el("dt", { textContent: "Data folder" }), el("dd", { textContent: diag.dataFolder }));
  $("settings").showModal();
}

function renderKeys(keys) {
  $("keys").replaceChildren(...keys.map((k) => {
    const input = el("input", { type: "password", placeholder: k.state === "missing" ? "Paste a key" : "Replace key", autocomplete: "off" });
    const stateText = k.state === "saved" ? "Saved" : k.state === "environment" ? `From ${k.variable}` : "Not set";
    const save = el("button", { type: "button", textContent: "Save", onclick: async () => {
      if (!input.value.trim()) return;
      await call("save_key", { provider: k.provider, key: input.value.trim() });
      toast(`${k.label} key saved.`);
      renderKeys(await call("list_keys"));
    } });
    const remove = el("button", { type: "button", className: "ghost", textContent: "Remove", disabled: k.state !== "saved", onclick: async () => {
      await call("remove_key", { provider: k.provider });
      renderKeys(await call("list_keys"));
    } });
    return el("div", { className: "key" },
      el("span", {}, el("div", { textContent: k.label }), el("div", { className: `state ${k.state}`, textContent: stateText })),
      input, save, remove);
  }));
}

async function saveSettings(event) {
  event.preventDefault();
  const settings = {
    ...state.settings,
    whisperModel: $("s-model").value,
    sourceLanguage: $("s-source").value,
    useGpu: $("s-gpu").checked,
    beamSize: Math.min(16, Math.max(1, Number($("s-beam").value) || 5)),
    translationModel: $("s-tmodel").value.trim() || state.settings.translationModel,
    translationTargetLanguage: $("s-target").value.trim() || "English",
    translationSourceLanguage: $("s-tsource").value.trim() || "auto",
    translationChunkMode: $("s-chunk").value,
    translationParallelism: Math.min(4, Math.max(1, Number($("s-parallel").value) || 2)),
    localEndpoint: $("s-endpoint").value.trim() || state.settings.localEndpoint,
    autoTranslate: $("s-auto-translate").checked,
    generateSummary: $("s-summary").checked,
    summaryDetail: $("s-summary-detail").value,
    summaryModel: $("s-summary-model").value.trim(),
    summaryFallbackModel: $("s-summary-fallback").value.trim(),
    autoStartAddedJobs: $("s-auto-start").checked,
    autoExportSidecars: $("s-sidecars").checked,
    sidecarBilingual: $("s-bilingual").checked,
    keepInTray: $("s-tray").checked,
    notifications: $("s-notify").checked,
    keepAwake: $("s-awake").checked,
    downloadFolder: state.downloadFolder || "",
  };
  await call("save_settings", { settings });
  $("settings").close();
  toast("Settings saved. They apply to the next job that starts.");
}

function renderYtdlp(path) {
  $("ytdlp-state").textContent = path ? `yt-dlp: ${path}` : "yt-dlp isn't installed. Cue can fetch the official release from GitHub.";
  $("ytdlp-install").textContent = path ? "Update yt-dlp" : "Install yt-dlp";
}

async function installYtdlp() {
  const button = $("ytdlp-install");
  button.disabled = true;
  button.textContent = "Installing…";
  try {
    const path = await call("install_ytdlp");
    renderYtdlp(path);
    toast("yt-dlp is installed.");
  } catch {
    renderYtdlp((await call("diagnostics")).ytdlp);
  } finally {
    button.disabled = false;
  }
}

// MARK: Watch folders

function renderWatch() {
  const list = $("watch-list");
  if (!list) return;
  if (!state.watch.length) {
    list.replaceChildren(el("li", { className: "muted", textContent: "No folders yet." }));
    return;
  }
  list.replaceChildren(...state.watch.map((folder) => {
    const profile = folder.profile || {};
    const enabled = el("input", { type: "checkbox", checked: folder.enabled, title: "Watch this folder" });
    const source = el("select");
    fillSelect(source, [["", "Default"], ...LANGUAGES], profile.sourceLanguage || "");
    const target = el("input", { value: profile.translationTargetLanguage || "", placeholder: "Default" });
    target.setAttribute("list", "target-languages");
    const model = el("input", { value: profile.openAIModel || "", placeholder: "Default" });
    model.setAttribute("list", "translation-models");
    const save = () => call("set_watch_folder", {
      id: folder.id,
      enabled: enabled.checked,
      profile: { sourceLanguage: source.value, translationTargetLanguage: target.value.trim(), openAIModel: model.value.trim() },
    });
    for (const input of [enabled, source, target, model]) input.addEventListener("change", save);
    const clear = el("button", { type: "button", className: "ghost", textContent: "Run again", title: "Forget which files already ran, so they are queued again",
      onclick: async () => {
        if (!confirmAction(`Queue every video in ${folder.name} again? Files already in the list are skipped.`)) return;
        await call("clear_watch_history", { id: folder.id });
        toast(`${folder.name}: history cleared.`);
      } });
    const remove = el("button", { type: "button", className: "ghost danger", textContent: "Remove",
      onclick: () => call("remove_watch_folder", { id: folder.id }) });
    const item = el("li", {},
      el("div", { className: "head" }, enabled, el("span", { className: "path", textContent: folder.path, title: folder.path }), clear, remove),
      el("div", { className: "profile" },
        el("label", {}, "Spoken language", source),
        el("label", {}, "Translate to", target),
        el("label", {}, "Translation model", model)));
    if (folder.error) item.append(el("p", { className: "error-text", textContent: folder.error }));
    return item;
  }));
}

// MARK: Downloads

function renderDownloads() {
  $("downloads").replaceChildren(...[...state.downloads.values()].map((d) => {
    const running = d.status === "running";
    const bar = el("div", { className: "bar" + (running && d.fraction == null ? " indeterminate" : "") }, el("div"));
    bar.firstChild.style.width = d.fraction != null ? `${Math.round(d.fraction * 100)}%` : "";
    bar.hidden = !running;
    const action = running
      ? el("button", { className: "ghost", textContent: "Cancel", onclick: () => call("cancel_download", { id: d.id }) })
      : el("button", { className: "ghost", textContent: "Dismiss", onclick: () => call("dismiss_download", { id: d.id }) });
    const open = d.jobId ? el("button", { className: "ghost", textContent: "Open", onclick: () => select(d.jobId) }) : null;
    const row = el("div", { className: "row" }, el("span", { className: "url", textContent: d.url, title: d.url }));
    if (open) row.append(open);
    row.append(action);
    return el("li", { className: d.status }, row, el("span", { className: "detail-text", textContent: d.detail }), bar);
  }));
}

function openUrl() {
  $("url-input").value = "";
  $("url").showModal();
  $("url-input").focus();
}

async function runUrl() {
  const text = $("url-input").value.trim();
  if (!text) return;
  await call("add_url", { url: text });
  $("url").close();
}

// MARK: Burn-in

async function openBurn() {
  const summary = state.jobs.get(state.selected);
  const hasTranslation = summary && summary.translationCount > 0;
  for (const radio of document.querySelectorAll('#burn input[name="burn-doc"]')) {
    radio.disabled = radio.value !== "original" && !hasTranslation;
    radio.checked = radio.value === (hasTranslation ? "translated" : "original");
  }
  state.burnOutput = null;
  $("burn-output").textContent = "Next to the video, as .subtitled.mp4";
  renderBurn();
  $("burn").showModal();
  try {
    await invoke("burn_in_preflight");
  } catch (error) {
    if (!state.burn?.running) {
      $("burn-error").hidden = false;
      $("burn-error").textContent = String(error);
      $("burn-go").disabled = true;
    }
  }
}

function renderBurn() {
  const burn = state.burn;
  const mine = burn && burn.jobId === state.selected;
  const running = Boolean(burn && burn.running);
  $("burn-go").disabled = running;
  $("burn-go").textContent = running && !mine ? "Another video is rendering" : "Burn in";
  $("burn-cancel").hidden = !running;
  $("burn-progress").hidden = !mine;
  $("burn-error").hidden = !(mine && burn.error);
  $("burn-error").textContent = mine && burn.error ? burn.error : "";
  if (mine) {
    $("burn-detail").textContent = burn.running ? burn.detail : burn.error ? "Failed." : `${burn.detail} ${burn.output}`;
    const bar = $("burn-bar").parentElement;
    bar.hidden = !burn.running;
    bar.classList.toggle("indeterminate", burn.running && burn.fraction == null);
    $("burn-bar").style.width = burn.fraction != null ? `${Math.round(burn.fraction * 100)}%` : "";
  }
}

async function runBurn() {
  const document_ = document.querySelector('#burn input[name="burn-doc"]:checked').value;
  const size = $("burn-size").value;
  await call("burn_in", { id: state.selected, document: document_, size, output: state.burnOutput });
}

// MARK: Command palette

function paletteCommands() {
  const summary = state.selected ? state.jobs.get(state.selected) : null;
  const commands = [
    ["Add videos…", addViaPicker],
    ["Add from URL…", openUrl],
    [state.queue.paused ? "Resume the queue" : "Pause the queue", () => call("set_paused", { paused: !state.queue.paused })],
    ["Open settings", openSettings],
    ["Watch a folder…", addWatchFolder],
  ];
  if (summary) {
    const running = isRunning(summary.status) || summary.status === "queued";
    if (running) commands.push(["Stop the selected video", () => call("cancel_job", { id: summary.id })]);
    if (!running && !summary.transcriptCount) commands.push(["Transcribe the selected video", () => call("start_job", { id: summary.id })]);
    if (!running && summary.transcriptCount) commands.push(["Translate the selected video", () => call("translate_job", { id: summary.id })]);
    if (summary.transcriptCount) commands.push(["Export subtitles…", openExport], ["Burn in subtitles…", openBurn]);
    if (!running && summary.transcriptCount) commands.push([summary.summary ? "Rewrite the intro summary" : "Write an intro summary", writeIntro]);
    commands.push(["Show the selected video in Explorer", () => call("reveal", { path: summary.sourcePath })]);
  }
  return commands.map(([label, run]) => ({ label, run, kind: "Command" }));
}

let paletteItems = [];
let paletteIndex = 0;

function openPalette() {
  if ($("palette").open) return;
  $("palette-input").value = "";
  renderPalette();
  $("palette").showModal();
  $("palette-input").focus();
}

function renderPalette() {
  const query = $("palette-input").value.trim().toLowerCase();
  const words = query.split(/\s+/).filter(Boolean);
  const matches = (text) => words.every((w) => text.toLowerCase().includes(w));
  const jobs = state.order.map((id) => state.jobs.get(id)).map((j) => ({ label: j.title, run: () => select(j.id), kind: j.statusLabel }));
  paletteItems = [...paletteCommands(), ...jobs].filter((item) => matches(item.label)).slice(0, 60);
  paletteIndex = Math.min(paletteIndex, Math.max(0, paletteItems.length - 1));
  if (!query) paletteIndex = 0;
  const list = $("palette-list");
  if (!paletteItems.length) {
    list.replaceChildren(el("li", { className: "empty", textContent: "Nothing matches." }));
    return;
  }
  list.replaceChildren(...paletteItems.map((item, index) => {
    const row = el("li", { className: index === paletteIndex ? "active" : "", role: "option" },
      el("span", { textContent: item.label }), el("span", { className: "kind", textContent: item.kind }));
    row.addEventListener("click", () => runPalette(index));
    row.addEventListener("mousemove", () => {
      if (paletteIndex !== index) { paletteIndex = index; renderPalette(); }
    });
    return row;
  }));
  list.children[paletteIndex]?.scrollIntoView({ block: "nearest" });
}

function runPalette(index) {
  const item = paletteItems[index];
  if (!item) return;
  $("palette").close();
  item.run();
}

function paletteKey(event) {
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    const step = event.key === "ArrowDown" ? 1 : -1;
    paletteIndex = (paletteIndex + step + paletteItems.length) % Math.max(1, paletteItems.length);
    renderPalette();
  } else if (event.key === "Enter") {
    event.preventDefault();
    runPalette(paletteIndex);
  }
}

async function addWatchFolder() {
  const id = await call("add_watch_folder");
  if (id) toast("Watching the folder. New videos there are queued automatically.");
}

// MARK: Export

function openExport() {
  const summary = state.jobs.get(state.selected);
  const hasTranslation = summary && summary.translationCount > 0;
  for (const box of document.querySelectorAll('#export input[name="doc"]')) {
    if (box.value !== "original") {
      box.disabled = !hasTranslation;
      box.checked = hasTranslation && box.value === "translated";
    }
  }
  state.exportFolder = null;
  $("export-folder").textContent = "Next to the video";
  $("export-result").replaceChildren();
  $("export").showModal();
}

async function runExport() {
  const documents = [...document.querySelectorAll('#export input[name="doc"]:checked')].map((b) => b.value);
  const formats = [...document.querySelectorAll('#export input[name="fmt"]:checked')].map((b) => b.value);
  if (!documents.length || !formats.length) return toast("Pick at least one file and one format.", "error");
  const paths = await call("export_job", { id: state.selected, documents, formats, folder: state.exportFolder });
  $("export-result").replaceChildren(...paths.map((p) =>
    el("li", {}, el("button", { type: "button", className: "link", textContent: p.split(/[\\/]/).pop(), title: `${p}\nShow in Explorer`, onclick: () => call("reveal", { path: p }) }))));
  toast(`Exported ${paths.length} file${paths.length === 1 ? "" : "s"}.`);
}

// MARK: Events

function applyEvent(event) {
  switch (event.type) {
    case "job": {
      const previous = state.jobs.get(event.job.id);
      state.jobs.set(event.job.id, event.job);
      if (!previous || previous.orderIndex !== event.job.orderIndex) sortOrder();
      renderList();
      updateQueueStatus();
      if (event.job.id === state.selected && state.job) {
        if (previous && previous.status !== event.job.status) refreshSelected();
        else renderJob();
      }
      break;
    }
    case "jobRemoved":
      state.jobs.delete(event.id);
      sortOrder();
      renderList();
      updateQueueStatus();
      if (event.id === state.selected) select(null);
      break;
    case "partialSegments":
      if (event.id === state.selected && state.job) {
        state.partial.push(...event.segments);
        renderCues();
      }
      break;
    case "segmentsChanged":
      if (event.id === state.selected) refreshSelected();
      break;
    case "queue":
      state.queue = event;
      updateQueueStatus();
      break;
    case "notice":
      toast(event.message, "error");
      break;
    case "watchFolders":
      state.watch = event.folders;
      renderWatch();
      break;
    case "download": {
      const previous = state.downloads.get(event.download.id);
      state.downloads.set(event.download.id, event.download);
      renderDownloads();
      if (previous?.status === "running" && event.download.status === "failed") toast(`Download failed: ${event.download.detail}`, "error");
      if (previous?.status === "running" && event.download.status === "done" && event.download.jobId && !state.selected) select(event.download.jobId);
      break;
    }
    case "downloadRemoved":
      state.downloads.delete(event.id);
      renderDownloads();
      break;
    case "burnIn": {
      const finished = state.burn?.running && !event.state.running;
      state.burn = event.state;
      if ($("burn").open) renderBurn();
      if (finished && !event.state.error && event.state.detail !== "Canceled.") {
        toast(`Saved ${baseName(event.state.output)}.`);
      } else if (finished && event.state.error && !$("burn").open) {
        toast(`Burn-in failed: ${event.state.error}`, "error");
      }
      break;
    }
  }
}

async function addViaPicker() {
  const ids = await call("pick_files");
  if (ids.length && !state.selected) select(ids[0]);
}

async function init() {
  fillSelect($("ov-source"), [["", "Default"], ...LANGUAGES]);
  fillDatalist($("target-languages"), TARGETS);
  fillDatalist($("translation-models"), MODELS);
  bindOverride("ov-source", "sourceLanguage");
  bindOverride("ov-target", "translationTargetLanguage");
  bindOverride("ov-model", "openAIModel");
  bindOverride("ov-summary", "generateSummary");
  bindOverride("ov-summary-detail", "summaryDetail");
  $("intro-generate").onclick = writeIntro;
  $("intro-save").onclick = () => saveIntro($("intro-text").value);
  $("intro-clear").onclick = () => saveIntro(null);

  $("add").onclick = addViaPicker;
  $("add-url").onclick = openUrl;
  $("url-go").onclick = runUrl;
  $("url-input").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); runUrl(); } });
  $("watch-add").onclick = addWatchFolder;
  $("ytdlp-install").onclick = installYtdlp;
  $("s-download-choose").onclick = async () => {
    const folder = await call("pick_folder");
    if (folder) {
      state.downloadFolder = folder;
      $("s-download-folder").textContent = folder;
    }
  };
  $("burn-go").onclick = runBurn;
  $("burn-cancel").onclick = () => call("cancel_burn_in");
  $("burn-choose").onclick = async () => {
    const path = await call("pick_burn_in_output", { id: state.selected });
    if (path) {
      state.burnOutput = path;
      $("burn-output").textContent = path;
    }
  };
  $("open-palette").onclick = openPalette;
  $("palette-input").addEventListener("input", renderPalette);
  $("palette-input").addEventListener("keydown", paletteKey);
  document.addEventListener("keydown", (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
      e.preventDefault();
      openPalette();
    }
  });
  $("welcome-add").onclick = addViaPicker;
  $("pause").onclick = () => call("set_paused", { paused: !state.queue.paused });
  $("open-settings").onclick = openSettings;
  $("settings-save").onclick = saveSettings;
  $("export-go").onclick = runExport;
  $("export-choose").onclick = async () => {
    const folder = await call("pick_folder");
    if (folder) {
      state.exportFolder = folder;
      $("export-folder").textContent = folder;
    }
  };
  $("job-path").onclick = () => call("reveal", { path: state.job.sourcePath });
  $("filter").addEventListener("input", renderList);
  $("search").addEventListener("input", renderCues);
  $("caption-mode").addEventListener("change", onTimeUpdate);
  const video = $("video");
  video.addEventListener("timeupdate", onTimeUpdate);
  video.addEventListener("seeked", onTimeUpdate);
  video.addEventListener("error", () => { if (state.job) $("video-note").hidden = false; });

  await listen("cue", (e) => applyEvent(e.payload));
  await listen("tauri://drag-enter", () => { $("drop").hidden = false; });
  await listen("tauri://drag-leave", () => { $("drop").hidden = true; });
  await listen("tauri://drag-drop", () => { $("drop").hidden = true; });

  for (const job of await call("list_jobs")) state.jobs.set(job.id, job);
  state.queue = await call("queue_state");
  for (const d of await call("list_downloads")) state.downloads.set(d.id, d);
  renderDownloads();
  sortOrder();
  renderList();
  updateQueueStatus();
  for (const failure of await call("startup_failures")) toast(failure, "error");
  if (state.order.length) select(state.order[0]);
}

init();
