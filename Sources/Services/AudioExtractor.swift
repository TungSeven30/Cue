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
    static func extract(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractorError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
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
            try Self.writeWAV(from: output, reader: reader, to: tempURL)
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
    private static func writeWAV(from output: AVAssetReaderTrackOutput,
                                 reader: AVAssetReader, to fileURL: URL) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: Self.wavHeader(dataLength: 0))

        var pcmBytes: UInt32 = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer, length > 0 {
                guard UInt64(pcmBytes) + UInt64(length) <= UInt64(UInt32.max) - 36 else {
                    throw AudioExtractorError.readerFailed("audio exceeds the 4 GiB WAV limit")
                }
                try handle.write(contentsOf: Data(bytes: pointer, count: length))
                pcmBytes += UInt32(length)
            }
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
        append(UInt32(16))                     // fmt chunk size
        append(UInt16(1))                      // PCM
        append(UInt16(1))                      // mono
        append(UInt32(16_000))                 // sample rate
        append(UInt32(16_000 * 2))             // byte rate
        append(UInt16(2))                      // block align
        append(UInt16(16))                     // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataLength)
        return data
    }
}
