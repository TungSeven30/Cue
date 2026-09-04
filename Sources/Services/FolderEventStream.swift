import CoreServices
import Foundation

/// A recursive change notification for one folder, built on FSEvents. A
/// kqueue source on a directory descriptor only reports changes to that
/// directory's own entries; FSEvents with file-level events covers every
/// subfolder, which is where episodic drops usually land.
///
/// Only "something changed" is delivered — the scan that follows is what
/// decides whether any file is ready, so coalescing is free and safe.
final class FolderEventStream {
    private final class Box {
        let onChange: @Sendable () -> Void

        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }
    }

    private let box: Box
    private var stream: FSEventStreamRef?

    /// - Parameters:
    ///   - latency: seconds FSEvents may coalesce before calling back; a
    ///     copy in progress produces a burst of events, and the scan that
    ///     follows applies its own stability gate anyway.
    ///   - queue: where `onChange` runs; callers hop to their own actor.
    init?(path: String, latency: TimeInterval, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        box = Box(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents) | UInt32(kFSEventStreamCreateFlagNoDefer)
        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(flags)
            )
        else { return nil }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
    }

    /// Stops delivery and releases the stream. Safe to call more than once;
    /// runs in `deinit` too, so the unretained box can never be called after
    /// it is gone.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
