import Darwin
import Foundation

/// Headless entry point. Like `PackagedInferenceSelfTest`, it lives inside
/// the shipped executable and runs before any SwiftUI scene exists, so a
/// scripted run exercises the same bundle, the same Metal resources, and
/// the same Keychain items as the app.
///
///     Cue.app/Contents/MacOS/Cue transcribe clip.mkv --json
///
/// Arguments that name no known command fall straight through to the normal
/// GUI launch — that is what keeps Finder's `-psn_…` and Xcode's debug flags
/// from being read as commands.
enum CueCommandLine {
    static func runAndExitIfRequested() {
        let tokens = Array(CommandLine.arguments.dropFirst())
        guard let first = tokens.first, CLICommand.named(first) != nil else { return }

        Task { @MainActor in
            let code = await execute(tokens)
            exit(code)
        }
        // Services the CLI calls are @MainActor, so the main thread has to
        // keep servicing the main queue instead of blocking on a semaphore
        // the way the packaged self-test does. dispatchMain never returns;
        // the Task above ends the process.
        dispatchMain()
    }

    @MainActor
    static func execute(_ tokens: [String]) async -> Int32 {
        let parsed: CLIArguments?
        do {
            parsed = try CLIArguments.parse(tokens)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n\n".utf8))
            FileHandle.standardError.write(Data((usageText + "\n").utf8))
            return 2
        }
        guard let arguments = parsed else { return 2 }

        let console = CLIConsole(
            isJSON: arguments.flag("--json"),
            isQuiet: arguments.flag("--quiet")
        )

        // Exhaustive on purpose: a command added later has to be classified
        // here rather than silently falling through to the stage runner.
        switch arguments.command {
        case .help:
            console.result(usageText)
            return 0
        case .version:
            console.result(versionText)
            return 0
        case .doctor:
            return await runDoctor(console: console)
        case .fetch, .transcribe, .translate, .summarize, .pipeline, .burnIn:
            break
        }
        if arguments.flag("--help") {
            console.result(usageText)
            return 0
        }

        let runner = CLIRunner(arguments: arguments, settings: AppSettingsStore(), console: console)
        do {
            guard let manifest = try await runner.run() else { return 0 }
            if console.isJSON {
                console.result(try manifest.jsonString())
            } else {
                for output in manifest.outputs {
                    console.result(output.path)
                }
            }
            return 0
        } catch let error as CLIError {
            console.failure(error.localizedDescription)
            return error.exitCode
        } catch is CancellationError {
            console.failure("Canceled.")
            return 130
        } catch {
            console.failure(error.localizedDescription)
            return 1
        }
    }

    @MainActor
    private static func runDoctor(console: CLIConsole) async -> Int32 {
        let settings = AppSettingsStore()
        let diagnostics = await EnvironmentDiagnosticsService().run(
            translationAPIKey: settings.currentTranslationAPIKey,
            translationProvider: settings.currentTranslationProvider,
            selectedBackend: settings.whisperBackend
        )
        if console.isJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(diagnostics) {
                console.result(String(decoding: data, as: UTF8.self))
            }
        } else {
            for diagnostic in diagnostics {
                console.result("\(symbol(for: diagnostic.state))  \(diagnostic.title) — \(diagnostic.detail)")
            }
        }
        // A failed row means the selected backend cannot run at all; a
        // warning is an optional extra the user has not installed.
        return diagnostics.contains { $0.state == .failed } ? 1 : 0
    }

    private static func symbol(for state: DiagnosticState) -> String {
        switch state {
        case .passed: return "ok  "
        case .warning: return "warn"
        case .failed: return "FAIL"
        }
    }

    private static var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Cue \(version) (\(build))"
    }

    static let usageText = """
        Cue — transcribe, translate, and export subtitles without the GUI.

        USAGE
          Cue <command> <input> [options]

        COMMANDS
          fetch <url>          Download a video page with yt-dlp.
          transcribe <input>   Transcribe media on-device.
          translate <input>    Translate an existing transcript.
          summarize <input>    Write the spoiler-free intro cue.
          burn-in <input>      Render subtitles into the video.
          pipeline <input>     fetch → transcribe → translate → summarize → export.
          doctor               Report engine and tool availability.
          help, version

        INPUT
          A media file, an http(s) page URL (fetched with yt-dlp first), an
          .srt/.vtt file, or a .cue.json manifest written by an earlier stage.
          Every stage writes <name>.cue.json next to its output, so stages
          chain by passing that file to the next command.

        OPTIONS
          --output-dir DIR       Where to write (default: beside the input).
          --format LIST          srt,vtt,text,markdown,json (default: srt).
          --language CODE        Spoken language, or "auto".
          --preset NAME          builtIn, bestAccuracy, fastAppleSilicon,
                                 mostCompatible, higherAccuracy, draft.
          --quality NAME         fast, balanced, movieDialogue, noisyAudio,
                                 maximumAccuracy, qwenMovie.
          --backend NAME         whisper-cpp, mlx-whisper, faster-whisper, qwen3-asr.
          --model NAME           ASR model; the LLM for translate/summarize.
          --translation-model M  The LLM, on any command.
          --qwen-context "..."   Names and terms for the Qwen backend.
          --to LANG              Translation target language.
          --from LANG            Translation source language override.
          --parallelism N        Concurrent translation requests (1-4).
          --bilingual            Also write the stacked bilingual document.
          --summary              Generate the intro cue in `pipeline`.
          --detail LEVEL         brief or detailed (summaries).
          --burn-in              Render the video at the end of `pipeline`.
          --document ROLE        original, translated, or bilingual (burn-in).
          --text-size SIZE       small, medium, large (burn-in).
          --output FILE          Burn-in destination.
          --json                 Print the manifest to stdout.
          --quiet                Suppress progress on stderr.

        Settings not given as flags come from the app's own Settings, and API
        keys come from the same Keychain items. Progress goes to stderr;
        stdout carries only the result.

        EXAMPLES
          Cue transcribe clip.mkv --preset bestAccuracy --language ja
          Cue translate clip.cue.json --to Vietnamese --bilingual
          Cue pipeline "https://example.com/watch?v=…" --to English --summary
          Cue doctor --json
        """
}
