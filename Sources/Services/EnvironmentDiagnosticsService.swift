import Foundation

struct EnvironmentDiagnosticsService {
    func run(openAIAPIKey: String) async -> [EnvironmentDiagnostic] {
        async let ffmpeg = commandDiagnostic(
            id: "ffmpeg",
            title: "ffmpeg",
            command: ["/usr/bin/env", "ffmpeg", "-version"],
            recovery: "Install ffmpeg and make sure it is available on PATH.",
            repairCommand: "brew install ffmpeg"
        )
        async let python = commandDiagnostic(
            id: "python3",
            title: "Python 3",
            command: ["/usr/bin/env", "python3", "--version"],
            recovery: "Install Python 3 and make sure python3 is available on PATH.",
            repairCommand: "brew install python"
        )
        async let mlx = pythonImportDiagnostic(
            id: "mlx-whisper",
            title: "MLX Whisper",
            module: "mlx_whisper",
            recovery: "Install with pip install mlx-whisper for fast Apple Silicon transcription.",
            repairCommand: "python3 -m pip install mlx-whisper"
        )
        async let faster = pythonImportDiagnostic(
            id: "faster-whisper",
            title: "Faster Whisper",
            module: "faster_whisper",
            recovery: "Optional fallback: pip install faster-whisper.",
            repairCommand: "python3 -m pip install faster-whisper"
        )

        var results = await [ffmpeg, python, mlx, faster]
        results.append(
            EnvironmentDiagnostic(
                id: "openai-key",
                title: "OpenAI API Key",
                detail: openAIAPIKey.isEmpty ? "No API key configured." : "API key is configured.",
                recovery: "Add an API key in Settings before translating.",
                state: openAIAPIKey.isEmpty ? .warning : .passed
            )
        )
        return results
    }

    private func commandDiagnostic(
        id: String,
        title: String,
        command: [String],
        recovery: String,
        repairCommand: String? = nil
    ) async -> EnvironmentDiagnostic {
        await Task.detached(priority: .utility) {
            let result = runProcess(command)
            return EnvironmentDiagnostic(
                id: id,
                title: title,
                detail: result.output.isEmpty ? result.message : result.output,
                recovery: recovery,
                state: result.succeeded ? .passed : .failed,
                repairCommand: repairCommand
            )
        }.value
    }

    private func pythonImportDiagnostic(
        id: String,
        title: String,
        module: String,
        recovery: String,
        repairCommand: String? = nil
    ) async -> EnvironmentDiagnostic {
        await commandDiagnostic(
            id: id,
            title: title,
            command: ["/usr/bin/env", "python3", "-c", "import \(module); print('available')"],
            recovery: recovery,
            repairCommand: repairCommand
        )
    }
}

private struct ProcessProbeResult {
    let succeeded: Bool
    let output: String
    let message: String
}

private func runProcess(_ command: [String]) -> ProcessProbeResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    process.environment = ProcessEnvironment.withToolPaths()

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ProcessProbeResult(succeeded: false, output: "", message: error.localizedDescription)
    }

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .components(separatedBy: .newlines)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    return ProcessProbeResult(
        succeeded: process.terminationStatus == 0,
        output: output,
        message: error.isEmpty ? "Exited with status \(process.terminationStatus)." : error
    )
}
