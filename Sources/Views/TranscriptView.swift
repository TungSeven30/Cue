import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptionSegment]
    let warnings: [SubtitleQualityWarning]
    var activeSegmentID: Int? = nil
    let onEdit: (TranscriptionSegment, String) -> Void
    var onSeek: ((TranscriptionSegment) -> Void)? = nil

    @StateObject private var editSession = TranscriptEditSession()
    @FocusState private var focusedSegmentID: Int?
    @State private var searchText = ""
    @State private var replacementText = ""
    @State private var warningsOnly = false

    var body: some View {
        // Build the lookup once per render; computing it per row made large
        // transcripts O(n^2) to draw.
        let warningsBySegment = Dictionary(grouping: warnings, by: \.segmentID)
        let filtered = filteredSegments(warningsBySegment: warningsBySegment)
        let replaceMatchCount = TranscriptReplaceAll.matchCount(in: filtered, query: searchText)
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
                TextField("Search cues…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                TextField("Replace with…", text: $replacementText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button(replaceAllButtonTitle(matchCount: replaceMatchCount)) {
                    replaceAll(in: filtered)
                }
                .disabled(replaceMatchCount == 0)
            }

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filtered) { segment in
                    SegmentEditorRow(
                        segment: segment,
                        warnings: warningsBySegment[segment.id] ?? [],
                        isActive: segment.id == activeSegmentID,
                        rowKind: editSession.rowKind(for: segment.id),
                        focusedSegmentID: $focusedSegmentID,
                        onBeginEditing: {
                            editSession.endEditingIfNeeded(segments: segments, commit: onEdit)
                            editSession.beginEditing(segmentID: segment.id, text: segment.text)
                            focusedSegmentID = segment.id
                        },
                        onLiveEdit: { newText in
                            editSession.applyLiveEdit(segment: segment, newText: newText, commit: onEdit)
                        },
                        onEndEditing: {
                            editSession.endEditing(segment: segment, finalText: segment.text, commit: onEdit)
                        },
                        onSeek: onSeek
                    )
                    .id(segment.id)
                }
            }
        }
        .environment(\.undoManager, editSession.undoManager)
        .onChange(of: focusedSegmentID) { oldValue, newValue in
            guard let oldValue, oldValue != newValue,
                let segment = segments.first(where: { $0.id == oldValue })
            else { return }
            editSession.endEditing(segment: segment, finalText: segment.text, commit: onEdit)
        }
    }

    private func replaceAllButtonTitle(matchCount: Int) -> String {
        switch matchCount {
        case 0: "Replace All"
        case 1: "Replace 1"
        default: "Replace \(matchCount)"
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
        let changes = TranscriptReplaceAll.plannedChanges(
            in: filtered,
            query: searchText,
            replacement: replacementText
        )
        guard !changes.isEmpty else { return }
        editSession.endEditingIfNeeded(segments: segments, commit: onEdit)
        focusedSegmentID = nil
        editSession.replaceAll(changes: changes, segments: segments, commit: onEdit)
    }
}

private struct SegmentEditorRow: View {
    let segment: TranscriptionSegment
    let warnings: [SubtitleQualityWarning]
    var isActive: Bool = false
    let rowKind: TranscriptSegmentRowKind
    var focusedSegmentID: FocusState<Int?>.Binding
    let onBeginEditing: () -> Void
    let onLiveEdit: (String) -> Void
    let onEndEditing: () -> Void
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
                    .accessibilityLabel("Cue \(segment.id)")

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

            cueText
                .font(.body)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
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

    @ViewBuilder
    private var cueText: some View {
        switch rowKind {
        case .idleText:
            Text(segment.text.isEmpty ? " " : segment.text)
                .foregroundStyle(segment.text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onBeginEditing)
        case .editingTextEditor:
            TextEditor(
                text: Binding(
                    get: { segment.text },
                    set: onLiveEdit
                )
            )
            .focused(focusedSegmentID, equals: segment.id)
            .scrollContentBackground(.hidden)
            .onDisappear(perform: onEndEditing)
        }
    }

    private var borderColor: Color {
        if isActive { return Color.accentColor.opacity(0.7) }
        return warnings.isEmpty ? Color.clear : Color.orange.opacity(0.4)
    }

    private func formatted(_ seconds: Double) -> String {
        SubtitleWriter.formatDisplayTimestamp(seconds)
    }
}