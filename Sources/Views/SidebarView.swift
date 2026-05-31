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
                                Button(role: .destructive) {
                                    model.deleteJob(job.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(model.isBusy)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.selectVideo()
            } label: {
                Label("Open Video…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
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
