import XCTest
@testable import RegistrationCore

final class WorkflowWaitTests: XCTestCase {
    @MainActor
    func testPageReadyDuringLastPollingIntervalIsAccepted() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let ready = try await WorkflowWait.until(timeout: 0.1, pollEvery: 0.1) {
            ProcessInfo.processInfo.systemUptime - started >= 0.05
        }
        XCTAssertTrue(ready)
    }

    @MainActor
    func testUnreadyPageTimesOut() async throws {
        let ready = try await WorkflowWait.until(timeout: 0.02) { false }
        XCTAssertFalse(ready)
    }

    @MainActor
    func testCancellationStopsBeforeCallingCondition() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkflowWait.until(timeout: 10) {
                XCTFail("Cancelled workflows must not inspect or operate on the page")
                return true
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
