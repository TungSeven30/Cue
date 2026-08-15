import SwiftUI

/// Asks which slot a manually loaded subtitle file should fill.
struct SubtitleSlotPickerView: View {
    @EnvironmentObject private var model: AppModel
    let request: AppModel.SubtitleLoadRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Load Subtitles")
                .font(.title3.weight(.semibold))
            Text("\(request.document.source.fileName) — ^[\(request.document.segments.count) cue](inflect: true)")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button("Load as Transcript") {
                    model.applySubtitleLoad(request, to: .transcript)
                }
                .buttonStyle(.borderedProminent)

                Button("Load as Translation") {
                    model.applySubtitleLoad(request, to: .translation)
                }
                .disabled(!model.canLoadTranslationSubtitles)
                if !model.canLoadTranslationSubtitles {
                    Text("Load a transcript first — a translation on its own cannot be exported or burned in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.subtitleLoadRequest = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
