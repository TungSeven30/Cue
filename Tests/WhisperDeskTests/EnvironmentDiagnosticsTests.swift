import Foundation
import Testing
@testable import WhisperDesk

struct EnvironmentDiagnosticsTests {
    @Test func nothingIsRequiredForNativeOrAutoBackend() {
        let allProbeIDs = ["ffmpeg", "python3", "mlx-whisper", "faster-whisper", "qwen3-asr"]
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
            providerLabel: "OpenAI",
            selectedBackend: .native
        )
        let first = try #require(diagnostics.first)
        #expect(first.id == "built-in-engine")
        #expect(first.state == .passed)
        // With the built-in backend selected, no probe result may block:
        // every other diagnostic is optional (warning at worst).
        #expect(!diagnostics.contains { $0.state == .failed })
    }
}
