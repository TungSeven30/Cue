import Foundation
import Testing
@testable import Cue

private actor ControlledDiagnostics: EnvironmentDiagnosing {
    private var requests: Set<String> = []
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    func run(
        translationAPIKey: String,
        translationProvider: TranslationProvider,
        selectedBackend: WhisperBackend
    ) async -> [EnvironmentDiagnostic] {
        requests.insert(translationAPIKey)
        await withCheckedContinuation { continuation in
            continuations[translationAPIKey, default: []].append(continuation)
        }
        return [
            EnvironmentDiagnostic(
                id: translationAPIKey,
                title: translationAPIKey,
                detail: translationAPIKey,
                recovery: "",
                state: .passed
            )
        ]
    }

    func waitUntilRequested(_ key: String) async {
        while !requests.contains(key) {
            await Task.yield()
        }
    }

    func complete(_ key: String) {
        let pending = continuations.removeValue(forKey: key) ?? []
        pending.forEach { $0.resume() }
    }
}

@MainActor
struct AppModelDiagnosticsTests {
    @Test func anOlderDiagnosticsRunCannotOverwriteTheNewestResult() async throws {
        let suiteName = "app-model-diagnostics-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(
            defaults: defaults,
            readSecret: { _ in nil },
            writeSecret: { _, _ in true }
        )
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let diagnostics = ControlledDiagnostics()
        let model = AppModel(
            settings: settings,
            jobStore: JobStore(baseURL: base),
            diagnosticsService: diagnostics
        )

        // Finish the launch-time request before arranging the overlap under
        // test, so there are exactly two controlled runs in flight.
        await diagnostics.waitUntilRequested("")
        await diagnostics.complete("")

        settings.openAIAPIKey = "slow"
        model.runDiagnostics()
        await diagnostics.waitUntilRequested("slow")
        settings.openAIAPIKey = "fast"
        model.runDiagnostics()
        await diagnostics.waitUntilRequested("fast")

        await diagnostics.complete("fast")
        for _ in 0..<10_000 {
            if model.diagnostics.map(\.id) == ["fast"] { break }
            await Task.yield()
        }
        await diagnostics.complete("slow")
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(model.diagnostics.map(\.id) == ["fast"])
        #expect(!model.isRunningDiagnostics)
    }
}
