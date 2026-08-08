import Foundation
import whisper

enum WhisperCppError: LocalizedError {
    case modelLoadFailed(String)
    case inferenceFailed(Int)
    case invalidWAV(String)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let name):
            return "Could not load the model \(name). Try re-downloading the model."
        case .inferenceFailed(let status):
            return "Transcription failed unexpectedly (status \(status))."
        case .invalidWAV(let reason):
            return "Invalid WAV file: \(reason)."
        }
    }
}

// The actor serializes inference: one transcription at a time. transcribe
// knowingly parks its executor thread for the whole whisper_full call — it is
// the only heavy work in flight, so a dedicated blocking thread is fine.
actor WhisperCppEngine {
    struct Result {
        let segments: [TranscriptionSegment]
    }

    // C function pointers cannot capture Swift context; the closures travel
    // through the callbacks' user_data as an unretained box.
    private final class CallbackBox {
        let onProgress: @Sendable (Double) -> Void
        let onSegments: @Sendable ([TranscriptionSegment]) -> Void
        let isCancelled: @Sendable () -> Bool

        init(
            onProgress: @escaping @Sendable (Double) -> Void,
            onSegments: @escaping @Sendable ([TranscriptionSegment]) -> Void,
            isCancelled: @escaping @Sendable () -> Bool
        ) {
            self.onProgress = onProgress
            self.onSegments = onSegments
            self.isCancelled = isCancelled
        }
    }

    /// whisper.cpp compiles its Metal shaders at runtime from ggml-metal.metal.
    /// SwiftPM ships that file in whisper_whisper.bundle, but the generated
    /// bundle accessor only looks at the .app root, where codesign forbids
    /// unsealed content — so the build script ships a self-contained copy
    /// (ggml-common.h inlined) in Contents/Resources and this points ggml at
    /// it. The test runner points at a self-contained development copy too;
    /// bare binaries without either resource fall back to whisper.cpp's normal
    /// backend discovery.
    private static let metalShaderPathConfigured: Void = {
        guard getenv("GGML_METAL_PATH_RESOURCES") == nil else { return }  // a user override wins
        guard let resources = Bundle.main.resourceURL,
            FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("ggml-metal.metal").path)
        else { return }
        setenv("GGML_METAL_PATH_RESOURCES", resources.path, 0)
    }()

    /// whisper.cpp reports segment timestamps in centiseconds.
    static func mapSegment(index: Int, t0: Int64, t1: Int64, text: String) -> TranscriptionSegment {
        TranscriptionSegment(
            id: index + 1,
            start: Double(t0) / 100.0,
            end: Double(t1) / 100.0,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// - Parameter isCancelled: Fires on whisper's worker threads, so it must
    ///   read thread-independent state (a flag set via
    ///   withTaskCancellationHandler, or an atomic) — NOT `Task.isCancelled`,
    ///   which has no current task in that context and would silently never
    ///   cancel.
    func transcribe(
        wavURL: URL,
        modelURL: URL,
        language: String,
        beamSize: Int,
        noSpeechThreshold: Double,
        onProgress: @escaping @Sendable (Double) -> Void,
        onSegments: @escaping @Sendable ([TranscriptionSegment]) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Result {
        let samples = try Self.loadPCM16AsFloat(wavURL)

        _ = Self.metalShaderPathConfigured
        let contextParams = whisper_context_default_params()  // Metal on by default
        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            throw WhisperCppError.modelLoadFailed(modelURL.lastPathComponent)
        }
        defer { whisper_free(context) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = Int32(beamSize)
        params.no_speech_thold = Float(noSpeechThreshold)
        // Reserve a couple of cores for UI/system; a floor of four matches
        // whisper.cpp's default.
        params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.no_context = true  // match condition_on_previous_text=False

        let box = CallbackBox(onProgress: onProgress, onSegments: onSegments, isCancelled: isCancelled)
        let userData = Unmanaged.passUnretained(box).toOpaque()
        params.progress_callback = { _, _, progress, userData in
            guard let userData else { return }
            Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                .onProgress(Double(progress) / 100.0)
        }
        params.progress_callback_user_data = userData
        params.new_segment_callback = { ctx, _, nNew, userData in
            guard let ctx, let userData, nNew > 0 else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
            let total = Int(whisper_full_n_segments(ctx))
            let first = max(0, total - Int(nNew))
            var batch: [TranscriptionSegment] = []
            for index in first..<total {
                batch.append(
                    WhisperCppEngine.mapSegment(
                        index: index,
                        t0: whisper_full_get_segment_t0(ctx, Int32(index)),
                        t1: whisper_full_get_segment_t1(ctx, Int32(index)),
                        text: String(cString: whisper_full_get_segment_text(ctx, Int32(index)))
                    ))
            }
            if !batch.isEmpty { box.onSegments(batch) }
        }
        params.new_segment_callback_user_data = userData
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue().isCancelled()
        }
        params.abort_callback_user_data = userData

        let status: Int32 = withExtendedLifetime(box) {
            // whisper.h: language nullptr, "" or "auto" means autodetect.
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "auto" {
                params.language = nil
                return whisper_full(context, params, samples, Int32(samples.count))
            }
            // withCString keeps the pointer valid across the whisper_full call.
            return trimmed.withCString { cLanguage in
                params.language = cLanguage
                return whisper_full(context, params, samples, Int32(samples.count))
            }
        }
        guard status == 0 else {
            if isCancelled() { throw CancellationError() }
            throw WhisperCppError.inferenceFailed(Int(status))
        }

        let count = Int(whisper_full_n_segments(context))
        let segments = (0..<count).map { i in
            Self.mapSegment(
                index: i,
                t0: whisper_full_get_segment_t0(context, Int32(i)),
                t1: whisper_full_get_segment_t1(context, Int32(i)),
                text: String(cString: whisper_full_get_segment_text(context, Int32(i)))
            )
        }
        return Result(segments: segments)
    }

    /// Reads a 16-bit mono PCM WAV into normalized Float32 samples, walking
    /// the RIFF chunks rather than assuming the canonical 44-byte layout.
    static func loadPCM16AsFloat(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func readU16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func readU32(_ offset: Int) -> UInt32 {
            UInt32(readU16(offset)) | UInt32(readU16(offset + 2)) << 16
        }

        guard data.count >= 12,
            data[0..<4].elementsEqual("RIFF".utf8),
            data[8..<12].elementsEqual("WAVE".utf8)
        else {
            throw WhisperCppError.invalidWAV("not a RIFF/WAVE file")
        }

        var offset = 12
        var sawValidFormat = false
        while offset + 8 <= data.count {
            let chunkID = data[offset..<offset + 4]
            let chunkSize = Int(readU32(offset + 4))
            let body = offset + 8
            guard body + chunkSize <= data.count else {
                throw WhisperCppError.invalidWAV("truncated chunk")
            }
            if chunkID.elementsEqual("fmt ".utf8) {
                guard chunkSize >= 16 else {
                    throw WhisperCppError.invalidWAV("fmt chunk too small")
                }
                let format = readU16(body)
                let channels = readU16(body + 2)
                let bitsPerSample = readU16(body + 14)
                guard format == 1, channels == 1, bitsPerSample == 16 else {
                    throw WhisperCppError.invalidWAV("expected 16-bit mono PCM")
                }
                sawValidFormat = true
            } else if chunkID.elementsEqual("data".utf8) {
                guard sawValidFormat else {
                    throw WhisperCppError.invalidWAV("data chunk before fmt chunk")
                }
                let sampleCount = chunkSize / 2
                return data.withUnsafeBytes { raw in
                    (0..<sampleCount).map { i in
                        let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: body + i * 2, as: Int16.self))
                        return Float(sample) / 32_768
                    }
                }
            }
            // RIFF chunks are word-aligned: odd sizes carry a pad byte.
            offset = body + chunkSize + (chunkSize & 1)
        }
        throw WhisperCppError.invalidWAV("no data chunk")
    }
}
