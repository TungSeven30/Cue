import Foundation

/// The commands `Cue` answers to when launched with arguments. Anything not
/// in this list falls through to the normal GUI launch, which is what keeps
/// Finder's `-psn_…` and Xcode's `-NSDocumentRevisionsDebugMode` from being
/// mistaken for a headless run.
enum CLICommand: String, CaseIterable {
    case fetch
    case transcribe
    case translate
    case summarize
    case pipeline
    case burnIn = "burn-in"
    case doctor
    case help
    case version

    static func named(_ token: String) -> CLICommand? {
        switch token {
        case "--help", "-h": return .help
        case "--version", "-v": return .version
        default: return CLICommand(rawValue: token)
        }
    }
}

enum CLIArgumentError: LocalizedError, Equatable {
    case missingValue(String)
    case unknownOption(String)
    case notANumber(option: String, value: String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "\(option) needs a value."
        case .unknownOption(let option):
            return "Unknown option \(option)."
        case .notANumber(let option, let value):
            return "\(option) expects a number, got \(value)."
        }
    }
}

/// A deliberately small `--key value` / `--key=value` / `--flag` parser.
///
/// Boolean flags are declared up front rather than inferred from what
/// follows them: `--json srt` must not silently swallow `srt`, and
/// `--to --json` must not silently translate into the language "--json".
struct CLIArguments: Equatable {
    let command: CLICommand
    let positional: [String]
    private let options: [String: String]
    private let flags: Set<String>

    static func parse(
        _ tokens: [String],
        booleanFlags: Set<String> = CLIArguments.knownBooleanFlags
    ) throws -> CLIArguments? {
        guard let first = tokens.first, let command = CLICommand.named(first) else { return nil }

        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        let rest = tokens

        while index < rest.count {
            let token = rest[index]
            index += 1
            guard token.hasPrefix("--") else {
                positional.append(token)
                continue
            }
            if let equals = token.firstIndex(of: "=") {
                let name = String(token[token.startIndex..<equals])
                guard knownOptions.contains(name) else { throw CLIArgumentError.unknownOption(name) }
                options[name] = String(token[token.index(after: equals)...])
                continue
            }
            if booleanFlags.contains(token) {
                flags.insert(token)
                continue
            }
            // A typo must fail loudly: an unattended `--pareset bestAccuracy`
            // that silently ran with defaults is the worst outcome for the
            // cron and agent runs this CLI exists for.
            guard knownOptions.contains(token) else { throw CLIArgumentError.unknownOption(token) }
            guard index < rest.count else { throw CLIArgumentError.missingValue(token) }
            options[token] = rest[index]
            index += 1
        }

        return CLIArguments(command: command, positional: positional, options: options, flags: flags)
    }

    static let knownBooleanFlags: Set<String> = [
        "--json", "--quiet", "--summary", "--bilingual", "--burn-in", "--help", "--version",
    ]

    /// Every value-taking option any command reads. Kept in one place so the
    /// parser and the help text cannot drift apart silently.
    static let knownOptions: Set<String> = [
        "--output-dir", "--format", "--language", "--preset", "--quality", "--backend", "--model",
        "--translation-model", "--qwen-context", "--to", "--from", "--parallelism", "--detail",
        "--document", "--text-size", "--output",
    ]

    func flag(_ name: String) -> Bool { flags.contains(name) }

    func value(_ name: String) -> String? {
        options[name].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func value(_ name: String, default fallback: String) -> String {
        value(name) ?? fallback
    }

    func intValue(_ name: String) throws -> Int? {
        guard let raw = value(name) else { return nil }
        guard let parsed = Int(raw) else { throw CLIArgumentError.notANumber(option: name, value: raw) }
        return parsed
    }

    /// A comma-separated list, e.g. `--format srt,vtt`. Empty entries are
    /// dropped so `srt,,vtt` and a trailing comma both behave.
    func listValue(_ name: String) -> [String]? {
        guard let raw = value(name) else { return nil }
        let parts =
            raw
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }

    func formats(_ name: String = "--format", default fallback: [SubtitleExportFormat]) throws -> [SubtitleExportFormat] {
        guard let names = listValue(name) else { return fallback }
        return try names.map { token in
            guard let format = SubtitleExportFormat(rawValue: token.lowercased()) else {
                throw CLIArgumentError.unknownOption("\(name) \(token)")
            }
            return format
        }
    }

    /// The first positional argument — every stage command's input.
    var input: String? { positional.first }
}
