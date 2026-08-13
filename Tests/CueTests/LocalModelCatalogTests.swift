import Foundation
import Testing
@testable import Cue

struct LocalModelCatalogTests {
    private let openAISample = Data(
        """
        {
          "object": "list",
          "data": [
            {"id": "qwen/qwen3.6-35b-a3b", "object": "model", "owned_by": "organization_owner"},
            {"id": "text-embedding-nomic-embed-text-v1.5", "object": "model", "owned_by": "organization_owner"},
            {"id": "Dolphin-Mistral-24B", "object": "model", "owned_by": "organization_owner"},
            {"id": "qwen/qwen3.6-35b-a3b", "object": "model", "owned_by": "duplicate"},
            {"object": "model"}
          ]
        }
        """.utf8
    )

    private let lmStudioSample = Data(
        """
        {
          "models": [
            {
              "type": "llm",
              "publisher": "qwen",
              "key": "qwen/qwen3.6-35b-a3b",
              "loaded_instances": []
            },
            {
              "type": "llm",
              "publisher": "DavidAU",
              "key": "qwen3.6-27b",
              "loaded_instances": [
                {"id": "qwen3.6-27b"},
                {"id": "qwen3.6-27b:2"},
                {"id": "qwen3.6-27b"}
              ]
            },
            {
              "type": "embedding",
              "publisher": "nomic-ai",
              "key": "nomic-embed-text",
              "loaded_instances": [{"id": "nomic-embed-text"}]
            }
          ]
        }
        """.utf8
    )

    @Test func bareAddressUsesOpenAIModelsEndpoint() throws {
        let url = try LocalModelCatalog.modelsURL(for: "http://192.168.0.196:1234")
        #expect(url.absoluteString == "http://192.168.0.196:1234/v1/models")

        let trailingSlash = try LocalModelCatalog.modelsURL(for: "http://192.168.0.196:1234/")
        #expect(trailingSlash.absoluteString == "http://192.168.0.196:1234/v1/models")
    }

    @Test func explicitAPIPathAndTrailingSlashArePreserved() throws {
        let v1 = try LocalModelCatalog.modelsURL(for: "http://localhost:1234/v1/")
        #expect(v1.absoluteString == "http://localhost:1234/v1/models")

        let custom = try LocalModelCatalog.modelsURL(for: "https://studio.example.test/api/v1")
        #expect(custom.absoluteString == "https://studio.example.test/api/v1/models")
    }

    @Test func lmStudioEndpointUsesServerOrigin() throws {
        let bare = try LocalModelCatalog.lmStudioModelsURL(for: "http://192.168.0.196:1234")
        #expect(bare.absoluteString == "http://192.168.0.196:1234/api/v1/models")

        let v1 = try LocalModelCatalog.lmStudioModelsURL(for: "http://localhost:1234/v1/")
        #expect(v1.absoluteString == "http://localhost:1234/api/v1/models")
    }

    @Test func invalidAddressIsRejected() {
        #expect(throws: LocalModelCatalogError.self) {
            _ = try LocalModelCatalog.modelsURL(for: "192.168.0.196:1234")
        }
        #expect(throws: LocalModelCatalogError.self) {
            _ = try LocalModelCatalog.modelsURL(for: "file:///tmp/models")
        }
    }

    @Test func parseReturnsUniqueGenerationModelsSortedByID() throws {
        let models = try LocalModelCatalog.parseOpenAI(openAISample)
        #expect(models.map(\.id) == ["Dolphin-Mistral-24B", "qwen/qwen3.6-35b-a3b"])
        #expect(models.last?.ownedBy == "organization_owner")
        #expect(models.allSatisfy { $0.availability == .advertised })
    }

    @Test func parseLMStudioReturnsOnlyUniqueRunningLLMInstances() throws {
        let models = try LocalModelCatalog.parseLMStudio(lmStudioSample)
        #expect(models.map(\.id) == ["qwen3.6-27b", "qwen3.6-27b:2"])
        #expect(models.first?.ownedBy == "DavidAU")
        #expect(models.allSatisfy { $0.availability == .running })
    }

    @Test func parseRejectsMissingGenerationModels() {
        let embeddingsOnly = Data(#"{"data":[{"id":"nomic-embed-text"}]}"#.utf8)
        #expect(throws: LocalModelCatalogError.self) {
            _ = try LocalModelCatalog.parseOpenAI(embeddingsOnly)
        }

        let stoppedLMStudioModels = Data(
            #"{"models":[{"type":"llm","loaded_instances":[]}]}"#.utf8
        )
        #expect(throws: LocalModelCatalogError.self) {
            _ = try LocalModelCatalog.parseLMStudio(stoppedLMStudioModels)
        }
    }

    @Test func fetchUsesConfiguredNetworkAddress() async throws {
        let client = RecordingHTTPClient(responses: [.init(data: lmStudioSample, statusCode: 200)])
        let models = try await LocalModelCatalog.fetch(
            endpoint: "http://192.168.0.196:1234",
            httpClient: client
        )
        #expect(models.count == 2)
        #expect(await client.capturedRequests().first?.url?.absoluteString == "http://192.168.0.196:1234/api/v1/models")
    }

    @Test func fetchFallsBackToOpenAICompatibleCatalog() async throws {
        let client = RecordingHTTPClient(
            responses: [
                .init(data: Data(), statusCode: 404),
                .init(data: openAISample, statusCode: 200),
            ]
        )
        let models = try await LocalModelCatalog.fetch(
            endpoint: "http://localhost:11434/v1",
            httpClient: client
        )

        #expect(models.count == 2)
        #expect(models.allSatisfy { $0.availability == .advertised })
        let requests = await client.capturedRequests()
        #expect(requests.map(\.url?.absoluteString) == [
            "http://localhost:11434/api/v1/models",
            "http://localhost:11434/v1/models",
        ])
    }

    @Test func fetchFallsBackWhenAnotherServerUsesADifferentModelsEnvelope() async throws {
        let genericEnvelope = Data(#"{"models":[{"id":"not-lm-studio"}]}"#.utf8)
        let client = RecordingHTTPClient(
            responses: [
                .init(data: genericEnvelope, statusCode: 200),
                .init(data: openAISample, statusCode: 200),
            ]
        )

        let models = try await LocalModelCatalog.fetch(
            endpoint: "http://localhost:8000",
            httpClient: client
        )
        #expect(models.count == 2)
        #expect(await client.capturedRequests().count == 2)
    }

    @Test func fetchExplainsNonSuccessStatus() async {
        do {
            _ = try await LocalModelCatalog.fetch(
                endpoint: "http://localhost:1234/v1",
                httpClient: StubHTTPClient(data: Data(), statusCode: 503)
            )
            Issue.record("Expected the model request to fail")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 503"))
        }
    }
}
