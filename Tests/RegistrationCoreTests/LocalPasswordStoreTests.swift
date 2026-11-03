import XCTest
@testable import RegistrationCore

final class LocalPasswordStoreTests: XCTestCase {
    func testPrivateFileRoundTripUpdateAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPasswordStore(directory: directory)
        XCTAssertNil(try store.read())
        try store.save("fixture-only-first-password")
        XCTAssertEqual(try LocalPasswordStore(directory: directory).read(), "fixture-only-first-password")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.save("fixture-only-replacement")
        XCTAssertEqual(try store.read(), "fixture-only-replacement")
        try store.save("")
        XCTAssertNil(try store.read())
        try store.save("")
    }

    func testDoesNotReadThroughSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPasswordStore(directory: directory)
        let target = directory.appendingPathComponent("other-file")
        try "fixture-private".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.read())
        try store.save("fixture-new")
        XCTAssertEqual(try store.read(), "fixture-new")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "fixture-private")
    }
}
