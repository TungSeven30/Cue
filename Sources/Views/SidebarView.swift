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
                        JobRow(job: job)
                            .tag(job.id)
                            .contextMenu {
                                if model.jobNeedsWork(job) && job.status != .queued {
                                    Button {
                                        model.enqueueJob(job.id)
                                    } label: {
                                        Label("Add to Queue", systemImage: "clock")
                                    }
                                }
                                Button(role: .destructive) {
                                    model.deleteJob(job.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(job.id == model.activeJobID)
                            }
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
}

private struct JobRow: View {
    let job: TranscriptionJob

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
        }
        .padding(.vertical, 2)
    }
}
