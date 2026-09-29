import Foundation

// Turns a value snapshot of the app into palette rows. Pure: no AppModel, no
// views, no file system beyond string formatting, so every rule below (what is
// searchable, how a row reads, what an empty query suggests, how a disabled
// row explains itself) is covered by unit tests without a window.

/// What a row does when it is chosen.
enum PaletteTarget: Hashable, Sendable {
    case job(UUID)
    case command(PaletteCommandID)
    case setting(SettingsPane)
    case watchFolder(UUID)
    case download(UUID)
}

extension PaletteSection {
    /// Singular noun for accessibility labels ("Command", "Job").
    var itemNoun: String {
        switch self {
        case .jobs: "Job"
        case .commands: "Command"
        case .settings: "Setting"
        case .watchFolders: "Watch folder"
        case .downloads: "Download"
        }
    }
}

extension SettingsPane {
    private static let paletteSummaries: [SettingsPane: String] = [
        .general: "Queue, archive, menu bar",
        .appearance: "Text size, font, list density",
        .models: "Whisper and translation models",
        .transcribe: "Language, quality, custom terms",
        .translate: "Target language and prompt",
        .summary: "Intro summary model",
        .apiKeys: "OpenAI, Anthropic, Google, and more",
    ]

    /// What lives in the pane, for the palette's subtitle. A lookup rather
    /// than a switch so a pane added later still works (it reads plain
    /// "Settings") instead of breaking this file's build.
    var paletteSummary: String? { Self.paletteSummaries[self] }
}

struct PaletteEntry: Identifiable, Equatable, Sendable {
    let id: String
    let target: PaletteTarget
    let section: PaletteSection
    let title: String
    let subtitle: String
    let symbol: String
    /// Set for job rows so the view can tint the icon like the sidebar does.
    let jobStatus: JobStatus?
    let shortcut: PaletteShortcut?
    let availability: PaletteAvailability
    /// What Return does when the row has no shortcut to show ("Try Again").
    /// Jobs, settings, and commands are self-explanatory and leave it nil.
    var actionLabel: String? = nil

    var isEnabled: Bool { availability.isEnabled }
}

// MARK: - Snapshot

struct PaletteJobSummary: Equatable, Sendable {
    let id: UUID
    let title: String
    let fileName: String
    let path: String
    let status: JobStatus
    let isArchived: Bool
    let updatedAt: Date
}

struct PaletteWatchFolderSummary: Equatable, Sendable {
    let id: UUID
    let name: String
    let path: String
    let isEnabled: Bool
}

struct PaletteDownloadSummary: Equatable, Sendable {
    let id: UUID
    let title: String
    let message: String
}

/// Everything the palette shows, as plain values. Equatable so an open
/// palette can tell cheaply whether the app changed under it.
struct PaletteSnapshot: Equatable, Sendable {
    var context = PaletteContext()
    var selectedJobID: UUID?
    var jobs: [PaletteJobSummary] = []
    var watchFolders: [PaletteWatchFolderSummary] = []
    var failedDownloads: [PaletteDownloadSummary] = []
}

// MARK: - Rows

struct PaletteHeader: Equatable, Sendable {
    let section: PaletteSection
    let title: String
    /// Rows shown / matches found; they differ when the section is capped.
    let shown: Int
    let total: Int

    var isCapped: Bool { total > shown }
}

struct PaletteRowModel: Identifiable, Equatable, Sendable {
    let entry: PaletteEntry
    /// Text shown under the title: the entry's subtitle, or the reason a
    /// disabled command cannot run, plus "matches “word”" when only a keyword
    /// found the row.
    let subtitle: String
    let titleRanges: [Range<Int>]
    let subtitleRanges: [Range<Int>]

    var id: String { entry.id }
    var isSelectable: Bool { entry.isEnabled }

    /// One sentence for VoiceOver: what it is, what it says, how to run it.
    var accessibilityLabel: String {
        var parts = [entry.title]
        if !subtitle.isEmpty { parts.append(subtitle) }
        parts.append(entry.section.itemNoun)
        if let shortcut = entry.shortcut { parts.append("Shortcut \(shortcut.spoken)") }
        if let action = entry.actionLabel { parts.append("Return to \(action)") }
        if !entry.isEnabled { parts.append("Unavailable") }
        return parts.joined(separator: ", ")
    }
}

enum PaletteListRow: Identifiable, Equatable, Sendable {
    case header(PaletteHeader)
    case entry(PaletteRowModel)

    var id: String {
        switch self {
        case .header(let header): "header:\(header.section.rawValue)"
        case .entry(let row): row.id
        }
    }

    var entryRow: PaletteRowModel? {
        if case .entry(let row) = self { return row }
        return nil
    }
}

struct PaletteEmptyState: Equatable, Sendable {
    let title: String
    let message: String
}

struct PaletteResults: Equatable, Sendable {
    let query: CommandPaletteSearch.Query
    let rows: [PaletteListRow]
    /// True for the suggestions shown before anything is typed.
    let isSuggestions: Bool

    var entryRows: [PaletteRowModel] { rows.compactMap(\.entryRow) }
    var selectableIDs: [String] { entryRows.filter(\.isSelectable).map(\.id) }
    var entryCount: Int { entryRows.count }

    var emptyState: PaletteEmptyState? {
        guard entryCount == 0 else { return nil }
        if query.isEmpty {
            return PaletteEmptyState(
                title: "Nothing to show yet",
                message: "Type to search jobs, commands, and settings."
            )
        }
        let shown = query.text
        if query.scope == .commands {
            return PaletteEmptyState(
                title: "No commands match “\(shown)”",
                message: "Delete the > to search jobs and settings too."
            )
        }
        return PaletteEmptyState(
            title: "No results for “\(shown)”",
            message: "Check the spelling, or type > to browse every command."
        )
    }

    /// "8 results", "No results": spoken after the list changes.
    var summary: String {
        switch entryCount {
        case 0: "No results"
        case 1: "1 result"
        default: "\(entryCount) results"
        }
    }
}

// MARK: - Index

struct PaletteIndex: Sendable {
    let entries: [PaletteEntry]
    /// Parallel to `entries`; folded once so a keystroke only matches.
    let items: [CommandPaletteSearch.Item]

    static let empty = PaletteIndex(entries: [], items: [])

    /// Archived jobs stay findable but sink below live ones at equal quality.
    static let archivedBias = -500
    /// Jobs offered before typing: the selected one, then live work, then the
    /// most recently touched.
    static let suggestedJobCount = 5

    static func build(from snapshot: PaletteSnapshot) -> PaletteIndex {
        var entries: [PaletteEntry] = []
        var items: [CommandPaletteSearch.Item] = []
        entries.reserveCapacity(snapshot.jobs.count + 40)
        items.reserveCapacity(snapshot.jobs.count + 40)

        func add(_ entry: PaletteEntry, keywords: [String], bias: Int = 0, suggestionRank: Int? = nil) {
            entries.append(entry)
            items.append(
                CommandPaletteSearch.Item(
                    id: entry.id,
                    section: entry.section,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    keywords: keywords,
                    isEnabled: entry.isEnabled,
                    bias: bias,
                    suggestionRank: suggestionRank
                )
            )
        }

        // Most recently touched first, so equal scores resolve to the job the
        // user most likely means; ties keep the app's own order.
        let jobs = snapshot.jobs.enumerated()
            .sorted { lhs, rhs in
                lhs.element.updatedAt == rhs.element.updatedAt
                    ? lhs.offset < rhs.offset : lhs.element.updatedAt > rhs.element.updatedAt
            }
            .map(\.element)
        let suggested = suggestedJobRanks(for: jobs, selectedJobID: snapshot.selectedJobID)
        for job in jobs {
            let entry = PaletteEntry(
                id: "job:\(job.id.uuidString)",
                target: .job(job.id),
                section: .jobs,
                title: job.title,
                subtitle: jobSubtitle(job),
                symbol: job.status.systemImage,
                jobStatus: job.status,
                shortcut: nil,
                availability: .enabled
            )
            add(
                entry,
                keywords: job.fileName == job.title ? [] : [job.fileName],
                bias: job.isArchived ? archivedBias : 0,
                suggestionRank: suggested[job.id]
            )
        }

        for id in PaletteCommandID.allCases {
            let availability = PaletteCatalog.availability(of: id, in: snapshot.context)
            guard !availability.isHidden else { continue }
            let spec = PaletteCatalog.spec(for: id, in: snapshot.context)
            let entry = PaletteEntry(
                id: "command:\(id.rawValue)",
                target: .command(id),
                section: .commands,
                title: spec.title,
                subtitle: spec.menuPath,
                symbol: spec.symbol,
                jobStatus: nil,
                shortcut: spec.shortcut,
                availability: availability
            )
            add(entry, keywords: spec.keywords, suggestionRank: spec.suggestionRank)
        }

        for pane in SettingsPane.allCases {
            let entry = PaletteEntry(
                id: "setting:\(pane.rawValue)",
                target: .setting(pane),
                section: .settings,
                title: pane.title,
                subtitle: settingSubtitle(pane),
                symbol: pane.systemImage,
                jobStatus: nil,
                shortcut: nil,
                availability: .enabled
            )
            add(entry, keywords: pane.keywords)
        }

        for folder in snapshot.watchFolders {
            let entry = PaletteEntry(
                id: "watch:\(folder.id.uuidString)",
                target: .watchFolder(folder.id),
                section: .watchFolders,
                title: folder.name,
                subtitle: folder.isEnabled
                    ? abbreviatedPath(folder.path) : "Paused · \(abbreviatedPath(folder.path))",
                symbol: folder.isEnabled ? "eye" : "eye.slash",
                jobStatus: nil,
                shortcut: nil,
                availability: .enabled,
                actionLabel: "Reveal in Finder"
            )
            add(entry, keywords: ["watch folder", "inbox", "folder", "auto import"])
        }

        for download in snapshot.failedDownloads {
            let entry = PaletteEntry(
                id: "download:\(download.id.uuidString)",
                target: .download(download.id),
                section: .downloads,
                title: download.title,
                subtitle: "Failed · \(download.message)",
                symbol: "exclamationmark.arrow.circlepath",
                jobStatus: nil,
                shortcut: nil,
                availability: .enabled,
                actionLabel: "Try Again"
            )
            add(entry, keywords: ["download", "retry", "failed", "link"])
        }

        return PaletteIndex(entries: entries, items: items)
    }

    func results(
        for rawQuery: String,
        limits: CommandPaletteSearch.Limits = .standard
    ) -> PaletteResults {
        let query = CommandPaletteSearch.Query(rawQuery)
        let sections = CommandPaletteSearch.results(for: query, in: items, limits: limits)
        let isSuggestions = query.isEmpty && query.scope == .everything
        var rows: [PaletteListRow] = []
        for section in sections where !section.matches.isEmpty {
            let title = isSuggestions ? section.section.suggestionTitle : section.section.title
            rows.append(
                .header(
                    PaletteHeader(
                        section: section.section,
                        title: title,
                        shown: section.matches.count,
                        total: section.totalMatches
                    )
                )
            )
            for match in section.matches {
                rows.append(.entry(Self.row(for: match, in: entries[match.itemIndex])))
            }
        }
        return PaletteResults(query: query, rows: rows, isSuggestions: isSuggestions)
    }

    // MARK: - Row text

    private static func row(for match: CommandPaletteSearch.Match, in entry: PaletteEntry) -> PaletteRowModel {
        if let reason = entry.availability.reason {
            // The reason replaces the subtitle, so its ranges no longer apply.
            return PaletteRowModel(
                entry: entry,
                subtitle: reason,
                titleRanges: match.titleRanges,
                subtitleRanges: []
            )
        }
        var subtitle = entry.subtitle
        // The keyword hint only fills a gap: a highlighted subtitle is
        // already the visible reason the row is here.
        if let keyword = match.matchedKeyword, match.subtitleRanges.isEmpty {
            let hint = "matches “\(keyword)”"
            subtitle = subtitle.isEmpty ? hint : "\(subtitle) · \(hint)"
        }
        // Appending keeps the engine's ranges valid: they index the original
        // subtitle, which stays a prefix.
        return PaletteRowModel(
            entry: entry,
            subtitle: subtitle,
            titleRanges: match.titleRanges,
            subtitleRanges: match.subtitleRanges
        )
    }

    static func jobSubtitle(_ job: PaletteJobSummary) -> String {
        var parts: [String] = []
        if job.isArchived { parts.append("Archived") }
        parts.append(job.status.label)
        let folder = abbreviatedPath((job.path as NSString).deletingLastPathComponent)
        if !folder.isEmpty { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    static func settingSubtitle(_ pane: SettingsPane) -> String {
        guard let summary = pane.paletteSummary else { return "Settings" }
        return "Settings · \(summary)"
    }

    static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Ranks for the jobs offered before typing. Archived jobs are never
    /// suggested; the rest order selected, then running or queued, then
    /// recency (`jobs` arrives newest first).
    private static func suggestedJobRanks(
        for jobs: [PaletteJobSummary],
        selectedJobID: UUID?
    ) -> [UUID: Int] {
        func tier(_ job: PaletteJobSummary) -> Int {
            if job.id == selectedJobID { return 0 }
            if job.status.isRunning || job.status == .queued { return 1 }
            return 2
        }
        let live = jobs.enumerated().filter { !$0.element.isArchived }
        let ordered = live.sorted { lhs, rhs in
            let (left, right) = (tier(lhs.element), tier(rhs.element))
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        var ranks: [UUID: Int] = [:]
        for (rank, pair) in ordered.prefix(suggestedJobCount).enumerated() {
            ranks[pair.element.id] = rank
        }
        return ranks
    }
}
