import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedJobID },
            set: { model.selectJob($0) }
        )) {
            Section("Jobs") {
                if model.jobs.isEmpty {
                    Text("No jobs yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.jobs) { job in
                        JobRow(job: job, hasOverrides: !job.overrides.isEmpty)
                            .tag(job.id)
                            .contextMenu { contextMenu(for: job) }
                    }
                    .onMove { source, destination in
                        model.moveJobs(from: source, to: destination)
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
        }
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
