import Foundation

/// The artifact every CLI stage reads and writes. One JSON file carries the
/// media path, the settings a run actually used, the segments produced so
/// far, and where the files landed — so `cue transcribe` followed by
/// `cue translate <manifest>` needs nothing else passed between them.
///
/// Every field is optional-tolerant on decode: a manifest written by an
/// older Cue must keep chaining rather than fail the stage that reads it.
struct CLIManifest: Codable, Equatable {
    /// Bumped only for a change that an older reader would misinterpret.
    /// Additive fields do not bump it.
    static let currentVersion = 1

    struct Source: Codable, Equatable {
        var path: String
        /// The page the media was fetched from, when it was not a local file.
        var pageURL: String?
    }

    struct Settings: Codable, Equatable {
        var sourceLanguage: String
        var backend: String
        var model: String
        var qualityPreset: String
        var translationTargetLanguage: String?
        var translationModel: String?
        var summaryModel: String?
    }

    struct Output: Codable, Equatable {
        /// "original", "translated", "bilingual", "log", "video".
        var role: String
        var format: String
        var path: String
    }

    var version: Int
    var stage: String
    var source: Source
    var settings: Settings
    var transcript: [TranscriptionSegment]
    var translation: [TranscriptionSegment]
    var summary: String?
    var outputs: [Output]
    var log: [String]

    init(
        stage: String,
        source: Source,
        settings: Settings,
        transcript: [TranscriptionSegment] = [],
        translation: [TranscriptionSegment] = [],
        summary: String? = nil,
        outputs: [Output] = [],
        log: [String] = []
    ) {
        self.version = Self.currentVersion
        self.stage = stage
        self.source = source
        self.settings = settings
        self.transcript = transcript
        self.translation = translation
        self.summary = summary
        self.outputs = outputs
        self.log = log
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? "unknown"
        source = try container.decode(Source.self, forKey: .source)
        settings = try container.decode(Settings.self, forKey: .settings)
        transcript = try container.decodeIfPresent([TranscriptionSegment].self, forKey: .transcript) ?? []
        translation = try container.decodeIfPresent([TranscriptionSegment].self, forKey: .translation) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        outputs = try container.decodeIfPresent([Output].self, forKey: .outputs) ?? []
        log = try container.decodeIfPresent([String].self, forKey: .log) ?? []
    }

    var sourceURL: URL { URL(filePath: source.path, directoryHint: .notDirectory) }

    /// `<video>.cue.json` next to whatever directory the stage writes into.
    static func manifestURL(inDirectory directory: URL, baseName: String) -> URL {
        directory.appendingPathComponent("\(ExportCoordinator.sanitizedBaseName(baseName)).cue.json")
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func read(contentsOf url: URL) throws -> CLIManifest {
        try JSONDecoder().decode(CLIManifest.self, from: Data(contentsOf: url))
    }

    func jsonString() throws -> String {
        String(decoding: try Self.encoder().encode(self), as: UTF8.self)
    }

    func write(to url: URL) throws {
        try Self.encoder().encode(self).write(to: url, options: .atomic)
    }

    mutating func note(_ entry: String) {
        log.append(entry)
    }

    mutating func record(outputs newOutputs: [Output]) {
        // A re-run of the same stage replaces its own outputs instead of
        // appending duplicates, so a manifest reused across retries stays
        // an accurate list of files that exist.
        for output in newOutputs {
            outputs.removeAll { $0.path == output.path }
            outputs.append(output)
        }
    }

    /// Whether a path looks like a manifest rather than media. Stages accept
    /// either, and this is the only thing that distinguishes them.
    static func looksLikeManifest(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".cue.json") || path.lowercased().hasSuffix(".json")
    }
}
