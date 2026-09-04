import Foundation

protocol EnvironmentDiagnosing: Sendable {
    func run(
        translationAPIKey: String,
        translationProvider: TranslationProvider,
        selectedBackend: WhisperBackend
    ) async -> [EnvironmentDiagnostic]
}

struct EnvironmentDiagnosticsService: EnvironmentDiagnosing {
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
        translationProvider: TranslationProvider,
        selectedBackend: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        @Sendable func optional(_ id: String) -> Bool {
            !Self.isRequired(diagnosticID: id, selectedBackend: selectedBackend)
        }

        async let ffmpeg = commandDiagnostic(
            id: "ffmpeg",
            title: "ffmpeg",
            command: ["/usr/bin/env", "ffmpeg", "-version"],
            recovery: "Only needed for burn-in export, the Clean audio option, and rare containers AVFoundation can't read.",
            repairCommand: "brew install ffmpeg",
            optional: optional("ffmpeg")
        )
        async let ytDlp = commandDiagnostic(
            id: "yt-dlp",
            title: "yt-dlp",
            command: ["/usr/bin/env", "yt-dlp", "--version"],
            recovery: "Only needed for Add from URL, which downloads a video page before transcribing it.",
            repairCommand: "brew install yt-dlp",
            optional: optional("yt-dlp")
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
            repairCommand: "python3 -m pip install --user --break-system-packages mlx-whisper",
            optional: optional("mlx-whisper")
        )
        async let faster = pythonImportDiagnostic(
            id: "faster-whisper",
            title: "Faster Whisper",
            module: "faster_whisper",
            recovery: optional("faster-whisper")
                ? "Optional fallback: pip install faster-whisper."
                : "Required by your selected engine: pip install faster-whisper.",
            repairCommand: "python3 -m pip install --user --break-system-packages faster-whisper",
            optional: optional("faster-whisper")
        )
        async let qwen3 = pythonImportDiagnostic(
            id: "qwen3-asr",
            title: "Qwen3 ASR",
            module: "mlx_qwen3_asr",
            recovery: optional("qwen3-asr")
                ? "Optional: best transcription accuracy. pip install 'mlx-qwen3-asr[aligner]'."
                : "Required by your selected engine: pip install 'mlx-qwen3-asr[aligner]'.",
            repairCommand: "python3 -m pip install --user --break-system-packages 'mlx-qwen3-asr[aligner]'",
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
        results.append(contentsOf: await [ffmpeg, ytDlp, python, mlx, faster, qwen3])
        let providerLabel = translationProvider.label
        let title: String
        let detail: String
        let recovery: String
        let state: DiagnosticState
        if translationProvider == .local {
            // Local servers authenticate nothing; the row exists so the
            // list still answers "is translation configured?" at a glance.
            title = "Translation (\(providerLabel))"
            detail = "Local server — no API key needed."
            recovery = "Local servers such as LM Studio and Ollama need no API key."
            state = .passed
        } else {
            title = "Translation API Key (\(providerLabel))"
            detail =
                translationAPIKey.isEmpty
                ? "No \(providerLabel) API key configured for the selected translation model."
                : "\(providerLabel) API key is configured."
            recovery = "Add a \(providerLabel) API key in Settings before translating."
            state = translationAPIKey.isEmpty ? .warning : .passed
        }
        results.append(
            EnvironmentDiagnostic(
                id: "translation-key",
                title: title,
                detail: detail,
                recovery: recovery,
                state: state
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
        let result = await runProcess(command)
        return EnvironmentDiagnostic(
            id: id,
            title: title,
            detail: result.output.isEmpty ? result.message : result.output,
            recovery: recovery,
            state: result.succeeded ? .passed : (optional ? .warning : .failed),
            repairCommand: repairCommand
        )
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

/// Runs one probe without ever blocking a Swift cooperative thread. The
/// previous implementation parked a detached task in `waitUntilExit` and a
/// dispatch-group wait while the pipe drains ran on the same QoS bucket's
/// global queue; with several probes in flight that starved the pool and
/// deadlocked (every cooperative thread waiting on drains that could not be
/// scheduled). Pipes now drain on the file handles' own readability queue,
/// and exit is awaited through the termination handler. Draining while the
/// probe runs also keeps a long Python traceback from filling the ~64 KB pipe
/// buffer and wedging the child.
private func runProcess(_ command: [String]) async -> ProcessProbeResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    process.environment = ProcessEnvironment.withToolPaths()

    let output = PipeCollector()
    let error = PipeCollector()
    process.standardOutput = output.pipe
    process.standardError = error.pipe

    do {
        try process.run()
    } catch {
        return ProcessProbeResult(succeeded: false, output: "", message: error.localizedDescription)
    }

    let status = await process.waitForTermination()
    await output.waitForEOF()
    await error.waitForEOF()
    output.close()
    error.close()

    let firstOutputLine =
        output.text()
        .components(separatedBy: .newlines)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorText = error.text().trimmingCharacters(in: .whitespacesAndNewlines)

    return ProcessProbeResult(
        succeeded: status == 0,
        output: firstOutputLine,
        message: errorText.isEmpty ? "Exited with status \(status)." : errorText
    )
}
