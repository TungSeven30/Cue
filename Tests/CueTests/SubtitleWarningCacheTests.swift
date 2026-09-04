import Foundation
import Testing
@testable import Cue

@MainActor
struct SubtitleWarningCacheTests {
    private let key = SubtitleWarningCache.Key(jobID: UUID(), slot: .transcript)

    private func segment(_ id: Int, text: String = "fine", start: Double = 0, end: Double = 1) -> TranscriptionSegment {
        TranscriptionSegment(id: id, start: start, end: end, text: text)
    }

    @Test func rulesMatchTheOriginalFourWarnings() {
        #expect(SubtitleWarningCache.compute(segment(1, text: "   ")).map(\.message) == ["Empty text"])
        #expect(SubtitleWarningCache.compute(segment(2, start: 5, end: 5)).map(\.message) == ["Invalid timing"])
        #expect(SubtitleWarningCache.compute(segment(3, start: 0, end: 9)).map(\.message) == ["Long duration"])
        #expect(SubtitleWarningCache.compute(segment(4, text: String(repeating: "x", count: 91))).map(\.message) == ["Long subtitle text"])
        #expect(SubtitleWarningCache.compute(segment(5)).isEmpty)
        let everything = segment(6, text: String(repeating: " ", count: 100), start: 3, end: 2)
        #expect(SubtitleWarningCache.compute(everything).map(\.message) == ["Empty text", "Invalid timing"])
    }

    @Test func sameArrayIsNotReevaluated() {
        let cache = SubtitleWarningCache()
        let segments = [segment(1), segment(2, text: " "), segment(3)]
        let first = cache.warnings(for: segments, key: key)
        let again = cache.warnings(for: segments, key: key)
        #expect(cache.computeCount == 3)
        #expect(first == again)
        #expect(first.list.map(\.segmentID) == [2])
        #expect(first.bySegment[2]?.map(\.message) == ["Empty text"])
    }

    @Test func appendedBatchOnlyEvaluatesTheSuffix() {
        let cache = SubtitleWarningCache()
        var segments = (1...100).map { segment($0) }
        _ = cache.warnings(for: segments, key: key)
        #expect(cache.computeCount == 100)
        segments.append(contentsOf: [segment(101, text: ""), segment(102)])
        let result = cache.warnings(for: segments, key: key)
        #expect(cache.computeCount == 102)
        #expect(result.list.map(\.segmentID) == [101])
        // And the appended array is now the identity fast path.
        _ = cache.warnings(for: segments, key: key)
        #expect(cache.computeCount == 102)
    }

    @Test func editedSegmentForcesARecomputeWithCorrectResults() {
        let cache = SubtitleWarningCache()
        var segments = [segment(1), segment(2), segment(3)]
        _ = cache.warnings(for: segments, key: key)
        segments[1].text = ""
        let result = cache.warnings(for: segments, key: key)
        #expect(cache.computeCount == 6)
        #expect(result.list.map(\.segmentID) == [2])
        segments[1].text = "fixed"
        #expect(cache.warnings(for: segments, key: key).list.isEmpty)
    }

    @Test func differentKeysDoNotShareEntriesAndSelectionChangeDropsTheOldJob() {
        let cache = SubtitleWarningCache()
        let other = SubtitleWarningCache.Key(jobID: key.jobID, slot: .translation)
        let segments = [segment(1, text: "")]
        #expect(cache.warnings(for: segments, key: key).list.count == 1)
        #expect(cache.warnings(for: segments, key: other).list.count == 1)
        #expect(cache.computeCount == 2)
        // A different job evicts both slots of the previous one.
        let elsewhere = SubtitleWarningCache.Key(jobID: UUID(), slot: .transcript)
        _ = cache.warnings(for: segments, key: elsewhere)
        _ = cache.warnings(for: segments, key: key)
        #expect(cache.computeCount == 4)
    }

    @Test func emptyArraysShareTheEmptyResult() {
        let cache = SubtitleWarningCache()
        #expect(cache.warnings(for: [], key: key) == .empty)
        #expect(cache.warnings(for: [], key: key) == .empty)
        #expect(cache.computeCount == 0)
    }
}

@Suite struct LogTailTests {
    private func reference(_ log: String, count: Int) -> (lines: [String], truncated: Bool) {
        let all = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard all.count > count else { return (all, false) }
        return (Array(all.suffix(count)), true)
    }

    @Test func matchesTheSplitBasedReference() {
        let samples: [String] = [
            "",
            "one",
            "one\n",
            "one\ntwo",
            "one\n\nthree\n",
            (1...399).map { "line \($0)" }.joined(separator: "\n"),
            (1...400).map { "line \($0)" }.joined(separator: "\n"),
            (1...401).map { "line \($0)" }.joined(separator: "\n"),
            (1...401).map { "line \($0)" }.joined(separator: "\n") + "\n",
            (1...5_000).map { "línea \($0) 日本語" }.joined(separator: "\n"),
            "\n\n\n",
        ]
        for sample in samples {
            for count in [1, 2, 400] {
                let fast = LogTail.lastLines(of: sample, count: count)
                let slow = reference(sample, count: count)
                #expect(fast.lines == slow.lines, "count \(count) on \(sample.prefix(20))")
                #expect(fast.truncated == slow.truncated, "count \(count) on \(sample.prefix(20))")
            }
        }
    }
}
