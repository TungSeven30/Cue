import Foundation
import Testing
@testable import WhisperDesk

@MainActor
@Suite struct JobTimingTests {
    /// Helper to build a job via JSON decoding so we don't need AppSettingsStore.
    private func makeJob(status: JobStatus = .idle) throws -> TranscriptionJob {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "sourcePath": "/tmp/example.mp4",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z",
          "status": "\(status.rawValue)",
          "progress": {"stage": "transcribing", "detail": "x"},
          "settings": {
            "sourceLanguage": "auto",
            "whisperModel": "m",
            "whisperBackend": "auto",
            "openAIModel": "gpt-5.2"
          },
          "transcriptSegments": [],
          "translatedSegments": [],
          "log": "log\\n"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: Data(json.utf8))
    }

    @Test func formatsSecondsMinutesHours() {
        #expect(JobTimingFormatter.format(45) == "45s")
        #expect(JobTimingFormatter.format(432) == "7m 12s")
        #expect(JobTimingFormatter.format(3840) == "1h 04m")
    }

    @Test func rejectsNonsenseDurations() {
        #expect(JobTimingFormatter.format(-5) == "")
        #expect(JobTimingFormatter.format(TimeInterval.infinity) == "")
    }

    @Test func decodesLegacyJobWithoutStreamingFields() throws {
        // A job encoded before this change must load with defaults.
        var job = try makeJob()
        job.partialTranscriptSegments = [TranscriptionSegment(id: 1, start: 0, end: 1, text: "x")]
        job.transcriptionStartedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(job)

        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "partialTranscriptSegments")
        json.removeValue(forKey: "transcriptionStartedAt")
        json.removeValue(forKey: "transcriptionFinishedAt")
        json.removeValue(forKey: "translationStartedAt")
        json.removeValue(forKey: "finishedAt")

        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TranscriptionJob.self, from: stripped)

        #expect(decoded.partialTranscriptSegments.isEmpty)
        #expect(decoded.transcriptionStartedAt == nil)
        #expect(decoded.finishedAt == nil)
    }
}
