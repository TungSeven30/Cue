import Foundation
import Testing
@testable import Cue

struct AudioCacheTests {
    // Mirrors the Python helper: payload is
    // "<resolved path>|<size>|<mtime_ns>|preprocess=<True/False>",
    // digest is the first 24 hex chars of sha256, file "<digest>.wav".
    @Test func cacheKeyMatchesPythonScheme() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-key-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let url = try AudioCache.cachedAudioURL(for: file, preprocess: false)
        #expect(url.pathExtension == "wav")
        #expect(url.deletingPathExtension().lastPathComponent.count == 24)
        #expect(try AudioCache.cachedAudioURL(for: file, preprocess: false) == url)
        #expect(try AudioCache.cachedAudioURL(for: file, preprocess: true) != url)
    }

    // Empirical parity check against the Python helper's scheme. The file
    // lives under /tmp (a symlink to /private/tmp) so this also proves the
    // Swift side resolves symlinks the same way Python's Path.resolve() does.
    @Test func cacheKeyMatchesPythonHelperDigest() throws {
        let file = URL(fileURLWithPath: "/tmp/parity-\(UUID().uuidString).bin")
        try Data([9, 8, 7]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let swiftDigest = try AudioCache.cachedAudioURL(for: file, preprocess: false)
            .deletingPathExtension().lastPathComponent

        let script = """
            import hashlib, os, sys
            p = sys.argv[1]
            st = os.stat(p)
            payload = f"{os.path.realpath(p)}|{st.st_size}|{st.st_mtime_ns}|preprocess=False"
            print(hashlib.sha256(payload.encode()).hexdigest()[:24])
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let pythonDigest = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(process.terminationStatus == 0)
        #expect(pythonDigest == swiftDigest)
    }

    @Test func pruneDeletesOldestBeyondCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<3 {
            let url = dir.appendingPathComponent("f\(index).wav")
            try Data(count: 1_000).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index - 10))],
                ofItemAtPath: url.path
            )
        }
        // Keep the OLDEST file so the exemption branch actually fires: prune
        // must skip f0 (first candidate) and evict f1 instead. 3,000 bytes
        // against a 2,500 cap forces exactly one eviction, so f2 survives.
        AudioCache.prune(directory: dir, maxBytes: 2_500, keeping: dir.appendingPathComponent("f0.wav"))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(remaining == ["f0.wav", "f2.wav"])
    }

    @Test func pruneSweepsStalePartialFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("abc.wav.partial-XYZ")
        try Data(count: 10).write(to: partial)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: partial.path)
        AudioCache.prune(directory: dir, maxBytes: 10_000, keeping: nil)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    // A fresh partial may belong to an extraction running in another Cue
    // process (the CLI beside the GUI); sweeping it would fail that run.
    @Test func pruneKeepsFreshPartialFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("abc.wav.partial-XYZ")
        try Data(count: 10).write(to: partial)
        AudioCache.prune(directory: dir, maxBytes: 10_000, keeping: nil)
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }
}
