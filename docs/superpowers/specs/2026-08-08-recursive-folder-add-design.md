# Recursive Folder Add — Design

**Date:** 2026-08-08
**Branch:** to be cut from master
**Status:** Implemented

## Goal

A folder always means "every video inside it, at any depth." Today none of the
folder entry points look into subfolders, and a folder dropped on the main
workspace becomes a junk job on a directory URL.

## Decisions taken

| Decision | Choice | Reason |
| --- | --- | --- |
| Scope | Both one-time adds AND watch folders recurse | Consistent semantics everywhere; user chose "Both". |
| Architecture | One shared recursive collector | Rejected: making WatchFolderScanEngine recursive and reusing it for one-time adds (drags stability-gate machinery into simple drops); ad-hoc recursion per call site (three copies). |
| File-count cap | None | Media-extension filter keeps real folders sane; unattended semantics mean "add what's there". |
| Zero-media folder | Alert on interactive adds | "No video or audio files found." (generic, not per-folder — a drop can mix multiple folders, so naming just one would be misleading.) Watch folders stay silent (nothing to ingest is normal). |

## 1. The scanner unit

`MediaFileTypes` (Sources/Models/MediaFileTypes.swift) gains:

```swift
static func collectMediaFiles(under url: URL) -> [URL]
```

Deep `FileManager.default.enumerator` walk over `url`:

- skips hidden files and hidden directories (`.skipsHiddenFiles`) and package
  contents (`.skipsPackageDescendants`)
- does not follow symlinked directories (enumerator default — cycle safety)
- includes only files whose lowercased path extension is in
  `MediaFileTypes.extensions`
- excludes files whose extension is in `partialDownloadExtensions`
- unreadable subfolders are skipped silently (enumerator default)
- returns paths sorted by `path` (localized-standard compare), so episodic
  folders enqueue in order

Pure with respect to its inputs on disk; unit-testable against a fixture tree.

## 2. One-time adds

- **Workspace drop** (`DetailView`'s `dropDestination`): directories among the
  dropped URLs are expanded via `collectMediaFiles(under:)`; plain files pass
  through as today. All resulting URLs go to the existing `addVideos(urls:)`
  in one batch (one `indicesForBatchAdd` call, so ordering is stable).
  This removes today's junk-job path for directory URLs.
- **Add Files picker** (`AppModel.selectVideo`): `canChooseDirectories = true`;
  panel message updated to say folders are searched including subfolders.
  Chosen directories expand the same way; files and folders can be mixed.
- **`AppModel.addMedia(urls:) -> Int`** (new, small): the shared entry for
  mixed file/folder lists — expands each directory via
  `collectMediaFiles(under:)`, passes files through, and hands the combined
  list to `addVideos` in ONE batch (one `indicesForBatchAdd` call). Returns
  the count added. Both the workspace drop and the picker call it; when the
  input contained at least one directory and the count is zero, the caller
  alerts ("No video or audio files found." — generic rather than per-folder,
  since a drop can mix multiple folders and naming just one would be
  misleading). The sidebar's folder-drop
  routing is untouched (folder dropped on the sidebar still starts watching
  it).

## 3. Watch folders

`WatchFolderService`'s scan replaces its top-level `contentsOfDirectory`
listing with `MediaFileTypes.collectMediaFiles(under:)`. Everything downstream
is already per-file-path and works unchanged on subpaths:

- the 2 s size-stability gate (per file)
- fingerprint dedup ("path|size|mtime") and the ledger
- implicit sidecars land next to each video, wherever it lives

**Known behavior change:** existing watch folders ingest videos already
sitting in subfolders on the first scan after this update. That is the chosen
semantics, not a bug; release notes should mention it.

kqueue note: the directory-watch hint only fires for top-level changes; the
60 s timer already covers subfolder changes, so subfolder ingest may lag up to
a minute behind the hint-driven path. Acceptable; no new watchers.

## 4. Out of scope

- Per-subfolder settings/profiles (a watch folder's profile applies to
  everything under it).
- Any cap, confirmation dialog, or progress UI for large folders.
- Following symlinks.

## 5. Testing

All swift-testing via `./script/run_tests.sh`:

- Scanner: fixture tree with nested subfolders, hidden files, non-media
  files, partial downloads (`.part`), and mixed case extensions — asserts
  exactly the media files return, sorted, hidden/partial excluded.
- Watch scan: a file in a subfolder is discovered and ingested through the
  existing scan-engine path.
- `addMedia`: mixed files + folders produce one batch in stable order;
  returns the collected count; zero-media folder returns 0 and adds nothing.
