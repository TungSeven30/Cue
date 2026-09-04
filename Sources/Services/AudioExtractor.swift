import AVFoundation
import Foundation

enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The file has no audio track."
        case .readerFailed(let message):
            return "Audio extraction failed: \(message)"
        }
    }
}

/// Decodes any AVFoundation-readable container to the 16 kHz mono 16-bit
/// PCM WAV the transcription engines expect. Replaces the ffmpeg step.
enum AudioExtractor {
    /// `onProgress` receives coarse fractions (0–1) derived from sample-buffer
    /// timestamps vs the asset duration, throttled to 5% steps; it fires
    /// synchronously on the decoding task's thread.
    static func extract(
        from sourceURL: URL,
        to destinationURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractorError.noAudioTrack
        }
        let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        guard reader.startReading() else {
            throw AudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "could not start reading")
        }

        // Stream into a same-volume temp file and move it into place only
        // after the header patch succeeds, so an interrupted extraction never
        // leaves a partial WAV at the destination (downstream cache logic
        // treats file-existence as validity).
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(destinationURL.lastPathComponent + ".partial-\(UUID().uuidString)")
        do {
            try Self.writeWAV(
                from: output,
                reader: reader,
                to: tempURL,
                durationSeconds: durationSeconds,
                onProgress: onProgress
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Streams decoded PCM into `fileURL` behind a placeholder header, then
    /// patches the header with the final sizes — avoids buffering hours of audio.
    private static func writeWAV(
        from output: AVAssetReaderTrackOutput,
        reader: AVAssetReader, to fileURL: URL,
        durationSeconds: Double = 0,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: Self.wavHeader(dataLength: 0))

        var pcmBytes: UInt32 = 0
        var lastReportedFraction = 0.0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if let onProgress, durationSeconds > 0 {
                let seconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                if seconds.isFinite {
                    let fraction = max(0, min(1, seconds / durationSeconds))
                    if fraction - lastReportedFraction >= 0.05 {
                        lastReportedFraction = fraction
                        onProgress(fraction)
                    }
                }
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            guard UInt64(pcmBytes) + UInt64(length) <= UInt64(UInt32.max) - 36 else {
                throw AudioExtractorError.readerFailed("audio exceeds the 4 GiB WAV limit")
            }
            // CMBlockBufferCopyDataBytes gathers non-contiguous block buffers;
            // reading a single data pointer for the total length would write
            // garbage past the first contiguous range. For contiguous buffers
            // (the default when the reader copies sample data) the bytes are
            // identical.
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
            }
            guard status == kCMBlockBufferNoErr else {
                throw AudioExtractorError.readerFailed("could not copy decoded samples (\(status))")
            }
            try handle.write(contentsOf: bytes)
            pcmBytes += UInt32(length)
        }
        if reader.status == .failed {
            throw AudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "unknown decode error")
        }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.wavHeader(dataLength: pcmBytes))
    }

    /// Canonical 44-byte PCM WAV header: 16 kHz, mono, 16-bit little-endian.
    static func wavHeader(dataLength: UInt32) -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataLength))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))  // fmt chunk size
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(16_000))  // sample rate
        append(UInt32(16_000 * 2))  // byte rate
        append(UInt16(2))  // block align
        append(UInt16(16))  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataLength)
        return data
    }
}
