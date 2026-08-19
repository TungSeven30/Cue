import Foundation
import Testing
@testable import Cue

private func makeDownloadTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cue-download-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct MediaDownloadServiceTests {
    @Test func acceptsWhatPeopleActuallyPaste() {
        #expect(MediaDownloadService.normalizedWebURL(from: "https://example.com/watch?v=abc")?.absoluteString == "https://example.com/watch?v=abc")
        #expect(MediaDownloadService.normalizedWebURL(from: "  https://example.com/a  ")?.absoluteString == "https://example.com/a")
        #expect(MediaDownloadService.normalizedWebURL(from: "<https://example.com/a>")?.absoluteString == "https://example.com/a")
        // A scheme-less host is what a copied address bar often yields.
        #expect(MediaDownloadService.normalizedWebURL(from: "youtu.be/abc123")?.absoluteString == "https://youtu.be/abc123")
        #expect(MediaDownloadService.normalizedWebURL(from: "http://example.com/a")?.scheme == "http")
    }

    @Test func rejectsAnythingThatIsNotAWebAddress() {
        // File paths belong on the ordinary add path, not the fetcher.
        #expect(MediaDownloadService.normalizedWebURL(from: "/Users/me/clip.mkv") == nil)
        #expect(MediaDownloadService.normalizedWebURL(from: "~/clip.mkv") == nil)
        #expect(MediaDownloadService.normalizedWebURL(from: "file:///Users/me/clip.mkv") == nil)
        #expect(MediaDownloadService.normalizedWebURL(from: "mailto:someone@example.com") == nil)
        #expect(MediaDownloadService.normalizedWebURL(from: "") == nil)
        #expect(MediaDownloadService.normalizedWebURL(from: "   ") == nil)
        #expect(MediaDownloadService.normalizedWebURL(from: "just some text") == nil)
        // A bare word is a search term, not a host.
        #expect(MediaDownloadService.normalizedWebURL(from: "localhost") == nil)
    }

    @Test func argumentsPinTheBehaviorThatMattersForABatchQueue() throws {
        let staging = URL(fileURLWithPath: "/tmp/staging", isDirectory: true)
        let url = try #require(URL(string: "https://example.com/watch?v=abc"))
        let arguments = MediaDownloadService.makeArguments(url: url, stagingDirectory: staging)

        #expect(arguments.first == "yt-dlp")
        // A playlist URL must produce one job, not two hundred.
        #expect(arguments.contains("--no-playlist"))
        // Progress parsing depends on line-buffered, uncoloured output.
        #expect(arguments.contains("--newline"))
        #expect(arguments.contains("--no-color"))
        #expect(arguments.last == url.absoluteString)
        #expect(arguments.contains { $0.hasPrefix(staging.path) })
    }

    @Test func parsesTheProgressLinesYtDlpEmits() throws {
        let downloading = try #require(MediaDownloadService.parseProgress("[download]  45.2% of  123.45MiB at  1.23MiB/s ETA 00:42"))
        #expect(downloading.fraction != nil)
        #expect(abs((downloading.fraction ?? 0) - 0.452) < 0.0001)
        #expect(downloading.detail.contains("45"))

        let complete = try #require(MediaDownloadService.parseProgress("[download] 100% of 10.00MiB in 00:03"))
        #expect(complete.fraction == 1.0)

        let merging = try #require(MediaDownloadService.parseProgress("[Merger] Merging formats into \"clip.mp4\""))
        #expect(merging.fraction == nil)

        let destination = try #require(MediaDownloadService.parseProgress("[download] Destination: /tmp/staging/clip.f137.mp4"))
        #expect(destination.fraction == 0)
    }

    @Test func ignoresLinesThatCarryNoProgress() {
        #expect(MediaDownloadService.parseProgress("") == nil)
        #expect(MediaDownloadService.parseProgress("[youtube] abc123: Downloading webpage") == nil)
        #expect(MediaDownloadService.parseProgress("[info] abc123: Downloading 1 format(s): 137+140") == nil)
        #expect(MediaDownloadService.parseProgress("[download] Resuming download at byte 1024") == nil)
    }

    @Test func picksTheMergedFileOutOfTheStagingDirectory() throws {
        let directory = try makeDownloadTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // yt-dlp can leave the pre-merge streams behind; the merged output is
        // always the largest of them, and the .json info file is not media.
        try Data(repeating: 0, count: 400).write(to: directory.appendingPathComponent("clip.f137.mp4"))
        try Data(repeating: 0, count: 100).write(to: directory.appendingPathComponent("clip.f140.m4a"))
        try Data(repeating: 0, count: 900).write(to: directory.appendingPathComponent("clip.mp4"))
        try Data(repeating: 0, count: 5000).write(to: directory.appendingPathComponent("clip.info.json"))

        let found = try #require(MediaDownloadService.finishedMedia(in: directory))
        #expect(found.lastPathComponent == "clip.mp4")
    }

    @Test func emptyStagingDirectoryYieldsNothing() throws {
        let directory = try makeDownloadTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(MediaDownloadService.finishedMedia(in: directory) == nil)
    }

    // Re-fetching the same page must not overwrite the file an earlier job
    // still points at.
    @Test func destinationNamesDoNotCollide() throws {
        let directory = try makeDownloadTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = MediaDownloadService.uniqueDestination(for: "clip.mp4", in: directory)
        #expect(first.lastPathComponent == "clip.mp4")
        try Data("x".utf8).write(to: first)

        let second = MediaDownloadService.uniqueDestination(for: "clip.mp4", in: directory)
        #expect(second.lastPathComponent == "clip-2.mp4")
        try Data("x".utf8).write(to: second)

        #expect(MediaDownloadService.uniqueDestination(for: "clip.mp4", in: directory).lastPathComponent == "clip-3.mp4")
    }

    @Test func defaultDirectoryLivesUnderMovies() {
        #expect(MediaDownloadService.defaultDirectory().lastPathComponent == "Cue Downloads")
    }

    @Test func urlJobsAreOrdinaryJobsWithAKnownOrigin() throws {
        // .url must decode like any other origin, and older job files with no
        // origin field must still load as manual.
        let encoded = try JSONEncoder().encode(JobOrigin.url)
        #expect(try JSONDecoder().decode(JobOrigin.self, from: encoded) == .url)
        #expect(JobOrigin(rawValue: "url") == .url)
        #expect(JobOrigin(rawValue: "somethingNewer") == nil)
    }
}

struct DownloadOutputCollectorTests {
    @Test func splitsStdoutIntoWholeLinesAcrossChunkBoundaries() {
        let collector = DownloadOutputCollector()
        // A pipe read can end mid-line; a half line must be held back, not
        // parsed as progress and not lost.
        #expect(collector.appendStdout("[download]  1.0% of 10MiB\n[down") == ["[download]  1.0% of 10MiB"])
        #expect(collector.appendStdout("load]  2.0% of 10MiB\n") == ["[download]  2.0% of 10MiB"])
        #expect(collector.appendStdout("no newline yet") == [])
    }

    @Test func errorTailKeepsTheLastMeaningfulLines() {
        let collector = DownloadOutputCollector()
        collector.appendStderr("WARNING: something\n\n")
        collector.appendStderr("ERROR: Video unavailable\n")
        let tail = collector.errorTail()
        #expect(tail.contains("ERROR: Video unavailable"))
        #expect(!tail.hasSuffix("\n"))
        #expect(!tail.contains("\n\n"))
    }

    @Test func errorTailIsBoundedSoALongTracebackCannotGrowWithoutLimit() {
        let collector = DownloadOutputCollector()
        for index in 0..<5000 {
            collector.appendStderr("line \(index)\n")
        }
        let tail = collector.errorTail()
        #expect(tail.count < 1000)
        #expect(tail.contains("4999"))
    }

    @Test func eofResolvesOnlyAfterBothStreamsClose() async {
        let collector = DownloadOutputCollector()
        collector.markStdoutEOF()
        collector.markStderrEOF()
        // Both already closed: waiting must return immediately rather than
        // hanging the download on a continuation nobody will resume.
        await collector.waitForEOF()
    }
}

struct MediaDownloadTests {
    @Test func rowTitlePrefersTheSlugAndFallsBackToTheHost() throws {
        let slug = MediaDownload(pageURL: try #require(URL(string: "https://example.com/videos/my-clip")))
        #expect(slug.title == "my-clip")

        // A watch-style URL carries everything in the query, so the last path
        // component is noise; the host is the only useful label.
        let watch = MediaDownload(pageURL: try #require(URL(string: "https://example.com/watch?v=abc123")))
        #expect(watch.title == "example.com")

        let bare = MediaDownload(pageURL: try #require(URL(string: "https://example.com")))
        #expect(bare.title == "example.com")
    }

    @Test func failureMessageIsOnlyReadableOnAFailedDownload() throws {
        var download = MediaDownload(pageURL: try #require(URL(string: "https://example.com/a")))
        #expect(!download.state.isFailed)
        #expect(download.failureMessage == nil)

        download.state = .failed("ERROR: Video unavailable")
        #expect(download.state.isFailed)
        #expect(download.failureMessage == "ERROR: Video unavailable")
    }
}
