# Local LLM Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Translate (and generate intro summaries) with a local OpenAI-compatible server (LM Studio, Ollama, mlx-lm) — no API key, works offline, and works over the LAN (e.g. an M3 Ultra serving a MacBook).

**Architecture:** A new `local` translation provider selected by the `local/` model-name prefix (consistent with the existing claude-/gemini-/gpt- prefix routing). Requests go to `<user-configured base URL>/chat/completions` in OpenAI chat-completions format with `response_format: json_schema` (the dialect local servers actually speak — NOT the newer Responses API the cloud OpenAI path uses). No Authorization header required. The base URL is a persisted setting defaulting to LM Studio's `http://localhost:1234/v1`.

**Design decisions (locked):**
- Model string `local/<served-model-id>`; the prefix is stripped before the wire (`local/qwen3.6-35b` → model `"qwen3.6-35b"` in the request body). Empty remainder is allowed (LM Studio ignores the model field when one model is loaded) — send the remainder as-is, even empty.
- `TranslationProvider.infer` gains: prefix `local/` (case-insensitive, like the others) → `.local`. Label: `"Local server"`.
- No API key: `.local` must never throw `missingAPIKey`, and Settings/diagnostics must not warn about a missing key when a `local/` model is selected.
- Timeout for `.local` requests: 600 s (big local models on big chunks can exceed the 300 s the cloud providers use).
- `chat/completions` request body: `model`, `messages` [system, user], `response_format: {type: "json_schema", json_schema: {name, strict: true, schema}}`, `stream: false`. Response envelope: `choices[0].message.content` (string); `finish_reason == "length"` → `responseTooLarge` (mirrors the other providers).
- Both `translate` (chunk) and `summarize` paths use the same routing — they share `makeRequest`/`extractOutputText`, so a correct `.local` case in each covers both.
- Endpoint plumbing: the service's entry points receive the endpoint alongside the API key (follow how `apiKey` currently flows from AppModel/settings into the service; add `localEndpoint` the same way). URL join must tolerate a trailing slash on the stored base URL.
- Persisted setting `localTranslationEndpoint`, default `http://localhost:1234/v1`. Settings UI: a TextField "Local server URL" in the Translation section (visible always — it documents the feature), plus a preset entry in `AppSettingPresets.translationModels`: value `local/`, label "Local server (LM Studio / Ollama)".
- Validation: selecting a `local/` model with an empty/invalid URL string surfaces the existing orange validation-message pattern in Settings (follow `transcriptionValidationMessage`'s shape if a translation equivalent exists; if none exists, add nothing heavier than the diagnostics row below — do not build new validation machinery).
- Diagnostics: the translation-key row (EnvironmentDiagnosticsService, id `translation-key`) becomes provider-aware: for `.local` it reports "Local server — no API key needed." with state `.passed` (no reachability probe; YAGNI).

---

## Task 1: `.local` provider in TranslationService

**Files:**
- Modify: `Sources/Services/TranslationService.swift`
- Test: `Tests/WhisperDeskTests/TranslationServiceParsingTests.swift`

TDD, in the existing test file's style:
1. Failing tests: `TranslationProvider.infer(from: "local/qwen3.6-35b") == .local` (plus case-insensitivity and bare `local/`); `extractOutputText(provider: .local, data:)` parses a canned chat-completions envelope; `finish_reason: "length"` → `responseTooLarge`; request-building test if the file's existing patterns test `makeRequest` (follow precedent — if requests aren't currently unit-tested, don't start; test infer + parsing only).
2. Implement: `.local` case in the enum, `infer`, `label`; `makeRequest` `.local` branch (endpoint parameter threaded through with a default that keeps existing call sites compiling only if that matches house style — prefer explicit threading from the callers); `extractOutputText` `.local` branch decoding a new `ChatCompletionsEnvelope`; timeout 600 for `.local`; strip the `local/` prefix for the wire model; no auth header; `missingAPIKey` guard skips `.local`.
3. `./script/run_tests.sh` green. Commit: `"Add local OpenAI-compatible translation provider"`.

## Task 2: Settings, UI, and diagnostics

**Files:**
- Modify: `Sources/Models/AppSettingsStore.swift` (persisted `localTranslationEndpoint`, preset entry)
- Modify: `Sources/Views/SettingsView.swift` (URL TextField)
- Modify: `Sources/Services/EnvironmentDiagnosticsService.swift` + its call site in `Sources/Stores/AppModel.swift` (provider-aware translation-key row)
- Modify: whatever call sites thread `apiKey` into `TranslationService` (AppModel) — thread `localTranslationEndpoint` too
- Test: `Tests/WhisperDeskTests/AppSettingsStoreTests.swift` (default value + persistence round-trip), `Tests/WhisperDeskTests/EnvironmentDiagnosticsTests.swift` (local → key row passed)

TDD where the seams exist; `./script/run_tests.sh` green; manual check: build the app, select the local preset, confirm no key warning and the URL field edits/persists. Commit: `"Wire local translation endpoint through settings and diagnostics"`.

---

**Verification (end of both tasks):** full suite green; manual end-to-end optional if a local server is running (do NOT install LM Studio as part of this plan); README gets a short "Local translation" subsection under Optional engines in Task 2 (three sentences: what it is, the `local/` prefix, the URL setting — mention LM Studio's network-serve toggle for the two-Mac setup).
