import Foundation

struct SubtitleQualityWarning: Identifiable, Hashable {
    let id = UUID()
    let segmentID: Int
    let message: String
}
