import Foundation

struct SubtitleQualityWarning: Identifiable, Hashable {
    let segmentID: Int
    let message: String

    // Derived identity keeps the id stable across recomputations of the
    // warnings array, so SwiftUI does not churn the rows on every refresh.
    var id: String { "\(segmentID)-\(message)" }
}
