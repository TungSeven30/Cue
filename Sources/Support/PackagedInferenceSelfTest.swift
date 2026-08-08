import Darwin
import Foundation

/// Command-line entry point used by the release smoke test. It deliberately
/// lives in the shipped executable so the test exercises Bundle.main,
/// Contents/Resources, dynamic-framework loading, and whisper.cpp exactly as
/// an installed app does. Normal launches never enter this path.
enum PackagedInferenceSelfTest {
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<Int, Error>?

        func store(_ value: Result<Int, Error>) {
            lock.withLock { outcome = value }
        }

        func load() -> Result<Int, Error>? {
            lock.withLock { outcome }
        }
    }

    static func runAndExitIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--self-test-packaged-inference") else { return }
        guard arguments.indices.contains(flagIndex + 1) else {
            writeError("usage: Cue --self-test-packaged-inference <model.bin>")
            exit(2)
        }

        let modelURL = URL(fileURLWithPath: arguments[flagIndex + 1])
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            writeError("self-test model is missing at \(modelURL.path)")
            exit(2)
        }

        let outcome = OutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cue-packaged-smoke-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let wavURL = directory.appendingPathComponent("silence.wav")
                try writeSilentWAV(to: wavURL)
                let result = try await WhisperCppEngine().transcribe(
                    wavURL: wavURL,
                    modelURL: modelURL,
                    language: "en",
                    beamSize: 1,
                    noSpeechThreshold: 0.6,
                    onProgress: { _ in },
                    isCancelled: { false }
                )
                outcome.store(.success(result.segments.count))
            } catch {
                outcome.store(.failure(error))
            }
            finished.signal()
        }
        finished.wait()

        switch outcome.load() {
        case .success(let segmentCount):
            print("CUE_PACKAGED_INFERENCE_OK segments=\(segmentCount)")
            fflush(stdout)
            exit(0)
        case .failure(let error):
            writeError("packaged inference failed: \(error.localizedDescription)")
            exit(1)
        case nil:
            writeError("packaged inference ended without a result")
            exit(1)
        }
    }

    private static func writeSilentWAV(to url: URL) throws {
        let sampleRate: UInt32 = 16_000
        let sampleCount = Int(sampleRate * 2)
        let dataByteCount = UInt32(sampleCount * MemoryLayout<Int16>.size)
        var data = Data()

        func appendASCII(_ value: String) {
            data.append(contentsOf: value.utf8)
        }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLE(UInt32(36) + dataByteCount)
        appendASCII("WAVEfmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(sampleRate)
        appendLE(sampleRate * UInt32(MemoryLayout<Int16>.size))
        appendLE(UInt16(MemoryLayout<Int16>.size))
        appendLE(UInt16(16))
        appendASCII("data")
        appendLE(dataByteCount)
        data.append(Data(repeating: 0, count: Int(dataByteCount)))
        try data.write(to: url, options: .atomic)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}
