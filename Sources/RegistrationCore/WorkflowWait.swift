import Foundation

public enum WorkflowWait {
    /// Check again at the deadline so pages becoming ready during the last interval are accepted.
    @MainActor
    public static func until(timeout: TimeInterval, pollEvery: TimeInterval = 1,
                             condition: () async throws -> Bool) async throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            if try await condition() { return true }
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { return false }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, max(0.001, pollEvery), 3_600) * 1_000_000_000))
        }
    }
}
