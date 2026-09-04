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

            VStack(spacing: 10) {
                Button {
                    model.applySubtitleLoad(request, to: .transcript)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "text.alignleft")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Load as Original Transcript")
                                .font(.headline)
                            Text("Sets this file as the primary transcript and source for translation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!model.canApplySubtitleLoad(request, to: .transcript))

                Button {
                    model.applySubtitleLoad(request, to: .translation)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "character.bubble")
                            .font(.title3)
                            .foregroundStyle(model.canLoadTranslationSubtitles ? Color.accentColor : Color.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Load as Translation")
                                .font(.headline)
                            Text(
                                model.canLoadTranslationSubtitles
                                    ? "Fills the translation tab for bilingual subtitles, export, and burn-in."
                                    : "Requires an existing transcript first."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.canLoadTranslationSubtitles {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        model.canLoadTranslationSubtitles ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.background.secondary.opacity(0.4)),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.separator.opacity(model.canLoadTranslationSubtitles ? 1 : 0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!model.canApplySubtitleLoad(request, to: .translation))
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
