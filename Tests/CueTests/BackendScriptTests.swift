import Foundation
import Testing
@testable import Cue

/// Runs the embedded Python helper for real (python3 ships with macOS) with a
/// fake ffmpeg on PATH, under a scratch HOME so the shared audio cache is
/// never touched.
struct BackendScriptTests {
    // When the Clean-audio filter chain fails and the helper falls back to
    // plain extraction, the unfiltered result must be cached under the
    // preprocess=False key — never under preprocess=True, which would poison
    // future Clean-audio runs for that file.
    @Test func fallbackExtractionIsNotCachedUnderPreprocessKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backend-script-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin")
        let home = root.appendingPathComponent("home")
        let work = root.appendingPathComponent("work")
        for dir in [binDir, home, work] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        // Fake ffmpeg: fails whenever the filter chain (-af) is requested,
        // succeeds otherwise by writing a placeholder output file.
        let fakeFFmpeg = binDir.appendingPathComponent("ffmpeg")
        try """
        #!/bin/sh
        for a in "$@"; do
          if [ "$a" = "-af" ]; then exit 1; fi
        done
        eval "out=\\${$#}"
        printf 'RIFF-placeholder' > "$out"
        exit 0
        """.write(to: fakeFFmpeg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpeg.path)

        let script = work.appendingPathComponent("backend.py")
        try BackendScript.source.write(to: script, atomically: true, encoding: .utf8)

        let input = work.appendingPathComponent("input.bin")
        try Data([0x01, 0x02, 0x03]).write(to: input)

        let driver = """
            import importlib.util, pathlib, sys
            spec = importlib.util.spec_from_file_location("backend", sys.argv[1])
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            inp = pathlib.Path(sys.argv[2])
            tmp = pathlib.Path(sys.argv[3])
            result = m.prepare_audio(inp, tmp, True)
            print("RESULT", result)
            print("TRUEKEY", m.audio_cache_path(inp, True))
            print("FALSEKEY", m.audio_cache_path(inp, False))
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, script.path, input.path, work.path]
        process.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "HOME": home.path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: outData, as: UTF8.self)
        let diagnostics = String(decoding: errData, as: UTF8.self)
        #expect(process.terminationStatus == 0, "helper failed: \(diagnostics)")

        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        let result = try #require(values["RESULT"])
        let trueKey = try #require(values["TRUEKEY"])
        let falseKey = try #require(values["FALSEKEY"])

        #expect(result == falseKey, "fallback result must be cached under the preprocess=False key")
        #expect(!FileManager.default.fileExists(atPath: trueKey), "no unfiltered audio may sit under the preprocess=True key")
        #expect(FileManager.default.fileExists(atPath: falseKey))
    }
}
