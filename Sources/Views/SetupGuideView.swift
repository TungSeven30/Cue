import AppKit
import SwiftUI

/// Walkthrough for installing the optional command-line tools the app can
/// drive (ffmpeg, Python 3, and the Python whisper engines). Transcription
/// works out of the box with the built-in engine; this sheet auto-opens
/// only when the user's selected Python backend is broken, and is reachable
/// any time from the diagnostics popover.
struct SetupGuideView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Set Up Cue")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Text("Cue works out of the box. The items below are optional engines and features. To add one, open Terminal (Applications → Utilities), paste its command, press Return, and wait for it to finish. Then come back and hit Check Again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("First time? Install Homebrew")
                            .font(.callout.weight(.semibold))
                        Text("The commands below use Homebrew, the standard macOS package manager. If Terminal says “command not found: brew”, run this first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    copyButton(Self.homebrewInstallCommand)
                }
                .padding(4)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.diagnostics) { diagnostic in
                        dependencyRow(diagnostic)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.runDiagnostics()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRunningDiagnostics)

                if model.isRunningDiagnostics {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if allRequiredInstalled {
                    Label("You're all set!", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                } else {
                    Text("Items marked optional can be added later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(allRequiredInstalled ? "Done" : "Skip for Now") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 540)
    }

    /// Warnings cover optional backends and the translation API key, which
    /// the app works without; only hard failures block transcription.
    private var allRequiredInstalled: Bool {
        !model.diagnostics.isEmpty && !model.diagnostics.contains { $0.state == .failed }
    }

    private func dependencyRow(_ diagnostic: EnvironmentDiagnostic) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: diagnostic.state.systemImage)
                        .foregroundStyle(diagnostic.state.tint)
                    Text(diagnostic.title)
                        .font(.callout.weight(.semibold))
                    if diagnostic.state == .warning {
                        Text("optional")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text(diagnostic.state == .passed ? diagnostic.detail : diagnostic.recovery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if diagnostic.state != .passed, let command = diagnostic.repairCommand {
                    HStack(spacing: 8) {
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 5))
                        copyButton(command)
                        Spacer()
                    }
                }
            }
            .padding(2)
        }
    }

    private func copyButton(_ command: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .font(.caption)
        .help("Copy this command, then paste it into Terminal")
    }
}
