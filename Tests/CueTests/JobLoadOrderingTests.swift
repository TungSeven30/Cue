import Foundation
import Testing
@testable import Cue

@Suite struct JobLoadOrderingTests {
    private func makeJob(orderIndex: Double, updatedAt: Date, id: UUID = UUID()) throws -> TranscriptionJob {
        let formatter = ISO8601DateFormatter()
        let json = """
            {
              "id": "\(id.uuidString)",
              "sourcePath": "/tmp/example.mp4",
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "\(formatter.string(from: updatedAt))",
              "status": "idle",
              "progress": {"stage": "idle", "detail": "x"},
              "settings": {"sourceLanguage": "auto", "whisperModel": "m", "whisperBackend": "auto", "openAIModel": "gpt-5.2"},
              "transcriptSegments": [],
              "translatedSegments": [],
              "orderIndex": \(orderIndex),
              "log": ""
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: Data(json.utf8))
    }

    @Test func equalOrderIndexFallsBackToNewestThenID() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let newest = try makeJob(orderIndex: 5, updatedAt: base.addingTimeInterval(20))
        let middleA = try makeJob(orderIndex: 5, updatedAt: base.addingTimeInterval(10), id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let middleB = try makeJob(orderIndex: 5, updatedAt: base.addingTimeInterval(10), id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        let oldest = try makeJob(orderIndex: 5, updatedAt: base)
        let first = try makeJob(orderIndex: -1, updatedAt: base)
        let expected = [first, newest, middleA, middleB, oldest].map(\.id)

        var jobs = [oldest, middleB, newest, first, middleA]
        for _ in 0..<25 {
            jobs.shuffle()
            #expect(JobLoadOrdering.stableSortedByOrderIndex(jobs).map(\.id) == expected)
        }
    }

    @Test func storeOrderIsNewestFirstThenID() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try makeJob(orderIndex: 0, updatedAt: base, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let b = try makeJob(orderIndex: 0, updatedAt: base, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        let newer = try makeJob(orderIndex: 0, updatedAt: base.addingTimeInterval(1))
        #expect([b, newer, a].sorted(by: JobLoadOrdering.storeOrder).map(\.id) == [newer.id, a.id, b.id])
    }
}
