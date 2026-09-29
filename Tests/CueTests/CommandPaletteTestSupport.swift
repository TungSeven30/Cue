import Foundation

@testable import Cue

/// Builders shared by the command palette tests. Everything here is a plain
/// value: no AppModel, no window, no file system.
enum PaletteFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// `age` is seconds before `epoch`, so a smaller age is more recent.
    static func job(
        _ title: String,
        status: JobStatus = .idle,
        folder: String = "/Volumes/Media/Shows",
        archived: Bool = false,
        age: TimeInterval = 0,
        id: UUID = UUID()
    ) -> PaletteJobSummary {
        PaletteJobSummary(
            id: id,
            title: title,
            fileName: "\(title).mov",
            path: "\(folder)/\(title).mov",
            status: status,
            isArchived: archived,
            updatedAt: epoch.addingTimeInterval(-age)
        )
    }

    static func snapshot(
        jobs: [PaletteJobSummary] = [],
        selected: UUID? = nil,
        watch: [PaletteWatchFolderSummary] = [],
        downloads: [PaletteDownloadSummary] = [],
        _ configure: (inout PaletteContext) -> Void = { _ in }
    ) -> PaletteSnapshot {
        var snapshot = PaletteSnapshot()
        snapshot.jobs = jobs
        snapshot.selectedJobID = selected
        snapshot.watchFolders = watch
        snapshot.failedDownloads = downloads
        configure(&snapshot.context)
        return snapshot
    }

    static func rows(_ results: PaletteResults, in section: PaletteSection) -> [PaletteRowModel] {
        results.entryRows.filter { $0.entry.section == section }
    }

    static func titles(_ results: PaletteResults, in section: PaletteSection) -> [String] {
        rows(results, in: section).map(\.entry.title)
    }
}
