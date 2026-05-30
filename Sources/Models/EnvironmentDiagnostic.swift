import Foundation

enum DiagnosticState: String, Codable {
    case passed
    case warning
    case failed

    var label: String {
        switch self {
        case .passed:
            return "OK"
        case .warning:
            return "Warning"
        case .failed:
            return "Missing"
        }
    }
}

struct EnvironmentDiagnostic: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var detail: String
    var recovery: String
    var state: DiagnosticState
}
