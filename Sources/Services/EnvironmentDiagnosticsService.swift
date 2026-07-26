import Foundation

struct EnvironmentDiagnosticsService {
    func run(translationAPIKey: String, providerLabel: String) async -> [EnvironmentDiagnostic] {
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
            repairCommand: "python3 -m pip install faster-whisper",
            optional: true
        )
        async let qwen3 = pythonImportDiagnostic(
            id: "qwen3-asr",
            title: "Qwen3 ASR",
            module: "mlx_qwen3_asr",
            recovery: "Optional: best transcription accuracy. pip install 'mlx-qwen3-asr[aligner]'.",
            repairCommand: "python3 -m pip install 'mlx-qwen3-asr[aligner]'",
            optional: true
        )

        var results = await [ffmpeg, python, mlx, faster, qwen3]
        results.append(
            EnvironmentDiagnostic(
                id: "translation-key",
                title: "Translation API Key (\(providerLabel))",
                detail: translationAPIKey.isEmpty
                    ? "No \(providerLabel) API key configured for the selected translation model."
                    : "\(providerLabel) API key is configured.",
                recovery: "Add a \(providerLabel) API key in Settings before translating.",
                state: translationAPIKey.isEmpty ? .warning : .passed
            )
        )
        return results
    }

    private func commandDiagnostic(
        id: String,
        title: String,
        command: [String],
        recovery: String,
        repairCommand: String? = nil,
        optional: Bool = false
    ) async -> EnvironmentDiagnostic {
        await Task.detached(priority: .utility) {
            let result = runProcess(command)
            return EnvironmentDiagnostic(
                id: id,
                title: title,
                detail: result.output.isEmpty ? result.message : result.output,
                recovery: recovery,
                state: result.succeeded ? .passed : (optional ? .warning : .failed),
                repairCommand: repairCommand
            )
        }.value
    }

    private func pythonImportDiagnostic(
        id: String,
        title: String,
        module: String,
        recovery: String,
        repairCommand: String? = nil,
        optional: Bool = false
    ) async -> EnvironmentDiagnostic {
        await commandDiagnostic(
            id: id,
            title: title,
            command: ["/usr/bin/env", "python3", "-c", "import \(module); print('available')"],
            recovery: recovery,
            repairCommand: repairCommand,
            optional: optional
        )
    }
}

private struct ProcessProbeResult {
    let succeeded: Bool
    let output: String
    let message: String
}

private final class PipeDataBox: @unchecked Sendable {
    var data = Data()
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
    } catch {
        return ProcessProbeResult(succeeded: false, output: "", message: error.localizedDescription)
    }

    // Drain both pipes while the probe runs. Waiting for exit before reading
    // deadlocks when the probe writes more than the ~64KB pipe buffer (e.g.
    // a long Python traceback): the child blocks on the full pipe and
    // waitUntilExit never returns, wedging diagnostics for the session.
    let outputBox = PipeDataBox()
    let errorBox = PipeDataBox()
    let drainGroup = DispatchGroup()
    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        outputBox.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        drainGroup.leave()
    }
    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        drainGroup.leave()
    }
    process.waitUntilExit()
    drainGroup.wait()

    let output = String(data: outputBox.data, encoding: .utf8)?
        .components(separatedBy: .newlines)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let error = String(data: errorBox.data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    return ProcessProbeResult(
        succeeded: process.terminationStatus == 0,
        output: output,
        message: error.isEmpty ? "Exited with status \(process.terminationStatus)." : error
    )
}
