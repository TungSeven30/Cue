import Foundation

/// Shared by services that spawn a `Process` and need to `await` its exit
/// (TranscriptionService, BurnInService) instead of using the completion
/// handler directly.
extension Process {
    func waitForTermination() async -> Int32 {
        await withCheckedContinuation { continuation in
            let resumer = ProcessTerminationResumer(continuation: continuation)
            terminationHandler = { process in
                resumer.resume(process.terminationStatus)
            }
            if !isRunning {
                resumer.resume(terminationStatus)
            }
        }
    }
}

private final class ProcessTerminationResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Int32, Never>

    init(continuation: CheckedContinuation<Int32, Never>) {
        self.continuation = continuation
    }

    func resume(_ status: Int32) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume(returning: status)
    }
}
