import Foundation
import Testing
@testable import Cue

/// `Cue/folders.json`: atomic round trip, tolerance for damaged files, and
/// the guarantee that an in-memory store never touches the disk.
struct JobFolderStoreTests {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("job-folder-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func cueDirectory(_ base: URL) -> URL {
        base.appendingPathComponent("Cue", isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func fileLivesNextToTheJobsDirectory() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobFolderStore(baseURL: base)
        #expect(store.fileURL == cueDirectory(base).appendingPathComponent("folders.json"))
        let direct = JobFolderStore(directoryURL: cueDirectory(base))
        #expect(direct.fileURL == store.fileURL)
    }

    @Test func roundTripPreservesEveryField() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobFolderStore(baseURL: base)
        let folders = [
            JobFolder(
                id: UUID(), name: "Actress A", sourceKeys: ["dir:/v/Actress A", "site:example.com"],
                isExpanded: false, createdAt: Date(timeIntervalSince1970: 1_700_000_000), isManual: false),
            JobFolder(id: UUID(), name: "Favourites", sourceKeys: [], isExpanded: true, createdAt: Date(timeIntervalSince1970: 1_700_000_100), isManual: true),
        ]
        store.save(folders)
        store.flush()

        let loaded = JobFolderStore(baseURL: base).load()
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.folders == folders)
    }

    @Test func aMissingFileLoadsAsEmptyWithoutWarnings() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let loaded = JobFolderStore(baseURL: base).load()
        #expect(loaded.folders.isEmpty)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func theLastSaveWins() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobFolderStore(baseURL: base)
        for index in 0..<20 {
            store.save([JobFolder(name: "Version \(index)")])
        }
        store.flush()
        #expect(store.load().folders.map(\.name) == ["Version 19"])
    }

    @Test func aCorruptFileIsBackedUpAndReported() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobFolderStore(baseURL: base)
        let fileURL = try #require(store.fileURL)
        try write("{ this is not json", to: fileURL)

        let loaded = store.load()
        #expect(loaded.folders.isEmpty)
        #expect(loaded.warnings.count == 1)
        #expect(loaded.warnings.first?.contains("folders.corrupt.json") == true)

        let backup = fileURL.deletingLastPathComponent().appendingPathComponent(JobFolderStore.corruptFileName)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ this is not json")
    }

    @Test func aNewerCorruptFileReplacesTheOlderBackup() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobFolderStore(baseURL: base)
        let fileURL = try #require(store.fileURL)
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent(JobFolderStore.corruptFileName)

        try write("first damage", to: fileURL)
        _ = store.load()
        try write("second damage", to: fileURL)
        _ = store.load()
        #expect(try String(contentsOf: backup, encoding: .utf8) == "second damage")
    }

    @Test func oneMalformedFolderDoesNotDiscardTheRest() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobFolderStore(baseURL: base)
        let fileURL = try #require(store.fileURL)
        let good = UUID()
        try write(
            """
            {"version": 1, "folders": [
              {"id": "\(good.uuidString)", "name": "Good", "sourceKeys": ["dir:/a"]},
              {"id": "not-a-uuid", "name": "Bad"},
              42
            ]}
            """, to: fileURL)

        let loaded = store.load()
        #expect(loaded.folders.map(\.id) == [good])
        #expect(loaded.folders.first?.name == "Good")
        #expect(loaded.warnings.count == 1)
        #expect(loaded.warnings.first?.contains("2") == true)
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent(JobFolderStore.corruptFileName)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func inMemoryStoreNeverTouchesTheDisk() {
        let store = JobFolderStore.inMemory
        #expect(store.fileURL == nil)
        store.save([JobFolder(name: "Ghost")])
        store.flush()
        let loaded = store.load()
        #expect(loaded.folders.isEmpty)
        #expect(loaded.warnings.isEmpty)
    }
}

/// `TranscriptionJob.folderID` is optional on disk, so every history written
/// before folders existed still decodes.
struct JobFolderIDCodingTests {
    private func json(folderID: String?) -> Data {
        let folderLine = folderID.map { #""folderID": "\#($0)","# } ?? ""
        return Data(
            """
            {
              "id": "\(UUID().uuidString)",
              "sourcePath": "/tmp/example.mp4",
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-02T00:00:00Z",
              "status": "idle",
              "progress": {"stage": "idle", "detail": "x"},
              "settings": {"sourceLanguage": "auto", "whisperModel": "m", "whisperBackend": "auto", "openAIModel": "gpt-5.2"},
              \(folderLine)
              "transcriptSegments": [], "translatedSegments": [], "log": ""
            }
            """.utf8)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func oldJSONWithoutFolderIDDecodesAsNil() throws {
        let job = try decoder().decode(TranscriptionJob.self, from: json(folderID: nil))
        #expect(job.folderID == nil)
    }

    @Test func folderIDRoundTripsThroughJSON() throws {
        let id = UUID()
        let job = try decoder().decode(TranscriptionJob.self, from: json(folderID: id.uuidString))
        #expect(job.folderID == id)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder().decode(TranscriptionJob.self, from: try encoder.encode(job))
        #expect(again.folderID == id)
        #expect(again == job)
    }

    @Test func aNilFolderIDStaysNilAfterARoundTrip() throws {
        let job = try decoder().decode(TranscriptionJob.self, from: json(folderID: nil))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder().decode(TranscriptionJob.self, from: try encoder.encode(job))
        #expect(again.folderID == nil)
    }
}
