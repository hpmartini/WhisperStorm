import Foundation

/// Runs `operation`, but stops waiting for it after `seconds`: nil then.
/// Unlike a task group, this returns even when the operation ignores
/// cancellation (an actor busy loading a model does); the operation keeps
/// running and callers must ignore whatever it does afterwards.
func withDeadline<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let once = ResumeOnce<T?>()
    return await withCheckedContinuation { continuation in
        once.set(continuation)
        let work = Task { once.resume(await operation()) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
            once.resume(nil)
        }
    }
}

/// How long the live final Whisper pass may take before the live text is
/// kept instead: 20 s, plus a tenth of the recording for long dictations
/// (a pass normally takes a few percent of the audio's length).
func finalPassDeadline(recordingDuration: TimeInterval) -> TimeInterval {
    20 + recordingDuration / 10
}

/// Resumes a continuation with the first value only.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var done = false

    func set(_ continuation: CheckedContinuation<T, Never>) {
        let value: T? = lock.withLock {
            if done, let pending { self.pending = nil; return pending }
            self.continuation = continuation
            return nil
        }
        if let value { continuation.resume(returning: value) }
    }

    func resume(_ value: T) {
        let continuation: CheckedContinuation<T, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            if let continuation = self.continuation {
                self.continuation = nil
                return continuation
            }
            pending = value
            return nil
        }
        continuation?.resume(returning: value)
    }
}
