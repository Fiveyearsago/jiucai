import XCTest
@testable import RegistrationCore

final class ProxyRotationQueueTests: XCTestCase {
    func testReplenishmentAtRoundTailWaitsForNextRound() {
        let a = proxy("a"), b = proxy("b"), replenished = proxy("new")
        var configuration = makeConfiguration([a, b])
        var queue = ProxyRotationQueue()

        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b])
        queue.didFinishProxy(id: a.id)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b])

        configuration.entries.append(replenished)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b])
        queue.didFinishProxy(id: b.id)

        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b, replenished])
    }

    func testReplenishmentWaitsBehindRemainingOlderProxies() {
        let a = proxy("a"), b = proxy("b"), replenished = proxy("new")
        var configuration = makeConfiguration([a, b])
        var queue = ProxyRotationQueue()

        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b])
        configuration.entries.append(replenished)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b])

        queue.didFinishProxy(id: a.id)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b])
        queue.didFinishProxy(id: b.id)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b, replenished])
    }

    func testRemovedAndDisabledProxiesAreSkipped() {
        let a = proxy("a"), b = proxy("b"), c = proxy("c"), d = proxy("d")
        var configuration = makeConfiguration([a, b, c, d])
        var queue = ProxyRotationQueue()

        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b, c, d])
        queue.didFinishProxy(id: a.id)
        configuration.entries.removeAll { $0.id == b.id }
        configuration.entries[1].enabled = false

        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [d])
        queue.didFinishProxy(id: d.id)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, d])
    }

    func testEmptyPoolRefillsWhenProxyBecomesAvailable() {
        let a = proxy("a"), b = proxy("b")
        var configuration = makeConfiguration([])
        var queue = ProxyRotationQueue()

        XCTAssertTrue(queue.selectionConfiguration(from: configuration).entries.isEmpty)
        configuration.entries = [a]
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a])
        configuration.entries = []
        XCTAssertTrue(queue.selectionConfiguration(from: configuration).entries.isEmpty)
        configuration.entries = [b]
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b])
    }

    func testFinishedProxyIsConsumedUntilNextRound() {
        let a = proxy("a"), b = proxy("b")
        let configuration = makeConfiguration([a, b])
        var queue = ProxyRotationQueue()

        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b])
        queue.didFinishProxy(id: a.id)
        queue.didFinishProxy(id: a.id)
        queue.didFinishProxy(id: UUID())
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b])
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b])

        queue.didFinishProxy(id: b.id)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b])
    }

    func testDuplicateIDsAreSelectedOnlyOncePerRound() {
        let a = proxy("a"), b = proxy("b")
        let configuration = makeConfiguration([a, a, b, b])
        var queue = ProxyRotationQueue()

        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b])
        queue.didFinishProxy(id: a.id)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b])
        queue.didFinishProxy(id: b.id)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b])
    }

    func testSelectionPreservesOriginalConfiguration() {
        let a = proxy("a"), b = proxy("b")
        var disabled = proxy("disabled")
        disabled.enabled = false
        var configuration = makeConfiguration([a, disabled, b])
        configuration.switchEvery = 3
        configuration.poolTestLimitMilliseconds = 1_234
        configuration.pageLoadingTimeoutSeconds = 17
        let original = configuration
        var queue = ProxyRotationQueue()

        _ = queue.selectionConfiguration(from: configuration)
        queue.didFinishProxy(id: a.id)
        let selected = queue.selectionConfiguration(from: configuration)
        var expected = original
        expected.entries = [b]

        XCTAssertEqual(selected, expected)
        XCTAssertEqual(configuration, original)
    }

    func testDisabledConfigurationPermitsDirectUseWithoutConsumingRound() {
        let a = proxy("a"), b = proxy("b"), replenished = proxy("new")
        var configuration = makeConfiguration([a, b])
        var queue = ProxyRotationQueue()

        _ = queue.selectionConfiguration(from: configuration)
        queue.didFinishProxy(id: a.id)
        configuration.enabled = false
        configuration.entries.append(replenished)
        let direct = queue.selectionConfiguration(from: configuration)
        XCTAssertEqual(direct, configuration)
        XCTAssertNil(direct.proxy(forCompletedCount: 0))

        configuration.enabled = true
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b])
    }

    func testSelectionUsesLatestEntryValuesInFrozenOrder() {
        var a = proxy("a")
        let b = proxy("b")
        var configuration = makeConfiguration([a, b])
        var queue = ProxyRotationQueue()

        _ = queue.selectionConfiguration(from: configuration)
        a.host = "updated.invalid"
        a.port = 2080
        configuration.entries = [b, a]

        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [a, b])
        queue.didFinishProxy(id: a.id)
        queue.didFinishProxy(id: b.id)
        XCTAssertEqual(queue.selectionConfiguration(from: configuration).entries, [b, a])
    }

    private func proxy(_ name: String) -> ProxyEntry {
        ProxyEntry(host: "\(name).invalid", port: 1080)
    }

    private func makeConfiguration(_ entries: [ProxyEntry]) -> ProxyConfiguration {
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        configuration.entries = entries
        return configuration
    }
}
