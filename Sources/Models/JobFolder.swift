import Foundation

/// A sidebar folder. Every job belongs to exactly one existing folder
/// (`TranscriptionJob.folderID`); the folder itself only stores its name,
/// where new jobs should land automatically, and whether it is collapsed.
struct JobFolder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Placement keys whose new jobs land here (`dir:<parent directory>` for
    /// files, `site:<host>` for downloads). Renaming never touches these, so
    /// future videos from the same place keep landing in the renamed folder.
    var sourceKeys: [String]
    /// Persisted disclosure state of the sidebar section.
    var isExpanded: Bool
    var createdAt: Date
    /// Created by the user, so it stays visible while empty. Automatic
    /// folders with nothing to show are hidden (but kept, with their keys).
    var isManual: Bool

    init(
        id: UUID = UUID(),
        name: String,
        sourceKeys: [String] = [],
        isExpanded: Bool = true,
        createdAt: Date = Date(),
        isManual: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sourceKeys = sourceKeys
        self.isExpanded = isExpanded
        self.createdAt = createdAt
        self.isManual = isManual
    }

    /// Everything but the id is optional on disk, so a hand-edited or older
    /// file degrades to sensible defaults instead of being discarded.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sourceKeys = try container.decodeIfPresent([String].self, forKey: .sourceKeys) ?? []
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
    }
}

// MARK: - Placement rules

/// Where a job belongs by default: a stable key plus the name a brand-new
/// folder for that key would get.
struct FolderPlacementKey: Hashable, Sendable {
    var key: String
    var name: String
    /// The grandparent directory's name, used to tell apart two same-named
    /// folders ("Extras (Season 1)"). nil for site keys.
    var qualifier: String?
}

/// The facts placement needs about one job, decoupled from
/// `TranscriptionJob` so the rules run (and are tested) without an
/// `AppSettingsStore`.
struct FolderPlacementInput: Sendable {
    var jobID: UUID
    var sourcePath: String
    var origin: JobOrigin
    var createdAt: Date
    var folderID: UUID?
    /// The head of the job log, where a download records its page URL.
    var logHead: String

    init(
        jobID: UUID,
        sourcePath: String,
        origin: JobOrigin = .manual,
        createdAt: Date = Date(),
        folderID: UUID? = nil,
        logHead: String = ""
    ) {
        self.jobID = jobID
        self.sourcePath = sourcePath
        self.origin = origin
        self.createdAt = createdAt
        self.folderID = folderID
        self.logHead = logHead
    }

    init(_ job: TranscriptionJob) {
        self.init(
            jobID: job.id,
            sourcePath: job.sourcePath,
            origin: job.origin,
            createdAt: job.createdAt,
            folderID: job.folderID,
            // Only downloads carry a page URL, and only in the first line;
            // skip copying a log that can run to 200 KB otherwise.
            logHead: job.origin == .url ? String(job.log.prefix(512)) : ""
        )
    }
}

/// The pure rules that decide a job's default folder. Everything here is
/// lexical: no `stat`, no symlink resolution, so it is safe to run for every
/// row on the main thread even when the media lives on a cold network mount.
enum FolderPlacement {
    static let directoryPrefix = "dir:"
    static let sitePrefix = "site:"
    /// The name of the folder for files that sit directly in the filesystem root.
    static let rootFolderName = "Files"

    /// Collapses `.`, `..` and repeated slashes and folds the `/private`
    /// prefix of the three well-known symlinks (`/var`, `/tmp`, `/etc`).
    /// The directory enumerator reports `/private/var/...` while a dropped
    /// file reports `/var/...`; both must land in the same folder.
    static func normalizedPath(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(part)
        }
        if isAbsolute, components.count >= 2, components[0] == "private",
            ["var", "tmp", "etc"].contains(components[1])
        {
            components.removeFirst()
        }
        return (isAbsolute ? "/" : "") + components.joined(separator: "/")
    }

    /// The default folder for a file, from its parent directory alone.
    static func directoryKey(forFileAt path: String) -> FolderPlacementKey {
        let normalized = normalizedPath(path)
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        let parentComponents = components.dropLast()
        let parentPath = (normalized.hasPrefix("/") ? "/" : "") + parentComponents.joined(separator: "/")
        let name = parentComponents.last.map(String.init) ?? rootFolderName
        let qualifier = parentComponents.dropLast().last.map(String.init)
        return FolderPlacementKey(key: directoryPrefix + parentPath, name: name, qualifier: qualifier)
    }

    /// The default folder for a job. A download prefers its site
    /// (`site:youtube.com`) when the page URL is recorded in the log; anything
    /// else, including a download whose host is unknown, uses the parent
    /// directory.
    static func key(sourcePath: String, origin: JobOrigin, logHead: String = "") -> FolderPlacementKey {
        if origin == .url, let host = downloadHost(inLogHead: logHead) {
            return FolderPlacementKey(key: sitePrefix + host, name: host, qualifier: nil)
        }
        return directoryKey(forFileAt: sourcePath)
    }

    static func key(for input: FolderPlacementInput) -> FolderPlacementKey {
        key(sourcePath: input.sourcePath, origin: input.origin, logHead: input.logHead)
    }

    /// The site a download came from, read from the note `AppModel` writes
    /// as the first log line: `Downloaded from <page URL>.`
    static func downloadHost(inLogHead logHead: String) -> String? {
        let marker = "Downloaded from "
        guard let range = logHead.range(of: marker) else { return nil }
        var rest = logHead[range.upperBound...]
        if let newline = rest.firstIndex(where: \.isNewline) {
            rest = rest[..<newline]
        }
        var urlText = rest.trimmingCharacters(in: .whitespaces)
        if urlText.hasSuffix(".") { urlText.removeLast() }
        guard let host = URL(string: urlText)?.host(percentEncoded: false) else { return nil }
        return canonicalHost(host)
    }

    /// Lowercased, without the mobile/`www` prefixes that never name a
    /// different site, with the one short-link alias that matters most.
    static func canonicalHost(_ host: String) -> String? {
        var value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        for prefix in ["www.", "m.", "mobile."] where value.hasPrefix(prefix) && value.count > prefix.count {
            value.removeFirst(prefix.count)
        }
        if value == "youtu.be" { value = "youtube.com" }
        return value.isEmpty ? nil : value
    }
}

// MARK: - Folder list

/// The outcome of a rename or create request.
enum FolderNameResult: Equatable, Sendable {
    case accepted(String)
    case empty
    case duplicate
}

/// The folder list and every rule that changes it. A plain value type with
/// no I/O, clock, or id source of its own, so the rules are unit-tested
/// directly; `AppModel` only adds job membership and persistence.
struct JobFolderBook: Equatable, Sendable {
    static let maximumNameLength = 120

    private(set) var folders: [JobFolder]
    private var indexByKey: [String: UUID] = [:]
    private var indexByID: [UUID: Int] = [:]

    /// Repairs whatever was on disk: duplicate ids and keys are dropped (the
    /// first claim wins, so key → folder stays a function) and blank names
    /// get a placeholder.
    init(folders: [JobFolder] = []) {
        var seenIDs = Set<UUID>()
        var seenKeys = Set<String>()
        var repaired: [JobFolder] = []
        for var folder in folders where seenIDs.insert(folder.id).inserted {
            folder.name = Self.sanitizedName(folder.name) ?? "Folder"
            folder.sourceKeys = folder.sourceKeys.filter { seenKeys.insert($0).inserted }
            repaired.append(folder)
        }
        self.folders = repaired
        rebuildIndexes()
    }

    private mutating func rebuildIndexes() {
        indexByID = Dictionary(uniqueKeysWithValues: folders.enumerated().map { ($1.id, $0) })
        indexByKey = [:]
        for folder in folders {
            for key in folder.sourceKeys where indexByKey[key] == nil {
                indexByKey[key] = folder.id
            }
        }
    }

    func folder(withID id: UUID) -> JobFolder? {
        indexByID[id].map { folders[$0] }
    }

    func contains(_ id: UUID) -> Bool {
        indexByID[id] != nil
    }

    func folderID(forKey key: String) -> UUID? {
        indexByKey[key]
    }

    // MARK: Names

    /// Trimmed, single-line, capped; nil when nothing is left.
    static func sanitizedName(_ raw: String) -> String? {
        let singleLine = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumNameLength))
    }

    private static func comparisonKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func isNameTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        let wanted = Self.comparisonKey(name)
        return folders.contains { $0.id != id && Self.comparisonKey($0.name) == wanted }
    }

    func validatedName(_ raw: String, excluding id: UUID? = nil) -> FolderNameResult {
        guard let name = Self.sanitizedName(raw) else { return .empty }
        return isNameTaken(name, excluding: id) ? .duplicate : .accepted(name)
    }

    /// "New Folder", then "New Folder 2", ... for the create prompt's default.
    func suggestedNewFolderName(base: String = "New Folder") -> String {
        guard isNameTaken(base) else { return base }
        var number = 2
        while isNameTaken("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// A name for an automatic folder that collides with nothing: the plain
    /// default, else qualified by the grandparent ("Extras (Season 1)"), else
    /// numbered.
    private func uniqueName(for placement: FolderPlacementKey, forceQualifier: Bool) -> String {
        var candidate = placement.name
        if let qualifier = placement.qualifier, !qualifier.isEmpty, forceQualifier || isNameTaken(candidate) {
            candidate = "\(placement.name) (\(qualifier))"
        }
        let base = candidate
        var number = 2
        while isNameTaken(candidate) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    // MARK: Placement

    /// Assigns a folder to every input that has none or an unknown one,
    /// creating automatic folders as needed. Existing assignments are left
    /// alone. Returns `jobID → folderID` for the inputs that changed.
    ///
    /// Two brand-new folders whose plain names collide are both qualified
    /// ("Extras (Season 1)" and "Extras (Season 2)") rather than leaving one
    /// arbitrarily plain; a new folder colliding with an existing one is the
    /// only one qualified.
    mutating func place(
        _ inputs: [FolderPlacementInput],
        now: Date = Date(),
        makeID: () -> UUID = { UUID() }
    ) -> [UUID: UUID] {
        let needing =
            inputs
            .filter { input in input.folderID.map { indexByID[$0] == nil } ?? true }
            .sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.jobID.uuidString < rhs.jobID.uuidString : lhs.createdAt < rhs.createdAt
            }
        guard !needing.isEmpty else { return [:] }

        var placements: [UUID: FolderPlacementKey] = [:]
        var newKeys: [FolderPlacementKey] = []
        var seenKeys = Set<String>()
        for input in needing {
            let placement = FolderPlacement.key(for: input)
            placements[input.jobID] = placement
            if indexByKey[placement.key] == nil, seenKeys.insert(placement.key).inserted {
                newKeys.append(placement)
            }
        }

        let batchNameCounts = Dictionary(grouping: newKeys, by: { Self.comparisonKey($0.name) }).mapValues(\.count)
        for placement in newKeys {
            let collidesInBatch = (batchNameCounts[Self.comparisonKey(placement.name)] ?? 0) > 1
            let folder = JobFolder(
                id: makeID(),
                name: uniqueName(for: placement, forceQualifier: collidesInBatch),
                sourceKeys: [placement.key],
                isExpanded: true,
                createdAt: now.wholeSeconds,
                isManual: false
            )
            folders.append(folder)
            indexByID[folder.id] = folders.count - 1
            indexByKey[placement.key] = folder.id
        }

        var assignments: [UUID: UUID] = [:]
        assignments.reserveCapacity(needing.count)
        for input in needing {
            if let placement = placements[input.jobID], let folderID = indexByKey[placement.key] {
                assignments[input.jobID] = folderID
            }
        }
        return assignments
    }

    // MARK: Editing

    /// A user-made folder: no keys (nothing lands here automatically until
    /// jobs are moved in), visible while empty.
    @discardableResult
    mutating func createManualFolder(
        named raw: String,
        now: Date = Date(),
        makeID: () -> UUID = { UUID() }
    ) -> UUID? {
        guard case .accepted(let name) = validatedName(raw) else { return nil }
        let folder = JobFolder(
            id: makeID(), name: name, sourceKeys: [], isExpanded: true, createdAt: now.wholeSeconds, isManual: true)
        folders.append(folder)
        indexByID[folder.id] = folders.count - 1
        return folder.id
    }

    /// Changes the name only; keys stay, so future jobs from the same place
    /// keep landing here.
    @discardableResult
    mutating func rename(_ id: UUID, to raw: String) -> FolderNameResult {
        guard let index = indexByID[id] else { return .empty }
        let result = validatedName(raw, excluding: id)
        if case .accepted(let name) = result {
            folders[index].name = name
        }
        return result
    }

    mutating func setExpanded(_ expanded: Bool, for id: UUID) {
        guard let index = indexByID[id], folders[index].isExpanded != expanded else { return }
        folders[index].isExpanded = expanded
    }

    mutating func setAllExpanded(_ expanded: Bool) {
        for index in folders.indices { folders[index].isExpanded = expanded }
    }

    /// Adds keys to a folder, taking them from whichever folder held them.
    mutating func adopt(keys: [String], into id: UUID) {
        guard let index = indexByID[id] else { return }
        for key in keys where !folders[index].sourceKeys.contains(key) {
            if let owner = indexByKey[key], owner != id, let ownerIndex = indexByID[owner] {
                folders[ownerIndex].sourceKeys.removeAll { $0 == key }
            }
            folders[index].sourceKeys.append(key)
        }
        rebuildIndexes()
    }

    /// Removes a folder and its keys. The caller re-places its jobs.
    @discardableResult
    mutating func remove(_ id: UUID) -> JobFolder? {
        guard let index = indexByID[id] else { return nil }
        let removed = folders.remove(at: index)
        rebuildIndexes()
        return removed
    }

    /// Puts a previously removed (or edited) folder back, replacing any
    /// current folder with the same id. By default keys another folder
    /// claimed in the meantime stay with that folder; undo passes
    /// `reclaimingKeys` to take them back, because undoing a merge or delete
    /// must return future videos to the folder the user restored.
    mutating func restore(_ folder: JobFolder, reclaimingKeys: Bool = false) {
        if reclaimingKeys {
            for key in folder.sourceKeys {
                if let owner = indexByKey[key], owner != folder.id, let ownerIndex = indexByID[owner] {
                    folders[ownerIndex].sourceKeys.removeAll { $0 == key }
                }
            }
            rebuildIndexes()
        }
        var restored = folder
        restored.sourceKeys = folder.sourceKeys.filter { key in
            indexByKey[key].map { $0 == folder.id } ?? true
        }
        if let index = indexByID[folder.id] {
            folders[index] = restored
        } else {
            folders.append(restored)
        }
        rebuildIndexes()
    }
}

// MARK: - Display order

/// How the sidebar orders its folders.
enum FolderSortOrder: String, CaseIterable, Identifiable, Sendable {
    /// The folder holding the most recently added job first. Date added, not
    /// last update: a running job touches its update time constantly, and
    /// folders must not jump around while work is in progress.
    case recentActivity
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentActivity: "Newest job"
        case .name: "Name"
        }
    }

    /// Orders `items` by this rule, breaking ties by name so the list never
    /// shuffles between renders.
    func sorted<Item>(
        _ items: [Item],
        name: (Item) -> String,
        newestActivity: (Item) -> Date
    ) -> [Item] {
        items.sorted { lhs, rhs in
            if self == .recentActivity {
                let left = newestActivity(lhs)
                let right = newestActivity(rhs)
                if left != right { return left > right }
            }
            let order = name(lhs).localizedStandardCompare(name(rhs))
            return order == .orderedAscending
        }
    }
}

/// How the sidebar groups its jobs.
enum SidebarGrouping: String, CaseIterable, Identifiable, Sendable {
    case folders
    case status
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folders: "Folders"
        case .status: "Status"
        case .none: "None"
        }
    }
}

/// Sidebar search: a job matches when its title or its folder's name does,
/// so typing a folder's name lists that folder's jobs.
enum JobSearch {
    static func matches(title: String, folderName: String?, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(trimmed) { return true }
        return folderName?.localizedCaseInsensitiveContains(trimmed) ?? false
    }
}

// MARK: - Undo, results, reveal

extension Date {
    /// `folders.json` stores dates as ISO 8601 (whole seconds). Folders are
    /// created with this so the in-memory value already equals what a reload
    /// reads back, and "did anything change since launch" stays exact.
    fileprivate var wholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}

/// Enough to take one folder operation back without disturbing anything the
/// user did afterwards: a job that was moved again in the meantime stays
/// where it is, and a folder someone started using is not removed.
struct FolderUndoRecord: Equatable, Sendable {
    struct Move: Equatable, Sendable {
        var jobID: UUID
        /// nil when the job had no folder yet; undo then re-places it by the rules.
        var from: UUID?
        var to: UUID
    }

    /// Folders the operation removed (a merge source, a deleted folder),
    /// exactly as they were, keys included.
    var removedFolders: [JobFolder] = []
    /// Folders the operation created; dropped again if nothing is in them.
    var createdFolderIDs: [UUID] = []
    var moves: [Move] = []
}

/// What a folder operation did, for the sidebar's undo notice.
struct FolderChange: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case created
        case moved
        case merged(sourceName: String)
        case deleted
    }

    var kind: Kind
    /// The folder the change is about: created, moved into, merged into, or
    /// (for a delete) the one that went away.
    var folderID: UUID
    var folderName: String
    var movedCount: Int
    var undo: FolderUndoRecord
}

/// Asks the sidebar to make one job visible: clear whatever hides it, then
/// scroll to it. `id` is unique per request so revealing the same job twice
/// still triggers.
struct JobRevealRequest: Equatable, Identifiable, Sendable {
    var id = UUID()
    var jobID: UUID
    /// The job is archived, so the sidebar must switch to the Archived view.
    var showsArchived: Bool
}

// MARK: - Sidebar layout

/// The pure arrangement of the sidebar in Folders mode: which folders show,
/// in what order, holding which of the already-filtered jobs.
struct SidebarFolderLayout: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var id: UUID
        var folderID: UUID?
    }

    struct Section: Identifiable, Equatable, Sendable {
        var folder: JobFolder
        /// The jobs to show, in display order.
        var jobIDs: [UUID]
        var id: UUID { folder.id }
    }

    var sections: [Section]
    /// Jobs whose folder is missing. Only possible while history is still
    /// loading (or after a damaged folder list); they are never hidden.
    var unfiledJobIDs: [UUID]

    /// - Parameters:
    ///   - displayed: the jobs that survived the status filter and search, in display order.
    ///   - newestActivity: each folder's newest job date over ALL its jobs, so
    ///     filtering does not reshuffle the folders.
    ///   - isFiltering: a status filter or search text is narrowing the list.
    static func make(
        book: JobFolderBook,
        displayed: [Entry],
        newestActivity: [UUID: Date],
        order: FolderSortOrder,
        isFiltering: Bool,
        searchQuery: String
    ) -> SidebarFolderLayout {
        var byFolder: [UUID: [UUID]] = [:]
        var unfiled: [UUID] = []
        for entry in displayed {
            if let folderID = entry.folderID, book.contains(folderID) {
                byFolder[folderID, default: []].append(entry.id)
            } else {
                unfiled.append(entry.id)
            }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = book.folders.filter { folder in
            if byFolder[folder.id]?.isEmpty == false { return true }
            // Automatic folders exist only to hold jobs. A folder the user
            // made stays put while empty, unless a filter is narrowing the
            // list and it is not what the search is looking for.
            guard folder.isManual else { return false }
            guard isFiltering else { return true }
            return !query.isEmpty && JobSearch.matches(title: "", folderName: folder.name, query: query)
        }
        let ordered = order.sorted(
            visible,
            name: { $0.name },
            newestActivity: { newestActivity[$0.id] ?? $0.createdAt }
        )
        return SidebarFolderLayout(
            sections: ordered.map { Section(folder: $0, jobIDs: byFolder[$0.id] ?? []) },
            unfiledJobIDs: unfiled
        )
    }
}
