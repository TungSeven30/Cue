import Foundation

struct TranscriptionResult {
    let backend: String
    let segments: [TranscriptionSegment]
}

enum TranscriptionServiceError: LocalizedError {
    case pythonFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .pythonFailed(let message):
            return message
        case .malformedResponse:
            return "The transcription helper returned malformed JSON."
        }
    }
}

struct TranscriptionService {
    @MainActor
    func transcribe(
        videoURL: URL,
        settings: AppSettingsStore,
        progress: @escaping @MainActor (JobProgress) -> Void
    ) async throws -> TranscriptionResult {
        let snapshot = TranscriptionSettingsSnapshot(
            sourceLanguage: settings.sourceLanguage,
            whisperModel: settings.whisperModel,
            whisperBackendRawValue: settings.whisperBackend.rawValue,
            preprocessAudio: settings.preprocessAudio,
            vadFilter: settings.vadFilter,
            removeEmptySegments: settings.removeEmptySegments,
            removeRepeatedText: settings.removeRepeatedText,
            mergeShortSegments: settings.mergeShortSegments,
            minSegmentDuration: settings.minSegmentDuration,
            maxMergeGap: settings.maxMergeGap,
            beamSize: settings.beamSize,
            bestOf: settings.bestOf,
            temperature: settings.temperature,
            noSpeechThreshold: settings.noSpeechThreshold
        )

        let scriptURL = try BackendScriptWriter.ensureScript()
        let processBox = ProcessBox()

        return try await withTaskCancellationHandler {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.environment = ProcessEnvironment.withToolPaths()
            process.arguments = [
                "python3",
                scriptURL.path,
                videoURL.path,
                "--json",
                "--language",
                snapshot.sourceLanguage,
                "--model",
                snapshot.whisperModel,
                "--backend",
                snapshot.whisperBackendRawValue,
                "--preprocess-audio",
                snapshot.preprocessAudio ? "true" : "false",
                "--vad-filter",
                snapshot.vadFilter ? "true" : "false",
                "--beam-size",
                "\(snapshot.beamSize)",
                "--best-of",
                "\(snapshot.bestOf)",
                "--temperature",
                "\(snapshot.temperature)",
                "--no-speech-threshold",
                "\(snapshot.noSpeechThreshold)",
            ]
            processBox.process = process

            let stdout = PipeCollector()
            let stderr = PipeCollector { line in
                if let event = TranscriptionProgressEvent.decode(line) {
                    Task { @MainActor in
                        progress(event.progress)
                    }
                }
            }

            process.standardOutput = stdout.pipe
            process.standardError = stderr.pipe

            try process.run()
            let terminationStatus = await process.waitForTermination()
            // The process has exited, but the readability handlers run on a
            // background queue and may still have buffered pipe data that has
            // not been appended yet. Wait for both pipes to reach EOF before
            // reading, otherwise a long transcript's JSON can be truncated.
            await stdout.waitForEOF()
            await stderr.waitForEOF()
            stdout.close()
            stderr.close()

            let stdoutData = stdout.data()
            let stderrText = stderr.text().trimmingCharacters(in: .whitespacesAndNewlines)

            if Task.isCancelled {
                throw CancellationError()
            }

            guard terminationStatus == 0 else {
                // stderr carries both JSON progress events and the real error
                // text; drop the progress lines so the message is legible.
                let errorText = stderrText
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                    .filter { !$0.hasPrefix("{") }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw TranscriptionServiceError.pythonFailed(
                    errorText.isEmpty ? "The Python helper exited with status \(terminationStatus)." : errorText
                )
            }

            let payload = try JSONDecoder().decode(TranscriptionPayload.self, from: stdoutData)
            let cleanedSegments = TranscriptionPostProcessor.clean(payload.segments, settings: snapshot)
            return TranscriptionResult(backend: payload.backend, segments: cleanedSegments)
        } onCancel: {
            processBox.terminate()
        }
    }
}

private struct TranscriptionSettingsSnapshot: Sendable {
    let sourceLanguage: String
    let whisperModel: String
    let whisperBackendRawValue: String
    let preprocessAudio: Bool
    let vadFilter: Bool
    let removeEmptySegments: Bool
    let removeRepeatedText: Bool
    let mergeShortSegments: Bool
    let minSegmentDuration: Double
    let maxMergeGap: Double
    let beamSize: Int
    let bestOf: Int
    let temperature: Double
    let noSpeechThreshold: Double
}

private struct TranscriptionPayload: Decodable {
    let backend: String
    let segments: [TranscriptionSegment]
}

private enum TranscriptionPostProcessor {
    static func clean(_ segments: [TranscriptionSegment], settings: TranscriptionSettingsSnapshot) -> [TranscriptionSegment] {
        var cleaned = segments.map { segment in
            TranscriptionSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: normalizeWhitespace(segment.text)
            )
        }

        if settings.removeRepeatedText {
            cleaned = cleaned.map { segment in
                TranscriptionSegment(
                    id: segment.id,
                    start: segment.start,
                    end: segment.end,
                    text: collapseRepeatedText(segment.text)
                )
            }
            cleaned = removeAdjacentDuplicates(cleaned)
            cleaned = removeEchoesAfterSilence(cleaned)
        }

        if settings.removeEmptySegments {
            cleaned = cleaned.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        if settings.mergeShortSegments {
            cleaned = mergeShortSegments(cleaned, minDuration: settings.minSegmentDuration, maxGap: settings.maxMergeGap)
        }

        cleaned = repairInvalidTimings(cleaned)

        return renumber(cleaned)
    }

    /// Transcribers occasionally emit segments with zero or near-zero
    /// duration (word-level alignment of an isolated word). A subtitle that
    /// displays for 0s is useless in a player, so extend it to a readable
    /// minimum without overlapping the next segment.
    private static func repairInvalidTimings(
        _ segments: [TranscriptionSegment],
        minimumDuration: Double = 0.8,
        gapToNext: Double = 0.05
    ) -> [TranscriptionSegment] {
        var result = segments
        for index in result.indices {
            let segment = result[index]
            guard segment.end - segment.start < 0.2 else { continue }
            var end = segment.start + minimumDuration
            if index + 1 < result.count {
                end = min(end, result[index + 1].start - gapToNext)
            }
            guard end > segment.start else { continue }
            result[index] = TranscriptionSegment(
                id: segment.id,
                start: segment.start,
                end: end,
                text: segment.text
            )
        }
        return result
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseRepeatedText(_ text: String) -> String {
        let trimmed = normalizeWhitespace(text)
        guard !trimmed.isEmpty else { return "" }

        let words = trimmed.split(separator: " ").map(String.init)
        if words.count >= 4 {
            for phraseLength in stride(from: min(8, words.count / 2), through: 1, by: -1) {
                var output: [String] = []
                var index = 0
                while index < words.count {
                    let phrase = Array(words[index..<min(index + phraseLength, words.count)])
                    var next = index + phraseLength
                    var repeated = false
                    while next + phraseLength <= words.count && Array(words[next..<next + phraseLength]) == phrase {
                        repeated = true
                        next += phraseLength
                    }
                    output.append(contentsOf: phrase)
                    index = repeated ? next : index + phraseLength
                }
                let candidate = output.joined(separator: " ")
                if candidate.count < trimmed.count {
                    return candidate
                }
            }
        }

        let scalars = Array(trimmed)
        guard scalars.count >= 8 else { return trimmed }
        for length in stride(from: min(20, scalars.count / 2), through: 2, by: -1) {
            let first = String(scalars.prefix(length))
            var cursor = length
            var repeats = 1
            while cursor + length <= scalars.count && String(scalars[cursor..<cursor + length]) == first {
                repeats += 1
                cursor += length
            }
            if repeats >= 2 && cursor == scalars.count {
                return first
            }
        }
        return trimmed
    }

    private static func removeAdjacentDuplicates(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        var result: [TranscriptionSegment] = []
        for segment in segments {
            let normalized = comparableText(segment.text)
            if let last = result.last {
                let previous = comparableText(last.text)
                let closeInTime = segment.start - last.end <= 0.35
                if closeInTime && !normalized.isEmpty && normalized == previous {
                    result[result.count - 1] = TranscriptionSegment(
                        id: last.id,
                        start: last.start,
                        end: max(last.end, segment.end),
                        text: last.text
                    )
                    continue
                }
            }
            result.append(segment)
        }
        return result
    }

    private static func removeEchoesAfterSilence(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        var result: [TranscriptionSegment] = []
        for segment in segments {
            if let last = result.last, isLikelySilenceEcho(segment, after: last) {
                continue
            }
            result.append(segment)
        }
        return result
    }

    private static func isLikelySilenceEcho(_ segment: TranscriptionSegment, after previous: TranscriptionSegment) -> Bool {
        let gap = segment.start - previous.end
        guard gap >= 1.5 else { return false }

        let current = comparableText(segment.text)
        let prior = comparableText(previous.text)
        let minimumLength = gap >= 4 ? 6 : 8
        guard current.count >= minimumLength, prior.count >= minimumLength else {
            return false
        }

        let duration = segment.end - segment.start
        let similarity = textSimilarity(current, prior)
        if current == prior {
            return duration >= 0.8
        }
        return duration >= 1.2 && similarity >= 0.9
    }

    private static func comparableText(_ text: String) -> String {
        text
            .lowercased()
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
    }

    private static func textSimilarity(_ first: String, _ second: String) -> Double {
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        if first == second { return 1 }

        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        let distance = editDistance(firstCharacters, secondCharacters)
        let longest = max(firstCharacters.count, secondCharacters.count)
        return 1 - (Double(distance) / Double(max(longest, 1)))
    }

    private static func editDistance(_ first: [Character], _ second: [Character]) -> Int {
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }

        var previous = Array(0...second.count)
        var current = Array(repeating: 0, count: second.count + 1)

        for firstIndex in 1...first.count {
            current[0] = firstIndex
            for secondIndex in 1...second.count {
                let substitutionCost = first[firstIndex - 1] == second[secondIndex - 1] ? 0 : 1
                current[secondIndex] = min(
                    previous[secondIndex] + 1,
                    current[secondIndex - 1] + 1,
                    previous[secondIndex - 1] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        return previous[second.count]
    }

    private static func mergeShortSegments(_ segments: [TranscriptionSegment], minDuration: Double, maxGap: Double) -> [TranscriptionSegment] {
        var result: [TranscriptionSegment] = []
        for segment in segments {
            let duration = segment.end - segment.start
            if duration < minDuration,
               let last = result.last,
               segment.start - last.end <= maxGap {
                result[result.count - 1] = TranscriptionSegment(
                    id: last.id,
                    start: last.start,
                    end: max(last.end, segment.end),
                    text: normalizeWhitespace("\(last.text) \(segment.text)")
                )
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func renumber(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.enumerated().map { index, segment in
            TranscriptionSegment(id: index + 1, start: segment.start, end: segment.end, text: segment.text)
        }
    }
}

private struct TranscriptionProgressEvent: Decodable {
    let stage: JobStage
    let detail: String
    let fraction: Double?

    var progress: JobProgress {
        JobProgress(stage: stage, detail: detail, fraction: fraction)
    }

    static func decode(_ line: String) -> TranscriptionProgressEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptionProgressEvent.self, from: data)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcess: Process?

    var process: Process? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedProcess
        }
        set {
            lock.lock()
            storedProcess = newValue
            lock.unlock()
        }
    }

    func terminate() {
        lock.lock()
        let process = storedProcess
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        // Python only runs signal handlers between bytecodes, so a helper
        // deep inside native inference code can miss SIGTERM entirely.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private final class PipeCollector: @unchecked Sendable {
    let pipe = Pipe()

    private let lock = NSLock()
    private var storage = Data()
    private var pendingLine = ""
    private let onLine: ((String) -> Void)?
    private var didReachEOF = false
    private var eofContinuation: CheckedContinuation<Void, Never>?

    init(onLine: ((String) -> Void)? = nil) {
        self.onLine = onLine
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                // Empty read signals EOF: the process closed its write end.
                handle.readabilityHandler = nil
                self.signalEOF()
            } else {
                self.append(data)
            }
        }
    }

    /// Suspends until the pipe has been fully drained to EOF. Resolves
    /// immediately if EOF was already observed.
    func waitForEOF() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didReachEOF {
                lock.unlock()
                continuation.resume()
                return
            }
            eofContinuation = continuation
            lock.unlock()
        }
    }

    private func signalEOF() {
        lock.lock()
        didReachEOF = true
        let continuation = eofContinuation
        eofContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func text() -> String {
        String(data: data(), encoding: .utf8) ?? ""
    }

    func close() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    private func append(_ data: Data) {
        let newText = String(data: data, encoding: .utf8) ?? ""
        var completeLines: [String] = []

        lock.lock()
        storage.append(data)
        pendingLine += newText
        while let newlineIndex = pendingLine.firstIndex(of: "\n") {
            let line = String(pendingLine[..<newlineIndex])
            completeLines.append(line)
            pendingLine.removeSubrange(...newlineIndex)
        }
        lock.unlock()

        completeLines.forEach { onLine?($0) }
    }
}

private extension Process {
    func waitForTermination() async -> Int32 {
        await withCheckedContinuation { continuation in
            let resumer = ProcessTerminationResumer(continuation: continuation)
            terminationHandler = { process in
                resumer.resume(process.terminationStatus)
            }
            if !isRunning {
                resumer.resume(terminationStatus)
            }
        }
    }
}

private final class ProcessTerminationResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Int32, Never>

    init(continuation: CheckedContinuation<Int32, Never>) {
        self.continuation = continuation
    }

    func resume(_ status: Int32) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume(returning: status)
    }
}
