import Foundation

/// How a job entered the app. Watch-folder jobs get implicit sidecar export
/// and write the watch ledger on terminal states; manual jobs do neither.
/// `url` jobs are manual adds whose media was fetched with yt-dlp first —
/// they behave exactly like `manual` and exist only so the sidebar and the
/// job log can say where the file came from.
enum JobOrigin: String, Codable, Hashable {
    case manual
    case watchFolder
    case url
}

/// Per-job settings overrides. `nil` means "inherit the global setting at the
/// time the job runs". This is the *input* side; the job's `settings`
/// snapshot remains the record of what a run actually used.
struct JobSettingsOverrides: Codable, Hashable {
    var sourceLanguage: String?
    var qwenContext: String?
    var transcriptionPreset: TranscriptionPreset?
    var transcriptionQualityPreset: TranscriptionQualityPreset?
    var whisperBackend: WhisperBackend?
    var whisperModel: String?
    var translationSourceLanguage: String?
    var translationTargetLanguage: String?
    var openAIModel: String?
    var autoTranslate: Bool?
    var generateSummary: Bool?
    var summaryDetail: SummaryDetail?

    var isEmpty: Bool {
        sourceLanguage == nil
            && qwenContext == nil
            && transcriptionPreset == nil
            && transcriptionQualityPreset == nil
            && whisperBackend == nil
            && whisperModel == nil
            && translationSourceLanguage == nil
            && translationTargetLanguage == nil
            && openAIModel == nil
            && autoTranslate == nil
            && generateSummary == nil
            && summaryDetail == nil
    }

    init() {}

    // Unknown enum raw values (a preset removed in a later build) must fall
    // back to inherit instead of failing the containing job file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        qwenContext = try container.decodeIfPresent(String.self, forKey: .qwenContext)
        transcriptionPreset = (try? container.decodeIfPresent(TranscriptionPreset.self, forKey: .transcriptionPreset)) ?? nil
        transcriptionQualityPreset = (try? container.decodeIfPresent(TranscriptionQualityPreset.self, forKey: .transcriptionQualityPreset)) ?? nil
        whisperBackend = (try? container.decodeIfPresent(WhisperBackend.self, forKey: .whisperBackend)) ?? nil
        whisperModel = try container.decodeIfPresent(String.self, forKey: .whisperModel)
        translationSourceLanguage = try container.decodeIfPresent(String.self, forKey: .translationSourceLanguage)
        translationTargetLanguage = try container.decodeIfPresent(String.self, forKey: .translationTargetLanguage)
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel)
        autoTranslate = try container.decodeIfPresent(Bool.self, forKey: .autoTranslate)
        generateSummary = try container.decodeIfPresent(Bool.self, forKey: .generateSummary)
        summaryDetail = (try? container.decodeIfPresent(SummaryDetail.self, forKey: .summaryDetail)) ?? nil
    }
}
