import CryptoKit
import Foundation

enum ModelDownloaderError: LocalizedError {
    case downloadFailed(model: String, message: String)
    case integrityCheckFailed(model: String)
    case unsupportedModel(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let model, let message):
            return "Downloading \(model) failed: \(message)"
        case .integrityCheckFailed(let model):
            return "The downloaded \(model) failed its integrity check. The incomplete file was removed; try again."
        case .unsupportedModel(let model):
            return "Cue cannot download the unrecognized model \"\(model)\". Choose a built-in model, or place a custom .bin file in Cue's models folder."
        }
    }
}

struct ModelArtifact: Sendable {
    let name: String
    let byteCount: Int64
    let sha256: String
}

private struct ModelVerificationStamp: Codable {
    let sha256: String
    let byteCount: Int64
    let modificationDate: Date
}

/// Network seam so tests exercise the downloader without touching the network.
protocol ModelNetwork: Sendable {
    /// Downloads `url` to a caller-owned temporary file and returns its
    /// location. `resumeData` from a prior interrupted attempt continues that
    /// download. Progress fractions (0–1) arrive on an arbitrary queue. An
    /// interruption that can be resumed later must throw a `URLError` carrying
    /// `downloadTaskResumeData`.
    func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

/// Fetches GGML whisper models into Application Support. Presence of the
/// final file is the sole "installed" signal; interrupted downloads persist
/// `URLSession` resume data next to the target as `<file>.resume`.
struct ModelDownloader: Sendable {
    /// Immutable Hugging Face revision and LFS object metadata. The SHA-256
    /// values are the repository's LFS object ids for this exact revision.
    static let modelRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let artifacts = [
        ModelArtifact(name: "ggml-large-v3-turbo-q5_0.bin", byteCount: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        ModelArtifact(name: "ggml-large-v3-turbo.bin", byteCount: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        ModelArtifact(name: "ggml-medium.bin", byteCount: 1_533_763_059, sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        ModelArtifact(name: "ggml-small.bin", byteCount: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        ModelArtifact(name: "ggml-base.bin", byteCount: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        ModelArtifact(name: "ggml-tiny.bin", byteCount: 77_691_713, sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
    ]
    static let models = artifacts.map(\.name)
    static let defaultModel = "ggml-large-v3-turbo-q5_0.bin"

    private let baseDirectory: URL
    private let network: any ModelNetwork
    private let artifactManifest: [String: ModelArtifact]

    init(
        baseDirectory: URL? = nil,
        network: any ModelNetwork = URLSessionModelNetwork(),
        artifactManifest: [String: ModelArtifact] = Dictionary(
            uniqueKeysWithValues: ModelDownloader.artifacts.map { ($0.name, $0) }
        )
    ) {
        self.baseDirectory =
            baseDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cue", isDirectory: true)
        self.network = network
        self.artifactManifest = artifactManifest
    }

    var modelsDirectory: URL {
        baseDirectory.appendingPathComponent("models", isDirectory: true)
    }

    func destinationURL(for model: String) -> URL {
        modelsDirectory.appendingPathComponent(model)
    }

    static func sourceURL(for model: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(modelRevision)/")!
            .appendingPathComponent(model)
    }

    func installedModels() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        return entries.filter { $0.hasSuffix(".bin") }.sorted()
    }

    /// Returns the local model file, downloading it first if needed. Already
    /// installed models return immediately without any network activity.
    ///
    /// - `onProgress` may fire on a background queue — callers must hop to
    ///   the main actor before touching UI state.
    /// - User cancellation throws `CancellationError` and leaves a `.resume`
    ///   file behind so the next attempt continues the download.
    ///
    /// Concurrent calls for the same model are unguarded by design: the app
    /// runs one transcription job at a time (AppModel's serial GPU slot).
    func ensureInstalled(
        model: String,
        onProgress: @escaping @Sendable (JobProgress) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let destination = destinationURL(for: model)
        if fileManager.fileExists(atPath: destination.path) {
            if let artifact = artifactManifest[model] {
                let isVerified =
                    try Self.hasValidVerificationStamp(for: destination, artifact: artifact)
                    || Self.verifyFile(at: destination, against: artifact)
                if isVerified {
                    // Models installed before verification stamps existed pay
                    // the hash cost once; subsequent jobs only compare file
                    // metadata, avoiding a multi-gigabyte read per job.
                    try? Self.writeVerificationStamp(for: destination, artifact: artifact)
                    return destination
                }
                // A truncated or replaced file must not remain the permanent
                // "installed" signal. Remove it and fetch the pinned artifact.
                try fileManager.removeItem(at: destination)
                try? fileManager.removeItem(at: Self.verificationStampURL(for: destination))
            } else {
                // User-supplied models are allowed when already installed, but
                // the built-in downloader only fetches the pinned manifest.
                return destination
            }
        }

        guard let artifact = artifactManifest[model] else {
            throw ModelDownloaderError.unsupportedModel(model)
        }

        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let resumeFile = destination.appendingPathExtension("resume")
        let resumeData = try? Data(contentsOf: resumeFile)

        onProgress(JobProgress(stage: .loadingModel, detail: "Downloading \(model)", fraction: 0))
        do {
            let downloaded = try await network.download(
                from: Self.sourceURL(for: model),
                resumeData: resumeData
            ) { fraction in
                let percent = Int((fraction * 100).rounded())
                onProgress(
                    JobProgress(
                        stage: .loadingModel,
                        detail: "Downloading \(model) (\(percent)%)",
                        fraction: fraction
                    ))
            }
            defer { try? fileManager.removeItem(at: downloaded) }
            if try !Self.verifyFile(at: downloaded, against: artifact) {
                throw ModelDownloaderError.integrityCheckFailed(model: model)
            }
            try? fileManager.removeItem(at: resumeFile)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: downloaded, to: destination)
            try? Self.writeVerificationStamp(for: destination, artifact: artifact)
            return destination
        } catch {
            // Any consumed resume data is stale now; only fresh resume data
            // from this failure is worth keeping for the next attempt.
            if let data = (error as? URLError)?.downloadTaskResumeData {
                try? data.write(to: resumeFile)
            } else {
                try? fileManager.removeItem(at: resumeFile)
            }
            if error is CancellationError {
                throw error
            }
            if let downloaderError = error as? ModelDownloaderError {
                throw downloaderError
            }
            switch (error as? URLError)?.code {
            case .cancelled:
                // Callers see exactly one cancellation shape; the resume data
                // above already preserved the partial download.
                throw CancellationError()
            case .badServerResponse:
                // Carries the HTTP status in its description — "check your
                // internet connection" would be untruthful for a 404.
                throw ModelDownloaderError.downloadFailed(model: model, message: error.localizedDescription)
            default:
                throw ModelDownloaderError.downloadFailed(
                    model: model,
                    message: "\(error.localizedDescription) Check your internet connection and try again."
                )
            }
        }
    }

    /// Streams the file through SHA-256 so even multi-gigabyte models stay out
    /// of memory. Internal for deterministic integrity tests.
    static func verifyFile(at url: URL, against artifact: ModelArtifact) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
            size.int64Value == artifact.byteCount
        else { return false }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == artifact.sha256
    }

    private static func verificationStampURL(for modelURL: URL) -> URL {
        modelURL.appendingPathExtension("verified.json")
    }

    private static func hasValidVerificationStamp(for url: URL, artifact: ModelArtifact) -> Bool {
        guard
            let data = try? Data(contentsOf: verificationStampURL(for: url)),
            let stamp = try? JSONDecoder().decode(ModelVerificationStamp.self, from: data),
            stamp.sha256 == artifact.sha256,
            stamp.byteCount == artifact.byteCount,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value == stamp.byteCount,
            let modificationDate = attributes[.modificationDate] as? Date,
            modificationDate == stamp.modificationDate
        else { return false }
        return true
    }

    private static func writeVerificationStamp(for url: URL, artifact: ModelArtifact) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modificationDate = attributes[.modificationDate] as? Date else {
            return
        }
        let stamp = ModelVerificationStamp(
            sha256: artifact.sha256,
            byteCount: artifact.byteCount,
            modificationDate: modificationDate
        )
        try JSONEncoder().encode(stamp).write(to: verificationStampURL(for: url), options: .atomic)
    }
}

/// Real network layer: a delegate-based download task so byte-level progress
/// and resume data are available (the async `URLSession.download` APIs expose
/// neither).
struct URLSessionModelNetwork: ModelNetwork {
    func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task =
            resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            // Produces a URLError(.cancelled) with resume data in the
            // delegate's didCompleteWithError, so the partial download is kept.
            task.cancel(byProducingResumeData: { _ in })
        }
    }
}

// State is only touched from the session's serial delegate queue (plus the
// pre-resume continuation assignment), hence @unchecked Sendable.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // A 404 from Hugging Face still "finishes" with an error page as the
        // body; never hand that back as a model file.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode,
            !(200..<300).contains(status)
        {
            result = .failure(
                URLError(
                    .badServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "The server returned status \(status)."]
                ))
            return
        }
        // The system deletes `location` once this callback returns, so the
        // move must happen synchronously here.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-model-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            result = .success(kept)
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: result ?? .failure(URLError(.unknown)))
        }
        continuation = nil
    }

    // Closes the theoretical hang if the session invalidates without ever
    // delivering task completion.
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        continuation?.resume(throwing: error ?? URLError(.unknown))
        continuation = nil
    }
}
