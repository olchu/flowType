import Foundation

/// Opening or closing a microphone can hang for good. When a device goes
/// away mid-query, as an iPhone's Continuity microphone does, AVFAudio keeps
/// asking CoreAudio for its sub-devices in a loop with no way out. So such
/// calls run on a thread of their own here and are given up on after a
/// while. That thread can't be stopped and spins until the process exits,
/// so each stall is announced and the app restarts to get rid of it.
nonisolated enum AudioInputStall {
    /// Posted on the main thread when a call is given up on.
    static let notification = Notification.Name("AudioInputStall")

    /// A healthy microphone opens in well under a tenth of this.
    private static let timeout: DispatchTimeInterval = .seconds(2)

    struct Error: LocalizedError {
        var errorDescription: String? {
            "macOS stopped answering for the microphone. Flow Type restarts to bring it back."
        }
    }

    /// The result of `work`, which runs on a background thread while the
    /// caller waits for it; throws `Error` if it takes too long. A result
    /// that comes after that goes to `discard`, as nobody takes it anymore.
    static func run<T>(
        _ work: @escaping @Sendable () throws -> T,
        discardingLateResult discard: (@Sendable (T) -> Void)? = nil
    ) throws -> T {
        let call = Call<T>(discard: discard)
        DispatchQueue.global(qos: .userInitiated).async {
            call.finish(with: Result(catching: work))
        }

        guard let result = call.wait(for: timeout) else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: notification, object: nil)
            }
            throw Error()
        }
        return try result.get()
    }

    private final class Call<T>: @unchecked Sendable {
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private let discard: ((T) -> Void)?
        private var result: Result<T, Swift.Error>?
        private var isAbandoned = false

        init(discard: ((T) -> Void)?) {
            self.discard = discard
        }

        func finish(with result: Result<T, Swift.Error>) {
            let isLate = lock.withLock {
                self.result = result
                return isAbandoned
            }
            if isLate, case .success(let value) = result {
                discard?(value)
            }
            finished.signal()
        }

        /// Nil when the call didn't finish in time.
        func wait(for timeout: DispatchTimeInterval) -> Result<T, Swift.Error>? {
            _ = finished.wait(timeout: .now() + timeout)
            return lock.withLock {
                if result == nil {
                    isAbandoned = true
                }
                return result
            }
        }
    }
}
