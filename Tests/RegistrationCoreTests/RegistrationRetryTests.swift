import XCTest
@testable import RegistrationCore

final class RegistrationRetryTests: XCTestCase {
    @MainActor
    func testErrorsSwitchToNextProxyAndRetrySameAccountUntilSuccess() async throws {
        let proxies = (0..<3).map { ProxyEntry(host: "retry\($0).invalid", port: 1080) }
        let record = AccountRecord(username: "fixture001", email: "fixture001@test.invalid")
        var attempts: [(UUID, UUID)] = []
        var failures: [UUID] = []
        try await RegistrationRetry.run(selectProxy: { previous, excluded in
            XCTAssertEqual(excluded, Set(failures))
            XCTAssertEqual(previous, failures.last)
            return proxies.first { !excluded.contains($0.id) }
        }, attempt: { proxy in
            let proxy = try XCTUnwrap(proxy)
            attempts.append((record.id, proxy.id))
            if proxy.id != proxies.last?.id { throw ClientError.message("网页无法访问") }
        }, shouldRetry: { true }, onRetry: { proxy, _ in failures.append(proxy.id) })

        XCTAssertEqual(attempts.map { $0.0 }, Array(repeating: record.id, count: 3))
        XCTAssertEqual(attempts.map { $0.1 }, proxies.map(\.id))
        XCTAssertEqual(failures, Array(proxies.prefix(2)).map(\.id))
    }

    @MainActor
    func testUnknownSubmissionAndStorageFailuresStopWithoutAnotherAttempt() async {
        for reason in ["提交结果未知", "记录写入失败", "账号已成功"] {
            var selections = 0
            var attempts = 0
            do {
                try await RegistrationRetry.run(selectProxy: { _, _ in
                    selections += 1
                    return ProxyEntry(host: "stop.invalid", port: 1080)
                }, attempt: { _ in
                    attempts += 1
                    throw ClientError.message(reason)
                }, shouldRetry: { false }, onRetry: { _, _ in XCTFail("This failure must not retry") })
                XCTFail("The original error must propagate")
            } catch {
                XCTAssertEqual(error.localizedDescription, reason)
            }
            XCTAssertEqual(selections, 1)
            XCTAssertEqual(attempts, 1)
        }
    }

    @MainActor
    func testUserCancellationNeverSwitchesProxy() async {
        var selections = 0
        do {
            try await RegistrationRetry.run(selectProxy: { _, _ in
                selections += 1
                return ProxyEntry(host: "cancel.invalid", port: 1080)
            }, attempt: { _ in throw CancellationError() }, shouldRetry: { true },
               onRetry: { _, _ in XCTFail("Cancellation must stop immediately") })
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(selections, 1)
    }

    @MainActor
    func testCancellationWhileSelectingDoesNotStartRegistration() async {
        var attempts = 0
        let task = Task {
            try await RegistrationRetry.run(selectProxy: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return ProxyEntry(host: "cancel-selection.invalid", port: 1080)
            }, attempt: { _ in attempts += 1 }, shouldRetry: { true }, onRetry: { _, _ in })
        }
        do {
            try await task.value
            XCTFail("Cancellation must stop before registration starts")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 0)
    }

    @MainActor
    func testPoolExhaustionStopsWithoutRepeatingFailedProxy() async {
        let proxy = ProxyEntry(host: "only.invalid", port: 1080)
        var attempts = 0
        do {
            try await RegistrationRetry.run(selectProxy: { _, excluded in
                if !excluded.isEmpty { throw ClientError.message("代理已耗尽") }
                return proxy
            }, attempt: { _ in attempts += 1; throw ClientError.message("网页错误") },
               shouldRetry: { true }, onRetry: { _, _ in })
            XCTFail("Exhaustion must propagate")
        } catch { XCTAssertEqual(error.localizedDescription, "代理已耗尽") }
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testDirectConnectionErrorDoesNotRetry() async {
        var attempts = 0
        do {
            try await RegistrationRetry.run(selectProxy: { _, _ in nil }, attempt: { _ in
                attempts += 1
                throw ClientError.message("直连失败")
            }, shouldRetry: { true }, onRetry: { _, _ in XCTFail("There is no proxy to switch") })
            XCTFail("Direct failure must propagate")
        } catch { XCTAssertEqual(error.localizedDescription, "直连失败") }
        XCTAssertEqual(attempts, 1)
    }
}
