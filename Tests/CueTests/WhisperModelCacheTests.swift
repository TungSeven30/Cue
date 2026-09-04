import Foundation
import Testing
@testable import Cue

/// Cache policy tests with a fake loader: no model file, no whisper.cpp.
@Suite struct WhisperModelCacheTests {
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var loadedNames: [String] = []
        private var freeCount = 0

        func recordLoad(_ name: String) {
            lock.withLock { loadedNames.append(name) }
        }

        func recordFree() {
            lock.withLock { freeCount += 1 }
        }

        var loads: [String] { lock.withLock { loadedNames } }
        var frees: Int { lock.withLock { freeCount } }
    }

    private func makeFile(_ name: String, contents: String = "weights") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-model-\(UUID().uuidString)-\(name).bin")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Polls instead of sleeping a fixed amount: a loaded CI runner can delay
    /// the sweep task well past the idle timeout.
    private func waitUntilEvicted(_ cache: WhisperModelCache, within seconds: Double = 10) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await cache.residentKeys().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await cache.residentKeys().isEmpty
    }

    private func makeCache(idleTimeout: TimeInterval = 600, ledger: Ledger) -> WhisperModelCache {
        WhisperModelCache(
            idleTimeout: idleTimeout,
            loader: { url in
                ledger.recordLoad(url.lastPathComponent)
                // Never dereferenced: the fake unloader only counts.
                return OpaquePointer(bitPattern: 0x10)!
            },
            unloader: { _ in ledger.recordFree() }
        )
    }

    @Test func sameModelIsLoadedOnceAndSharedAcrossLeases() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let url = try makeFile("a")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await cache.acquire(modelURL: url)
        await cache.release(first)
        let second = try await cache.acquire(modelURL: url)
        await cache.release(second)

        #expect(ledger.loads.count == 1)
        #expect(first === second)
        #expect(ledger.frees == 0)
    }

    @Test func acquiringADifferentModelEvictsTheIdleOne() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let a = try makeFile("a")
        let b = try makeFile("b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        // Acquire/release inside helpers so this test holds no reference to
        // the evicted model: the free happens when the last reference drops.
        func cycle(_ url: URL) async throws {
            let model = try await cache.acquire(modelURL: url)
            await cache.release(model)
        }
        try await cycle(a)
        try await cycle(b)

        #expect(await cache.residentKeys().map(\.path) == [b.path])
        #expect(ledger.frees == 1)
        #expect(ledger.loads == [a.lastPathComponent, b.lastPathComponent])
    }

    @Test func leasedModelSurvivesEvictionUntilReleased() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let url = try makeFile("a")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = try await cache.acquire(modelURL: url)
        await cache.evictAll()
        #expect(await cache.residentKeys().count == 1, "a leased model must not be freed under the caller")
        #expect(ledger.frees == 0)

        await cache.release(model)
        await cache.evictAll()
        #expect(await cache.residentKeys().isEmpty)
        // The WhisperModel object is still referenced by `model` here, so its
        // deinit (and the free) happens when this test's reference drops.
    }

    @Test func aDifferentModelDoesNotEvictALeasedOne() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let a = try makeFile("a")
        let b = try makeFile("b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let modelA = try await cache.acquire(modelURL: a)
        let modelB = try await cache.acquire(modelURL: b)
        #expect(await cache.residentKeys().count == 2)
        await cache.release(modelA)
        await cache.release(modelB)
    }

    @Test func replacedModelFileInvalidatesTheEntry() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let url = try makeFile("a")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await cache.acquire(modelURL: url)
        await cache.release(first)
        // Same path, different bytes: the size changes, and so does the key.
        try Data("different weights entirely".utf8).write(to: url)
        let second = try await cache.acquire(modelURL: url)
        await cache.release(second)

        #expect(ledger.loads.count == 2)
        #expect(first !== second)
        #expect(await cache.residentKeys().count == 1)
    }

    @Test func missingModelFileFailsBeforeLoading() async throws {
        let ledger = Ledger()
        let cache = makeCache(ledger: ledger)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).bin")
        await #expect(throws: WhisperCppError.self) {
            _ = try await cache.acquire(modelURL: missing)
        }
        #expect(ledger.loads.isEmpty)
    }

    @Test func idleTimeoutFreesAReleasedModel() async throws {
        let ledger = Ledger()
        let cache = makeCache(idleTimeout: 0.2, ledger: ledger)
        let url = try makeFile("a")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = try await cache.acquire(modelURL: url)
        await cache.release(model)

        #expect(await waitUntilEvicted(cache))
    }

    @Test func reacquiringBeforeTheIdleTimeoutKeepsTheModel() async throws {
        let ledger = Ledger()
        let cache = makeCache(idleTimeout: 0.3, ledger: ledger)
        let url = try makeFile("a")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = try await cache.acquire(modelURL: url)
        await cache.release(model)
        // Re-lease straight away: the sweep scheduled by the release must be
        // cancelled, and a leased model survives however long we wait.
        let again = try await cache.acquire(modelURL: url)
        try await Task.sleep(for: .milliseconds(900))
        #expect(await cache.residentKeys().count == 1, "a lease taken before the sweep must cancel it")
        #expect(ledger.loads.count == 1)
        await cache.release(again)
        #expect(await waitUntilEvicted(cache), "released again, the idle timeout frees it")
        #expect(ledger.loads.count == 1)
    }
}
