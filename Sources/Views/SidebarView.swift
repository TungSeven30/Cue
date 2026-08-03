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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .stopped: return "Canceled & Failed"
        }
    }

    func includes(_ status: JobStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .inProgress:
            return status.isRunning || status == .queued || status == .idle
        case .done:
            return status == .transcriptionComplete || status == .translationComplete
        case .stopped:
            return status == .canceled || status == .failed
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @AppStorage("sidebarGroupByStatus") private var groupByStatus = false
    @AppStorage("sidebarStatusFilter") private var statusFilterRaw = JobStatusFilter.all.rawValue

    var body: some View {
        List(selection: Binding(
            get: { model.selectedJobID },
            set: { model.selectJob($0) }
        )) {
            if groupByStatus {
                groupedSections
            } else {
                flatSection
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search jobs")
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
                } label: {
                    Label("Organize", systemImage: organizeMenuIcon)
                        .help("Filter the job list or group it by status")
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

    // MARK: - List content

    private var statusFilter: JobStatusFilter {
        JobStatusFilter(rawValue: statusFilterRaw) ?? .all
    }

    /// A filled funnel marks an active filter, so a shortened list is never
    /// mistaken for missing jobs.
    private var organizeMenuIcon: String {
        statusFilter == .all
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
    }

    private var visibleJobs: [TranscriptionJob] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.jobs.filter { job in
            guard statusFilter.includes(job.status) else { return false }
            guard !trimmedSearch.isEmpty else { return true }
            return job.title.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    /// Drag-reorder only works on the full flat list: reordering a filtered
    /// subset would move jobs relative to neighbours the user cannot see.
    private var isReorderable: Bool {
        !groupByStatus && statusFilter == .all
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
            NSWorkspace.shared.activateFileViewerSelecting([job.sourceURL])
        } label: {
            Label("Open Destination Folder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            model.deleteJob(job.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(job.id == model.activeJobID)
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
