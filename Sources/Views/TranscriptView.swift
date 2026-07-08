import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptionSegment]
    let warnings: [SubtitleQualityWarning]
    let onEdit: (TranscriptionSegment, String) -> Void
    @State private var searchText = ""
    @State private var replacementText = ""
    @State private var warningsOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("^[\(filteredSegments.count) segment](inflect: true)")
                    .font(.callout.weight(.medium))
                if filteredSegments.count != segments.count {
                    Text("of \(segments.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !warnings.isEmpty {
                    Label("^[\(warnings.count) warning](inflect: true)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Toggle("Warnings", isOn: $warningsOnly)
                    .toggleStyle(.checkbox)
                    .disabled(warnings.isEmpty)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                TextField("Replace", text: $replacementText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button("Replace All") {
                    replaceAll()
                }
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filteredSegments) { segment in
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

    private var filteredSegments: [TranscriptionSegment] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return segments.filter { segment in
            let matchesSearch = query.isEmpty || segment.text.lowercased().contains(query) || "\(segment.id)".contains(query)
            let matchesWarning = !warningsOnly || warningsBySegment[segment.id]?.isEmpty == false
            return matchesSearch && matchesWarning
        }
    }

    private func replaceAll() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        for segment in filteredSegments where segment.text.localizedCaseInsensitiveContains(query) {
            let updated = segment.text.replacingOccurrences(
                of: query,
                with: replacementText,
                options: [.caseInsensitive, .literal]
            )
            onEdit(segment, updated)
        }
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
