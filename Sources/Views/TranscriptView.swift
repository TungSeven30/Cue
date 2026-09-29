import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptionSegment]
    let warnings: SubtitleWarnings
    var activeSegmentID: Int? = nil
    let onEdit: (TranscriptionSegment, String) -> Void
    var onSeek: ((TranscriptionSegment) -> Void)? = nil
    var onEditBatch: (([TranscriptionSegment]) -> Void)? = nil
    @ViewState private var searchText = ""
    @ViewState private var replacementText = ""
    @ViewState private var warningsOnly = false
    @Environment(\.cueListDensity) private var density

    var body: some View {
        // The grouping arrives precomputed with the (memoised) warnings, so a
        // render costs the filter, not another pass over every cue.
        let warningsBySegment = warnings.bySegment
        let filtered = filteredSegments(warningsBySegment: warningsBySegment)
        let metrics = TranscriptRowMetrics(density: density)
        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            HStack(spacing: 8) {
                Text("^[\(filtered.count) segment](inflect: true)")
                    .cueFont(.callout, weight: .medium)
                if filtered.count != segments.count {
                    Text("of \(segments.count)")
                        .cueFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if !warnings.list.isEmpty {
                    Label("^[\(warnings.list.count) warning](inflect: true)", systemImage: "exclamationmark.triangle.fill")
                        .cueFont(.caption)
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

            LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                ForEach(filtered) { segment in
                    SegmentEditorRow(
                        segment: segment,
                        warnings: warningsBySegment[segment.id] ?? [],
                        isActive: segment.id == activeSegmentID,
                        canSeek: onSeek != nil,
                        density: density,
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
    /// List density from Settings › Appearance, passed as a value so equality
    /// re-renders every row when it changes.
    var density: ListDensity = .comfortable
    let onEdit: (TranscriptionSegment, String) -> Void
    var onSeek: ((TranscriptionSegment) -> Void)? = nil

    nonisolated static func == (lhs: SegmentEditorRow, rhs: SegmentEditorRow) -> Bool {
        lhs.segment == rhs.segment
            && lhs.warnings == rhs.warnings
            && lhs.isActive == rhs.isActive
            && lhs.canSeek == rhs.canSeek
            && lhs.density == rhs.density
    }

    var body: some View {
        let metrics = TranscriptRowMetrics(density: density)
        VStack(alignment: .leading, spacing: metrics.contentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(segment.id)")
                    .cueFont(.caption, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
                    .padding(.horizontal, 6)
                    .padding(.vertical, metrics.badgeVerticalPadding)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Cue \(segment.id)")

                if canSeek, let onSeek {
                    Button {
                        onSeek(segment)
                    } label: {
                        Label("\(formatted(segment.start)) – \(formatted(segment.end))", systemImage: "play.circle")
                            .cueFont(.caption, monospacedDigit: true)
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .help("Jump the video to this segment")
                    .accessibilityLabel("Seek video to cue \(segment.id), from \(formatted(segment.start)) to \(formatted(segment.end))")
                } else {
                    Label("\(formatted(segment.start)) – \(formatted(segment.end))", systemImage: "clock")
                        .cueFont(.caption, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("Timestamp \(formatted(segment.start)) to \(formatted(segment.end))")
                }

                if metrics.showsSegmentMetrics {
                    let segmentMetrics = TranscriptSegmentMetrics(segment: segment)
                    Text(segmentMetrics.summary)
                        .cueFont(.caption, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(segmentMetrics.accessibilityLabel)
                }

                Spacer()

                if !warnings.isEmpty {
                    Text(warnings.map(\.message).joined(separator: " · "))
                        .cueFont(.caption)
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
            .cueFont(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: metrics.editorMinHeight)
            .padding(metrics.editorPadding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Subtitle text for cue \(segment.id)")
        }
        .padding(metrics.rowPadding)
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

/// Spacing for one transcript row at a List density. `.comfortable` is the
/// layout Cue always had, value for value; `.compact` trims padding and
/// spacing but drops no information; `.detailed` keeps the comfortable spacing
/// and adds a length and reading-rate readout to each row header.
struct TranscriptRowMetrics: Equatable {
    let sectionSpacing: CGFloat
    let rowSpacing: CGFloat
    let rowPadding: CGFloat
    let contentSpacing: CGFloat
    let editorPadding: CGFloat
    let editorMinHeight: CGFloat
    let badgeVerticalPadding: CGFloat
    let showsSegmentMetrics: Bool

    init(density: ListDensity) {
        switch density {
        case .compact:
            sectionSpacing = 8
            rowSpacing = 4
            rowPadding = 8
            contentSpacing = 4
            editorPadding = 5
            editorMinHeight = 30
            badgeVerticalPadding = 1
        case .comfortable, .detailed:
            sectionSpacing = 10
            rowSpacing = 8
            rowPadding = 12
            contentSpacing = 6
            editorPadding = 8
            editorMinHeight = 46
            badgeVerticalPadding = 2
        }
        showsSegmentMetrics = density.showsDetailLine
    }
}

/// Length and reading pace of one cue, shown in the Detailed row header.
struct TranscriptSegmentMetrics: Equatable {
    let duration: Double
    let characterCount: Int

    init(segment: TranscriptionSegment) {
        // Imported or hand-edited times can be inverted or non-finite; a cue
        // like that reads as zero-length rather than "inf s".
        let span = segment.end - segment.start
        duration = span.isFinite ? max(0, span) : 0
        characterCount = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Characters per second; nil when the cue has no duration or no text.
    var charactersPerSecond: Double? {
        guard duration > 0, characterCount > 0 else { return nil }
        return Double(characterCount) / duration
    }

    var durationLabel: String { String(format: "%.1f s", duration) }

    /// Whole numbers from 10 up, one decimal below, so slow cues stay legible.
    /// The choice is made on the rounded value, so 9.96 reads "10 chars/s",
    /// never "10.0 chars/s".
    var rateLabel: String? {
        guard let rate = charactersPerSecond else { return nil }
        return String(format: Self.usesWholeNumbers(rate) ? "%.0f chars/s" : "%.1f chars/s", rate)
    }

    private static func usesWholeNumbers(_ rate: Double) -> Bool {
        (rate * 10).rounded() / 10 >= 10
    }

    var summary: String {
        [durationLabel, rateLabel].compactMap { $0 }.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        var label = "Duration \(String(format: "%.1f", duration)) seconds"
        if let rate = charactersPerSecond {
            label += ", \(String(format: Self.usesWholeNumbers(rate) ? "%.0f" : "%.1f", rate)) characters per second"
        }
        return label
    }
}
