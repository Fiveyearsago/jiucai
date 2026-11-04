import XCTest
import RegistrationCore
@testable import BeautyRegistration

@MainActor
final class ProxyNetworkSchedulerTests: XCTestCase {
    private func until(_ condition: () -> Bool) async throws {
        let ready = try await WorkflowWait.until(timeout: 2, pollEvery: 0.01) { condition() }
        XCTAssertTrue(ready)
    }

    func testOneToThreeBackgroundSlotsRemainAvailableDuringForegroundRequests() async throws {
        for limit in 1...3 {
            let scheduler = ProxyNetworkScheduler()
            scheduler.setRegistrationConcurrency(limit)
            var active = 0
            var peak = 0
            var release = false
            let probes = (0..<6).map { _ in Task {
                try await scheduler.background {
                    active += 1; peak = max(peak, active)
                    defer { active -= 1 }
                    _ = try await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { release }
                    return 10
                }
            } }
            defer { release = true; probes.forEach { $0.cancel() } }
            try await until { active == limit }
            let foreground = try await scheduler.foreground { active }
            XCTAssertEqual(foreground, limit, "Foreground must start without waiting for admitted probes")
            release = true
            for probe in probes { let value = try await probe.value; XCTAssertEqual(value, 10) }
            XCTAssertEqual(peak, limit, "The limit also applies between foreground requests")
        }
    }

    func testChangingLiveLimitRetriesExcessProbesAndEndingRunRestoresConcurrency() async throws {
        let scheduler = ProxyNetworkScheduler()
        scheduler.setRegistrationConcurrency(3)
        var active = 0
        var release = false
        let probes = (0..<6).map { _ in Task {
            try await scheduler.background {
                active += 1
                defer { active -= 1 }
                _ = try? await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { release }
                return Task.isCancelled ? -1 : 10
            }
        } }
        defer { release = true; probes.forEach { $0.cancel() } }
        try await until { active == 3 }
        scheduler.setRegistrationConcurrency(1)
        try await until { active == 1 }
        let foreground = try await scheduler.foreground { active }
        XCTAssertEqual(foreground, 1)
        scheduler.setRegistrationConcurrency(2)
        try await until { active == 2 }
        scheduler.setRegistrationConcurrency(nil)
        try await until { active == 6 }
        release = true
        for probe in probes {
            let value = try await probe.value
            XCTAssertEqual(value, 10, "Excess probes must retry instead of returning their cancellation result")
        }
    }

    func testCancellingQueuedProbeDoesNotConsumeLimitedSlot() async throws {
        let scheduler = ProxyNetworkScheduler()
        scheduler.setRegistrationConcurrency(1)
        var active = false
        var release = false
        let held = Task { try await scheduler.background {
            active = true
            _ = try await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { release }
            return 1
        } }
        defer { release = true; held.cancel() }
        try await until { active }
        let queued = Task { try await scheduler.background { XCTFail("Queued probe was cancelled"); return 2 } }
        await Task.yield()
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Queued cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        release = true
        _ = try await held.value
        let resumed = try await scheduler.background { 3 }
        XCTAssertEqual(resumed, 3)
    }

    func testCancelledBackgroundRequestReleasesConnectionForForeground() async throws {
        let scheduler = ProxyNetworkScheduler()
        var started = false
        let task = Task {
            try await scheduler.background {
                started = true
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
        }
        try await until { started }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must not return a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let value = try await scheduler.foreground { 2 }
        XCTAssertEqual(value, 2)
    }

    func testCancellingWaitingForegroundRequestAllowsInterruptedProbeToResume() async throws {
        let scheduler = ProxyNetworkScheduler()
        var attempts = 0
        var cancellationObserved = false
        var releaseCleanup = false
        let background = Task {
            try await scheduler.background {
                attempts += 1
                if attempts == 1 {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch {
                        cancellationObserved = true
                        while !releaseCleanup { await Task.yield() }
                    }
                    return 1
                }
                return 2
            }
        }
        defer { releaseCleanup = true; background.cancel() }
        try await until { attempts == 1 }
        let foreground = Task {
            try await scheduler.foreground { XCTFail("Cancelled waiter must not start a request"); return 0 }
        }
        try await until { cancellationObserved }
        foreground.cancel()
        do { _ = try await foreground.value; XCTFail("Wait must respect cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        releaseCleanup = true
        let result = try await background.value
        XCTAssertEqual(result, 2)
        XCTAssertEqual(attempts, 2)
    }
}
