import Foundation

/// The last `count` lines of an append-only log, found by walking the UTF-8
/// bytes backwards, so showing the tail of a 200 KB log costs the tail, not
/// the whole string, on every progress tick.
enum LogTail {
    static func lastLines(of log: String, count: Int) -> (lines: [String], truncated: Bool) {
        guard count > 0 else { return ([], !log.isEmpty) }
        let utf8 = log.utf8
        // A trailing newline terminates the last line rather than starting an
        // empty one, matching `split(omittingEmptySubsequences: false)`, which
        // yields a final empty element in that case — counted as a line here
        // too, so the two agree on `truncated`.
        var newlines = 0
        var cut: String.Index? = nil
        var index = utf8.endIndex
        while index > utf8.startIndex {
            index = utf8.index(before: index)
            if utf8[index] == UInt8(ascii: "\n") {
                newlines += 1
                if newlines == count {
                    cut = utf8.index(after: index)
                    break
                }
            }
        }
        guard let cut else {
            // Fewer than `count` newlines: everything fits.
            return (log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), false)
        }
        let tail = log[cut...]
        return (tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), true)
    }
}
