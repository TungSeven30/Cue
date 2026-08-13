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
    case running
    case queued
    case done
    case stopped
    case failed
    case archived

    var id: String { rawValue }

    static let quickCases: [JobStatusFilter] = [.all, .running, .queued, .done, .failed]

    var label: String {
        switch self {
        case .all: return "All"
        case .inProgress: return "In Progress"
        case .running: return "Running"
        case .queued: return "Queued"
        case .done: return "Done"
        case .stopped: return "Canceled & Failed"
        case .failed: return "Failed"
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
        case .running:
            return job.status.isRunning
        case .queued:
            return job.status == .queued
        case .done:
            return job.status == .transcriptionComplete || job.status == .translationComplete
        case .stopped:
            return job.status == .canceled || job.status == .failed
        case .failed:
            return job.status == .failed
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var editingWatchFolderID: UUID?
    @State private var pendingDeletionIDs: Set<UUID> = []
    @State private var undoNotice: SidebarUndoNotice?
    @AppStorage("sidebarGroupByStatus") private var groupByStatus = false
    @AppStorage("sidebarStatusFilter") private var statusFilterRaw = JobStatusFilter.all.rawValue
    @AppStorage("sidebarSortOrder") private var sortOrderRaw = JobSortOrder.queueOrder.rawValue

    var body: some View {
        // Counts, queue positions, selection groups, and visible rows all come
        // from one pass so the extra UI does not regress large-list behavior.
        let listState = makeSidebarListState()
        List(
            selection: Binding(
                get: { model.selectedJobIDs },
                set: { model.selectJobs($0) }
            )
        ) {
            watchFoldersSection
            jobControlsSection(listState.counts)
            if groupByStatus {
                groupedSections(listState)
            } else {
                flatSection(listState)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            requestDeletion(of: model.selectedJobIDs)
        }
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
        .task(id: undoNotice?.id) {
            guard let noticeID = undoNotice?.id else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, undoNotice?.id == noticeID else { return }
            undoNotice = nil
        }
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
            if model.selectedJobIDs.count > 1 {
                ToolbarItem {
                    Text("\(model.selectedJobIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Actions in a selected job's shortcut menu apply to the selection")
                }
            }
            if !model.selectedJobIDs.isEmpty {
                ToolbarItem {
                    Button(role: .destructive) {
                        requestDeletion(of: model.selectedJobIDs)
                    } label: {
                        Label(deleteSelectionLabel, systemImage: "trash")
                            .help(deleteSelectionHelp)
                    }
                    .disabled(!model.canDeleteJobs(model.selectedJobIDs))
                }
            }
            ToolbarItem {
                Menu {
                    if !listState.retryableFailedIDs.isEmpty {
                        Button {
                            model.retryFailedJobs(listState.retryableFailedIDs)
                        } label: {
                            Label(
                                retryFailedLabel(listState.retryableFailedIDs.count),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        Divider()
                    }
                    Menu {
                        Button("Select All Visible") {
                            model.selectJobs(Set(listState.displayedJobs.map(\.id)))
                        }
                        .disabled(listState.displayedJobs.isEmpty)
                        Divider()
                        Button("Select Running") {
                            selectJobs(listState.runningIDs, showing: .running)
                        }
                        .disabled(listState.runningIDs.isEmpty)
                        Button("Select Queued") {
                            selectJobs(listState.queuedIDs, showing: .queued)
                        }
                        .disabled(listState.queuedIDs.isEmpty)
                        Button("Select Completed") {
                            selectJobs(listState.doneIDs, showing: .done)
                        }
                        .disabled(listState.doneIDs.isEmpty)
                        Button("Select Failed") {
                            selectJobs(listState.failedIDs, showing: .failed)
                        }
                        .disabled(listState.failedIDs.isEmpty)
                        Divider()
                        Button("Clear Selection") {
                            model.selectJobs([])
                        }
                        .disabled(model.selectedJobIDs.isEmpty)
                    } label: {
                        Label("Select Jobs", systemImage: "checkmark.circle")
                    }
                    Divider()
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
        .alert(
            deletionAlertTitle,
            isPresented: Binding(
                get: { !pendingDeletionIDs.isEmpty },
                set: { if !$0 { pendingDeletionIDs = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDeletionIDs = []
            }
            Button(deletionButtonTitle, role: .destructive) {
                let ids = pendingDeletionIDs
                pendingDeletionIDs = []
                model.deleteJobs(ids)
            }
        } message: {
            Text(deletionAlertMessage)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let undoNotice {
                    HStack(spacing: 8) {
                        Text(undoNotice.message)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Undo") {
                            performUndo(undoNotice)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if model.hasPendingWork || model.queuePaused {
                    HStack(spacing: 8) {
                        Button {
                            model.startSelectedJob()
                        } label: {
                            Label("Start", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!model.canStartSelectedJob)
                        .help(
                            model.selectedJobIDs.count == 1
                                ? "Start only the selected job; other queued jobs stay paused"
                                : "Select exactly one job to start"
                        )

                        Button {
                            model.startAllPendingJobs()
                        } label: {
                            Label(
                                model.queuePaused ? "Resume Queue" : "Start All",
                                systemImage: "play.rectangle.on.rectangle.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .help("Queue every job that still needs transcription or translation")
                    }
                    .controlSize(.large)
                }
                if let summary = model.queueSummaryText {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
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

    private func retryFailedLabel(_ count: Int) -> String {
        count == 1 ? "Retry Failed Job" : "Retry \(count) Failed Jobs"
    }

    private func selectJobs(_ ids: Set<UUID>, showing filter: JobStatusFilter) {
        statusFilterRaw = filter.rawValue
        model.selectJobs(ids)
    }

    private var deleteSelectionLabel: String {
        model.selectedJobIDs.count == 1
            ? "Delete Job"
            : "Delete \(model.selectedJobIDs.count) Jobs"
    }

    private var deleteSelectionHelp: String {
        if model.canDeleteJobs(model.selectedJobIDs) {
            return "Remove the selected jobs from Cue"
        }
        return "Cancel active selected jobs before deleting them"
    }

    private var deletionAlertTitle: String {
        pendingDeletionIDs.count == 1
            ? "Delete Job?"
            : "Delete \(pendingDeletionIDs.count) Jobs?"
    }

    private var deletionButtonTitle: String {
        pendingDeletionIDs.count == 1
            ? "Delete Job"
            : "Delete Jobs"
    }

    private var deletionAlertMessage: String {
        let subject = pendingDeletionIDs.count == 1 ? "This job" : "These jobs"
        return "\(subject) will be removed from Cue. Source media and exported files will not be deleted."
    }

    private func requestDeletion(of ids: Set<UUID>) {
        guard model.canDeleteJobs(ids) else { return }
        pendingDeletionIDs = ids
    }

    private func selectionTargets(for job: TranscriptionJob) -> Set<UUID> {
        if model.selectedJobIDs.count > 1, model.selectedJobIDs.contains(job.id) {
            return model.selectedJobIDs
        }
        return [job.id]
    }

    private func actionTargets(for job: TranscriptionJob) -> JobActionTargets {
        let ids = selectionTargets(for: job)
        var queueableIDs = Set<UUID>()
        var retryableFailedIDs = Set<UUID>()
        var queuedIDs = Set<UUID>()
        var archivableIDs = Set<UUID>()
        var unarchivableIDs = Set<UUID>()
        for candidate in model.jobs where ids.contains(candidate.id) {
            if model.jobNeedsWork(candidate) && candidate.status != .queued {
                if candidate.status == .failed {
                    retryableFailedIDs.insert(candidate.id)
                } else {
                    queueableIDs.insert(candidate.id)
                }
            }
            if candidate.status == .queued {
                queuedIDs.insert(candidate.id)
            }
            if !candidate.status.isRunning && candidate.status != .queued {
                if candidate.archivedAt == nil {
                    archivableIDs.insert(candidate.id)
                } else {
                    unarchivableIDs.insert(candidate.id)
                }
            }
        }
        return JobActionTargets(
            ids: ids,
            queueableIDs: queueableIDs,
            retryableFailedIDs: retryableFailedIDs,
            queuedIDs: queuedIDs,
            archivableIDs: archivableIDs,
            unarchivableIDs: unarchivableIDs
        )
    }

    private func makeSidebarListState() -> SidebarListState {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var counts = SidebarJobCounts()
        var queuePositions: [UUID: Int] = [:]
        var displayedJobs: [TranscriptionJob] = []
        var runningIDs = Set<UUID>()
        var queuedIDs = Set<UUID>()
        var doneIDs = Set<UUID>()
        var failedIDs = Set<UUID>()
        var retryableFailedIDs = Set<UUID>()
        var nextQueuePosition = 1

        for job in model.jobs {
            let matchesSearch = trimmedSearch.isEmpty || job.title.localizedCaseInsensitiveContains(trimmedSearch)
            if job.archivedAt == nil {
                counts.record(job)
                if job.status == .queued {
                    queuePositions[job.id] = nextQueuePosition
                    nextQueuePosition += 1
                }
                if matchesSearch {
                    if job.status.isRunning { runningIDs.insert(job.id) }
                    if job.status == .queued { queuedIDs.insert(job.id) }
                    if job.status == .transcriptionComplete || job.status == .translationComplete {
                        doneIDs.insert(job.id)
                    }
                    if job.status == .failed {
                        failedIDs.insert(job.id)
                        if model.jobNeedsWork(job) {
                            retryableFailedIDs.insert(job.id)
                        }
                    }
                }
            }
            if statusFilter.includes(job) && matchesSearch {
                displayedJobs.append(job)
            }
        }

        if sortOrder != .queueOrder {
            displayedJobs = sortOrder.sortedOffsets(of: displayedJobs.map(JobSortOrder.Key.init(job:))).map {
                displayedJobs[$0]
            }
        }
        return SidebarListState(
            displayedJobs: displayedJobs,
            counts: counts,
            queuePositions: queuePositions,
            runningIDs: runningIDs,
            queuedIDs: queuedIDs,
            doneIDs: doneIDs,
            failedIDs: failedIDs,
            retryableFailedIDs: retryableFailedIDs
        )
    }

    /// Drag-reorder only works on the full flat list: reordering a filtered
    /// subset would move jobs relative to neighbours the user cannot see.
    private var isReorderable: Bool {
        !groupByStatus && statusFilter == .all && sortOrder == .queueOrder
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func jobControlsSection(_ counts: SidebarJobCounts) -> some View {
        Section("Jobs") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(JobStatusFilter.quickCases) { filter in
                        JobFilterChip(
                            label: filter.label,
                            count: counts.count(for: filter),
                            isSelected: statusFilter == filter
                        ) {
                            statusFilterRaw = filter.rawValue
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 4, trailing: 8))
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func flatSection(_ state: SidebarListState) -> some View {
        Section {
            if state.displayedJobs.isEmpty {
                emptyPlaceholder
            } else if isReorderable {
                ForEach(state.displayedJobs) { job in
                    row(for: job, queuePosition: state.queuePositions[job.id])
                }
                .onMove { source, destination in
                    model.moveJobs(from: source, to: destination)
                }
            } else {
                ForEach(state.displayedJobs) { job in
                    row(for: job, queuePosition: state.queuePositions[job.id])
                }
            }
        }
    }

    @ViewBuilder
    private func groupedSections(_ state: SidebarListState) -> some View {
        if state.displayedJobs.isEmpty {
            Section {
                emptyPlaceholder
            }
        } else {
            ForEach(JobGroup.allCases) { group in
                let jobs = state.displayedJobs.filter { JobGroup(status: $0.status) == group }
                if !jobs.isEmpty {
                    Section("\(group.label) (\(jobs.count))") {
                        ForEach(jobs) { job in
                            row(for: job, queuePosition: state.queuePositions[job.id])
                        }
                    }
                }
            }
        }
    }

    private func row(for job: TranscriptionJob, queuePosition: Int?) -> some View {
        let canRetry = job.status == .failed && model.jobNeedsWork(job)
        return JobRow(
            id: job.id,
            title: job.title,
            status: job.status,
            statusText: rowStatusText(for: job, queuePosition: queuePosition),
            progressFraction: job.status.isRunning ? job.progress.fraction : nil,
            hasOverrides: !job.overrides.isEmpty,
            canRetry: canRetry,
            onRetry: { model.retryFailedJobs([job.id]) }
        )
        .equatable()
        .tag(job.id)
        .contextMenu { contextMenu(for: job) }
    }

    private func rowStatusText(for job: TranscriptionJob, queuePosition: Int?) -> String {
        if job.status.isRunning, let fraction = job.progress.fraction {
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            return "\(job.status.label) · \(percent)%"
        }
        if job.status == .queued, let queuePosition {
            return "Queued · #\(queuePosition)"
        }
        return job.status.label
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        Text(model.jobs.isEmpty ? "No jobs yet" : "No jobs match")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func contextMenu(for job: TranscriptionJob) -> some View {
        let targets = actionTargets(for: job)
        if targets.isBulk {
            bulkContextMenu(targets)
        } else {
            singleJobContextMenu(for: job, deletionIDs: targets.ids)
        }
    }

    @ViewBuilder
    private func bulkContextMenu(_ targets: JobActionTargets) -> some View {
        if !targets.retryableFailedIDs.isEmpty {
            Button {
                model.retryFailedJobs(targets.retryableFailedIDs)
            } label: {
                Label(retryFailedLabel(targets.retryableFailedIDs.count), systemImage: "arrow.clockwise")
            }
        }
        if !targets.queueableIDs.isEmpty {
            Button {
                model.enqueueJobs(targets.queueableIDs)
            } label: {
                Label("Add \(targets.queueableIDs.count) to Queue", systemImage: "clock")
            }
        }
        if !targets.queuedIDs.isEmpty {
            Button {
                removeJobsFromQueueWithUndo(targets.queuedIDs)
            } label: {
                Label("Remove \(targets.queuedIDs.count) from Queue", systemImage: "clock.badge.xmark")
            }
        }
        if !targets.retryableFailedIDs.isEmpty || !targets.queueableIDs.isEmpty || !targets.queuedIDs.isEmpty {
            Divider()
        }
        if !targets.archivableIDs.isEmpty {
            Button {
                setArchivedWithUndo(targets.archivableIDs, true)
            } label: {
                Label(
                    targets.archivableIDs.count == 1 ? "Archive 1 Job" : "Archive \(targets.archivableIDs.count) Jobs",
                    systemImage: "archivebox"
                )
            }
        }
        if !targets.unarchivableIDs.isEmpty {
            Button {
                setArchivedWithUndo(targets.unarchivableIDs, false)
            } label: {
                Label(
                    targets.unarchivableIDs.count == 1
                        ? "Unarchive 1 Job" : "Unarchive \(targets.unarchivableIDs.count) Jobs",
                    systemImage: "tray.and.arrow.up"
                )
            }
        }
        if !targets.archivableIDs.isEmpty || !targets.unarchivableIDs.isEmpty {
            Divider()
        }
        Button(role: .destructive) {
            requestDeletion(of: targets.ids)
        } label: {
            Label("Delete \(targets.ids.count) Jobs", systemImage: "trash")
        }
        .disabled(!model.canDeleteJobs(targets.ids))
    }

    @ViewBuilder
    private func singleJobContextMenu(for job: TranscriptionJob, deletionIDs: Set<UUID>) -> some View {
        if job.status == .failed && model.jobNeedsWork(job) {
            Button {
                model.retryFailedJobs([job.id])
            } label: {
                Label("Retry Failed Job", systemImage: "arrow.clockwise")
            }
        } else if model.jobNeedsWork(job) && job.status != .queued {
            Button {
                model.enqueueJob(job.id)
            } label: {
                Label("Add to Queue", systemImage: "clock")
            }
        }
        if job.status == .queued {
            Button {
                removeJobsFromQueueWithUndo([job.id])
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
            setArchivedWithUndo([job.id], job.archivedAt == nil)
        } label: {
            Label(
                job.archivedAt == nil ? "Archive" : "Unarchive",
                systemImage: job.archivedAt == nil ? "archivebox" : "tray.and.arrow.up"
            )
        }
        .disabled(job.status.isRunning || job.status == .queued)
        Button(role: .destructive) {
            requestDeletion(of: deletionIDs)
        } label: {
            Label(
                deletionIDs.count == 1 ? "Delete" : "Delete \(deletionIDs.count) Jobs",
                systemImage: "trash"
            )
        }
        .disabled(!model.canDeleteJobs(deletionIDs))
    }

    private func setArchivedWithUndo(_ ids: Set<UUID>, _ archived: Bool) {
        guard !ids.isEmpty else { return }
        let eligibleIDs = Set(
            model.jobs.lazy
                .filter {
                    ids.contains($0.id) && !$0.status.isRunning && $0.status != .queued
                        && (archived ? $0.archivedAt == nil : $0.archivedAt != nil)
                }
                .map(\.id)
        )
        guard !eligibleIDs.isEmpty else { return }
        model.setArchived(ids, archived)
        let verb = archived ? "archived" : "unarchived"
        undoNotice = SidebarUndoNotice(
            message: eligibleIDs.count == 1 ? "1 job \(verb)" : "\(eligibleIDs.count) jobs \(verb)",
            action: .setArchived(ids: eligibleIDs, archived: !archived)
        )
    }

    private func removeJobsFromQueueWithUndo(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let queuedIDs = Set(model.jobs.lazy.filter { ids.contains($0.id) && $0.status == .queued }.map(\.id))
        guard !queuedIDs.isEmpty else { return }
        let wasPaused = model.queuePaused
        model.removeJobsFromQueue(queuedIDs)
        undoNotice = SidebarUndoNotice(
            message: queuedIDs.count == 1 ? "1 job removed from queue" : "\(queuedIDs.count) jobs removed from queue",
            action: .restoreQueue(ids: queuedIDs, wasPaused: wasPaused)
        )
    }

    private func performUndo(_ notice: SidebarUndoNotice) {
        switch notice.action {
        case .setArchived(let ids, let archived):
            model.setArchived(ids, archived)
            statusFilterRaw = archived ? JobStatusFilter.archived.rawValue : JobStatusFilter.all.rawValue
            model.selectJobs(ids)
        case .restoreQueue(let ids, let wasPaused):
            model.restoreJobsToQueue(ids, queueWasPaused: wasPaused)
            let restoredIDs = Set(
                model.jobs.lazy
                    .filter { ids.contains($0.id) && ($0.status == .queued || $0.status.isRunning) }
                    .map(\.id)
            )
            statusFilterRaw = JobStatusFilter.inProgress.rawValue
            model.selectJobs(restoredIDs)
        }
        undoNotice = nil
    }
}

private struct JobActionTargets {
    let ids: Set<UUID>
    let queueableIDs: Set<UUID>
    let retryableFailedIDs: Set<UUID>
    let queuedIDs: Set<UUID>
    let archivableIDs: Set<UUID>
    let unarchivableIDs: Set<UUID>

    var isBulk: Bool { ids.count > 1 }
}

private struct SidebarListState {
    let displayedJobs: [TranscriptionJob]
    let counts: SidebarJobCounts
    let queuePositions: [UUID: Int]
    let runningIDs: Set<UUID>
    let queuedIDs: Set<UUID>
    let doneIDs: Set<UUID>
    let failedIDs: Set<UUID>
    let retryableFailedIDs: Set<UUID>
}

private struct SidebarJobCounts {
    private(set) var all = 0
    private(set) var running = 0
    private(set) var queued = 0
    private(set) var done = 0
    private(set) var failed = 0

    mutating func record(_ job: TranscriptionJob) {
        all += 1
        if job.status.isRunning { running += 1 }
        if job.status == .queued { queued += 1 }
        if job.status == .transcriptionComplete || job.status == .translationComplete { done += 1 }
        if job.status == .failed { failed += 1 }
    }

    func count(for filter: JobStatusFilter) -> Int {
        switch filter {
        case .all: return all
        case .running: return running
        case .queued: return queued
        case .done: return done
        case .failed: return failed
        case .inProgress, .stopped, .archived: return 0
        }
    }
}

private struct JobFilterChip: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Text("\(count)")
                    .monospacedDigit()
                    .opacity(0.8)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.14),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(count) jobs")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarUndoNotice: Identifiable {
    enum Action {
        case setArchived(ids: Set<UUID>, archived: Bool)
        case restoreQueue(ids: Set<UUID>, wasPaused: Bool)
    }

    let id = UUID()
    let message: String
    let action: Action
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

private struct JobRow: View, Equatable {
    let id: UUID
    let title: String
    let status: JobStatus
    let statusText: String
    let progressFraction: Double?
    let hasOverrides: Bool
    let canRetry: Bool
    let onRetry: () -> Void

    nonisolated static func == (lhs: JobRow, rhs: JobRow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.status == rhs.status
            && lhs.statusText == rhs.statusText
            && lhs.progressFraction == rhs.progressFraction
            && lhs.hasOverrides == rhs.hasOverrides
            && lhs.canRetry == rhs.canRetry
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if status.isRunning {
                if let progressFraction {
                    ProgressView(value: min(max(progressFraction, 0), 1))
                        .frame(width: 36)
                        .help(statusText)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .help(statusText)
                }
            }
            if canRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .help("Retry this failed job")
                }
                .buttonStyle(.plain)
            }
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
