import Foundation
import Testing
@testable import Cue

struct EnvironmentDiagnosticsTests {
    @Test func nothingIsRequiredForNativeOrAutoBackend() {
        let allProbeIDs = ["ffmpeg", "yt-dlp", "python3", "mlx-whisper", "faster-whisper", "qwen3-asr"]
        for backend in [WhisperBackend.native, .auto] {
            for id in allProbeIDs {
                #expect(!EnvironmentDiagnosticsService.isRequired(diagnosticID: id, selectedBackend: backend))
            }
        }
    }

    @Test func onlyTheSelectedPythonBackendModuleIsRequired() {
        #expect(EnvironmentDiagnosticsService.isRequired(diagnosticID: "mlx-whisper", selectedBackend: .mlxWhisper))
        #expect(EnvironmentDiagnosticsService.isRequired(diagnosticID: "faster-whisper", selectedBackend: .fasterWhisper))
        #expect(EnvironmentDiagnosticsService.isRequired(diagnosticID: "qwen3-asr", selectedBackend: .qwen3ASR))
        // A non-selected module stays optional even when another Python
        // backend is selected, and python3 itself is never the flagged item
        // (a missing python3 fails the selected module's probe instead).
        #expect(!EnvironmentDiagnosticsService.isRequired(diagnosticID: "mlx-whisper", selectedBackend: .qwen3ASR))
        #expect(!EnvironmentDiagnosticsService.isRequired(diagnosticID: "python3", selectedBackend: .qwen3ASR))
        #expect(!EnvironmentDiagnosticsService.isRequired(diagnosticID: "ffmpeg", selectedBackend: .mlxWhisper))
    }

    @Test func runLeadsWithPassedBuiltInEngineDiagnostic() async throws {
        let diagnostics = await EnvironmentDiagnosticsService().run(
            translationAPIKey: "key",
            translationProvider: .openai,
            selectedBackend: .native
        )
        let first = try #require(diagnostics.first)
        #expect(first.id == "built-in-engine")
        #expect(first.state == .passed)
        // With the built-in backend selected, no probe result may block:
        // every other diagnostic is optional (warning at worst).
        #expect(!diagnostics.contains { $0.state == .failed })
        // The engine IDs run() emits are the same strings isRequired keys
        // on — pin them so the seam cannot drift silently.
        let ids = Set(diagnostics.map(\.id))
        #expect(ids.isSuperset(of: ["mlx-whisper", "faster-whisper", "qwen3-asr"]))
        // yt-dlp backs Add from URL and must never be a required probe.
        #expect(ids.contains("yt-dlp"))
    }

    @Test func translationKeyRowPassesForLocalProvider() async throws {
        let diagnostics = await EnvironmentDiagnosticsService().run(
            translationAPIKey: "",
            translationProvider: .local,
            selectedBackend: .native
        )
        let row = try #require(diagnostics.first { $0.id == "translation-key" })
        #expect(row.state == .passed)
        #expect(row.detail == "Local server — no API key needed.")
    }

    @Test func translationKeyRowWarnsForCloudProviderWithoutKey() async throws {
        let diagnostics = await EnvironmentDiagnosticsService().run(
            translationAPIKey: "",
            translationProvider: .openai,
            selectedBackend: .native
        )
        let row = try #require(diagnostics.first { $0.id == "translation-key" })
        #expect(row.state == .warning)
    }
}
