import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Burn-in options (spec §3.4 entry point): pick the document, text size,
/// and destination, then hand off to AppModel.startBurnIn.
struct BurnInOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var document: AppModel.BurnInDocument = .translation
    @AppStorage("burnInTextSize") private var textSizeRaw = BurnInService.TextSize.medium.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Burn In Subtitles")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            Form {
                if model.burnInPreflight?.available != true {
                    Section {
                        Label(
                            model.burnInPreflight?.message ?? "Checking for ffmpeg…",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        Button("Recheck") { model.checkBurnInAvailability() }
                    }
                }
                Picker("Subtitles", selection: $document) {
                    ForEach(availableDocuments) { doc in
                        Text(doc.label).tag(doc)
                    }
                }
                Picker("Text size", selection: $textSizeRaw) {
                    ForEach(BurnInService.TextSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Text("Re-encodes the whole video — takes a while.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseDestinationAndStart() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.burnInPreflight?.available != true || !model.canBurnIn)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if model.burnInPreflight == nil { model.checkBurnInAvailability() }
            if !availableDocuments.contains(document) {
                document = availableDocuments.first ?? .original
            }
        }
    }

    private var availableDocuments: [AppModel.BurnInDocument] {
        var docs: [AppModel.BurnInDocument] = [.original]
        if !model.translatedSegments.isEmpty {
            docs.append(.translation)
            docs.append(.bilingual)
        }
        return docs
    }

    private func chooseDestinationAndStart() {
        guard let source = model.selectedVideoURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".burned.mp4"
        panel.directoryURL = source.deletingLastPathComponent()
        let size = BurnInService.TextSize(rawValue: textSizeRaw) ?? .medium
        let doc = document
        dismiss()
        DispatchQueue.main.async {
            guard panel.runModal() == .OK, let output = panel.url else { return }
            // A watch-folder ingest can start a job while the save panel is
            // up; startBurnIn's guard would then no-op silently. Say so.
            guard model.canBurnIn else {
                let alert = NSAlert()
                alert.messageText = "Cannot Start Burn-In"
                alert.informativeText = "Another job started while choosing a destination. Wait for it to finish, then try again."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            model.startBurnIn(AppModel.BurnInRequest(document: doc, textSize: size, output: output))
        }
    }
}
