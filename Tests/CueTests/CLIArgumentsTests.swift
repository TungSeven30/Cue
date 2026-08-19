import Foundation
import Testing
@testable import Cue

struct CLIArgumentsTests {
    @Test func nonCommandArgumentsAreNotACLIInvocation() throws {
        // What Finder and Xcode pass on a normal GUI launch must never be
        // read as a headless run.
        #expect(try CLIArguments.parse(["-psn_0_12345"]) == nil)
        #expect(try CLIArguments.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(try CLIArguments.parse([]) == nil)
        #expect(try CLIArguments.parse(["--self-test-packaged-inference", "model.bin"]) == nil)
    }

    @Test func commandsAndAliasesResolve() throws {
        #expect(CLICommand.named("transcribe") == .transcribe)
        #expect(CLICommand.named("burn-in") == .burnIn)
        #expect(CLICommand.named("--help") == .help)
        #expect(CLICommand.named("-h") == .help)
        #expect(CLICommand.named("--version") == .version)
        #expect(CLICommand.named("transcribed") == nil)
    }

    @Test func parsesPositionalOptionsAndFlags() throws {
        let arguments = try #require(
            try CLIArguments.parse([
                "transcribe", "clip.mkv", "--language", "ja", "--format=srt,vtt", "--json",
            ])
        )
        #expect(arguments.command == .transcribe)
        #expect(arguments.input == "clip.mkv")
        #expect(arguments.value("--language") == "ja")
        #expect(arguments.flag("--json"))
        #expect(!arguments.flag("--quiet"))
        #expect(try arguments.formats(default: [.srt]) == [.srt, .vtt])
    }

    // The whole reason boolean flags are declared rather than inferred: a
    // flag followed by a positional must not swallow it, and an option
    // missing its value must fail loudly instead of consuming the next flag.
    @Test func booleanFlagsDoNotConsumeTheFollowingToken() throws {
        let arguments = try #require(try CLIArguments.parse(["translate", "--json", "clip.cue.json"]))
        #expect(arguments.flag("--json"))
        #expect(arguments.input == "clip.cue.json")
    }

    @Test func optionAtTheEndWithoutAValueIsAUsageError() {
        #expect(throws: CLIArgumentError.missingValue("--to")) {
            _ = try CLIArguments.parse(["translate", "clip.cue.json", "--to"])
        }
    }

    @Test func optionTakesTheNextTokenEvenWhenItLooksLikeAFlag() throws {
        // `--to --json` is a mistake, but silently translating into the
        // language "--json" would be worse than doing exactly what was typed.
        let arguments = try #require(try CLIArguments.parse(["translate", "in.json", "--to", "--json"]))
        #expect(arguments.value("--to") == "--json")
        #expect(!arguments.flag("--json"))
    }

    @Test func unknownFormatIsRejected() throws {
        let arguments = try #require(try CLIArguments.parse(["transcribe", "clip.mkv", "--format", "srt,docx"]))
        #expect(throws: (any Error).self) {
            _ = try arguments.formats(default: [.srt])
        }
    }

    @Test func listValuesToleratePaddingAndEmptyEntries() throws {
        let arguments = try #require(try CLIArguments.parse(["transcribe", "a.mkv", "--format", " srt , , vtt ,"]))
        #expect(try arguments.formats(default: []) == [.srt, .vtt])
    }

    @Test func intValueRejectsNonNumbers() throws {
        let good = try #require(try CLIArguments.parse(["translate", "a.json", "--parallelism", "3"]))
        #expect(try good.intValue("--parallelism") == 3)
        let bad = try #require(try CLIArguments.parse(["translate", "a.json", "--parallelism", "lots"]))
        #expect(throws: CLIArgumentError.notANumber(option: "--parallelism", value: "lots")) {
            _ = try bad.intValue("--parallelism")
        }
    }

    @Test func missingOptionsReadAsNil() throws {
        let arguments = try #require(try CLIArguments.parse(["doctor"]))
        #expect(arguments.value("--to") == nil)
        #expect(arguments.input == nil)
        #expect(arguments.value("--to", default: "English") == "English")
    }

    // Help text that silently stops listing a command is how a CLI becomes
    // undiscoverable, so pin it to the command list itself.
    @Test func usageTextDocumentsEveryCommand() {
        for command in CLICommand.allCases {
            #expect(CueCommandLine.usageText.contains(command.rawValue), "\(command.rawValue) is missing from the help text")
        }
    }
}
