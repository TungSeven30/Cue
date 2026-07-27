import Foundation
import Testing
@testable import WhisperDesk

/// Records calls and serves canned outcomes so no test touches the network.
private final class FakeNetwork: ModelNetwork, @unchecked Sendable {
    var calls: [(url: URL, resumeData: Data?)] = []
    var results: [Result<Data, Error>]

    init(results: [Result<Data, Error>] = [.success(Data([1]))]) {
        self.results = results
    }

    func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        calls.append((url, resumeData))
        switch results.removeFirst() {
        case .success(let data):
            onProgress(0.5)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-download-\(UUID().uuidString)")
            try data.write(to: temp)
            return temp
        case .failure(let error):
            throw error
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    var updates: [JobProgress] = []
}

struct ModelDownloaderTests {
    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func derivesDestinationAndSourceForKnownModel() {
        let defaultDownloader = ModelDownloader()
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperDesk/models/ggml-tiny.bin")
        #expect(defaultDownloader.destinationURL(for: "ggml-tiny.bin").path == expected.path)
        #expect(
            ModelDownloader.sourceURL(for: "ggml-tiny.bin").absoluteString
                == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
        )
        #expect(ModelDownloader.models.contains(ModelDownloader.defaultModel))
        #expect(ModelDownloader.models.count == 6)
    }

    @Test func alreadyInstalledShortCircuitsWithoutNetwork() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let network = FakeNetwork()
        let downloader = ModelDownloader(baseDirectory: base, network: network)

        let destination = downloader.destinationURL(for: "ggml-base.bin")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([7]).write(to: destination)

        let url = try await downloader.ensureInstalled(model: "ggml-base.bin") { _ in }
        #expect(url == destination)
        #expect(network.calls.isEmpty)
    }

    @Test func failedDownloadPersistsResumeDataNextToTarget() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let resumeData = Data([1, 2, 3, 4])
        let network = FakeNetwork(results: [
            .failure(URLError(
                .networkConnectionLost,
                userInfo: [NSURLSessionDownloadTaskResumeData: resumeData]
            )),
        ])
        let downloader = ModelDownloader(baseDirectory: base, network: network)

        await #expect(throws: ModelDownloaderError.self) {
            try await downloader.ensureInstalled(model: "ggml-tiny.bin") { _ in }
        }

        let resumeFile = downloader.destinationURL(for: "ggml-tiny.bin")
            .appendingPathExtension("resume")
        #expect(resumeFile.lastPathComponent == "ggml-tiny.bin.resume")
        #expect(try Data(contentsOf: resumeFile) == resumeData)
    }

    // Callers must see exactly one cancellation shape (CancellationError, not
    // ModelDownloaderError or URLError) with the partial download preserved.
    @Test func cancellationThrowsCancellationErrorAndPersistsResumeData() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let resumeData = Data([8, 8, 8])
        let network = FakeNetwork(results: [
            .failure(URLError(
                .cancelled,
                userInfo: [NSURLSessionDownloadTaskResumeData: resumeData]
            )),
        ])
        let downloader = ModelDownloader(baseDirectory: base, network: network)

        await #expect(throws: CancellationError.self) {
            try await downloader.ensureInstalled(model: "ggml-tiny.bin") { _ in }
        }

        let resumeFile = downloader.destinationURL(for: "ggml-tiny.bin")
            .appendingPathExtension("resume")
        #expect(try Data(contentsOf: resumeFile) == resumeData)
    }

    @Test func retryConsumesPersistedResumeDataAndDeletesIt() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let network = FakeNetwork(results: [.success(Data([9, 9]))])
        let downloader = ModelDownloader(baseDirectory: base, network: network)

        let resumeData = Data([5, 6, 7])
        let destination = downloader.destinationURL(for: "ggml-tiny.bin")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let resumeFile = destination.appendingPathExtension("resume")
        try resumeData.write(to: resumeFile)

        let recorder = ProgressRecorder()
        let url = try await downloader.ensureInstalled(model: "ggml-tiny.bin") { progress in
            recorder.updates.append(progress)
        }

        #expect(network.calls.count == 1)
        #expect(network.calls.first?.resumeData == resumeData)
        #expect(!FileManager.default.fileExists(atPath: resumeFile.path))
        #expect(try Data(contentsOf: url) == Data([9, 9]))
        #expect(recorder.updates.allSatisfy { $0.stage == .loadingModel })
        #expect(recorder.updates.contains { $0.detail == "Downloading ggml-tiny.bin (50%)" && $0.fraction == 0.5 })
    }

    @Test func failureWithoutResumeDataDeletesStaleResumeFile() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let network = FakeNetwork(results: [.failure(URLError(.timedOut))])
        let downloader = ModelDownloader(baseDirectory: base, network: network)

        let destination = downloader.destinationURL(for: "ggml-tiny.bin")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let resumeFile = destination.appendingPathExtension("resume")
        try Data([1]).write(to: resumeFile)

        await #expect(throws: ModelDownloaderError.self) {
            try await downloader.ensureInstalled(model: "ggml-tiny.bin") { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: resumeFile.path))
    }

    @Test func installedModelsListsOnlyBinFiles() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let downloader = ModelDownloader(baseDirectory: base, network: FakeNetwork())

        #expect(downloader.installedModels() == [])

        let models = base.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data([1]).write(to: models.appendingPathComponent("ggml-tiny.bin"))
        try Data([1]).write(to: models.appendingPathComponent("ggml-base.bin"))
        try Data([1]).write(to: models.appendingPathComponent("ggml-small.bin.resume"))

        #expect(downloader.installedModels() == ["ggml-base.bin", "ggml-tiny.bin"])
    }
}
