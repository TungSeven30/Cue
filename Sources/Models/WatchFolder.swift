import Foundation

/// One watched folder with its own ingest settings. Files it picks up are
/// stamped with `profile`, so different folders can transcribe/translate
/// differently (e.g. a Japanese-drama inbox and an English-podcast inbox).
struct WatchFolder: Codable, Identifiable, Hashable {
    var id: UUID
    var path: String
    var enabled: Bool
    var profile: JobSettingsOverrides

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    init(path: String) {
        self.id = UUID()
        self.path = path
        self.enabled = true
        self.profile = JobSettingsOverrides()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decode(String.self, forKey: .path)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        profile = try container.decodeIfPresent(JobSettingsOverrides.self, forKey: .profile) ?? JobSettingsOverrides()
    }
}
