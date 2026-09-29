import SwiftUI

// MARK: - Text

/// The words the sidebar uses around folders, kept apart from the views so
/// they can be tested without rendering anything.
enum SidebarFolderText {
    static func jobCount(_ count: Int) -> String {
        count == 1 ? "1 job" : "\(count) jobs"
    }

    /// What VoiceOver reads for a folder header: the disclosure control says
    /// whether it is open, so this only needs the name and the size.
    static func headerAccessibilityLabel(name: String, count: Int) -> String {
        "\(name), \(jobCount(count))"
    }

    static let renameNote =
        "Only the name changes. New videos from the same place are still filed in this folder, under its new name."

    static func emptyFolderHint(isFiltering: Bool) -> String {
        isFiltering
            ? "No jobs here match the current filter."
            : "Empty. Drag jobs here, or use Move to Folder."
    }

    static func createNote(movingJobs count: Int) -> String {
        count == 0
            ? "Folders are yours to arrange: move jobs in with drag and drop or Move to Folder."
            : "\(jobCount(count)) will move into the new folder."
    }

    static func duplicateNote(for name: String) -> String {
        "A folder named “\(name)” already exists."
    }

    /// The sidebar's undo notice for one folder operation.
    static func undoMessage(for change: FolderChange) -> String {
        let name = "“\(change.folderName)”"
        switch change.kind {
        case .created:
            return change.movedCount == 0
                ? "Created folder \(name)"
                : "Created \(name) with \(jobCount(change.movedCount))"
        case .moved:
            return "Moved \(jobCount(change.movedCount)) to \(name)"
        case .merged(let sourceName):
            return "Merged “\(sourceName)” into \(name)"
        case .deleted:
            return change.movedCount == 0
                ? "Deleted folder \(name)"
                : "Deleted folder \(name). \(jobCount(change.movedCount)) returned to automatic placement."
        }
    }
}

/// What the Detailed density adds under a row's status: cheap values only, so
/// rows stay `Equatable` and the text is formatted only for rows on screen.
struct SidebarRowDetail: Equatable {
    var languages: String
    var speechSeconds: Double?
    var addedAt: Date

    init(job: TranscriptionJob) {
        languages = SidebarRowText.languageText(for: job)
        speechSeconds = job.transcriptSegments.last?.end
        addedAt = job.createdAt
    }

    var text: String {
        SidebarRowText.detailLine(languages: languages, speechSeconds: speechSeconds, addedAt: addedAt)
    }
}

/// The per-row strings the sidebar shows at each list density.
enum SidebarRowText {
    /// Longer than any real recording (1,000 hours); beyond it a length is
    /// treated as corrupt data and not shown.
    static let maximumLengthSeconds: Double = 3_600_000
    /// Compact rows put a short status after the title; the full text stays in
    /// the row's help and accessibility label.
    static func compactStatus(for status: JobStatus, progressPercent: Int?, queuePosition: Int?) -> String {
        if status.isRunning, let progressPercent { return "\(progressPercent)%" }
        if status == .queued, let queuePosition { return "#\(queuePosition)" }
        switch status {
        case .idle: return "Idle"
        case .queued: return "Queued"
        case .transcribing: return "Transcribing"
        case .transcriptionComplete: return "Transcript"
        case .translating: return "Translating"
        case .translationComplete: return "Translated"
        case .burningIn: return "Burning In"
        case .canceled: return "Canceled"
        case .failed: return "Failed"
        }
    }

    /// The extra line of the Detailed density: languages, length, date added.
    /// Everything comes from what is already in memory; no file is read.
    static func detailLine(languages: String, speechSeconds: Double?, addedAt: Date) -> String {
        var parts = [languages]
        if let length = lengthText(seconds: speechSeconds) {
            parts.append(length)
        }
        parts.append("Added " + addedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    /// "Japanese → English": what the job transcribes and where it translates to.
    static func languageText(for job: TranscriptionJob) -> String {
        let source = languageLabel(job.overrides.sourceLanguage ?? job.settings.sourceLanguage)
        let target = (job.overrides.translationTargetLanguage ?? job.settings.translationTargetLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? source : "\(source) → \(target)"
    }

    private static func languageLabel(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppSettingPresets.transcriptionLanguages.first { $0.value.lowercased() == trimmed.lowercased() }?.label
            ?? (trimmed.isEmpty ? "Auto" : trimmed)
    }

    /// The end of the last transcribed line: the length of the speech, which
    /// is what the transcript covers, and free to read (no media probing).
    /// Values that cannot be a real duration show nothing rather than a
    /// number: a damaged job file must not be able to trap the sidebar.
    static func lengthText(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, (1...maximumLengthSeconds).contains(seconds) else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Selection

/// Decides what the sidebar does with the selection its List reports back.
///
/// A List can only report rows it is showing. When a folder closes, the jobs
/// inside it leave the list, and the List may echo the selection without them.
/// That is the folder closing, not the user deselecting anything, so those
/// jobs stay selected: dropping them would blank the detail pane of a job the
/// user only tucked away.
enum SidebarSelection {
    /// - Parameters:
    ///   - current: the model's selection.
    ///   - proposed: the selection the List reports.
    ///   - isHidden: whether a job's row is out of sight (inside a closed folder).
    /// - Returns: the selection to apply, or nil to leave the current one alone.
    static func accepted(
        current: Set<UUID>,
        proposed: Set<UUID>,
        isHidden: (UUID) -> Bool
    ) -> Set<UUID>? {
        // Anything that adds a row is the user acting on rows they can see
        // (a click, a shift-click): honour it whole, including what it drops.
        guard proposed.isSubset(of: current) else { return proposed }
        let removed = current.subtracting(proposed)
        // Only a change that removes nothing but hidden rows is the list
        // catching up with a folder that closed. Removing a visible row, or
        // clearing everything, is deliberate.
        guard !removed.isEmpty, removed.allSatisfy(isHidden) else { return proposed }
        return nil
    }
}

// MARK: - Header

/// A folder's section header: symbol, name, and how many jobs it shows.
struct FolderHeaderLabel: View {
    let name: String
    let count: Int
    let isDropTarget: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDropTarget ? "folder.fill" : "folder")
                .foregroundStyle(isDropTarget ? Color.accentColor : Color.secondary)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isDropTarget ? 0.22 : 0))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDropTarget)
        .contentShape(Rectangle())
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SidebarFolderText.headerAccessibilityLabel(name: name, count: count))
    }
}

// MARK: - Name prompt

/// What the folder name sheet is for.
struct FolderPrompt: Identifiable {
    enum Kind {
        /// A new folder, optionally created around jobs that move into it.
        case create(movingJobIDs: Set<UUID>)
        case rename(folderID: UUID)
    }

    let id = UUID()
    let kind: Kind
}

/// Asks for a folder's name, validating as the user types. Used for both New
/// Folder and Rename so the two cannot drift apart.
struct FolderNameSheet: View {
    let title: String
    let note: String
    let confirmTitle: String
    let validate: (String) -> FolderNameResult
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @ViewState private var name: String
    @FocusState private var nameFieldFocused: Bool

    init(
        title: String,
        note: String,
        confirmTitle: String,
        initialName: String,
        validate: @escaping (String) -> FolderNameResult,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.note = note
        self.confirmTitle = confirmTitle
        self.validate = validate
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = ViewState(initialValue: initialName)
    }

    private var result: FolderNameResult { validate(name) }

    private var acceptedName: String? {
        if case .accepted(let accepted) = result { return accepted }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .cueFont(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(confirm)
            if result == .duplicate {
                Text(SidebarFolderText.duplicateNote(for: name.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .cueFont(.caption)
                    .foregroundStyle(.red)
            }
            Text(note)
                .cueFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(acceptedName == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { nameFieldFocused = true }
    }

    private func confirm() {
        guard let acceptedName else { return }
        onConfirm(acceptedName)
    }
}

// MARK: - Drag and drop

/// The jobs being dragged: the row under the pointer, or the whole selection
/// when that row is part of one.
///
/// Encoded as JSON but exported with `.ownProcess` visibility, so it exists
/// only for Cue's own sidebar: nothing is offered to Finder or other apps, a
/// Finder file drag can never look like one of these, and no custom type has
/// to be declared in the bundle's Info.plist.
struct SidebarJobDrag: Codable, Transferable, Equatable {
    var jobIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
            .visibility(.ownProcess)
    }
}
