import Foundation

/// One in-flight (or just-failed) yt-dlp fetch, shown in the sidebar until
/// it becomes a job or the user dismisses it. Downloads deliberately live
/// outside `jobs`: a job's identity is a file on disk, and there is no file
/// until the fetch succeeds.
struct MediaDownload: Identifiable, Hashable {
    enum State: Hashable {
        case running
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let id: UUID
    let pageURL: URL
    var fraction: Double?
    var detail: String
    var state: State
    let startedAt: Date

    init(pageURL: URL, id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.pageURL = pageURL
        self.fraction = nil
        self.detail = "Resolving link…"
        self.state = .running
        self.startedAt = startedAt
    }

    /// A short label for a sidebar row. The last meaningful path component
    /// beats the host for most sites, but watch-style URLs carry everything
    /// in the query, so those fall back to the host.
    var title: String {
        let component = pageURL.lastPathComponent
        if !component.isEmpty, component != "/", component.count > 1, !component.hasPrefix("watch") {
            return component
        }
        return pageURL.host() ?? pageURL.absoluteString
    }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}
