import XCTest
@testable import RegistrationCore

final class RegistrationCoreTests: XCTestCase {
    func testNumberingAndInvitationEncoding() throws {
        var config = TaskConfiguration()
        XCTAssertEqual(config.username(7), "xiaorange007")
        XCTAssertEqual(config.email(176), "xiaorange176@fviainboxes.com")
        config.invitation = "a&b?x=1"
        XCTAssertEqual(URLComponents(url: config.registrationURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b?x=1")
        try config.validate(password: "test-only-password")
    }
    func testConfigurationRejectsInvalidRangesAndUsernames() throws {
        var config = TaskConfiguration()
        for prefix in ["", "two words", "<script>", "ab@cd", String(repeating: "a", count: 17)] {
            config.prefix = prefix
            XCTAssertThrowsError(try config.validate(password: "test-only-password"))
        }
        config = TaskConfiguration(); config.startIndex = Int.max
        XCTAssertThrowsError(try config.validate(password: "test-only-password"))
        config = TaskConfiguration(); config.count = 0
        XCTAssertThrowsError(try config.validate(password: "test-only-password"))
        config = TaskConfiguration(); config.intervalSeconds = 2
        XCTAssertThrowsError(try config.validate(password: "test-only-password"))
        config.intervalSeconds = 3
        XCTAssertNoThrow(try config.validate(password: "test-only-password"))
        config.intervalSeconds = 3600
        XCTAssertNoThrow(try config.validate(password: "test-only-password"))
        config.intervalSeconds = 3601
        XCTAssertThrowsError(try config.validate(password: "test-only-password"))
        config = TaskConfiguration()
        XCTAssertThrowsError(try config.validate(password: "short"))
    }
    func testCrashRecoveryNeverAutomaticallyRepeatsSubmittedAccount() {
        var journal = Journal()
        journal.records = RecordStatus.allCases.enumerated().map { index, status in
            AccountRecord(username: "user\(index)", email: "user\(index)@test.invalid", status: status)
        }
        journal.recoverInterruptedRun()
        XCTAssertEqual(journal.records.map(\.status), [.cancelled, .cancelled, .uncertain, .succeeded, .failed, .uncertain, .cancelled])
        XCTAssertTrue(journal.blocksAutomaticRegistration(username: "user2"))
        XCTAssertTrue(journal.blocksAutomaticRegistration(username: "user3"))
        XCTAssertFalse(journal.blocksAutomaticRegistration(username: "user1"))
    }
    func testRegistrationCountHasNoArtificialCapAndNumbersDoNotTruncate() throws {
        var config = TaskConfiguration()
        for count in [101, 10_000, 2_000_000] {
            config.count = count
            try config.validate(password: "fixture-only-password")
        }
        config.startIndex = 4_294_967_296; config.count = 101
        try config.validate(password: "fixture-only-password")
        XCTAssertEqual(config.username(config.startIndex), "xiaorange4294967296")
        config.count = Int.max
        XCTAssertThrowsError(try config.validate(password: "fixture-only-password"))
        config.count = -1
        XCTAssertThrowsError(try config.validate(password: "fixture-only-password"))
    }
    func testLargeBatchCountsOnlyUniqueBlockedAccountsWithoutAllocatingFutureRecords() throws {
        var config = TaskConfiguration(); config.startIndex = 1; config.count = 2_000_000
        try config.validate(password: "fixture-only-password")
        let records = [
            AccountRecord(username: "xiaorange001", email: "fixture@test.invalid", status: .succeeded),
            AccountRecord(username: "xiaorange001", email: "fixture@test.invalid", status: .succeeded),
            AccountRecord(username: "xiaorange003", email: "fixture@test.invalid", status: .uncertain),
            AccountRecord(username: "xiaorange004", email: "fixture@test.invalid", status: .failed),
            AccountRecord(username: "other001", email: "fixture@test.invalid", status: .succeeded)
        ]
        let batch = RegistrationBatch(configuration: config, records: records)
        XCTAssertEqual(batch.count, 1_999_998)
        XCTAssertEqual(batch.blockedIndices, [1, 3])
        XCTAssertEqual(Array(batch.indices.prefix(3)), [1, 2, 3])
        XCTAssertEqual(records.count, 5)
    }
    func testJournalRoundTripAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        var journal = Journal()
        journal.records = [AccountRecord(username: "sample", email: "sample@test.invalid", status: .submitting)]
        try store.save(journal)
        XCTAssertEqual(try store.load().records, journal.records)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let saved = try String(contentsOf: store.fileURL)
        XCTAssertFalse(saved.contains("password"))
        XCTAssertFalse(saved.contains("verification_code"))
    }
    func testOldRecordsWithoutLogsAreReadableAndNewLogsRemainIntact() throws {
        var journal = Journal()
        var old = AccountRecord(username: "legacy", email: "legacy@test.invalid", status: .succeeded)
        old.screenshot = "/fixture/screenshot.png"
        var current = AccountRecord(username: "current", email: "current@test.invalid", status: .failed)
        current.logs = ["first step", "second step"]
        journal.records = [old, current]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "logs")
        object["records"] = records
        let restored = try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.records, journal.records)
        records[0]["logs"] = "not-an-array"
        object["records"] = records
        XCTAssertThrowsError(try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testOldConfigurationWithoutCooldownLoadsAndExistingValueIsPreserved() throws {
        var original = TaskConfiguration()
        original.prefix = "fixture"
        original.startIndex = 251
        original.intervalSeconds = 3
        original.cooldownMinutes = 7
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(TaskConfiguration.self, from: data), original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "cooldownMinutes")
        let restored = try JSONDecoder().decode(TaskConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        original.cooldownMinutes = 0
        XCTAssertEqual(restored, original)
        legacy["cooldownMinutes"] = "invalid"
        XCTAssertThrowsError(try JSONDecoder().decode(TaskConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }
    func testLegacyJournalWithoutProxyPoolPreservesSingleProxyConfiguration() throws {
        var journal = Journal()
        journal.records = [AccountRecord(username: "fixture", email: "fixture@test.invalid", status: .succeeded)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        object.removeValue(forKey: "proxyConfiguration")
        var configuration = try XCTUnwrap(object["configuration"] as? [String: Any])
        configuration["proxyHost"] = "fixture.invalid"
        configuration["proxyPort"] = 1234
        configuration["proxyUser"] = "fixture-user"
        configuration["proxyPassword"] = "fixture-password"
        configuration["proxyRotateSession"] = false
        object["configuration"] = configuration
        let decoded = try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.records, journal.records)
        XCTAssertFalse(decoded.proxyConfiguration.enabled)
        let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let preserved = try XCTUnwrap(reencoded["configuration"] as? [String: Any])
        for key in ["proxyHost", "proxyUser", "proxyPassword"] {
            XCTAssertEqual(preserved[key] as? String, configuration[key] as? String)
        }
        XCTAssertEqual(preserved["proxyPort"] as? Int, configuration["proxyPort"] as? Int)
        XCTAssertEqual(preserved["proxyRotateSession"] as? Bool, configuration["proxyRotateSession"] as? Bool)
        object["proxyConfiguration"] = "invalid"
        XCTAssertThrowsError(try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testCorruptJournalIsNotSilentlyReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = JournalStore(directory: directory)
        try Data("broken".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.fileURL), "broken")
    }
    func testCSVQuotingAndFormulaNeutralization() {
        var record = AccountRecord(username: "=cmd()", email: "sample@test.invalid")
        record.note = "line1,\"quoted\"\nline2"
        let csv = Journal.csv([record])
        XCTAssertTrue(csv.contains("\"'=cmd()\""))
        XCTAssertTrue(csv.contains("\"line1,\"\"quoted\"\"\nline2\""))
        XCTAssertFalse(csv.contains("password"))
    }
}
