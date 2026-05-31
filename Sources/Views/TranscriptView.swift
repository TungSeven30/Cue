import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptionSegment]
    let warnings: [SubtitleQualityWarning]
    let onEdit: (TranscriptionSegment, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("^[\(segments.count) segment](inflect: true)")
                    .font(.callout.weight(.medium))
                if !warnings.isEmpty {
                    Label("^[\(warnings.count) warning](inflect: true)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            LazyVStack(alignment: .leading, spacing: 8) {
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(segment.id)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                Label("\(formatted(segment.start)) – \(formatted(segment.end))", systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)

                Spacer()

                if !warnings.isEmpty {
                    Text(warnings.map(\.message).joined(separator: " · "))
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
            .frame(minHeight: 46)
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(.background.secondary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(warnings.isEmpty ? Color.clear : Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private func formatted(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
