import SwiftUI

/// Sheet that lets the user pick exactly which documents and formats to
/// export, and edit the base file name, instead of always writing every
/// artifact with fixed names.
struct ExportOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var baseName = ""
    @AppStorage("exportIncludeOriginal") private var includeOriginal = true
    @AppStorage("exportIncludeTranslation") private var includeTranslation = true
    @AppStorage("exportIncludeBilingual") private var includeBilingual = false
    @AppStorage("exportIncludeLog") private var includeLog = false
    @AppStorage("exportFormatSRT") private var formatSRT = true
    @AppStorage("exportFormatTXT") private var formatTXT = false
    @AppStorage("exportFormatMD") private var formatMD = false
    @AppStorage("exportFormatJSON") private var formatJSON = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField("File name", text: $baseName, prompt: Text("File name"))
                } footer: {
                    Text(nameHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Documents") {
                    Toggle("Original transcript", isOn: $includeOriginal)
                        .disabled(!hasTranscript)
                    Toggle("\(model.translationTargetLabel) translation", isOn: $includeTranslation)
                        .disabled(!hasTranslation)
                    Toggle("Bilingual captions", isOn: $includeBilingual)
                        .disabled(!hasTranslation)
                    Toggle("Run log", isOn: $includeLog)
                }

                Section("Formats") {
                    Toggle("SRT (subtitles)", isOn: $formatSRT)
                    Toggle("Plain text", isOn: $formatTXT)
                    Toggle("Markdown", isOn: $formatMD)
                    Toggle("JSON", isOn: $formatJSON)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let options = exportOptions
                    dismiss()
                    // Let the sheet close before the folder panel goes modal.
                    DispatchQueue.main.async {
                        model.performExport(options)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(fileCount == 0)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            baseName = model.defaultExportBaseName
        }
    }

    private var hasTranscript: Bool { !model.transcriptSegments.isEmpty }
    private var hasTranslation: Bool { !model.translatedSegments.isEmpty }

    private var selectedFormats: [SubtitleExportFormat] {
        var formats: [SubtitleExportFormat] = []
        if formatSRT { formats.append(.srt) }
        if formatTXT { formats.append(.text) }
        if formatMD { formats.append(.markdown) }
        if formatJSON { formats.append(.json) }
        return formats
    }

    private var documentCount: Int {
        var count = 0
        if includeOriginal && hasTranscript { count += 1 }
        if includeTranslation && hasTranslation { count += 1 }
        if includeBilingual && hasTranslation { count += 1 }
        return count
    }

    private var fileCount: Int {
        documentCount * selectedFormats.count + (includeLog ? 1 : 0)
    }

    private var summary: String {
        switch fileCount {
        case 0: return "Nothing selected"
        case 1: return "1 file"
        default: return "\(fileCount) files"
        }
    }

    private var nameHint: String {
        if documentCount * selectedFormats.count == 1 {
            let ext = selectedFormats.first?.fileExtension ?? "srt"
            return "Will be saved as \(displayBase).\(ext)"
        }
        return "Multiple files add a suffix, e.g. \(displayBase).original.srt"
    }

    private var displayBase: String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model.defaultExportBaseName : trimmed
    }

    private var exportOptions: ExportOptions {
        ExportOptions(
            baseName: displayBase,
            includeOriginal: includeOriginal,
            includeTranslation: includeTranslation,
            includeBilingual: includeBilingual,
            includeLog: includeLog,
            formats: selectedFormats
        )
    }
}

struct ExportOptions {
    let baseName: String
    let includeOriginal: Bool
    let includeTranslation: Bool
    let includeBilingual: Bool
    let includeLog: Bool
    let formats: [SubtitleExportFormat]
}
