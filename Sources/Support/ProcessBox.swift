import Foundation

/// Thread-safe holder for a child `Process` that a cancellation handler
/// may need to stop from any thread. Termination is graceful first and
/// forceful after a grace period: Python only runs signal handlers between
/// bytecodes, so a helper deep inside native inference code can miss SIGTERM
/// entirely, and ffmpeg can sit in a decoder call.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcess: Process?
    private let killGrace: TimeInterval

    init(killGrace: TimeInterval = 3) {
        self.killGrace = killGrace
    }

    var process: Process? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedProcess
        }
        set {
            lock.lock()
            storedProcess = newValue
            lock.unlock()
        }
    }

    func terminate() {
        lock.lock()
        let process = storedProcess
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        let grace = killGrace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
