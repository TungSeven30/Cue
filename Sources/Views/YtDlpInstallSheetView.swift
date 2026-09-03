import SwiftUI

/// Presented while Homebrew installs yt-dlp. Shows the coarse phase plus a
/// bounded tail of brew's output, and offers retry when the install fails.
struct YtDlpInstallSheetView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Installing yt-dlp")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            switch model.ytDlpInstallRequest?.phase {
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(message)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                    CopyFeedbackButton(text: message, helpText: "Copy error to clipboard")
                }
            default:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running brew install yt-dlp…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let lines = model.ytDlpInstallRequest?.detailLines, !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }

            if let pageURL = model.ytDlpInstallRequest?.pageURL {
                Text("Your link (\(pageURL.absoluteString)) starts downloading when this finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                if model.ytDlpInstallRequest?.phase.isFailed == true {
                    Button("Retry Install") {
                        model.beginYtDlpInstall(pageURL: model.ytDlpInstallRequest?.pageURL)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Cancel") {
                    model.cancelYtDlpInstall()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
