import XCTest
@testable import RegistrationCore

final class ProxyConfigurationTests: XCTestCase {
    func testObsoletePreflightSettingIsIgnoredAndRemovedOnSave() throws {
        let original = ProxyConfiguration()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["preflightTestLimitMilliseconds"] = "obsolete"
        let decoded = try JSONDecoder().decode(ProxyConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, original)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(saved["preflightTestLimitMilliseconds"])
    }

    func testDefaultLatencyLimits() {
        let configuration = ProxyConfiguration()
        XCTAssertEqual(configuration.poolTestLimitMilliseconds, 3_000)
        XCTAssertEqual(configuration.pageLoadingTimeoutSeconds, 10)
    }

    func testOlderSavedPoolLoadsNewDefaultsAndPreservesExistingSettings() throws {
        var configuration = ProxyConfiguration()
        configuration.enabled = true
        configuration.switchEvery = 4
        configuration.entries = [ProxyEntry(host: "legacy.invalid", port: 1080)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object.removeValue(forKey: "poolTestLimitMilliseconds")
        object.removeValue(forKey: "preflightTestLimitMilliseconds")
        object.removeValue(forKey: "pageLoadingTimeoutSeconds")
        let decoded = try JSONDecoder().decode(ProxyConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, configuration)
    }

    func testCustomLatencyLimitsSurviveJournalSaveAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        var journal = Journal()
        journal.proxyConfiguration.poolTestLimitMilliseconds = 1_750
        journal.proxyConfiguration.pageLoadingTimeoutSeconds = 17
        journal.proxyConfiguration.entries = [ProxyEntry(host: "saved.invalid", port: 1080)]
        try store.save(journal)
        XCTAssertEqual(try store.load().proxyConfiguration, journal.proxyConfiguration)
    }

    func testLatencyLimitsMustBePositive() throws {
        XCTAssertNoThrow(try ProxyConfiguration().validateLatencyLimits())
        for invalid in [0, -1] {
            var configuration = ProxyConfiguration()
            configuration.poolTestLimitMilliseconds = invalid
            XCTAssertThrowsError(try configuration.validateLatencyLimits())
            configuration.poolTestLimitMilliseconds = 3_000
            configuration.pageLoadingTimeoutSeconds = invalid
            XCTAssertThrowsError(try configuration.validateLatencyLimits())
        }
    }

    func testPageTimeoutValidationAlsoAppliesWithoutProxyMode() {
        var configuration = ProxyConfiguration()
        XCTAssertFalse(configuration.enabled)
        for value in [-1, 0] {
            configuration.pageLoadingTimeoutSeconds = value
            XCTAssertThrowsError(try configuration.validatePageLoadingTimeout())
        }
        configuration.pageLoadingTimeoutSeconds = 17
        XCTAssertNoThrow(try configuration.validatePageLoadingTimeout())
    }
}
