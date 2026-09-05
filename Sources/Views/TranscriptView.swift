import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptionSegment]
    let warnings: SubtitleWarnings
    var activeSegmentID: Int? = nil
    let onEdit: (TranscriptionSegment, String) -> Void
    var onSeek: ((TranscriptionSegment) -> Void)? = nil
    var onEditBatch: (([TranscriptionSegment]) -> Void)? = nil
    @State private var searchText = ""
    @State private var replacementText = ""
    @State private var warningsOnly = false

    var body: some View {
        // The grouping arrives precomputed with the (memoised) warnings, so a
        // render costs the filter, not another pass over every cue.
        let warningsBySegment = warnings.bySegment
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
                if !warnings.list.isEmpty {
                    Label("^[\(warnings.list.count) warning](inflect: true)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Toggle("Warnings", isOn: $warningsOnly)
                    .toggleStyle(.checkbox)
                    .disabled(warnings.list.isEmpty)
                TextField("Search cues…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                TextField("Replace with…", text: $replacementText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
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
                        canSeek: onSeek != nil,
                        onEdit: onEdit,
                        onSeek: onSeek
                    )
                    .equatable()
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
        let edited = filtered.filter { $0.text.localizedCaseInsensitiveContains(query) }.map { segment in
            var updated = segment
            updated.text = segment.text.replacingOccurrences(
                of: query,
                with: replacementText,
                options: [.caseInsensitive, .literal]
            )
            return updated
        }
        if let onEditBatch { onEditBatch(edited) } else { for segment in edited { onEdit(segment, segment.text) } }
    }
}

/// Equatable on its data so SwiftUI skips the body of every row whose cue,
/// warnings, and highlight state did not change (the closures are stable
/// per parent and deliberately excluded, as in JobRow).
private struct SegmentEditorRow: View, Equatable {
    let segment: TranscriptionSegment
    let warnings: [SubtitleQualityWarning]
    var isActive: Bool = false
    /// Whether the timestamp is a seek button; mirrors `onSeek != nil` as a
    /// plain value so equality can consider it without touching the closure.
    var canSeek: Bool = false
    let onEdit: (TranscriptionSegment, String) -> Void
    var onSeek: ((TranscriptionSegment) -> Void)? = nil

    nonisolated static func == (lhs: SegmentEditorRow, rhs: SegmentEditorRow) -> Bool {
        lhs.segment == rhs.segment
            && lhs.warnings == rhs.warnings
            && lhs.isActive == rhs.isActive
            && lhs.canSeek == rhs.canSeek
    }

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
                    .accessibilityLabel("Cue \(segment.id)")

                if canSeek, let onSeek {
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
                    .accessibilityLabel("Seek video to cue \(segment.id), from \(formatted(segment.start)) to \(formatted(segment.end))")
                } else {
                    Label("\(formatted(segment.start)) – \(formatted(segment.end))", systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("Timestamp \(formatted(segment.start)) to \(formatted(segment.end))")
                }

                Spacer()

                if !warnings.isEmpty {
                    Text(warnings.map(\.message).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .accessibilityLabel("Warning: \(warnings.map(\.message).joined(separator: ", "))")
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
            .accessibilityLabel("Subtitle text for cue \(segment.id)")
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
        SubtitleWriter.formatDisplayTimestamp(seconds)
    }
}
