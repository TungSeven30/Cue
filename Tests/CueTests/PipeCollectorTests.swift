import Foundation
import Testing
@testable import Cue

@Suite struct PipeCollectorTests {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ line: String) {
            lock.withLock { values.append(line) }
        }

        var all: [String] {
            lock.withLock { values }
        }
    }

    @Test func linesSplitAcrossReadsDecodeIdentically() {
        let lines = Lines()
        let collector = PipeCollector { lines.append($0) }
        collector.ingest(Data("{\"a\":1}\n{\"b\":".utf8))
        collector.ingest(Data("2}\n{\"c\":\"é".utf8))
        collector.ingest(Data("\"}\n".utf8))
        #expect(lines.all == ["{\"a\":1}", "{\"b\":2}", "{\"c\":\"é\"}"])
        #expect(collector.text() == "{\"a\":1}\n{\"b\":2}\n{\"c\":\"é\"}\n")
    }

    @Test func multibyteCharacterSplitAcrossReadsIsPreserved() {
        let lines = Lines()
        let collector = PipeCollector { lines.append($0) }
        let bytes = Array("héllo\n".utf8)  // é is C3 A9
        collector.ingest(Data(bytes[0..<2]))
        collector.ingest(Data(bytes[2...]))
        #expect(lines.all == ["héllo"])
    }

    @Test func manyLinesInOneReadAndEmptyLinesAreDelivered() {
        let lines = Lines()
        let collector = PipeCollector { lines.append($0) }
        collector.ingest(Data("one\ntwo\n\nfour\n".utf8))
        #expect(lines.all == ["one", "two", "", "four"])
    }

    @Test func trailingPartialLineIsHeldUntilItsNewline() {
        let lines = Lines()
        let collector = PipeCollector { lines.append($0) }
        collector.ingest(Data("partial".utf8))
        #expect(lines.all.isEmpty)
        collector.ingest(Data(" line\nnext".utf8))
        #expect(lines.all == ["partial line"])
        collector.ingest(Data("\n".utf8))
        #expect(lines.all == ["partial line", "next"])
    }

    /// stdout has no line consumer and the helper writes one enormous JSON
    /// line at the end; the collector must not rescan the growing buffer on
    /// every read.
    @Test func singleHugeLineIsCollectedIntactWithoutQuadraticRescans() {
        let collector = PipeCollector()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<400 {
            collector.ingest(chunk)  // 25 MB with no newline
        }
        collector.ingest(Data("\n".utf8))
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(collector.data().count == 400 * 64 * 1024 + 1)
        #expect(seconds < 2.0, "buffer handling took \(seconds)s")
    }

    @Test func hugeLineWithConsumerIsStillLinearAndDeliveredOnce() {
        let lines = Lines()
        let collector = PipeCollector { lines.append($0) }
        let chunk = Data(repeating: UInt8(ascii: "y"), count: 64 * 1024)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 {
            collector.ingest(chunk)
        }
        collector.ingest(Data("\n".utf8))
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.utf8.count == 200 * 64 * 1024)
        #expect(seconds < 2.0, "incremental scan took \(seconds)s")
    }

    @Test func concurrentDrainWaitersAndCancellationDoNotLoseContinuations() async throws {
        let collector = PipeCollector()
        let started = Lines()
        let completed = Lines()
        let tasks = (0..<3).map { index in
            Task {
                started.append("\(index)")
                await collector.waitForEOF()
                completed.append("\(index)")
            }
        }
        let startedDeadline = ContinuousClock.now + .seconds(2)
        while started.all.count < 3 && ContinuousClock.now < startedDeadline { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        tasks[0].cancel()
        let cancelDeadline = ContinuousClock.now + .seconds(1)
        while completed.all.isEmpty && ContinuousClock.now < cancelDeadline { await Task.yield() }
        #expect(completed.all == ["0"], "Cancellation must resume only its own drain waiter")
        try collector.pipe.fileHandleForWriting.close()
        let eofDeadline = ContinuousClock.now + .seconds(2)
        while completed.all.count < 3 && ContinuousClock.now < eofDeadline { await Task.yield() }
        #expect(Set(completed.all) == Set(["0", "1", "2"]))
        tasks.forEach { $0.cancel() }
        collector.close()
    }

    @Test func drainsARealProcessAndReportsEOF() async throws {
        let lines = Lines()
        let collector = PipeCollector { lines.append($0) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'a\\nb\\n'; printf 'tail-without-newline'"]
        process.standardOutput = collector.pipe
        try process.run()
        let status = await process.waitForTermination()
        await collector.waitForEOF()
        collector.close()
        #expect(status == 0)
        #expect(lines.all == ["a", "b", "tail-without-newline"])
        #expect(collector.text() == "a\nb\ntail-without-newline")
    }
}
