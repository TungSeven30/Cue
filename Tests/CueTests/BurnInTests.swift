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

    // The default macOS volume format is case-insensitive.
    @Test func outputGuardIsCaseInsensitive() {
        #expect(throws: BurnInService.BurnInError.self) {
            try BurnInService.validateOutput(
                source: URL(fileURLWithPath: "/v/Movie.mp4"),
                output: URL(fileURLWithPath: "/v/movie.MP4")
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

struct BurnInProcessTests {
    @Test func preflightDrainsFloodedStderr() async {
        let start = ContinuousClock.now
        let output = await BurnInService.runCapturingOutput(arguments: [
            "/usr/bin/python3", "-c",
            "import os, signal; signal.alarm(3); os.write(2, b'x' * 1048576); print(' subtitles ')",
        ])
        print("AUDIT12 flood_seconds=\(ContinuousClock.now - start) success=\(output != nil)")
        #expect(output?.contains(" subtitles ") == true)
    }

    @Test func preflightCancellationStopsTheChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let task = Task {
            await BurnInService.runCapturingOutput(arguments: [
                "/usr/bin/python3", "-c",
                "import os, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(sys.argv[1], 'w').write(str(os.getpid())); time.sleep(30)",
                pidFile.path,
            ])
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        let start = ContinuousClock.now
        task.cancel()
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func preflightDoesNotWaitForAnInheritedPipe() async {
        let start = ContinuousClock.now
        let output = await BurnInService.runCapturingOutput(arguments: [
            "/usr/bin/python3", "-c",
            "import os, time; pid = os.fork(); time.sleep(1.5) if pid == 0 else None; os._exit(0)",
        ], timeout: .milliseconds(100))
        #expect(output == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func preflightTimeoutBoundsAnUnresponsiveChild() async {
        let start = ContinuousClock.now
        let output = await BurnInService.runCapturingOutput(arguments: [
            "/usr/bin/python3", "-c",
            "import signal, time; signal.alarm(3); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
        ], timeout: .milliseconds(100))
        let elapsed = ContinuousClock.now - start
        print("AUDIT12 timeout_seconds=\(elapsed)")
        #expect(output == nil)
        #expect(elapsed < .seconds(2))
    }
}
