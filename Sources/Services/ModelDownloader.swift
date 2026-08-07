import Foundation

enum ModelDownloaderError: LocalizedError {
    case downloadFailed(model: String, message: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let model, let message):
            return "Downloading \(model) failed: \(message)"
        }
    }
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
    static let models = [
        "ggml-large-v3-turbo-q5_0.bin",
        "ggml-large-v3-turbo.bin",
        "ggml-medium.bin",
        "ggml-small.bin",
        "ggml-base.bin",
        "ggml-tiny.bin",
    ]
    static let defaultModel = "ggml-large-v3-turbo-q5_0.bin"

    private let baseDirectory: URL
    private let network: any ModelNetwork

    init(baseDirectory: URL? = nil, network: any ModelNetwork = URLSessionModelNetwork()) {
        self.baseDirectory = baseDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/WhisperDesk", isDirectory: true)
        self.network = network
    }

    var modelsDirectory: URL {
        baseDirectory.appendingPathComponent("models", isDirectory: true)
    }

    func destinationURL(for model: String) -> URL {
        modelsDirectory.appendingPathComponent(model)
    }

    static func sourceURL(for model: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/")!
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
            return destination
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
                onProgress(JobProgress(
                    stage: .loadingModel,
                    detail: "Downloading \(model) (\(percent)%)",
                    fraction: fraction
                ))
            }
            try? fileManager.removeItem(at: resumeFile)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: downloaded, to: destination)
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
        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
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
           !(200..<300).contains(status) {
            result = .failure(URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "The server returned status \(status)."]
            ))
            return
        }
        // The system deletes `location` once this callback returns, so the
        // move must happen synchronously here.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperdesk-model-\(UUID().uuidString)")
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
