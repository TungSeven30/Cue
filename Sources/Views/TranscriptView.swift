import SwiftUI

struct TranscriptView: View {
    let title: String
    let segments: [TranscriptionSegment]
    let warnings: [SubtitleQualityWarning]
    let onEdit: (TranscriptionSegment, String) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(summary)
                        .foregroundStyle(.secondary)
                }

                if segments.isEmpty {
                    Text("Nothing here yet.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(segments) { segment in
                            SegmentEditorRow(
                                segment: segment,
                                warnings: warningsBySegment[segment.id] ?? [],
                                onEdit: onEdit
                            )
                        }
                    }
                }
            }
        }
    }

    private var summary: String {
        if warnings.isEmpty {
            return "\(segments.count) segments"
        }
        return "\(segments.count) segments, \(warnings.count) warnings"
    }

    private var warningsBySegment: [Int: [SubtitleQualityWarning]] {
        Dictionary(grouping: warnings, by: \.segmentID)
    }
}

private struct SegmentEditorRow: View {
    let segment: TranscriptionSegment
    let warnings: [SubtitleQualityWarning]
    let onEdit: (TranscriptionSegment, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(segment.id)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                Text("\(formatted(segment.start)) - \(formatted(segment.end))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if !warnings.isEmpty {
                    Text(warnings.map(\.message).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            TextEditor(
                text: Binding(
                    get: { segment.text },
                    set: { onEdit(segment, $0) }
                )
            )
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 48)
            .padding(6)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    private func formatted(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
