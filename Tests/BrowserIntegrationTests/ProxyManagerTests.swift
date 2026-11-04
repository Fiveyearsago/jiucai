import XCTest
import Network
import RegistrationCore
@testable import BeautyRegistration

final class ProxyManagerTests: XCTestCase {
    func testInvalidProxyConfigurationCannotBecomeAClampedOrDirectConnection() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("SOCKS5 configurations require macOS 14") }
        for entry in [ProxyEntry(host: "", port: 1080), ProxyEntry(host: " \n\t", port: 1080),
                      ProxyEntry(host: "proxy.invalid", port: -1), ProxyEntry(host: "proxy.invalid", port: 0),
                      ProxyEntry(host: "proxy.invalid", port: 65_536), ProxyEntry(host: "proxy.invalid", port: Int.max)] {
            XCTAssertNil(ProxyManager.configuration(for: entry), entry.displayName)
        }
        for port in [1, 65_535] {
            XCTAssertNotNil(ProxyManager.configuration(for: ProxyEntry(host: "proxy.invalid", port: port)))
        }
    }

    func testProbeRequestsUncachedJSONStatusEndpointWithConfiguredTimeout() {
        let request = ProxyManager.testRequest(timeout: 7.5)
        XCTAssertEqual(request.url?.absoluteString, "https://api.jiucaihezi.studio/api/status")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(request.timeoutInterval, 7.5)
        XCTAssertEqual(request.networkServiceType, .background)
        XCTAssertNil(request.httpBody)
    }

    func testProbeAcceptsOnlySuccessfulJSONStatusObjects() {
        for status in [200, 201, 299] {
            let response = HTTPURLResponse(url: URL(string: "https://api.jiucaihezi.studio/api/status")!,
                                           statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let result = ProxyManager.testResult(data: Data(#"{"success":true,"data":{"email_verification":true}}"#.utf8),
                                                 response: response, milliseconds: 42)
            XCTAssertEqual(result.verdict, .usable)
            XCTAssertEqual(result.status, status)
            XCTAssertEqual(result.milliseconds, 42)
            XCTAssertNil(result.exit)
        }
    }

    func testProbeRejectsHTMLAndMalformedOrNonBooleanStatusResponses() {
        let response = HTTPURLResponse(url: URL(string: "https://api.jiucaihezi.studio/api/status")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        for body in ["<html><title>Just a moment...</title></html>", "invalid JSON", "{}", "[]",
                     #"{"success":false,"data":{}}"#, #"{"success":"true","data":{}}"#,
                     #"{"success":1,"data":{}}"#, #"{"success":null,"data":{}}"#,
                     #"{"success":true}"#, #"{"success":true,"data":null}"#,
                     #"{"success":true,"data":[]}"#, #"{"success":true,"data":"status"}"#] {
            let result = ProxyManager.testResult(data: Data(body.utf8), response: response, milliseconds: 42)
            XCTAssertEqual(result.verdict, .blocked, body)
            XCTAssertEqual(result.status, 200)
            XCTAssertEqual(result.milliseconds, 42)
        }
    }

    func testProbeRejectsRedirectsHTTPFailuresAndChallengeResponses() {
        let body = Data(#"{"success":true,"data":{}}"#.utf8)
        let statusURL = URL(string: "https://api.jiucaihezi.studio/api/status")!
        for status in [301, 302, 307, 308, 400, 403, 429, 500, 503] {
            let response = HTTPURLResponse(url: statusURL, statusCode: status, httpVersion: nil,
                                           headerFields: ["Location": "/sign-in"])!
            XCTAssertEqual(ProxyManager.testResult(data: body, response: response, milliseconds: 42).verdict, .blocked)
        }
        for url in [URL(string: "https://api.jiucaihezi.studio/sign-in")!, URL(string: "https://other.invalid/api/status")!] {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            XCTAssertEqual(ProxyManager.testResult(data: body, response: response, milliseconds: 42).verdict, .blocked)
        }
        let challenge = HTTPURLResponse(url: statusURL, statusCode: 200, httpVersion: nil,
                                        headerFields: ["CF-Mitigated": "challenge"])!
        XCTAssertEqual(ProxyManager.testResult(data: body, response: challenge, milliseconds: 42).verdict, .blocked)
    }

    func testReusableSessionsDisableCachesAndApplyBothTimeouts() throws {
        let direct = try XCTUnwrap(ProxyManager.session(through: nil, timeout: 17))
        defer { direct.invalidateAndCancel() }
        XCTAssertNil(direct.configuration.urlCache)
        XCTAssertEqual(direct.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(direct.configuration.timeoutIntervalForRequest, 17)
        XCTAssertEqual(direct.configuration.timeoutIntervalForResource, 17)
        XCTAssertEqual(direct.configuration.networkServiceType, .default)
        let background = try XCTUnwrap(ProxyManager.session(through: nil, timeout: 3, background: true))
        defer { background.invalidateAndCancel() }
        XCTAssertEqual(background.configuration.networkServiceType, .background)
        guard #available(macOS 14.0, *) else { return }
        let proxied = try XCTUnwrap(ProxyManager.session(through: ProxyEntry(host: "proxy.invalid", port: 1080), timeout: 6))
        defer { proxied.invalidateAndCancel() }
        XCTAssertEqual(proxied.configuration.proxyConfigurations.count, 1)
        XCTAssertFalse(try XCTUnwrap(proxied.configuration.proxyConfigurations.first).allowFailover)
        XCTAssertNil(proxied.configuration.urlCache)
        XCTAssertEqual(proxied.configuration.timeoutIntervalForRequest, 6)
        XCTAssertEqual(proxied.configuration.timeoutIntervalForResource, 6)
    }

    func testInvalidProxySessionNeverFallsBackToDirectConnection() {
        for entry in [ProxyEntry(host: "", port: 1080), ProxyEntry(host: " \t", port: 1080),
                      ProxyEntry(host: "proxy.invalid", port: 0), ProxyEntry(host: "proxy.invalid", port: -1),
                      ProxyEntry(host: "proxy.invalid", port: 65_536)] {
            let session = ProxyManager.session(through: entry, timeout: 5)
            defer { session?.invalidateAndCancel() }
            XCTAssertNil(session, entry.displayName)
        }
    }

    private func result(_ milliseconds: Int, verdict: ProxyManager.TestResult.Verdict = .usable) -> ProxyManager.TestResult {
        ProxyManager.TestResult(verdict: verdict, status: verdict == .usable ? 200 : nil,
                                milliseconds: milliseconds, exit: nil, error: nil)
    }

    @MainActor
    func testRegistrationRetryStartsAfterFailedProxyAndSkipsPreviouslyTriedProxies() throws {
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        configuration.entries = (0..<4).map { ProxyEntry(host: "ordered\($0).invalid", port: 1080) }
        let entries = configuration.entries
        let selected = try ProxyManager.selectProxy(configuration: configuration, completedCount: 0,
                                                     startingAfter: entries[1].id, excluding: [entries[2].id])
        XCTAssertEqual(selected?.id, entries[3].id)
    }

    @MainActor
    func testRegistrationRetryReportsExhaustionAfterEveryProxyHasFailed() {
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        configuration.entries = (0..<2).map { ProxyEntry(host: "exhausted\($0).invalid", port: 1080) }
        XCTAssertThrowsError(try ProxyManager.selectProxy(configuration: configuration, completedCount: 0,
                                                          startingAfter: configuration.entries.last?.id,
                                                          excluding: Set(configuration.entries.map(\.id)))) {
            XCTAssertTrue($0 is ProxyManager.SelectionError)
        }
    }

    func testPoolTestingRemovesOnlyProxiesAboveThreeSecondsByDefault() {
        for milliseconds in [2_999, 3_000, 3_001] {
            let entry = ProxyEntry(host: "tested.invalid", port: 1080)
            let other = ProxyEntry(host: "other.invalid", port: 1080)
            var configuration = ProxyConfiguration()
            configuration.enabled = true
            configuration.entries = [entry, other]
            let discarded = ProxyManager.discardIfNeeded(entry, result: result(milliseconds), configuration: &configuration)
            XCTAssertEqual(discarded, milliseconds > 3_000)
            XCTAssertEqual(configuration.entries, milliseconds > 3_000 ? [other] : [entry, other])
            XCTAssertTrue(configuration.enabled)
        }
    }

    func testPoolFilteringAndNetworkTimeoutUseConfiguredThreshold() {
        for limit in [1, 1_500, 7_000] {
            for milliseconds in [limit - 1, limit, limit + 1] {
                let entry = ProxyEntry(host: "custom.invalid", port: 1080)
                var configuration = ProxyConfiguration()
                configuration.poolTestLimitMilliseconds = limit
                configuration.entries = [entry]
                XCTAssertEqual(ProxyManager.poolTestTimeout(in: configuration), Double(limit) / 1_000, accuracy: 0.000_001)
                XCTAssertEqual(ProxyManager.discardIfNeeded(entry, result: result(milliseconds), configuration: &configuration), milliseconds > limit)
                XCTAssertEqual(configuration.entries.isEmpty, milliseconds > limit)
            }
        }
    }

    @MainActor
    func testSelectionDoesNotDependOnBatchThreshold() throws {
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        configuration.poolTestLimitMilliseconds = -1
        configuration.entries = [ProxyEntry(host: "direct-selection.invalid", port: 1080)]
        let selected = try ProxyManager.selectProxy(configuration: configuration, completedCount: 0)
        XCTAssertEqual(selected, configuration.entries.first)
    }

    @MainActor
    func testExhaustionMessageExplainsHowToResume() {
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        XCTAssertThrowsError(try ProxyManager.selectProxy(configuration: configuration, completedCount: 0)) {
            XCTAssertTrue($0.localizedDescription.contains("补充代理后会自动继续"))
            XCTAssertFalse($0.localizedDescription.contains("复测"))
        }
    }

    func testUnreachableAndBlockedProxiesAreDiscardedEvenWithShortLatency() {
        for verdict in [ProxyManager.TestResult.Verdict.unreachable, .blocked] {
            let entry = ProxyEntry(host: "unusable.invalid", port: 1080)
            var configuration = ProxyConfiguration()
            configuration.entries = [entry]
            XCTAssertTrue(ProxyManager.discardIfNeeded(entry, result: result(100, verdict: verdict), configuration: &configuration))
            XCTAssertTrue(configuration.entries.isEmpty)
        }
    }

    @MainActor
    func testSelectionUsesConfiguredAccountGroupAndSkipsDisabledProxies() throws {
        let first = ProxyEntry(host: "first.invalid", port: 1080)
        var disabled = ProxyEntry(host: "disabled.invalid", port: 1080)
        disabled.enabled = false
        let second = ProxyEntry(host: "second.invalid", port: 1080)
        let third = ProxyEntry(host: "third.invalid", port: 1080)
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        configuration.switchEvery = 2
        configuration.entries = [first, disabled, second, third]
        for (completed, expected) in [(0, first), (1, first), (2, second), (4, third), (6, first)] {
            let selected = try ProxyManager.selectProxy(configuration: configuration, completedCount: completed)
            XCTAssertEqual(selected, expected)
        }
        XCTAssertEqual(configuration.entries, [first, disabled, second, third])
    }

    @MainActor
    func testEmptyEnabledPoolWaitsButDisabledPoolAllowsDirectConnection() throws {
        var configuration = ProxyConfiguration()
        XCTAssertNil(try ProxyManager.selectProxy(configuration: configuration, completedCount: 0))
        for entries in [[], [ProxyEntry(host: "disabled.invalid", port: 1080)]] {
            configuration.enabled = true
            configuration.entries = entries.map { entry in var value = entry; value.enabled = false; return value }
            XCTAssertThrowsError(try ProxyManager.selectProxy(configuration: configuration, completedCount: 0)) {
                XCTAssertTrue($0 is ProxyManager.SelectionError)
            }
        }
    }

    @MainActor
    func testCancelledSelectionDoesNotChangePool() async {
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        configuration.entries = (1...2).map { ProxyEntry(host: "cancel\($0).invalid", port: 1080) }
        let expected = configuration.entries
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ProxyManager.selectProxy(configuration: configuration, completedCount: 0)
        }
        do {
            _ = try await task.value
            XCTFail("Selection must honor cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(configuration.entries, expected)
    }

    @MainActor
    func testTenThousandProxiesUseOnlyFiveConcurrentTestsAndCompleteExactlyOnce() async {
        let entries = (0..<10_000).map { ProxyEntry(host: "batch\($0).invalid", port: 1080) }
        var active = 0
        var peak = 0
        var started: Set<UUID> = []
        var completed: Set<UUID> = []
        await ProxyManager.testBatch(entries, test: { entry in
            XCTAssertTrue(started.insert(entry.id).inserted)
            active += 1
            peak = max(peak, active)
            await Task.yield()
            active -= 1
            return self.result(100)
        }, completed: { entry, result in
            XCTAssertTrue(completed.insert(entry.id).inserted)
            XCTAssertEqual(result.milliseconds, 100)
        })
        XCTAssertEqual(started.count, entries.count)
        XCTAssertEqual(completed, started)
        XCTAssertEqual(peak, 5)
        XCTAssertEqual(active, 0)
    }

    @MainActor
    func testBatchSupportsTwentyConcurrentTestsAndCapsHigherLimits() async {
        let entries = (0..<1_000).map { ProxyEntry(host: "maximum\($0).invalid", port: 1080) }
        for requested in [20, 100] {
            var active = 0
            var peak = 0
            var completed = 0
            await ProxyManager.testBatch(entries, concurrencyLimit: requested, test: { _ in
                active += 1
                peak = max(peak, active)
                await Task.yield()
                active -= 1
                return self.result(100)
            }, completed: { _, _ in completed += 1 })
            XCTAssertEqual(peak, 20)
            XCTAssertEqual(completed, entries.count)
            XCTAssertEqual(active, 0)
        }
    }

    @MainActor
    func testBatchHonorsSerialModeForSlowLocalNetworks() async {
        let entries = (0..<20).map { ProxyEntry(host: "serial\($0).invalid", port: 1080) }
        var active = 0
        var tested: [UUID] = []
        await ProxyManager.testBatch(entries, concurrencyLimit: 1, test: { entry in
            active += 1
            XCTAssertEqual(active, 1)
            tested.append(entry.id)
            await Task.yield()
            active -= 1
            return self.result(100)
        }, completed: { _, _ in })
        XCTAssertEqual(tested, entries.map(\.id))
    }

    @MainActor
    func testStoppingBatchDoesNotStartQueuedTestsAndWaitsForActiveTestsToFinish() async {
        let entries = (0..<10_000).map { ProxyEntry(host: "stopped\($0).invalid", port: 1080) }
        var active = 0
        var started = 0
        let task = Task {
            await ProxyManager.testBatch(entries, test: { _ in
                started += 1
                active += 1
                defer { active -= 1 }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return self.result(100)
            }, completed: { _, _ in XCTFail("Cancelled tests must not change results") })
        }
        for _ in 0..<1_000 {
            if active == 5 { break }
            await Task.yield()
        }
        XCTAssertEqual(active, 5)
        task.cancel()
        await task.value
        XCTAssertEqual(started, 5)
        XCTAssertEqual(active, 0)
    }
}
