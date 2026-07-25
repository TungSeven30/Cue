import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptionSegment]
    let warnings: [SubtitleQualityWarning]
    var activeSegmentID: Int? = nil
    let onEdit: (TranscriptionSegment, String) -> Void
    var onSeek: ((TranscriptionSegment) -> Void)? = nil
    @State private var searchText = ""
    @State private var replacementText = ""
    @State private var warningsOnly = false

    var body: some View {
        // Build the lookup once per render; computing it per row made large
        // transcripts O(n^2) to draw.
        let warningsBySegment = Dictionary(grouping: warnings, by: \.segmentID)
        let filtered = filteredSegments(warningsBySegment: warningsBySegment)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("^[\(filtered.count) segment](inflect: true)")
                    .font(.callout.weight(.medium))
                if filtered.count != segments.count {
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
                    replaceAll(in: filtered)
                }
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filtered) { segment in
                    SegmentEditorRow(
                        segment: segment,
                        warnings: warningsBySegment[segment.id] ?? [],
                        isActive: segment.id == activeSegmentID,
                        onEdit: onEdit,
                        onSeek: onSeek
                    )
                    .id(segment.id)
                }
            }
        }
    }

    private func filteredSegments(warningsBySegment: [Int: [SubtitleQualityWarning]]) -> [TranscriptionSegment] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return segments.filter { segment in
            let matchesSearch = query.isEmpty || segment.text.lowercased().contains(query) || "\(segment.id)".contains(query)
            let matchesWarning = !warningsOnly || warningsBySegment[segment.id]?.isEmpty == false
            return matchesSearch && matchesWarning
        }
    }

    private func replaceAll(in filtered: [TranscriptionSegment]) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        for segment in filtered where segment.text.localizedCaseInsensitiveContains(query) {
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
    var isActive: Bool = false
    let onEdit: (TranscriptionSegment, String) -> Void
    var onSeek: ((TranscriptionSegment) -> Void)? = nil

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

                if let onSeek {
                    Button {
                        onSeek(segment)
                    } label: {
                        Label("\(formatted(segment.start)) – \(formatted(segment.end))", systemImage: "play.circle")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .help("Jump the video to this segment")
                } else {
                    Label("\(formatted(segment.start)) – \(formatted(segment.end))", systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

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
        .background(
            isActive ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.background.secondary.opacity(0.4)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private var borderColor: Color {
        if isActive { return Color.accentColor.opacity(0.7) }
        return warnings.isEmpty ? Color.clear : Color.orange.opacity(0.4)
    }

    private func formatted(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
