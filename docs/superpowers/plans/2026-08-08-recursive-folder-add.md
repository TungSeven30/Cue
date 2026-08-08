# Recursive Folder Add Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A folder always means "every video inside it, at any depth" — for workspace drops, the Add Files picker, and watch folders — per `docs/superpowers/specs/2026-08-08-recursive-folder-add-design.md`.

**Architecture:** One shared recursive collector on `MediaFileTypes` feeds everything: a pure `expandForAdd` helper backs the new `AppModel.addMedia(urls:)` batch entry (workspace drop + picker), and a static observation collector on `WatchFolderService` replaces its top-level directory listing. Watch-folder stability gating, fingerprints, and the ledger already operate per file path and are untouched.

**Tech Stack:** Swift 6 toolchain in language mode 5, SwiftPM, swift-testing (`import Testing`, `@Test`, `#expect`, `@testable import Cue`).

## Global Constraints

- **Tests run ONLY via `./script/run_tests.sh`** — never bare `swift test` (CLT-only machine silently runs zero tests). The whole suite runs every time; no filtering.
- Suite baseline: 156 tests / 33 suites green — must stay green.
- The sidebar's folder-drop routing is untouched: a folder dropped on the *sidebar* still starts watching it; only the *workspace* drop and the picker expand folders into one-time jobs.
- Recursion rules (spec §1): skip hidden files/dirs and package descendants; do not follow symlinked directories; include only `MediaFileTypes.extensions`; exclude `partialDownloadExtensions`; sorted by localized-standard path compare; unreadable subfolders skipped silently.
- No file-count cap, no confirmation dialogs, no progress UI (spec §4).
- Match existing style; touch only what each task requires.
- Commits end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: MediaFileTypes recursive collector and add-expansion helper

**Files:**
- Modify: `Sources/Models/MediaFileTypes.swift`
- Test: `Tests/CueTests/MediaFileScannerTests.swift`

**Interfaces:**
- Consumes: existing `MediaFileTypes.extensions` and `partialDownloadExtensions` sets (same file).
- Produces (later tasks rely on these exact names):
  - `MediaFileTypes.collectMediaFiles(under url: URL) -> [URL]`
  - `MediaFileTypes.expandForAdd(urls: [URL]) -> [URL]` — files pass through, directories expand recursively, input order preserved (each input slot contributes its expansion in place).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Cue

@Suite struct MediaFileScannerTests {
    /// Builds: root/{a.mkv, notes.txt, .hidden.mp4, show/{ep2.mp4, ep1.mp4, partial.mp4.part}, show/extras/{clip.mov}, .hiddendir/{secret.mp4}}
    private func makeFixtureTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
        let show = root.appendingPathComponent("show", isDirectory: true)
        let extras = show.appendingPathComponent("extras", isDirectory: true)
        let hiddenDir = root.appendingPathComponent(".hiddendir", isDirectory: true)
        for dir in [root, show, extras, hiddenDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for name in ["a.mkv", "notes.txt", ".hidden.mp4"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
        }
        for name in ["ep2.mp4", "ep1.mp4", "partial.mp4.part"] {
            FileManager.default.createFile(atPath: show.appendingPathComponent(name).path, contents: Data())
        }
        FileManager.default.createFile(atPath: extras.appendingPathComponent("clip.mov").path, contents: Data())
        FileManager.default.createFile(atPath: hiddenDir.appendingPathComponent("secret.mp4").path, contents: Data())
        return root
    }

    @Test func collectsOnlyMediaRecursivelySorted() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = MediaFileTypes.collectMediaFiles(under: root)
        // Assert full relative paths, not lastPathComponent — the sorted
        // order across directories is part of the contract.
        let relative = found.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        #expect(relative == ["a.mkv", "show/ep1.mp4", "show/ep2.mp4", "show/extras/clip.mov"])
    }

    @Test func emptyOrNonMediaFolderYieldsNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("readme.md").path, contents: Data())
        #expect(MediaFileTypes.collectMediaFiles(under: root).isEmpty)
    }

    @Test func expandForAddMixesFilesAndFoldersInOrder() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let loose = root.appendingPathComponent("a.mkv")
        let folder = root.appendingPathComponent("show", isDirectory: true)
        let expanded = MediaFileTypes.expandForAdd(urls: [loose, folder])
        let names = expanded.map(\.lastPathComponent)
        #expect(names == ["a.mkv", "ep1.mp4", "ep2.mp4", "clip.mov"])
    }
}
```

- [ ] **Step 2: Run the suite to verify the new tests fail**

Run: `./script/run_tests.sh 2>&1 | tail -5`
Expected: compile error — `collectMediaFiles`/`expandForAdd` don't exist.

- [ ] **Step 3: Implement** (append inside the `MediaFileTypes` enum)

```swift
/// Every media file under `url`, at any depth: hidden files/directories
/// and package contents skipped, symlinked directories not followed,
/// partial downloads excluded, sorted by path so episodic folders
/// enqueue in order.
static func collectMediaFiles(under url: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    var found: [URL] = []
    for case let candidate as URL in enumerator {
        guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let ext = candidate.pathExtension.lowercased()
        guard extensions.contains(ext), !partialDownloadExtensions.contains(ext) else { continue }
        found.append(candidate)
    }
    return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
}

/// Expands an interactive add: files pass through, folders contribute
/// their recursive media contents in place, so a mixed drop keeps its
/// order. Used by the workspace drop and the file picker.
static func expandForAdd(urls: [URL]) -> [URL] {
    urls.flatMap { url -> [URL] in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        return isDirectory.boolValue ? collectMediaFiles(under: url) : [url]
    }
}
```

Note: the `.part`/`.download`/`.crdownload` exclusion via `partialDownloadExtensions` only fires when the partial marker IS the path extension (`ep.mp4.part` has extension `part`), which is exactly how the watch-folder scan already treats these — no new semantics.

- [ ] **Step 4: Run the suite to verify it passes** — `./script/run_tests.sh 2>&1 | tail -5`; all green (159 tests expected).

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/MediaFileTypes.swift Tests/CueTests/MediaFileScannerTests.swift
git commit -m "Add recursive media collection to MediaFileTypes"
```

---

### Task 2: addMedia batch entry — workspace drop and picker expand folders

**Files:**
- Modify: `Sources/Stores/AppModel.swift` (next to `addVideos`, ~line 363; and `selectVideo`, ~line 327)
- Modify: `Sources/Views/DetailView.swift` (the `.dropDestination` at ~line 47)

**Interfaces:**
- Consumes: Task 1's `MediaFileTypes.expandForAdd(urls:)`; existing `addVideos(urls:)`.
- Produces: `AppModel.addMedia(urls: [URL]) -> Int` (discardable).

No new unit tests: the expansion logic is Task 1's tested helper; `addMedia` is a thin `@MainActor` pass-through on `AppModel`, which has no test harness (established codebase pattern) — verified by the suite staying green plus the build.

- [ ] **Step 1: Add `addMedia` to AppModel** (directly above `addVideos`)

```swift
/// Adds a mixed list of files and folders: folders contribute every
/// media file inside them, at any depth, in one batch. Returns how many
/// jobs were added so interactive callers can tell an empty folder from
/// a successful add.
@discardableResult
func addMedia(urls: [URL]) -> Int {
    let expanded = MediaFileTypes.expandForAdd(urls: urls)
    addVideos(urls: expanded)
    return expanded.count
}
```

- [ ] **Step 2: Route the workspace drop through it, with the zero-media alert**

In `DetailView.swift`, replace the drop handler body:

```swift
.dropDestination(for: URL.self) { urls, _ in
    let fileURLs = urls.filter(\.isFileURL)
    guard !fileURLs.isEmpty else { return false }
    var isDirectory: ObjCBool = false
    let containsFolder = fileURLs.contains { url in
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    let added = model.addMedia(urls: fileURLs)
    if added == 0 && containsFolder {
        let alert = NSAlert()
        alert.messageText = "No Video or Audio Files Found"
        alert.informativeText = "The dropped folder does not contain any video or audio files."
        alert.alertStyle = .informational
        alert.runModal()
    }
    return added > 0
}
```

Add `import AppKit` to DetailView.swift if not already imported (check the file head; SwiftUI on macOS usually pulls it in — only add if the build complains).

- [ ] **Step 3: Let the picker choose directories**

In `AppModel.selectVideo`, set `panel.canChooseDirectories = true`, change the message to `"Choose video or audio files, or folders to add everything inside them (including subfolders)."`, and replace `addVideos(urls: panel.urls)` with:

```swift
let added = addMedia(urls: panel.urls)
if added == 0, panel.urls.contains(where: { url in
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}) {
    let alert = NSAlert()
    alert.messageText = "No Video or Audio Files Found"
    alert.informativeText = "The chosen folder does not contain any video or audio files."
    alert.alertStyle = .informational
    alert.runModal()
}
```

Keep `allowedContentTypes` as is — with directories allowed, folders are selectable regardless, and files stay filtered to media types.

- [ ] **Step 4: Build and run the suite** — `swift build 2>&1 | tail -3` then `./script/run_tests.sh 2>&1 | tail -3`; green, no new warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/Stores/AppModel.swift Sources/Views/DetailView.swift
git commit -m "Expand folders recursively for workspace drops and the file picker"
```

---

### Task 3: Watch folders scan subfolders, plus docs

**Files:**
- Modify: `Sources/Services/WatchFolderService.swift` (the `scan()` listing, ~lines 83-117)
- Modify: `CLAUDE.md` (watch-folder paragraph, one clause)
- Test: `Tests/CueTests/WatchFolderTests.swift` (append one test to the existing suite file)

**Interfaces:**
- Consumes: Task 1's `MediaFileTypes.collectMediaFiles(under:)`.
- Produces: `WatchFolderService.observeMediaFiles(underPath: String) -> [FileObservation]?` (static; `nil` when the folder itself is unreadable, `[]` when readable but empty).

- [ ] **Step 1: Write the failing test** (append to the existing `WatchFolderTests` suite; match its existing helper style for temp dirs)

```swift
@Test func observesMediaFilesInSubfolders() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("watch-recursive-\(UUID().uuidString)", isDirectory: true)
    let sub = root.appendingPathComponent("season1", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    FileManager.default.createFile(atPath: root.appendingPathComponent("top.mp4").path, contents: Data("x".utf8))
    FileManager.default.createFile(atPath: sub.appendingPathComponent("ep1.mkv").path, contents: Data("xx".utf8))
    FileManager.default.createFile(atPath: sub.appendingPathComponent("notes.txt").path, contents: Data())

    let observations = try #require(WatchFolderService.observeMediaFiles(underPath: root.path))
    let names = Set(observations.map { URL(fileURLWithPath: $0.path).lastPathComponent })
    #expect(names == ["top.mp4", "ep1.mkv"])
    let sizes = Dictionary(uniqueKeysWithValues: observations.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.size) })
    #expect(sizes["ep1.mkv"] == 2)
}

@Test func observeMediaFilesReturnsNilForMissingFolder() {
    #expect(WatchFolderService.observeMediaFiles(underPath: "/nonexistent/\(UUID().uuidString)") == nil)
}
```

If `FileObservation` is not visible from the test target under that name, check its declaring file (`WatchFolderScanEngine.swift`) — it is used in existing tests, so it is reachable; mirror however they reference it.

- [ ] **Step 2: Run the suite to verify the new tests fail** — compile error (`observeMediaFiles` undefined).

- [ ] **Step 3: Implement**

Add to `WatchFolderService`:

```swift
/// Snapshot of every media file under the folder, at any depth. `nil`
/// when the folder itself is unreadable (unmounted volume), so callers
/// can distinguish "gone" from "empty".
static func observeMediaFiles(underPath path: String) -> [FileObservation]? {
    let folderURL = URL(fileURLWithPath: path, isDirectory: true)
    var probeIsDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &probeIsDirectory), probeIsDirectory.boolValue else {
        return nil
    }
    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
    return MediaFileTypes.collectMediaFiles(under: folderURL).compactMap { url in
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true
        else { return nil }
        return FileObservation(
            path: url.path,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        )
    }
}
```

Rework `scan()` to use it, preserving the unreadable-folder error path:

```swift
func scan() {
    guard let watchedPath else { return }
    guard let observations = Self.observeMediaFiles(underPath: watchedPath) else {
        // Do not spin or tear down: the folder may be a briefly
        // unmounted volume. The timer keeps trying; Settings shows this.
        lastError = "The watch folder could not be read."
        return
    }
    lastError = nil

    let ready = engine.filesReadyToIngest(
        observations: observations,
        now: Date(),
        blockedFingerprints: blockedFingerprints()
    )
    onScanCompleted(watchedPath, Set(observations.map(\.path)))
    if !ready.isEmpty {
        onFilesReady(ready.map { URL(fileURLWithPath: $0.path) })
    }
}
```

Behavior note to preserve: the old code passed ALL regular files to the engine (the engine does its own media filtering); the new observation list is pre-filtered to media files. The engine's filter still runs — double filtering is harmless and keeps the engine's contract unchanged. The `onScanCompleted` path set (ledger pruning) now contains only media paths — correct, since the ledger only ever records ingested media files.

- [ ] **Step 4: Update CLAUDE.md**

In the watch-folder sentence of the Architecture section, extend the `WatchFolderScanEngine` clause to say the scan is recursive — e.g. change "`WatchFolderScanEngine` (diffing the folder)" to "`WatchFolderScanEngine` (diffing the folder, scanned recursively through subfolders)". One clause; do not rewrite the paragraph.

- [ ] **Step 5: Run the suite** — `./script/run_tests.sh 2>&1 | tail -3`; all green (161 tests expected).

- [ ] **Step 6: Commit**

```bash
git add Sources/Services/WatchFolderService.swift Tests/CueTests/WatchFolderTests.swift CLAUDE.md
git commit -m "Scan watch folders recursively through subfolders"
```

---

## Manual smoke (user-owed, quick)

- Drop a folder with nested episode subfolders on the workspace: jobs appear in alphabetical order, one per video, none for the folder itself.
- Add Files → pick a folder: same result; pick an empty folder: the informational alert appears.
- Drop a folder on the *sidebar*: still becomes a watch folder; drop a file into one of its *subfolders*: ingested within ~a minute (timer-driven).
