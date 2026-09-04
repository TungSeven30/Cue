import Foundation
import Testing

@testable import Cue

struct SubtitleFileWriterTests {
    @Test func consecutiveWritesShareTheirUpdatedFileFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("captions.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nOriginal\n".utf8).write(to: url)
        let document = try SubtitleImporter.importFile(at: url, backingUp: false)
        let writer = SubtitleFileWriter(beforeWrite: { #expect(!Thread.isMainThread) })
        let key = SubtitleFileWriter.Key(jobID: UUID(), slot: .transcript)
        for text in ["First edit", "Tiếng Việt"] {
            let request = SubtitleFileWriter.Request(
                key: key, source: document.source,
                segments: [TranscriptionSegment(id: 1, start: 0, end: 1, text: text)]
            )
            writer.write(request) { _ in }
        }
        let results = writer.flush()
        #expect(results.count == 1)
        #expect(results.first?.source.syncPaused == false)
        #expect(results.first?.source.matchesFileOnDisk() == true)
        #expect(try SubtitleReader.read(contentsOf: url).first?.text == "Tiếng Việt")
        #expect(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8).contains("Original"))
    }

    @Test func canceledQueuedWriteLeavesTheSourceUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("captions.srt")
        let original = Data("1\n00:00:00,000 --> 00:00:01,000\nOriginal\n".utf8)
        try original.write(to: url)
        let document = try SubtitleImporter.importFile(at: url, backingUp: false)
        let gate = DispatchSemaphore(value: 0)
        let writer = SubtitleFileWriter(beforeWrite: { gate.wait() })
        let request = SubtitleFileWriter.Request(
            key: .init(jobID: UUID(), slot: .transcript), source: document.source,
            segments: [TranscriptionSegment(id: 1, start: 0, end: 1, text: "Canceled")]
        )
        writer.write(request) { _ in Issue.record("Canceled write completed") }
        request.cancellation.cancel()
        gate.signal()
        #expect(writer.flush().isEmpty)
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }
}
