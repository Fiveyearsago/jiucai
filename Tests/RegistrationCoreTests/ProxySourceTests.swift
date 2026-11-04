import XCTest
@testable import RegistrationCore

final class ProxySourceTests: XCTestCase {
    func testOldSourceSettingsDefaultToOneRegistrationProbeAndCustomLimitPersists() throws {
        let settings = ProxySourceConfiguration()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object.removeValue(forKey: "registrationConcurrency")
        let old = try JSONDecoder().decode(ProxySourceConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertEqual(saved["registrationConcurrency"] as? Int, 1)
        for limit in 0...3 {
            object["registrationConcurrency"] = limit
            let decoded = try JSONDecoder().decode(ProxySourceConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNoThrow(try decoded.validate())
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
            XCTAssertEqual(encoded["registrationConcurrency"] as? Int, limit)
        }
        for invalid in [-1, 4] {
            object["registrationConcurrency"] = invalid
            let decoded = try JSONDecoder().decode(ProxySourceConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try decoded.validate())
        }
    }

    func testDefaultSourcesAndSixtyMinuteScheduleSurviveOldJournalMigration() throws {
        var configuration = ProxyConfiguration()
        XCTAssertTrue(configuration.sourceConfiguration.automatic)
        XCTAssertEqual(configuration.sourceConfiguration.intervalMinutes, 60)
        XCTAssertEqual(configuration.sourceConfiguration.urls, [
            "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt",
            "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt",
            "https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt"
        ])
        configuration.entries = [ProxyEntry(host: "saved.invalid", port: 1080)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object.removeValue(forKey: "sourceConfiguration")
        let migrated = try JSONDecoder().decode(ProxyConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated, configuration)
    }

    func testCustomSourcesAndRefreshSettingsPersist() throws {
        var configuration = ProxyConfiguration()
        configuration.sourceConfiguration.urls = ["https://custom.invalid/proxies.txt"]
        configuration.sourceConfiguration.intervalMinutes = 17
        configuration.sourceConfiguration.automatic = false
        let restored = try JSONDecoder().decode(ProxyConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored, configuration)
    }

    func testSourceSettingsRequirePositiveIntervalAndHTTPURLs() throws {
        var settings = ProxySourceConfiguration()
        for interval in [0, -1] {
            settings.intervalMinutes = interval
            XCTAssertThrowsError(try settings.validate())
        }
        settings.intervalMinutes = 1
        for url in ["", "not-a-url", "file:///tmp/proxies", "ftp://host.invalid/proxies", "https://user:pass@host.invalid/proxies"] {
            settings.urls = [url]
            XCTAssertThrowsError(try settings.validate())
        }
        settings.urls = ["http://local.invalid/list", "https://host.invalid/list?format=txt"]
        XCTAssertNoThrow(try settings.validate())
        settings.urls = []
        XCTAssertNoThrow(try settings.validate(), "Users can remove all sources before adding replacements")
    }

    func testListsStripSOCKSPrefixAndDeduplicateAcrossSourcesAndPool() {
        let existing = ProxyEntry(host: "EXISTING.invalid", port: 1080)
        let lists = [
            "\u{FEFF}1.2.3.4:1080\r\nsocks5://5.6.7.8:1081\nexisting.invalid:1080\n# comment\n",
            "SOCKS5://1.2.3.4:1080\nsocks5://5.6.7.8:1081\nnew.invalid:80\ninvalid\nhttp://9.9.9.9:80"
        ]
        let candidates = ProxySources.candidates(in: lists, excluding: [existing])
        XCTAssertEqual(candidates.map(\.host), ["1.2.3.4", "5.6.7.8", "new.invalid"])
        XCTAssertEqual(candidates.map(\.port), [1080, 1081, 80])
        XCTAssertEqual(Set(candidates.map(ProxyIdentity.init)).count, candidates.count)
    }

    func testProxyURIParsingPreservesCredentialsAndRejectsUnrelatedContent() throws {
        let entry = try XCTUnwrap(ProxyEntry.parse(" socks5://alice:p%40ss@proxy.invalid:1080 \r"))
        XCTAssertEqual(entry.host, "proxy.invalid")
        XCTAssertEqual(entry.user, "alice")
        XCTAssertEqual(entry.password, "p@ss")
        let bare = try XCTUnwrap(ProxyEntry.parse("proxy.invalid:1080:alice:p@ss"))
        XCTAssertEqual(ProxyIdentity(entry), ProxyIdentity(bare))
        for line in ["socks5://proxy.invalid", "socks5://proxy.invalid:0", "socks5://proxy.invalid:65536",
                     "socks5://proxy.invalid:1080/path", "http://proxy.invalid:1080", "<html>:80", "bad host:80"] {
            XCTAssertNil(ProxyEntry.parse(line), line)
        }
    }

    func testIdentitiesKeepDifferentCredentialsAndPortsSeparate() {
        let entries = [ProxyEntry(host: "host.invalid", port: 1080),
                       ProxyEntry(host: "host.invalid", port: 1081),
                       ProxyEntry(host: "host.invalid", port: 1080, user: "alice", password: "one"),
                       ProxyEntry(host: "host.invalid", port: 1080, user: "alice", password: "two")]
        XCTAssertEqual(Set(entries.map(ProxyIdentity.init)).count, 4)
    }

    func testDownloadRequiresSuccessfulPlainTextAndValidUTF8() throws {
        let url = URL(string: "https://source.invalid/list")!
        func response(_ status: Int, _ type: String = "text/plain") -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
        }
        let body = Data("socks5://1.2.3.4:1080\n".utf8)
        XCTAssertEqual(try ProxySourceClient.text(data: body, response: response(200)), String(decoding: body, as: UTF8.self))
        for status in [301, 403, 429, 500] {
            XCTAssertThrowsError(try ProxySourceClient.text(data: body, response: response(status)))
        }
        XCTAssertThrowsError(try ProxySourceClient.text(data: Data("<html>error</html>".utf8), response: response(200)))
        XCTAssertThrowsError(try ProxySourceClient.text(data: body, response: response(200, "text/html")))
        XCTAssertThrowsError(try ProxySourceClient.text(data: Data([0xFF, 0xFE]), response: response(200)))
    }
}
