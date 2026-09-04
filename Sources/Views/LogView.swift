import AppKit
import SwiftUI

struct LogView: View {
    let log: String

    /// Rendering the whole log as one Text re-runs CoreText layout of up to
    /// 200k characters on every progress tick; show a bounded tail as
    /// per-line rows instead. Copy still exports everything.
    private static let maxVisibleLines = 400

    var body: some View {
        let lines = visibleLines
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Run Log")
                    .font(.callout.weight(.medium))
                if lines.truncated {
                    Text("showing last \(Self.maxVisibleLines) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CopyFeedbackButton(text: log, helpText: "Copy entire run log to clipboard")
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var visibleLines: (lines: [String], truncated: Bool) {
        // Walks the UTF-8 tail backwards instead of splitting the whole log
        // on every progress tick.
        LogTail.lastLines(of: log, count: Self.maxVisibleLines)
    }
}
