import Foundation

struct EnvironmentDiagnosticsService {
    /// Decides which probe genuinely blocks the user's configuration. The
    /// built-in whisper.cpp engine ships in the app, so on `.native` (and
    /// `.auto`, which resolves to native at dispatch) nothing is required.
    /// When the user explicitly selected a Python backend, that backend's
    /// own module probe is the one thing that can still fail hard — a
    /// missing python3 surfaces through it, since the import probe runs
    /// via python3.
    static func isRequired(diagnosticID: String, selectedBackend: WhisperBackend) -> Bool {
        switch selectedBackend {
        case .native, .auto:
            return false
        case .mlxWhisper:
            return diagnosticID == "mlx-whisper"
        case .fasterWhisper:
            return diagnosticID == "faster-whisper"
        case .qwen3ASR:
            return diagnosticID == "qwen3-asr"
        }
    }

    func run(
        translationAPIKey: String,
        providerLabel: String,
        selectedBackend: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        func optional(_ id: String) -> Bool {
            !Self.isRequired(diagnosticID: id, selectedBackend: selectedBackend)
        }

        async let ffmpeg = commandDiagnostic(
            id: "ffmpeg",
            title: "ffmpeg",
            command: ["/usr/bin/env", "ffmpeg", "-version"],
            recovery: "Only needed for the Clean audio option and rare containers AVFoundation can't read.",
            repairCommand: "brew install ffmpeg",
            optional: optional("ffmpeg")
        )
        async let python = commandDiagnostic(
            id: "python3",
            title: "Python 3",
            command: ["/usr/bin/env", "python3", "--version"],
            recovery: "Only needed for the advanced Python engines (MLX Whisper, Faster Whisper, Qwen3 ASR).",
            repairCommand: "brew install python",
            optional: optional("python3")
        )
        async let mlx = pythonImportDiagnostic(
            id: "mlx-whisper",
            title: "MLX Whisper",
            module: "mlx_whisper",
            recovery: optional("mlx-whisper")
                ? "Optional engine: pip install mlx-whisper for fast Apple Silicon transcription."
                : "Required by your selected engine: pip install mlx-whisper.",
            repairCommand: "python3 -m pip install mlx-whisper",
            optional: optional("mlx-whisper")
        )
        async let faster = pythonImportDiagnostic(
            id: "faster-whisper",
            title: "Faster Whisper",
            module: "faster_whisper",
            recovery: optional("faster-whisper")
                ? "Optional fallback: pip install faster-whisper."
                : "Required by your selected engine: pip install faster-whisper.",
            repairCommand: "python3 -m pip install faster-whisper",
            optional: optional("faster-whisper")
        )
        async let qwen3 = pythonImportDiagnostic(
            id: "qwen3-asr",
            title: "Qwen3 ASR",
            module: "mlx_qwen3_asr",
            recovery: optional("qwen3-asr")
                ? "Optional: best transcription accuracy. pip install 'mlx-qwen3-asr[aligner]'."
                : "Required by your selected engine: pip install 'mlx-qwen3-asr[aligner]'.",
            repairCommand: "python3 -m pip install 'mlx-qwen3-asr[aligner]'",
            optional: optional("qwen3-asr")
        )

        // The built-in engine is compiled into the app, so there is nothing
        // to probe: it always leads the list as passed.
        var results = [
            EnvironmentDiagnostic(
                id: "built-in-engine",
                title: "Built-in engine",
                detail: "Ready — nothing to install.",
                recovery: "The built-in whisper.cpp engine ships inside the app.",
                state: .passed
            )
        ]
        results.append(contentsOf: await [ffmpeg, python, mlx, faster, qwen3])
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
