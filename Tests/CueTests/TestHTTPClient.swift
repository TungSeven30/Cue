import Foundation
@testable import Cue

struct StubHTTPClient: HTTPClient {
    let data: Data
    let statusCode: Int

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

actor RecordingHTTPClient: HTTPClient {
    struct StubResponse: Sendable {
        let data: Data
        let statusCode: Int
    }

    private var responses: [StubResponse]
    private var requests: [URLRequest] = []

    init(responses: [StubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let stub = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (stub.data, response)
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}
