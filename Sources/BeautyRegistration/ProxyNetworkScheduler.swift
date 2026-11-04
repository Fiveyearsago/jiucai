import Foundation

/// Reserve foreground access while limiting background traffic throughout a registration run.
@MainActor
final class ProxyNetworkScheduler {
    private var foregroundWaiting = 0
    private var foregroundActive = false
    private var backgroundCancellations: [UUID: () -> Void] = [:]
    private var backgroundOrder: [UUID] = []
    private var interrupted: Set<UUID> = []
    private var registrationConcurrency: Int?

    /// Nil restores idle batch concurrency; zero retains exclusive foreground requests.
    func setRegistrationConcurrency(_ limit: Int?) {
        registrationConcurrency = limit.map { min(3, max(0, $0)) }
        interruptExcessBackground(keeping: backgroundLimit)
    }

    private var foregroundBackgroundLimit: Int { registrationConcurrency ?? 0 }

    private var backgroundLimit: Int {
        if let registrationConcurrency, registrationConcurrency > 0 { return registrationConcurrency }
        return foregroundActive || foregroundWaiting > 0 ? 0 : Int.max
    }

    private func interruptExcessBackground(keeping limit: Int) {
        let active = backgroundOrder.filter { !interrupted.contains($0) }
        for id in active.dropFirst(limit) {
            interrupted.insert(id)
            backgroundCancellations[id]?()
        }
    }

    func foreground<Value>(whenReady: () -> Bool = { true },
                           _ operation: () async throws -> Value) async throws -> Value {
        while true {
            try Task.checkCancellation()
            while !whenReady() { try await Task.sleep(nanoseconds: 20_000_000) }
            foregroundWaiting += 1
            var acquired = false
            defer {
                if acquired { foregroundActive = false }
                else { foregroundWaiting -= 1 }
            }
            // Excess probes retry later; admitted probes never hold up a foreground request.
            interruptExcessBackground(keeping: foregroundBackgroundLimit)
            while foregroundActive || backgroundCancellations.count > foregroundBackgroundLimit {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try Task.checkCancellation()
            // A pause during draining releases admission so background work can continue.
            guard whenReady() else { continue }
            foregroundWaiting -= 1; foregroundActive = true; acquired = true
            return try await operation()
        }
    }

    func background<Value>(_ operation: @escaping () async throws -> Value) async throws -> Value {
        while true {
            try Task.checkCancellation()
            while foregroundWaiting > 0 || backgroundCancellations.count >= backgroundLimit {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try Task.checkCancellation()
            let id = UUID()
            let work = Task(priority: .utility) {
                try Task.checkCancellation()
                return try await operation()
            }
            backgroundCancellations[id] = { work.cancel() }
            backgroundOrder.append(id)
            let result = await withTaskCancellationHandler(operation: {
                await work.result
            }, onCancel: { work.cancel() })
            backgroundCancellations.removeValue(forKey: id)
            backgroundOrder.removeAll { $0 == id }
            let wasInterrupted = interrupted.remove(id) != nil
            try Task.checkCancellation()
            if wasInterrupted { continue }
            return try result.get()
        }
    }
}
