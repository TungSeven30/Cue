import Foundation
@testable import Cue

/// Builds jobs by decoding JSON, so folder tests need no `AppSettingsStore`
/// (which reads UserDefaults and the real Keychain).
enum FolderTestJobs {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func make(
        id: UUID = UUID(),
        sourcePath: String,
        origin: JobOrigin = .manual,
        createdAt: Date = epoch,
        updatedAt: Date? = nil,
        folderID: UUID? = nil,
        status: String = "idle",
        log: String = "",
        archivedAt: Date? = nil
    ) throws -> TranscriptionJob {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "id": id.uuidString,
            "sourcePath": sourcePath,
            "createdAt": formatter.string(from: createdAt),
            "updatedAt": formatter.string(from: updatedAt ?? createdAt),
            "status": status,
            "progress": ["stage": "idle", "detail": "x"],
            "settings": [
                "sourceLanguage": "auto", "whisperModel": "m",
                "whisperBackend": "auto", "openAIModel": "gpt-5.2",
            ],
            "transcriptSegments": [] as [Any],
            "translatedSegments": [] as [Any],
            "log": log,
            "origin": origin.rawValue,
        ]
        if let folderID { object["folderID"] = folderID.uuidString }
        if let archivedAt { object["archivedAt"] = formatter.string(from: archivedAt) }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: data)
    }
}

/// Hands out predictable folder ids so assertions can name them.
final class FolderIDSequence {
    private var next: UInt8 = 1

    func make() -> UUID {
        defer { next += 1 }
        return UUID(uuid: (next, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
