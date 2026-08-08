import Foundation
import Testing
@testable import Cue

struct BurnInArgumentTests {
    @Test func argumentsFollowSpecCommandShape() throws {
        let args = BurnInService.makeArguments(
            source: URL(fileURLWithPath: "/videos/movie.mkv"),
            subtitleFile: URL(fileURLWithPath: "/tmp/work/subs.srt"),
            forceStyle: "FontSize=20,MarginV=25,BorderStyle=3",
            output: URL(fileURLWithPath: "/videos/movie.burned.mp4")
        )
        #expect(args.first == "-y")
        #expect(args.contains("-nostdin"))
        #expect(args.contains("h264_videotoolbox"))
        #expect(args.contains("+faststart"))
        #expect(args.last == "/videos/movie.burned.mp4")
        let vfIndex = try #require(args.firstIndex(of: "-vf"))
        #expect(args[vfIndex + 1] == "subtitles=filename=/tmp/work/subs.srt:force_style='FontSize=20,MarginV=25,BorderStyle=3'")
    }

    // Path safety (spec §3.2): the subtitle path we generate must never
    // contain filter metacharacters, since we do not escape it.
    @Test func workingSubtitlePathIsFilterSafe() {
        let url = BurnInService.makeWorkingSubtitleURL()
        for character in ":'[],;" {
            #expect(!url.path.contains(character), "temp path must not contain \(character)")
        }
        #expect(url.lastPathComponent == "subs.srt")
    }

    @Test func outputGuardRefusesSourcePath() {
        #expect(throws: BurnInService.BurnInError.self) {
            try BurnInService.validateOutput(
                source: URL(fileURLWithPath: "/v/movie.mp4"),
                output: URL(fileURLWithPath: "/v/../v/movie.mp4")
            )
        }
    }

    @Test func outputGuardAcceptsDistinctPath() throws {
        try BurnInService.validateOutput(
            source: URL(fileURLWithPath: "/v/movie.mp4"),
            output: URL(fileURLWithPath: "/v/movie.burned.mp4")
        )
    }

    @Test func everyTextSizeYieldsBoxedStyle() {
        for size in BurnInService.TextSize.allCases {
            let style = BurnInService.forceStyle(for: size)
            #expect(style.contains("BorderStyle=3"), "box background is non-negotiable for legibility")
            #expect(style.contains("FontSize="))
            #expect(style.contains("MarginV="))
        }
    }
}

struct BurnInProgressParsingTests {
    @Test func parsesStandardProgressLine() {
        let line = "frame= 2160 fps=120 q=-0.0 size=  102400KiB time=00:01:30.05 bitrate=9300.1kbits/s speed=4.1x"
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: line) == 90.05)
    }

    @Test func parsesHoursComponent() {
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: "time=01:02:03.50 bitrate=...") == 3723.5)
    }

    @Test func rejectsMalformedLines() {
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: "time=N/A bitrate=N/A") == nil)
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: "no timestamps here") == nil)
        #expect(BurnInService.parseProgressSeconds(fromStderrLine: "time=12:34") == nil)
    }
}

struct BurnInPreflightParsingTests {
    @Test func detectsSubtitlesFilter() {
        let output = """
            Filters:
             ... scale            V->V  Scale the input video size...
             ... subtitles        V->V  Render text subtitles onto input video...
            """
        #expect(BurnInService.hasSubtitlesFilter(inFiltersOutput: output))
    }

    @Test func minimalBuildLacksFilter() {
        // Spec §3.1: a build without libass must be caught up front, not
        // forty minutes into an encode.
        #expect(!BurnInService.hasSubtitlesFilter(inFiltersOutput: "Filters:\n ... scale V->V ..."))
        #expect(!BurnInService.hasSubtitlesFilter(inFiltersOutput: ""))
    }
}
