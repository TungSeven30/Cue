import Foundation

/// Small network boundary shared by API-backed services. Production uses
/// URLSession; tests can provide deterministic responses without installing a
/// global URLProtocol or reaching the internet.
protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
