import XCTest
@testable import RegistrationCore

final class VerificationRetryTests: XCTestCase {
    func testDelayHonorsServerHintsAndGrowsForRepeatedRejections() {
        let limited: [String: Any] = ["status": 429, "success": false, "message": "发送过于频繁，请等待 1 秒后再试"]
        XCTAssertEqual((1...3).compactMap { VerificationRetry.delay(for: limited, retry: $0) }, [5, 10, 20])
        XCTAssertNil(VerificationRetry.delay(for: limited, retry: 4))
        XCTAssertEqual(VerificationRetry.delay(for: ["status": 429, "retryAfterSeconds": 120], retry: 1), 121)
        XCTAssertEqual(VerificationRetry.delay(for: ["status": 429, "retryAfterSeconds": 30, "message": "请等待 2 分钟后再试"], retry: 1), 121)
        XCTAssertEqual(VerificationRetry.delay(for: ["status": 429, "message": "Please wait 45 seconds"], retry: 1), 46)
        XCTAssertNil(VerificationRetry.delay(for: ["status": 429, "retryAfterSeconds": 7200], retry: 1))
        XCTAssertNil(VerificationRetry.delay(for: ["status": 403], retry: 1))
        XCTAssertNil(VerificationRetry.delay(for: ["status": 200, "success": false], retry: 1))
    }

    @MainActor
    func testRejectedSendsWaitBeforeRetryAndStopOnSuccess() async throws {
        var events: [String] = []
        var attempts = 0
        try await VerificationRetry.send(attempt: {
            attempts += 1; events.append("send")
            return attempts == 3 ? ["status": 200, "success": true] : ["status": 429, "success": false]
        }, wait: { seconds, _ in events.append("wait \(seconds)") })
        XCTAssertEqual(events, ["send", "wait 5", "send", "wait 10", "send"])
    }

    @MainActor
    func testPersistentRateLimitStopsAfterThreeRetries() async {
        var attempts = 0
        var waits = 0
        do {
            try await VerificationRetry.send(attempt: {
                attempts += 1; return ["status": 429, "success": false, "message": "发送过于频繁"]
            }, wait: { _, _ in waits += 1 })
            XCTFail("Persistent rate limiting must stop")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已自动重试 3 次"))
        }
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(waits, 3)
    }

    @MainActor
    func testCancellationAndUnknownSendOutcomeNeverTriggerAnotherAttempt() async {
        for cancelWhileWaiting in [false, true] {
            var attempts = 0
            do {
                try await VerificationRetry.send(attempt: {
                    attempts += 1
                    if !cancelWhileWaiting { throw ClientError.message("发送结果未知") }
                    return ["status": 429, "success": false]
                }, wait: { _, _ in throw CancellationError() })
                XCTFail("The send must stop")
            } catch {
                if cancelWhileWaiting { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error.localizedDescription, "发送结果未知") }
            }
            XCTAssertEqual(attempts, 1)
        }
    }
}
