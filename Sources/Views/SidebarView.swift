import AppKit
import SwiftUI

/// Status buckets for the optional grouped sidebar view, in display order.
private enum JobGroup: String, CaseIterable, Identifiable {
    case running
    case queued
    case notStarted
    case done
    case canceled
    case failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .running: return "Running"
        case .queued: return "Queued"
        case .notStarted: return "Not Started"
        case .done: return "Done"
        case .canceled: return "Canceled"
        case .failed: return "Failed"
        }
    }

    init(status: JobStatus) {
        switch status {
        case .transcribing, .translating, .burningIn:
            self = .running
        case .queued:
            self = .queued
        case .idle:
            self = .notStarted
        case .transcriptionComplete, .translationComplete:
            self = .done
        case .canceled:
            self = .canceled
        case .failed:
            self = .failed
        }
    }
}

/// Status filter for the sidebar; coarser than JobGroup on purpose — it
/// answers "what am I looking for", not "what exact state is this in".
private enum JobStatusFilter: String, CaseIterable, Identifiable {
    case all
    case inProgress
    case done
    case stopped
    case archived

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .stopped: return "Canceled & Failed"
        case .archived: return "Archived"
        }
    }

    func includes(_ job: TranscriptionJob) -> Bool {
        // Archived jobs appear only under their own filter, so day-to-day
        // views stay small no matter how much history accumulates.
        guard self != .archived else { return job.archivedAt != nil }
        guard job.archivedAt == nil else { return false }
        switch self {
        case .all, .archived:
            return true
        case .inProgress:
            return job.status.isRunning || job.status == .queued || job.status == .idle
        case .done:
            return job.status == .transcriptionComplete || job.status == .translationComplete
        case .stopped:
            return job.status == .canceled || job.status == .failed
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var editingWatchFolderID: UUID?
    @AppStorage("sidebarGroupByStatus") private var groupByStatus = false
    @AppStorage("sidebarStatusFilter") private var statusFilterRaw = JobStatusFilter.all.rawValue
    @AppStorage("sidebarSortOrder") private var sortOrderRaw = JobSortOrder.queueOrder.rawValue

    var body: some View {
        List(
            selection: Binding(
                get: { model.selectedJobID },
                set: { model.selectJob($0) }
            )
        ) {
            watchFoldersSection
            if groupByStatus {
                groupedSections
            } else {
                flatSection
            }
        }
        .listStyle(.sidebar)
        // Dropping folders from Finder starts watching them; dropped files
        // become jobs, same as dropping on the main workspace.
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            var isDirectory: ObjCBool = false
            for url in fileURLs {
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    model.addWatchFolder(path: url.path)
                } else {
                    model.addVideos(urls: [url])
                }
            }
            return true
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search jobs")
        // Sheet lives on the List, not inside a Section: section-scoped
        // sheets present unreliably on macOS.
        .sheet(
            item: Binding(
                get: { editingWatchFolderID.flatMap { id in settingsWatchFolders.first { $0.id == id } } },
                set: { editingWatchFolderID = $0?.id }
            )
        ) { folder in
            JobSettingsOverridesView(
                title: "Watch Folder Settings — \(folder.name)",
                settings: model.settings,
                overrides: folder.profile
            ) { model.setWatchFolderProfile(folder.id, $0) }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Toggle(isOn: $groupByStatus) {
                        Label("Group by Status", systemImage: "rectangle.3.group")
                    }
                    Picker("Show", selection: $statusFilterRaw) {
                        ForEach(JobStatusFilter.allCases) { filter in
                            Text(filter.label).tag(filter.rawValue)
                        }
                    }
                    Picker("Sort by", selection: $sortOrderRaw) {
                        ForEach(JobSortOrder.allCases) { order in
                            Text(order.label).tag(order.rawValue)
                        }
                    }
                } label: {
                    Label("Organize", systemImage: organizeMenuIcon)
                        .help("Filter, sort, or group the job list")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if model.hasPendingWork || model.queuePaused {
                    Button {
                        model.startAllPendingJobs()
                    } label: {
                        Label(
                            model.queuePaused ? "Resume Queue" : "Start All",
                            systemImage: "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help("Queue every job that still needs transcription or translation")
                }
                if let eta = model.queueETAText {
                    Text(eta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.selectVideo()
                } label: {
                    Label("Add Files…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            // Rows scroll beneath the inset; without a backing material the
            // list text bleeds through the buttons.
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Watch folders

    @ViewBuilder
    private var watchFoldersSection: some View {
        Section("Watch Folders") {
            ForEach(settingsWatchFolders) { folder in
                WatchFolderRow(
                    folder: folder,
                    service: model.watchServices[folder.id],
                    needsProviderWarning: needsProviderWarning(folder)
                )
                .contextMenu { watchFolderMenu(for: folder) }
            }
            Button {
                addWatchFolderViaPanel()
            } label: {
                Label("Add Watch Folder…", systemImage: "folder.badge.plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(
                "Watch a folder: files dropped into it are transcribed and translated automatically, with subtitles saved next to each video. You can also drag a folder from Finder into this sidebar."
            )
        }
    }

    private var settingsWatchFolders: [WatchFolder] {
        model.settings.watchFolders
    }

    /// The folder promises translated output its provider can't deliver yet.
    private func needsProviderWarning(_ folder: WatchFolder) -> Bool {
        guard folder.enabled else { return false }
        let autoTranslate = folder.profile.autoTranslate ?? model.settings.autoTranslateAfterTranscription
        return autoTranslate && !model.settings.isTranslationReady
    }

    @ViewBuilder
    private func watchFolderMenu(for folder: WatchFolder) -> some View {
        Button {
            model.setWatchFolderEnabled(folder.id, !folder.enabled)
        } label: {
            Label(
                folder.enabled ? "Pause Watching" : "Resume Watching",
                systemImage: folder.enabled ? "pause.circle" : "play.circle")
        }
        Button {
            editingWatchFolderID = folder.id
        } label: {
            Label("Folder Settings…", systemImage: "slider.horizontal.3")
        }
        Button {
            revealInFinder(URL(fileURLWithPath: folder.path))
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Button {
            model.clearWatchHistory(for: folder.id)
        } label: {
            Label("Clear Watch History", systemImage: "clock.arrow.circlepath")
        }
        Divider()
        Button(role: .destructive) {
            model.removeWatchFolder(folder.id)
        } label: {
            Label("Stop Watching This Folder", systemImage: "trash")
        }
    }

    /// Deferred one runloop tick: revealing from inside a dismissing context
    /// menu races the menu teardown re-activating this app, which leaves
    /// Finder's window behind ours — indistinguishable from a dead button.
    private func revealInFinder(_ url: URL) {
        NSLog("reveal: requested %@", url.path)
        DispatchQueue.main.async {
            if FileManager.default.fileExists(atPath: url.path) {
                NSLog("reveal: file exists, revealing")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                // The file moved or was deleted; its folder is still useful.
                NSLog("reveal: file missing, opening parent")
                let opened = NSWorkspace.shared.open(url.deletingLastPathComponent())
                NSLog("reveal: open(parent) -> %d", opened ? 1 : 0)
            } else {
                NSLog("reveal: nothing exists at %@", url.path)
                NSSound.beep()
            }
        }
    }

    private func addWatchFolderViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders to watch. New videos dropped into them are processed automatically."
        if panel.runModal() == .OK {
            for url in panel.urls {
                model.addWatchFolder(path: url.path)
            }
        }
    }

    // MARK: - List content

    private var statusFilter: JobStatusFilter {
        JobStatusFilter(rawValue: statusFilterRaw) ?? .all
    }

    /// A filled funnel marks an active filter or non-default sort, so a
    /// shortened or rearranged list is never mistaken for missing jobs.
    private var organizeMenuIcon: String {
        statusFilter == .all && sortOrder == .queueOrder
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
    }

    private var sortOrder: JobSortOrder {
        JobSortOrder(rawValue: sortOrderRaw) ?? .queueOrder
    }

    private var visibleJobs: [TranscriptionJob] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = model.jobs.filter { job in
            guard statusFilter.includes(job) else { return false }
            guard !trimmedSearch.isEmpty else { return true }
            return job.title.localizedCaseInsensitiveContains(trimmedSearch)
        }
        guard sortOrder != .queueOrder else { return filtered }
        return sortOrder.sortedOffsets(of: filtered.map(JobSortOrder.Key.init(job:))).map { filtered[$0] }
    }

    /// Drag-reorder only works on the full flat list: reordering a filtered
    /// subset would move jobs relative to neighbours the user cannot see.
    private var isReorderable: Bool {
        !groupByStatus && statusFilter == .all && sortOrder == .queueOrder
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var flatSection: some View {
        Section("Jobs") {
            if visibleJobs.isEmpty {
                emptyPlaceholder
            } else if isReorderable {
                ForEach(visibleJobs) { job in
                    row(for: job)
                }
                .onMove { source, destination in
                    model.moveJobs(from: source, to: destination)
                }
            } else {
                ForEach(visibleJobs) { job in
                    row(for: job)
                }
            }
        }
    }

    @ViewBuilder
    private var groupedSections: some View {
        if visibleJobs.isEmpty {
            Section("Jobs") {
                emptyPlaceholder
            }
        } else {
            ForEach(JobGroup.allCases) { group in
                let jobs = visibleJobs.filter { JobGroup(status: $0.status) == group }
                if !jobs.isEmpty {
                    Section("\(group.label) (\(jobs.count))") {
                        ForEach(jobs) { job in
                            row(for: job)
                        }
                    }
                }
            }
        }
    }

    private func row(for job: TranscriptionJob) -> some View {
        JobRow(job: job, hasOverrides: !job.overrides.isEmpty)
            .tag(job.id)
            .contextMenu { contextMenu(for: job) }
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        Text(model.jobs.isEmpty ? "No jobs yet" : "No jobs match")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func contextMenu(for job: TranscriptionJob) -> some View {
        if model.jobNeedsWork(job) && job.status != .queued {
            Button {
                model.enqueueJob(job.id)
            } label: {
                Label("Add to Queue", systemImage: "clock")
            }
        }
        if job.status == .queued {
            Button {
                model.removeFromQueue(job.id)
            } label: {
                Label("Remove from Queue", systemImage: "clock.badge.xmark")
            }
        }
        Button {
            model.moveJobToTop(job.id)
        } label: {
            Label("Move to Top", systemImage: "arrow.up.to.line")
        }
        Button {
            model.moveJobToBottom(job.id)
        } label: {
            Label("Move to Bottom", systemImage: "arrow.down.to.line")
        }
        Button {
            model.overridesEditorJobID = job.id
        } label: {
            Label("Job Settings…", systemImage: "slider.horizontal.3")
        }
        .disabled(job.status.isRunning)
        if !job.transcriptSegments.isEmpty {
            Button {
                model.selectJob(job.id)
                model.isShowingBurnInSheet = true
            } label: {
                Label("Burn In Video…", systemImage: "film")
            }
            .disabled(model.isProcessing || job.status.isRunning)
        }
        Button {
            // Sidecars and burned-in videos land next to the source, so
            // revealing the source file IS the destination folder.
            revealInFinder(job.sourceURL)
        } label: {
            Label("Open Destination Folder", systemImage: "folder")
        }
        Divider()
        Button {
            model.setArchived(job.id, job.archivedAt == nil)
        } label: {
            Label(
                job.archivedAt == nil ? "Archive" : "Unarchive",
                systemImage: job.archivedAt == nil ? "archivebox" : "tray.and.arrow.up"
            )
        }
        .disabled(job.status.isRunning || job.status == .queued)
        Button(role: .destructive) {
            model.deleteJob(job.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(model.isJobActive(job.id))
    }
}

private struct WatchFolderRow: View {
    let folder: WatchFolder
    let service: WatchFolderService?
    let needsProviderWarning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.enabled ? "folder.fill.badge.gearshape" : "folder.badge.gearshape")
                .foregroundStyle(folder.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(hasError ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !folder.profile.isEmpty {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This folder has its own settings")
            }
            if needsProviderWarning {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Files will be transcribed but not translated until a translation API key or local server is configured")
            }
        }
        .padding(.vertical, 2)
        .help(folder.path)
    }

    private var hasError: Bool {
        folder.enabled && service?.lastError != nil
    }

    private var statusText: String {
        if !folder.enabled { return "Paused" }
        if let error = service?.lastError { return error }
        return "Watching"
    }
}

private struct JobRow: View {
    let job: TranscriptionJob
    let hasOverrides: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.status.systemImage)
                .foregroundStyle(job.status.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .lineLimit(1)
                Text(job.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hasOverrides {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This job has its own settings")
            }
        }
        .padding(.vertical, 2)
    }
}
