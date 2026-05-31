import AppKit
import SwiftUI

struct LogView: View {
    let log: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Run Log")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Text(log)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
