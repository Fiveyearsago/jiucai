import XCTest
import RegistrationCore
@testable import BeautyRegistration

@MainActor
final class ProxySourceRefreshTests: XCTestCase {
    private func model(fetch: @escaping RegistrationModel.ProxySourceFetch,
                       test: @escaping RegistrationModel.ProxyTest = { _, _ in
                           .init(verdict: .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
                       }, onRequest: @escaping (URLRequest) throws -> Void = { _ in }) throws -> RegistrationModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-refresh-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let value = RegistrationModel(store: JournalStore(directory: directory.appendingPathComponent("journal")),
                                      passwordStore: LocalPasswordStore(directory: directory.appendingPathComponent("password")),
                                      transportFactory: { _, _ in { request in
            try onRequest(request)
            let body = request.url!.path == "/api/status" ? #"{"success":true,"data":{"email_verification":false,"register_enabled":true}}"# : #"{"success":true}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        } },
                                      retryDelaySeconds: 0.02, proxySourceFetch: fetch, poolProxyTest: test)
        value.password = "fixture-password"; value.autoReadMailbox = false
        value.proxyConfiguration.sourceConfiguration.urls = ["https://source.invalid/list"]
        return value
    }

    private func until(_ condition: () -> Bool) async throws {
        let completed = try await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { condition() }
        XCTAssertTrue(completed)
    }

    func testManualRefreshDeduplicatesTestsAndAddsOnlyPassingProxiesDespiteSourceFailure() async throws {
        var fetched: [String] = []
        var tested: [String] = []
        let value = try model(fetch: { url in
            fetched.append(url.host!)
            if url.host == "failed.invalid" { throw URLError(.cannotConnectToHost) }
            if url.host == "first.invalid" { return "existing.invalid:1080\nfast.invalid:1080\nslow.invalid:1080\n" }
            return "socks5://fast.invalid:1080\nsocks5://boundary.invalid:1080\nblocked.invalid:1080"
        }, test: { proxy, configuration in
            tested.append(proxy.host)
            XCTAssertEqual(configuration.poolTestLimitMilliseconds, 3_000)
            return .init(verdict: proxy.host == "blocked.invalid" ? .blocked : .usable, status: 200,
                         milliseconds: proxy.host == "slow.invalid" ? 3_001 : (proxy.host == "boundary.invalid" ? 3_000 : 10),
                         exit: nil, error: nil)
        })
        defer { value.stopProxySourceUpdates() }
        let existing = ProxyEntry(host: "EXISTING.invalid", port: 1080)
        value.proxyConfiguration.entries = [existing]
        value.proxyConfiguration.sourceConfiguration.urls = ["https://first.invalid/list", "https://failed.invalid/list", "https://last.invalid/list"]
        value.refreshProxySources()
        try await until { !value.isRefreshingProxySources }
        XCTAssertEqual(fetched, ["first.invalid", "failed.invalid", "last.invalid"])
        XCTAssertEqual(Set(tested), ["fast.invalid", "boundary.invalid", "slow.invalid", "blocked.invalid"])
        XCTAssertEqual(tested.count, 4)
        XCTAssertEqual(value.proxySourceCandidates, 4)
        XCTAssertEqual(value.proxySourceTested, 4)
        XCTAssertEqual(value.proxySourceAdded, 2)
        XCTAssertEqual(value.proxySourceRejected, 2)
        XCTAssertEqual(value.proxySourceErrors.count, 1)
        XCTAssertEqual(Set(value.proxyConfiguration.entries.map(\.host)), ["EXISTING.invalid", "fast.invalid", "boundary.invalid"])
        XCTAssertTrue(value.proxyConfiguration.entries.contains(existing))
        XCTAssertEqual(try value.store.load().proxyConfiguration, value.proxyConfiguration)
        XCTAssertNil(value.alert)
    }

    func testBackgroundRefreshReplenishesEmptyPoolAndRegistrationAutomaticallyFinishes() async throws {
        let value = try model(fetch: { _ in "socks5://refill.invalid:1080" })
        defer { value.stop(); value.stopProxySourceUpdates() }
        value.proxyConfiguration.enabled = true
        value.start()
        try await until { value.phase == "等待可用代理" }
        value.refreshProxySources()
        try await until { !value.isRunning && !value.isRefreshingProxySources }
        XCTAssertEqual(value.records.first?.status, .succeeded)
        XCTAssertEqual(value.proxySourceAdded, 1)
        XCTAssertFalse(value.isPaused)
        XCTAssertNil(value.alert)
    }

    func testSchedulerStartsOnceHonorsDueTimeAndManualRefreshWorksWhenDisabled() async throws {
        var fetched = 0
        let value = try model(fetch: { _ in fetched += 1; return "scheduled.invalid:1080" })
        defer { value.stopProxySourceUpdates() }
        value.startProxySourceUpdates(); value.startProxySourceUpdates()
        try await until { fetched == 1 && !value.isRefreshingProxySources }
        let next = try XCTUnwrap(value.nextProxySourceRefreshAt)
        XCTAssertEqual(next.timeIntervalSinceNow, 3_600, accuracy: 2)
        value.refreshProxySourcesIfDue(at: next.addingTimeInterval(-1))
        XCTAssertEqual(fetched, 1)
        value.refreshProxySourcesIfDue(at: next)
        try await until { fetched == 2 && !value.isRefreshingProxySources }
        var settings = value.proxyConfiguration.sourceConfiguration
        settings.intervalMinutes = 7
        XCTAssertTrue(value.saveProxySourceConfiguration(settings))
        XCTAssertEqual(try XCTUnwrap(value.nextProxySourceRefreshAt).timeIntervalSinceNow, 420, accuracy: 2)
        settings.automatic = false
        XCTAssertTrue(value.saveProxySourceConfiguration(settings))
        XCTAssertNil(value.nextProxySourceRefreshAt)
        value.refreshProxySourcesIfDue(at: next.addingTimeInterval(10_000))
        XCTAssertEqual(fetched, 2)
        value.refreshProxySources()
        try await until { fetched == 3 && !value.isRefreshingProxySources }
        XCTAssertEqual(value.proxyConfiguration.entries.count, 1)
        XCTAssertNil(value.nextProxySourceRefreshAt)
    }

    func testOverlappingRefreshesAreIgnoredAndCancellationDoesNotAdmitCandidates() async throws {
        var fetched = 0
        var tested = 0
        let value = try model(fetch: { _ in
            fetched += 1
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "cancelled.invalid:1080"
        }, test: { _, _ in
            tested += 1
            return .init(verdict: .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
        })
        defer { value.stopProxySourceUpdates() }
        value.refreshProxySources()
        try await until { fetched == 1 }
        value.refreshProxySources(); value.refreshProxySources()
        XCTAssertEqual(fetched, 1)
        value.stopProxySourceRefresh()
        try await until { !value.isRefreshingProxySources }
        XCTAssertEqual(tested, 0)
        XCTAssertTrue(value.proxyConfiguration.entries.isEmpty)
        XCTAssertNil(value.alert)
    }

    func testPassingResultsAreAvailableWhileOtherCandidatesAreStillTesting() async throws {
        let value = try model(fetch: { _ in "first.invalid:1080\nheld.invalid:1080" }, test: { proxy, _ in
            if proxy.host == "held.invalid" { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            return .init(verdict: .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
        })
        defer { value.stopProxySourceUpdates() }
        value.refreshProxySources()
        try await until { value.proxyConfiguration.entries.contains(where: { $0.host == "first.invalid" }) }
        XCTAssertTrue(value.isRefreshingProxySources)
        value.stopProxySourceRefresh()
        try await until { !value.isRefreshingProxySources }
        XCTAssertEqual(value.proxyConfiguration.entries.map(\.host), ["first.invalid"])
    }

    func testRefreshCannotOverwriteUnreadableJournalOrStartNetworkRequests() async throws {
        var fetched = 0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-source-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("unreadable-original-journal".utf8)
        try original.write(to: store.fileURL)
        let value = RegistrationModel(store: store, passwordStore: LocalPasswordStore(directory: directory.appendingPathComponent("password")),
                                      proxySourceFetch: { _ in fetched += 1; return "never.invalid:1080" })
        defer { value.stopProxySourceUpdates() }
        value.startProxySourceUpdates(); value.refreshProxySources()
        XCTAssertFalse(value.isRefreshingProxySources)
        XCTAssertEqual(fetched, 0)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testBackgroundTestsUseDefaultConcurrencyAndCapAtTwenty() async throws {
        for (requested, expected) in [(5, 5), (100, 20)] {
            var active = 0
            var peak = 0
            let value = try model(fetch: { _ in (0..<40).map { "candidate\($0).invalid:1080" }.joined(separator: "\n") }, test: { _, _ in
                active += 1; peak = max(peak, active)
                await Task.yield()
                active -= 1
                return .init(verdict: .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
            })
            defer { value.stopProxySourceUpdates() }
            value.proxyTestConcurrency = requested
            value.refreshProxySources()
            try await until { !value.isRefreshingProxySources }
            XCTAssertEqual(peak, expected)
            XCTAssertEqual(value.proxyConfiguration.entries.count, 40)
        }
    }

    func testRefreshDoesNotResurrectProxyDiscardedWhileItsTestWasInFlight() async throws {
        var testing = false
        var release = false
        let value = try model(fetch: { _ in "failed-during-refresh.invalid:1080" }, test: { _, _ in
            testing = true
            _ = try? await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { release }
            return .init(verdict: .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
        }, onRequest: { _ in throw URLError(.timedOut) })
        defer { release = true; value.stop(); value.stopProxySourceUpdates() }
        value.refreshProxySources()
        try await until { testing }
        value.proxyConfiguration.entries = [ProxyEntry(host: "failed-during-refresh.invalid", port: 1080)]
        value.proxyConfiguration.enabled = true
        value.start()
        try await until { value.phase == "等待可用代理" }
        release = true
        try await until { !value.isRefreshingProxySources }
        XCTAssertEqual(value.proxySourceAdded, 0)
        XCTAssertEqual(value.proxySourceRejected, 1)
        XCTAssertTrue(value.proxyConfiguration.entries.isEmpty)
        XCTAssertTrue(value.isRunning)
        XCTAssertFalse(value.isPaused)
    }

    func testSourceRefreshWaitsForManualBatchTestsInsteadOfOverlapping() async throws {
        var fetched = 0
        let value = try model(fetch: { _ in fetched += 1; return "source.invalid:1080" }, test: { _, _ in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return .init(verdict: .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
        })
        defer { value.stopProxyTests(); value.stopProxySourceUpdates() }
        value.proxyConfiguration.entries = [ProxyEntry(host: "manual.invalid", port: 1080)]
        value.testProxies(value.proxyConfiguration.entries)
        XCTAssertTrue(value.isTestingProxies)
        value.refreshProxySources()
        XCTAssertFalse(value.isRefreshingProxySources)
        XCTAssertEqual(fetched, 0)
        value.stopProxyTests()
        try await until { !value.isTestingProxies }
    }

    func testPausingWhileBackgroundProbeDrainsDefersRegistrationRequestsUntilResume() async throws {
        var attempts = 0
        var cancellationObserved = false
        var releaseCleanup = false
        var drained = false
        var requests = 0
        let value = try model(fetch: { _ in "pause-background.invalid:1080" }, test: { _, _ in
            attempts += 1
            if attempts == 1 {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch {
                    cancellationObserved = true
                    while !releaseCleanup { await Task.yield() }
                }
                drained = true
            }
            return .init(verdict: .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
        }, onRequest: { _ in requests += 1 })
        defer { releaseCleanup = true; value.stop(); value.stopProxySourceUpdates() }
        value.proxyConfiguration.entries = [ProxyEntry(host: "pause-existing.invalid", port: 1080)]
        value.proxyConfiguration.enabled = true
        value.proxyConfiguration.sourceConfiguration.registrationConcurrency = 0
        value.refreshProxySources()
        try await until { attempts == 1 }
        value.start()
        try await until { cancellationObserved }
        value.togglePause()
        releaseCleanup = true
        try await until { drained }
        let sentWhilePaused = try await WorkflowWait.until(timeout: 0.15, pollEvery: 0.01) { requests > 0 }
        XCTAssertFalse(sentWhilePaused, "A request queued before pause must wait for resume")
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(value.isPaused)
        try await until { !value.isRefreshingProxySources }
        XCTAssertEqual(value.proxySourceAdded, 1, "Paused registration must let background replenishment continue")
        value.togglePause()
        try await until { !value.isRunning && !value.isRefreshingProxySources }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(value.records.first?.status, .succeeded)
    }

    func testRegistrationKeepsOneBackgroundProbeRunningWithoutWaitingForIt() async throws {
        var active = 0
        var release = false
        var requests = 0
        let value = try model(fetch: { _ in (0..<5).map { "parallel\($0).invalid:1080" }.joined(separator: "\n") }, test: { _, _ in
            active += 1
            defer { active -= 1 }
            _ = try? await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { release }
            return .init(verdict: Task.isCancelled ? .unreachable : .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
        }, onRequest: { _ in
            requests += 1
            XCTAssertEqual(active, 1, "Registration must coexist with exactly one held background probe by default")
        })
        defer { release = true; value.stop(); value.stopProxySourceUpdates() }
        value.proxyConfiguration.entries = [ProxyEntry(host: "existing-parallel.invalid", port: 1080)]
        value.proxyConfiguration.enabled = true
        value.refreshProxySources()
        try await until { active == 5 }
        value.start()
        try await until { !value.isRunning }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(value.records.first?.status, .succeeded)
        XCTAssertEqual(value.proxySourceTested, 0, "Interrupting excess probes must not count them as failed")
        XCTAssertEqual(value.proxySourceRejected, 0)
        release = true
        try await until { !value.isRefreshingProxySources }
        XCTAssertEqual(value.proxySourceAdded, 5)
        XCTAssertEqual(value.proxySourceRejected, 0)
    }

    func testLiveLimitPersistsAndAppliesWhileManualRegistrationWaitsForSubmit() async throws {
        var active = 0
        var release = false
        let value = try model(fetch: { _ in (0..<6).map { "live-limit\($0).invalid:1080" }.joined(separator: "\n") }, test: { _, _ in
            active += 1
            defer { active -= 1 }
            _ = try? await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { release }
            return .init(verdict: Task.isCancelled ? .unreachable : .usable, status: 200, milliseconds: 10, exit: nil, error: nil)
        })
        defer { release = true; value.stop(); value.stopProxySourceUpdates() }
        value.proxyConfiguration.entries = [ProxyEntry(host: "live-existing.invalid", port: 1080)]
        value.proxyConfiguration.enabled = true
        value.refreshProxySources()
        try await until { active == 5 }
        let nextRefresh = value.nextProxySourceRefreshAt
        value.requestNativeVerification()
        try await until { value.waitingForCode && active == 1 }
        XCTAssertTrue(value.saveRegistrationProxyConcurrency(3))
        try await until { active == 3 }
        XCTAssertTrue(value.saveRegistrationProxyConcurrency(1))
        try await until { active == 1 }
        XCTAssertEqual(try value.store.load().proxyConfiguration.sourceConfiguration.registrationConcurrency, 1)
        XCTAssertEqual(value.nextProxySourceRefreshAt, nextRefresh, "Changing concurrency must not reset the refresh schedule")
        XCTAssertEqual(value.proxySourceRejected, 0)
        value.submitNativeRegistration()
        try await until { !value.isRunning && active == 5 }
        release = true
        try await until { !value.isRefreshingProxySources }
        XCTAssertEqual(value.proxySourceAdded, 6)
        XCTAssertEqual(value.records.first?.status, .succeeded)
    }

    func testRegistrationYieldsBackgroundProbesWithoutRejectingInterruptedCandidates() async throws {
        var activeBackgroundProbes = 0
        var release = false
        var requests = 0
        let value = try model(fetch: { _ in (0..<5).map { "background\($0).invalid:1080" }.joined(separator: "\n") }, test: { _, _ in
            activeBackgroundProbes += 1
            defer { activeBackgroundProbes -= 1 }
            _ = try? await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { release }
            // URLSession-based probes also convert cancellation into a result; the scheduler must retry it.
            return .init(verdict: .unreachable, status: nil, milliseconds: 0, exit: nil, error: "interrupted")
        }, onRequest: { _ in
            requests += 1
            XCTAssertEqual(activeBackgroundProbes, 0, "Registration requests must have priority over background probes")
        })
        defer { release = true; value.stop(); value.stopProxySourceUpdates() }
        let existing = ProxyEntry(host: "existing-working.invalid", port: 1080)
        value.proxyConfiguration.entries = [existing]; value.proxyConfiguration.enabled = true
        value.proxyConfiguration.sourceConfiguration.registrationConcurrency = 0
        value.refreshProxySources()
        try await until { activeBackgroundProbes == 5 }
        value.start()
        try await until { !value.isRunning }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(value.records.first?.status, .succeeded)
        XCTAssertEqual(value.proxySourceTested, 0, "Preempted probes must stay pending until they actually complete")
        XCTAssertEqual(value.proxySourceRejected, 0)
        release = true
        try await until { !value.isRefreshingProxySources }
        XCTAssertEqual(value.proxySourceTested, 5)
        XCTAssertEqual(value.proxySourceRejected, 5)
        XCTAssertEqual(value.proxyConfiguration.entries, [existing])
    }
}
