import Foundation
@testable import Cue

/// Runs a fixture process without parking a Swift cooperative thread.
///
/// Swift Testing runs suites in parallel on the cooperative pool, which is
/// only as wide as the machine has cores (three on GitHub's macOS runners).
/// A test that blocks in `waitUntilExit` or `readDataToEndOfFile` holds one
/// of those threads for as long as the child runs, and a few of them at once
/// starve every other test: timers stop firing and timing assertions in
/// unrelated suites fail. Waiting here goes through `waitForTermination()`
/// and `PipeCollector`, which park nothing.
enum TestProcess {
    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: Data

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = PipeCollector()
        let stderr = PipeCollector()
        defer { stdout.close(); stderr.close() }
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        try process.run()
        let status = await process.waitForTermination()
        await stdout.waitForEOF()
        await stderr.waitForEOF()
        return Result(status: status, stdout: stdout.data(), stderr: stderr.data())
    }
}
