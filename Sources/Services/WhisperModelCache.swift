import Foundation
import whisper

/// Resident whisper.cpp weights: a `whisper_context` created without an
/// inference state. Inference never runs on this object directly — every
/// run allocates its own `whisper_state` from it (see `WhisperCppEngine`),
/// which is what keeps output identical to a freshly loaded model.
///
/// Deallocation frees the context. A `WhisperModel` is only ever released
/// after every state created from it has been freed: states are created and
/// freed inside the same call that holds the model lease.
final class WhisperModel: @unchecked Sendable {
    let context: OpaquePointer
    let key: WhisperModelCache.Key
    private let unloader: @Sendable (OpaquePointer) -> Void

    init(context: OpaquePointer, key: WhisperModelCache.Key, unloader: @escaping @Sendable (OpaquePointer) -> Void) {
        self.context = context
        self.key = key
        self.unloader = unloader
    }

    deinit {
        unloader(context)
    }
}

/// Keeps model weights loaded across jobs so a batch of short clips does not
/// pay the multi-hundred-megabyte read and Metal upload for every file.
///
/// Policy:
/// - Keyed by the model file's path, size, and mtime, so a replaced file with
///   the same name loads fresh.
/// - Capacity one: acquiring a different model evicts the previous one as
///   soon as it is not leased (the GPU slot serialises jobs, so two resident
///   multi-gigabyte models would only ever be waste).
/// - Leases: an entry is evictable only when no caller holds it.
/// - Eviction: model change, idle timeout after the last release, memory
///   pressure, and explicit `evictAll()`.
actor WhisperModelCache {
    struct Key: Hashable, Sendable {
        let path: String
        let size: Int64
        let modifiedNanoseconds: Int64
    }

    typealias Loader = @Sendable (URL) throws -> OpaquePointer
    typealias Unloader = @Sendable (OpaquePointer) -> Void

    static let shared = WhisperModelCache(monitorsMemoryPressure: true)

    private struct Entry {
        let model: WhisperModel
        var leases: Int
        var idleSince: ContinuousClock.Instant?
    }

    private let idleTimeout: Duration
    private let loader: Loader
    private let unloader: Unloader
    private var entries: [Key: Entry] = [:]
    private var idleSweep: Task<Void, Never>?
    private let memoryPressure: DispatchSourceMemoryPressure?

    /// - Parameters:
    ///   - idleTimeout: seconds a released model stays resident before it is
    ///     freed. Ten minutes covers the gap between queued jobs without
    ///     holding a gigabyte for an app that sits idle all afternoon.
    ///   - monitorsMemoryPressure: install a memory-pressure source that
    ///     frees idle models on warning/critical. Only the shared instance
    ///     does this; test caches stay inert.
    ///   - loader/unloader: test seams; production loads via whisper.cpp.
    init(
        idleTimeout: TimeInterval = 600,
        monitorsMemoryPressure: Bool = false,
        loader: @escaping Loader = WhisperModelCache.loadFromFile,
        unloader: @escaping Unloader = { whisper_free($0) }
    ) {
        self.idleTimeout = .seconds(idleTimeout)
        self.loader = loader
        self.unloader = unloader
        if monitorsMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical], queue: .global(qos: .utility))
            memoryPressure = source
            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task { await self.evictAll() }
            }
            source.resume()
        } else {
            memoryPressure = nil
        }
    }

    /// Identity of a model file: a replaced file with the same name must not
    /// be served from the cache.
    static func key(for url: URL) throws -> Key {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw WhisperCppError.modelLoadFailed(url.lastPathComponent)
        }
        return Key(
            path: url.path,
            size: Int64(info.st_size),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        )
    }

    /// Returns the resident model for `modelURL`, loading it if needed, and
    /// takes a lease. Every `acquire` must be paired with `release`.
    func acquire(modelURL: URL) throws -> WhisperModel {
        let key = try Self.key(for: modelURL)
        if var entry = entries[key] {
            entry.leases += 1
            entry.idleSince = nil
            entries[key] = entry
            return entry.model
        }
        evictIdle(except: key)
        let context = try loader(modelURL)
        let model = WhisperModel(context: context, key: key, unloader: unloader)
        entries[key] = Entry(model: model, leases: 1, idleSince: nil)
        return model
    }

    func release(_ model: WhisperModel) {
        guard var entry = entries[model.key] else { return }
        entry.leases = max(0, entry.leases - 1)
        if entry.leases == 0 {
            entry.idleSince = .now
            scheduleIdleSweep()
        }
        entries[model.key] = entry
    }

    /// Frees every model that is not currently leased.
    func evictAll() {
        evictIdle(except: nil)
    }

    func residentKeys() -> [Key] {
        Array(entries.keys)
    }

    private func evictIdle(except key: Key?) {
        for (candidate, entry) in entries where entry.leases == 0 && candidate != key {
            entries[candidate] = nil
        }
    }

    private func scheduleIdleSweep() {
        idleSweep?.cancel()
        idleSweep = Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            sweepExpired()
        }
    }

    private func sweepExpired() {
        let now = ContinuousClock.now
        for (key, entry) in entries where entry.leases == 0 {
            if let since = entry.idleSince, now - since >= idleTimeout {
                entries[key] = nil
            }
        }
    }

    /// whisper.cpp compiles its Metal shaders at runtime from ggml-metal.metal.
    /// SwiftPM ships that file in whisper_whisper.bundle, but the generated
    /// bundle accessor only looks at the .app root, where codesign forbids
    /// unsealed content — so the build script ships a self-contained copy
    /// (ggml-common.h inlined) in Contents/Resources and this points ggml at
    /// it. The test runner points at a self-contained development copy too;
    /// bare binaries without either resource fall back to whisper.cpp's normal
    /// backend discovery.
    private static let metalShaderPathConfigured: Void = {
        guard getenv("GGML_METAL_PATH_RESOURCES") == nil else { return }  // a user override wins
        guard let resources = Bundle.main.resourceURL,
            FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("ggml-metal.metal").path)
        else { return }
        setenv("GGML_METAL_PATH_RESOURCES", resources.path, 0)
    }()

    static let loadFromFile: Loader = { url in
        _ = metalShaderPathConfigured
        let params = whisper_context_default_params()
        guard let context = whisper_init_from_file_with_params_no_state(url.path, params) else {
            throw WhisperCppError.modelLoadFailed(url.lastPathComponent)
        }
        return context
    }
}
