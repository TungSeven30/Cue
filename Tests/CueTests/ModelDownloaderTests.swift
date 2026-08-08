import CryptoKit
import Foundation
import Testing
@testable import Cue

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

    private func artifact(name: String, data: Data) -> ModelArtifact {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ModelArtifact(name: name, byteCount: Int64(data.count), sha256: digest)
    }

    @Test func derivesDestinationAndSourceForKnownModel() {
        let defaultDownloader = ModelDownloader()
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cue/models/ggml-tiny.bin")
        #expect(defaultDownloader.destinationURL(for: "ggml-tiny.bin").path == expected.path)
        #expect(
            ModelDownloader.sourceURL(for: "ggml-tiny.bin").absoluteString
                == "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(ModelDownloader.modelRevision)/ggml-tiny.bin"
        )
        #expect(ModelDownloader.models.contains(ModelDownloader.defaultModel))
        #expect(ModelDownloader.models.count == 6)
    }

    @Test func alreadyInstalledShortCircuitsWithoutNetwork() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let network = FakeNetwork()
        let installed = Data([7])
        let downloader = ModelDownloader(
            baseDirectory: base,
            network: network,
            artifactManifest: ["ggml-base.bin": artifact(name: "ggml-base.bin", data: installed)]
        )

        let destination = downloader.destinationURL(for: "ggml-base.bin")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try installed.write(to: destination)

        let url = try await downloader.ensureInstalled(model: "ggml-base.bin") { _ in }
        #expect(url == destination)
        #expect(network.calls.isEmpty)
    }

    @Test func failedDownloadPersistsResumeDataNextToTarget() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let resumeData = Data([1, 2, 3, 4])
        let network = FakeNetwork(results: [
            .failure(
                URLError(
                    .networkConnectionLost,
                    userInfo: [NSURLSessionDownloadTaskResumeData: resumeData]
                ))
        ])
        let downloader = ModelDownloader(
            baseDirectory: base,
            network: network,
            artifactManifest: ["ggml-tiny.bin": artifact(name: "ggml-tiny.bin", data: Data([1]))]
        )

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
            .failure(
                URLError(
                    .cancelled,
                    userInfo: [NSURLSessionDownloadTaskResumeData: resumeData]
                ))
        ])
        let downloader = ModelDownloader(
            baseDirectory: base,
            network: network,
            artifactManifest: ["ggml-tiny.bin": artifact(name: "ggml-tiny.bin", data: Data([1]))]
        )

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
        let downloaded = Data([9, 9])
        let network = FakeNetwork(results: [.success(downloaded)])
        let downloader = ModelDownloader(
            baseDirectory: base,
            network: network,
            artifactManifest: ["ggml-tiny.bin": artifact(name: "ggml-tiny.bin", data: downloaded)]
        )

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
        let downloader = ModelDownloader(
            baseDirectory: base,
            network: network,
            artifactManifest: ["ggml-tiny.bin": artifact(name: "ggml-tiny.bin", data: Data([1]))]
        )

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
        let downloader = ModelDownloader(baseDirectory: base, network: FakeNetwork(), artifactManifest: [:])

        #expect(downloader.installedModels() == [])

        let models = base.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data([1]).write(to: models.appendingPathComponent("ggml-tiny.bin"))
        try Data([1]).write(to: models.appendingPathComponent("ggml-base.bin"))
        try Data([1]).write(to: models.appendingPathComponent("ggml-small.bin.resume"))

        #expect(downloader.installedModels() == ["ggml-base.bin", "ggml-tiny.bin"])
    }

    @Test func invalidInstalledArtifactIsReplacedWithVerifiedDownload() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = "verified-test.bin"
        let valid = Data([1, 2, 3, 4])
        let network = FakeNetwork(results: [.success(valid)])
        let downloader = ModelDownloader(
            baseDirectory: base,
            network: network,
            artifactManifest: [model: artifact(name: model, data: valid)]
        )
        let destination = downloader.destinationURL(for: model)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([9, 9, 9, 9]).write(to: destination)

        let result = try await downloader.ensureInstalled(model: model) { _ in }

        #expect(network.calls.count == 1)
        #expect(try Data(contentsOf: result) == valid)
    }

    @Test func badDownloadedArtifactIsRejectedAndRemoved() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = "verified-test.bin"
        let expected = Data([1, 2, 3, 4])
        let downloader = ModelDownloader(
            baseDirectory: base,
            network: FakeNetwork(results: [.success(Data([4, 3, 2, 1]))]),
            artifactManifest: [model: artifact(name: model, data: expected)]
        )

        await #expect(throws: ModelDownloaderError.self) {
            try await downloader.ensureInstalled(model: model) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: downloader.destinationURL(for: model).path))
    }

    @Test func unrecognizedModelIsNeverDownloadedWithoutIntegrityMetadata() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let network = FakeNetwork()
        let downloader = ModelDownloader(baseDirectory: base, network: network, artifactManifest: [:])

        await #expect(throws: ModelDownloaderError.self) {
            try await downloader.ensureInstalled(model: "unknown.bin") { _ in }
        }
        #expect(network.calls.isEmpty)
    }

    @Test func verificationStampAvoidsRehashingUntilTheModelChanges() async throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = "verified-test.bin"
        let valid = Data([1, 2, 3, 4])
        let network = FakeNetwork(results: [.success(valid), .success(valid)])
        let downloader = ModelDownloader(
            baseDirectory: base,
            network: network,
            artifactManifest: [model: artifact(name: model, data: valid)]
        )

        let destination = try await downloader.ensureInstalled(model: model) { _ in }
        _ = try await downloader.ensureInstalled(model: model) { _ in }
        #expect(network.calls.count == 1)

        try Data([4, 3, 2, 1]).write(to: destination)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: destination.path
        )
        _ = try await downloader.ensureInstalled(model: model) { _ in }
        #expect(network.calls.count == 2)
        #expect(try Data(contentsOf: destination) == valid)
    }
}
