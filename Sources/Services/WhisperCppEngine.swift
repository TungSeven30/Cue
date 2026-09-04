import Accelerate
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
        let timeOffset: Double
        let startingID: Int

        init(
            onProgress: @escaping @Sendable (Double) -> Void,
            onSegments: @escaping @Sendable ([TranscriptionSegment]) -> Void,
            isCancelled: @escaping @Sendable () -> Bool,
            timeOffset: Double,
            startingID: Int
        ) {
            self.onProgress = onProgress
            self.onSegments = onSegments
            self.isCancelled = isCancelled
            self.timeOffset = timeOffset
            self.startingID = startingID
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
    /// - Parameter resumeThrough: Skip speech chunks ending at or before this
    ///   second boundary. Mid-chunk crashes re-run the interrupted chunk.
    /// - Parameter onChunkComplete: Fires on the caller's executor after each
    ///   chunk finishes, carrying that chunk's end time in seconds.
    func transcribe(
        wavURL: URL,
        modelURL: URL,
        language: String,
        beamSize: Int,
        noSpeechThreshold: Double,
        resumeThrough: Double = 0,
        startingSegmentID: Int = 1,
        onProgress: @escaping @Sendable (Double) -> Void,
        onSegments: @escaping @Sendable ([TranscriptionSegment]) -> Void = { _ in },
        onChunkComplete: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Result {
        let samples = try Self.loadPCM16AsFloat(wavURL)
        let sampleRate = 16_000
        let totalSeconds = Double(samples.count) / Double(sampleRate)
        let planned = TranscriptionChunkPlanner.planSpeechChunks(samples: samples, sampleRate: sampleRate)
        let pending = TranscriptionChunkPlanner.pendingChunks(planned, resumeThrough: resumeThrough)
        guard !pending.isEmpty else {
            return Result(segments: [])
        }

        _ = Self.metalShaderPathConfigured
        let contextParams = whisper_context_default_params()
        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            throw WhisperCppError.modelLoadFailed(modelURL.lastPathComponent)
        }
        defer { whisper_free(context) }

        if pending.count == 1, pending[0].start <= 0.01, pending[0].end >= totalSeconds - 0.01, resumeThrough <= 0 {
            let segments = try Self.runInference(
                context: context,
                samples: samples,
                sampleRate: sampleRate,
                language: language,
                beamSize: beamSize,
                noSpeechThreshold: noSpeechThreshold,
                timeOffset: 0,
                startingID: 1,
                onProgress: onProgress,
                onSegments: onSegments,
                isCancelled: isCancelled
            )
            onChunkComplete(totalSeconds)
            return Result(segments: segments)
        }

        var collected: [TranscriptionSegment] = []
        var nextID = startingSegmentID
        let completedBefore = planned.filter { $0.end <= resumeThrough + 0.01 }.count
        for (index, chunk) in pending.enumerated() {
            if isCancelled() { throw CancellationError() }
            let firstSample = max(0, Int(chunk.start * Double(sampleRate)))
            let lastSample = min(samples.count, Int(chunk.end * Double(sampleRate)))
            guard lastSample > firstSample else { continue }
            let slice = Array(samples[firstSample..<lastSample])
            let chunkProgress: @Sendable (Double) -> Void = { fraction in
                let overall = Double(completedBefore + index) + fraction
                onProgress(min(1, overall / Double(max(1, planned.count))))
            }
            let batch = try Self.runInference(
                context: context,
                samples: slice,
                sampleRate: sampleRate,
                language: language,
                beamSize: beamSize,
                noSpeechThreshold: noSpeechThreshold,
                timeOffset: chunk.start,
                startingID: nextID,
                onProgress: chunkProgress,
                onSegments: { segments in
                    onSegments(segments)
                },
                isCancelled: isCancelled
            )
            collected.append(contentsOf: batch)
            nextID += batch.count
            onChunkComplete(chunk.end)
        }
        return Result(segments: collected)
    }

    private static func runInference(
        context: OpaquePointer,
        samples: [Float],
        sampleRate: Int,
        language: String,
        beamSize: Int,
        noSpeechThreshold: Double,
        timeOffset: Double,
        startingID: Int,
        onProgress: @escaping @Sendable (Double) -> Void,
        onSegments: @escaping @Sendable ([TranscriptionSegment]) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> [TranscriptionSegment] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = Int32(beamSize)
        params.no_speech_thold = Float(noSpeechThreshold)
        // Reserve a couple of cores for UI/system; a floor of four matches
        // whisper.cpp's default.
        params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.no_context = true  // match condition_on_previous_text=False

        let box = CallbackBox(
            onProgress: onProgress,
            onSegments: onSegments,
            isCancelled: isCancelled,
            timeOffset: timeOffset,
            startingID: startingID
        )
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
                let mapped = WhisperCppEngine.mapSegment(
                    index: box.startingID - 1 + index,
                    t0: whisper_full_get_segment_t0(ctx, Int32(index)),
                    t1: whisper_full_get_segment_t1(ctx, Int32(index)),
                    text: String(cString: whisper_full_get_segment_text(ctx, Int32(index)))
                )
                batch.append(
                    TranscriptionSegment(
                        id: mapped.id,
                        start: mapped.start + box.timeOffset,
                        end: mapped.end + box.timeOffset,
                        text: mapped.text
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
        return (0..<count).map { i in
            let mapped = Self.mapSegment(
                index: startingID - 1 + i,
                t0: whisper_full_get_segment_t0(context, Int32(i)),
                t1: whisper_full_get_segment_t1(context, Int32(i)),
                text: String(cString: whisper_full_get_segment_text(context, Int32(i)))
            )
            return TranscriptionSegment(
                id: mapped.id,
                start: mapped.start + timeOffset,
                end: mapped.end + timeOffset,
                text: mapped.text
            )
        }
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
                    Self.pcm16ToFloat(raw, byteOffset: body, sampleCount: sampleCount)
                }
            }
            // RIFF chunks are word-aligned: odd sizes carry a pad byte.
            offset = body + chunkSize + (chunkSize & 1)
        }
        throw WhisperCppError.invalidWAV("no data chunk")
    }

    /// Little-endian 16-bit PCM to normalized Float32 via vDSP. Dividing by
    /// 32768 and multiplying by 1/32768 are the same IEEE operation because
    /// the scale is a power of two, so the result is bit-identical to the
    /// per-sample `Float(sample) / 32_768` it replaces (asserted by
    /// ChunkPlannerVectorTests). RIFF chunks are word-aligned, so the data
    /// chunk is 2-byte aligned in practice; an unaligned offset takes one
    /// memcpy into an aligned scratch buffer instead.
    static func pcm16ToFloat(_ raw: UnsafeRawBufferPointer, byteOffset: Int, sampleCount: Int) -> [Float] {
        var floats = [Float](repeating: 0, count: sampleCount)
        guard sampleCount > 0, let base = raw.baseAddress else { return floats }
        let source = base + byteOffset
        var scale: Float = 1.0 / 32_768
        floats.withUnsafeMutableBufferPointer { out in
            guard let output = out.baseAddress else { return }
            if Int(bitPattern: source) % MemoryLayout<Int16>.alignment == 0 {
                let words = source.assumingMemoryBound(to: Int16.self)
                vDSP_vflt16(words, 1, output, 1, vDSP_Length(sampleCount))
            } else {
                let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: sampleCount)
                defer { scratch.deallocate() }
                memcpy(scratch, source, sampleCount * MemoryLayout<Int16>.size)
                vDSP_vflt16(scratch, 1, output, 1, vDSP_Length(sampleCount))
            }
            vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(sampleCount))
        }
        return floats
    }
}
