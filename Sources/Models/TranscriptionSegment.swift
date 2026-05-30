import Foundation

struct TranscriptionSegment: Codable, Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    var text: String
}
