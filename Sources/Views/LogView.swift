import SwiftUI

struct LogView: View {
    let log: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run Log")
                    .font(.headline)

                Text(log)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
