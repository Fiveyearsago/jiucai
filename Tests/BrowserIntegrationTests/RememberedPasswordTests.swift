import AppKit
import XCTest
import RegistrationCore
@testable import BeautyRegistration

private final class FixturePasswordStore: PasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: String?
    private var count = 0
    let failing: Bool
    init(_ value: String? = nil, failing: Bool = false) { saved = value; self.failing = failing }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if failing { throw ClientError.message("fixture-only-error") }
        return saved
    }
    func save(_ password: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw ClientError.message("fixture-only-error") }
        saved = password.isEmpty ? nil : password
        count += 1
    }
}

final class RememberedPasswordTests: XCTestCase {
    @MainActor
    private func waitForLoad(_ value: RememberedPassword) async throws {
        for _ in 0..<100 {
            if !value.isLoading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Password load did not finish")
    }

    @MainActor
    func testRestoresWithoutRewritingAndNeverSavesAfterReadFailure() async throws {
        let store = FixturePasswordStore("fixture-existing")
        let value = RememberedPassword(store: store)
        try await waitForLoad(value)
        XCTAssertEqual(value.value, "fixture-existing")
        value.flush()
        XCTAssertEqual(store.writes, 0)
        let failingStore = FixturePasswordStore(failing: true)
        let failed = RememberedPassword(store: failingStore)
        try await waitForLoad(failed)
        failed.flush()
        XCTAssertTrue(failed.status.contains("无法读取"))
        XCTAssertEqual(failingStore.writes, 0)
    }

    @MainActor
    func testDebouncesTypingAndClearsSavedPassword() async throws {
        let store = FixturePasswordStore()
        let value = RememberedPassword(store: store)
        try await waitForLoad(value)
        value.value = "fixture-1"
        value.value = "fixture-2"
        for _ in 0..<100 {
            if value.status.hasPrefix("已保存") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try store.read(), "fixture-2")
        XCTAssertEqual(store.writes, 1)
        value.value = ""
        value.flush()
        XCTAssertNil(try store.read())
        XCTAssertTrue(value.status.contains("已清除"))
    }

    @MainActor
    func testImmediateTerminationPersistsLatestEditForNextLaunch() async throws {
        let store = FixturePasswordStore("fixture-old")
        let value = RememberedPassword(store: store)
        try await waitForLoad(value)
        value.value = "fixture-new"
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let relaunched = RememberedPassword(store: store)
        try await waitForLoad(relaunched)
        XCTAssertEqual(relaunched.value, "fixture-new")
    }

    @MainActor
    func testEarlyUserEditWinsOverLoadingAndSaveFailureIsVisible() async throws {
        let store = FixturePasswordStore("fixture-old")
        let value = RememberedPassword(store: store)
        value.value = "fixture-typed-before-load"
        try await waitForLoad(value)
        value.flush()
        XCTAssertEqual(value.value, "fixture-typed-before-load")
        XCTAssertEqual(try store.read(), "fixture-typed-before-load")
        let failed = RememberedPassword(store: FixturePasswordStore(failing: true))
        try await waitForLoad(failed)
        failed.value = "fixture-unsaved"
        failed.flush()
        XCTAssertTrue(failed.status.contains("未保存"))
    }
}
