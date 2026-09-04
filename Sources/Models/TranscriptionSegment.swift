import Foundation

struct TranscriptionSegment: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let start: Double
    let end: Double
    var text: String
}
