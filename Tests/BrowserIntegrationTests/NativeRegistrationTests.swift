import XCTest
import RegistrationCore
@testable import BeautyRegistration

@MainActor
final class NativeRegistrationTests: XCTestCase {
    private let statusWithEmail = #"{"success":true,"data":{"email_verification":true,"turnstile_check":false,"register_enabled":true}}"#
    private let statusWithoutEmail = #"{"success":true,"data":{"email_verification":false,"turnstile_check":false,"register_enabled":true}}"#

    private func response(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func model(factory: @escaping RegistrationModel.TransportFactory,
                       proxyTest: @escaping RegistrationModel.ProxyTest = { _, _ in
                           .init(verdict: .usable, status: 200, milliseconds: 20, exit: nil, error: nil)
                       }) throws -> RegistrationModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-workflow-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = RegistrationModel(store: JournalStore(directory: directory.appendingPathComponent("journal")),
                                      passwordStore: LocalPasswordStore(directory: directory.appendingPathComponent("password")),
                                      transportFactory: factory, proxyTest: proxyTest, retryDelaySeconds: 0.02)
        model.password = "fixture-password"
        model.acknowledgedMailboxTerms = true
        model.autoReadMailbox = false
        return model
    }

    private func until(_ condition: () -> Bool) async throws {
        let ready = try await WorkflowWait.until(timeout: 3, pollEvery: 0.01) { condition() }
        XCTAssertTrue(ready, "Workflow did not reach expected state")
    }

    func testManualFormSendsMailThenWaitsForExplicitSubmitUsingSameConnection() async throws {
        var requests: [URLRequest] = []
        var connections = 0
        let model = try model { proxy, timeout in
            XCTAssertNil(proxy); XCTAssertEqual(timeout, 10)
            connections += 1
            return { request in
                requests.append(request)
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithEmail : #"{"success":true}"#)
            }
        }
        model.formUsername = "native176"; model.formEmail = "native176@fviainboxes.com"
        model.requestNativeVerification()
        try await until { model.waitingForCode }
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/status", "/api/verification"])
        model.manualCode = "a7F91c"
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(requests.count, 2, "Manual flow must wait for the register button")
        XCTAssertTrue(model.canSubmitNativeRegistration)
        model.submitNativeRegistration()
        try await until { !model.isRunning }
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(requests.last?.url?.path, "/api/user/register")
        XCTAssertEqual(model.records.first?.status, .succeeded)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: String])
        XCTAssertEqual(body["username"], "native176")
        XCTAssertEqual(body["verification_code"], "a7F91c")
        let journal = String(decoding: try Data(contentsOf: model.store.fileURL), as: UTF8.self)
        XCTAssertFalse(journal.contains("fixture-password")); XCTAssertFalse(journal.contains("a7F91c"))
    }

    func testBatchAutomaticallyReadsJSONEncodedMailboxMessageAndSubmits() async throws {
        var inboxReads = 0
        var registration: [String: String]?
        var origins: [String] = []
        let model = try model { proxy, _ in
            XCTAssertNil(proxy)
            return { request in
                origins.append(request.url!.host!)
                switch request.url!.path {
                case "/api/status": return self.response(request, self.statusWithEmail)
                case "/captcha/status": return self.response(request, #"{"turnstile_enabled":false}"#)
                case "/messages":
                    inboxReads += 1
                    if inboxReads == 1 { return self.response(request, #"{"result":[]}"#) }
                    return self.response(request, "{\"result\":[{\"id\":\"new-code\",\"subject\":\"韭菜盒子邮箱验证码\",\"from\":\"jiucai\",\"createdAt\":\(Date().timeIntervalSince1970)}]}")
                case "/message":
                    // The deployed mailbox API returns a JSON string with escaped HTML tags.
                    return self.response(request, #""\u003cp\u003e您好，你正在进行韭菜盒子邮箱验证。\u003c/p\u003e\u003cp\u003e您的验证码为: \u003cstrong\u003ea7F91c\u003c/strong\u003e\u003c/p\u003e\r\n""#)
                case "/api/user/register":
                    registration = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
                    return self.response(request, #"{"success":true}"#)
                default: return self.response(request, #"{"success":true}"#)
                }
            }
        }
        defer { model.stop() }
        model.autoReadMailbox = true
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(model.completedInRun, 1)
        XCTAssertEqual(registration?["verification_code"], "a7F91c")
        XCTAssertTrue(origins.contains("fviainboxes.com"))
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertTrue(model.records.first?.logs.contains(where: { $0.contains("已自动读取并填入验证码") }) == true)
    }

    func testAmbiguousPostStopsWithoutTryingAnotherProxy() async throws {
        var posts = 0
        var attempts: [UUID?] = []
        let model = try model { proxy, _ in
            attempts.append(proxy?.id)
            return { request in
                if request.url!.path == "/api/status" { return self.response(request, self.statusWithoutEmail) }
                posts += 1
                throw URLError(.timedOut)
            }
        }
        let first = ProxyEntry(host: "first.invalid", port: 1080)
        let next = ProxyEntry(host: "next.invalid", port: 1080)
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [first, next]
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(attempts, [first.id])
        XCTAssertEqual(model.records.first?.status, .uncertain)
        XCTAssertEqual(model.proxyConfiguration.entries, [next], "Timeout still removes the failed proxy")
    }

    func testTimeoutBeforeSubmissionDeletesProxyAndTriesImmediateSuccessor() async throws {
        var attempts: [UUID?] = []
        let first = ProxyEntry(host: "first.invalid", port: 1080)
        let second = ProxyEntry(host: "second.invalid", port: 1080)
        let third = ProxyEntry(host: "third.invalid", port: 1080)
        let model = try model { proxy, _ in
            attempts.append(proxy?.id)
            return { request in
                if proxy?.id == first.id { throw URLError(.timedOut) }
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithoutEmail : #"{"success":true}"#)
            }
        }
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [first, second, third]
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(attempts, [first.id, second.id])
        XCTAssertEqual(model.proxyConfiguration.entries, [second, third])
        XCTAssertEqual(model.records.first?.status, .succeeded)
    }

    func testExplicitRegistrationRejectionCanUseNextProxy() async throws {
        var posts: [UUID?] = []
        let first = ProxyEntry(host: "first.invalid", port: 1080)
        let second = ProxyEntry(host: "second.invalid", port: 1080)
        let model = try model { proxy, _ in
            return { request in
                if request.url!.path == "/api/status" { return self.response(request, self.statusWithoutEmail) }
                posts.append(proxy?.id)
                return self.response(request, proxy?.id == first.id ? #"{"success":false,"message":"rejected"}"# : #"{"success":true}"#)
            }
        }
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [first, second]
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(posts, [first.id, second.id])
        XCTAssertEqual(model.records.first?.status, .succeeded)
    }

    func testMailboxChallengeSwitchesProxyAndAutomaticallyRecovers() async throws {
        let first = ProxyEntry(host: "mail-challenge.invalid", port: 1080)
        let second = ProxyEntry(host: "mail-working.invalid", port: 1080)
        var reads = 0
        var posts = 0
        let model = try model { proxy, _ in
            return { request in
                switch request.url!.path {
                case "/api/status": return self.response(request, self.statusWithEmail)
                case "/captcha/status":
                    return self.response(request, proxy?.id == first.id ? #"{"turnstile_enabled":true}"# : #"{"turnstile_enabled":false}"#)
                case "/messages":
                    reads += 1
                    if reads == 1 { return self.response(request, #"{"result":[]}"#) }
                    return self.response(request, "{\"result\":[{\"id\":\"new-mail\",\"subject\":\"韭菜盒子邮箱验证邮件\",\"from\":\"jiucai\",\"createdAt\":\(Date().timeIntervalSince1970)}]}")
                case "/message": return self.response(request, "<p>验证码：ABC123</p>")
                case "/api/user/register": posts += 1; return self.response(request, #"{"success":true}"#)
                default: return self.response(request, #"{"success":true}"#)
                }
            }
        }
        defer { model.stop() }
        model.autoReadMailbox = true
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [first, second]
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertFalse(model.isPaused)
        XCTAssertNil(model.alert)
    }

    func testPausePreventsSubmissionAndStopCancelsWaitingCode() async throws {
        var posts = 0
        let model = try model { _, _ in
            return { request in
                if request.url!.path == "/api/user/register" { posts += 1 }
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithEmail : #"{"success":true}"#)
            }
        }
        model.requestNativeVerification()
        try await until { model.waitingForCode }
        model.togglePause(); model.manualCode = "ABC123"; model.submitNativeRegistration()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(posts, 0)
        model.stop()
        try await until { !model.isRunning }
        XCTAssertEqual(model.records.first?.status, .cancelled)
        XCTAssertEqual(posts, 0)
    }

    func testJournalFailureKeepsTaskRunningAndRecoversBeforePosting() async throws {
        var posts = 0
        let model = try model { _, _ in
            return { request in
                if request.url!.path == "/api/user/register" { posts += 1 }
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithEmail : #"{"success":true}"#)
            }
        }
        defer { model.stop() }
        model.requestNativeVerification()
        try await until { model.waitingForCode }
        try FileManager.default.removeItem(at: model.store.directory)
        try Data("blocks-journal-directory".utf8).write(to: model.store.directory)
        model.manualCode = "ABC123"; model.submitNativeRegistration()
        try await until { model.phase == "等待本地记录恢复" }
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(posts, 0)
        XCTAssertNotEqual(model.records.first?.status, .uncertain)
        XCTAssertNil(model.alert)
        try FileManager.default.removeItem(at: model.store.directory)
        try await until { model.waitingForCode }
        model.manualCode = "ABC123"; model.submitNativeRegistration()
        try await until { !model.isRunning }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(model.records.first?.status, .succeeded)
    }

    func testConnectionCheckNeverSendsMailOrCreatesAccount() async throws {
        var paths: [String] = []
        let model = try model { _, _ in
            return { request in
                paths.append(request.url!.path)
                return self.response(request, self.statusWithEmail)
            }
        }
        model.checkAPIConnection()
        try await until { !model.isCheckingConnection }
        XCTAssertEqual(paths, ["/api/status"])
        XCTAssertTrue(model.records.isEmpty)
    }

    func testSiteChallengeSwitchesProxyAndContinuesWithoutPausing() async throws {
        var connections = 0
        var paths: [String] = []
        let model = try model { _, _ in
            connections += 1
            return { request in
                paths.append(request.url!.path)
                if connections == 1 {
                    return self.response(request, #"{"success":true,"data":{"email_verification":true,"turnstile_check":true}}"#)
                }
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithoutEmail : #"{"success":true}"#)
            }
        }
        model.proxyConfiguration.enabled = true
        model.proxyConfiguration.entries = (0..<3).map { ProxyEntry(host: "challenge\($0).invalid", port: 1080) }
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(connections, 2)
        XCTAssertEqual(paths, ["/api/status", "/api/status", "/api/user/register"])
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertEqual(model.proxyConfiguration.entries.count, 3)
        XCTAssertFalse(model.isPaused)
        XCTAssertNil(model.alert)
    }

    func testProxyRetryRequiresFreshManualCodeAndAnotherSubmitClick() async throws {
        var sends = 0
        var posts = 0
        let model = try model { _, _ in
            return { request in
                switch request.url!.path {
                case "/api/status": return self.response(request, self.statusWithEmail)
                case "/api/verification": sends += 1; return self.response(request, #"{"success":true}"#)
                case "/api/user/register":
                    posts += 1
                    return self.response(request, posts == 1 ? #"{"success":false,"message":"rejected"}"# : #"{"success":true}"#)
                default: XCTFail("Unexpected request"); return self.response(request, "{}")
                }
            }
        }
        model.proxyConfiguration.enabled = true
        model.proxyConfiguration.entries = (0..<2).map { ProxyEntry(host: "retry\($0).invalid", port: 1080) }
        model.requestNativeVerification()
        try await until { model.waitingForCode && sends == 1 }
        model.manualCode = "OLD123"; model.submitNativeRegistration()
        try await until { model.waitingForCode && sends == 2 }
        XCTAssertEqual(model.manualCode, "")
        XCTAssertFalse(model.canSubmitNativeRegistration)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(posts, 1)
        model.manualCode = "NEW456"; model.submitNativeRegistration()
        try await until { !model.isRunning }
        XCTAssertEqual(posts, 2)
        XCTAssertEqual(model.records.first?.status, .succeeded)
    }

    func testExplicitSuccessIsPreservedWhenStopArrivesDuringPost() async throws {
        var activeModel: RegistrationModel?
        let model = try model { _, _ in
            return { request in
                if request.url!.path == "/api/status" { return self.response(request, self.statusWithoutEmail) }
                activeModel?.stop()
                return self.response(request, #"{"success":true}"#)
            }
        }
        activeModel = model
        model.start()
        try await until { !model.isRunning }
        activeModel = nil
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertEqual(model.completedInRun, 1)
    }

    func testStoppedUnknownBatchSubmissionCountsAsProcessed() async throws {
        var activeModel: RegistrationModel?
        var posts = 0
        let model = try model { _, _ in
            return { request in
                if request.url!.path == "/api/status" { return self.response(request, self.statusWithoutEmail) }
                posts += 1
                activeModel?.stop()
                throw URLError(.cancelled)
            }
        }
        activeModel = model
        defer { activeModel = nil; model.stop() }
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(model.records.first?.status, .uncertain)
        XCTAssertEqual(model.completedInRun, 1)
    }

    func testStoppedUnknownManualSubmissionCountsAsProcessed() async throws {
        var activeModel: RegistrationModel?
        var posts = 0
        let model = try model { _, _ in
            return { request in
                if request.url!.path == "/api/status" { return self.response(request, self.statusWithoutEmail) }
                posts += 1
                activeModel?.stop()
                return self.response(request, "Bad Gateway", status: 502)
            }
        }
        activeModel = model
        defer { activeModel = nil; model.stop() }
        model.requestNativeVerification()
        try await until { model.waitingForCode }
        model.submitNativeRegistration()
        try await until { !model.isRunning }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(model.records.first?.status, .uncertain)
        XCTAssertEqual(model.completedInRun, 1)
    }

    func testUnreadableJournalCannotBeOverwrittenByProxyTesting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corrupted-native-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("original-unreadable-records-to-preserve".utf8)
        try original.write(to: store.fileURL)
        let model = RegistrationModel(store: store,
                                      passwordStore: LocalPasswordStore(directory: directory.appendingPathComponent("password")),
                                      transportFactory: { _, _ in { _ in XCTFail("Must not make requests"); throw CancellationError() } })
        XCTAssertFalse(model.storageAvailable)
        model.proxyConfiguration.entries = [ProxyEntry(host: "never-test.invalid", port: 1080)]
        model.testProxies(model.proxyConfiguration.entries)
        // Cancel before yielding the main actor: even the old behavior cannot start network traffic.
        model.stopProxyTests()
        let startedTesting = model.isTestingProxies
        try await until { !model.isTestingProxies }
        XCTAssertFalse(startedTesting)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testPauseDuringMailboxAvailabilityDoesNotStartInboxRequest() async throws {
        var activeModel: RegistrationModel?
        var inboxRequests = 0
        let model = try model { _, _ in
            return { request in
                switch request.url!.path {
                case "/api/status": return self.response(request, self.statusWithEmail)
                case "/captcha/status":
                    activeModel?.togglePause()
                    return self.response(request, #"{"turnstile_enabled":false}"#)
                case "/messages": inboxRequests += 1; return self.response(request, #"{"result":[]}"#)
                default: return self.response(request, #"{"success":true}"#)
                }
            }
        }
        activeModel = model
        model.autoReadMailbox = true
        model.requestNativeVerification()
        try await until { model.isPaused }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(inboxRequests, 0)
        model.togglePause()
        try await until { model.waitingForCode }
        XCTAssertGreaterThan(inboxRequests, 0)
        model.stop()
        try await until { !model.isRunning }
        activeModel = nil
    }

    func testAllProxiesFailOneRoundThenAutomaticallyRetryUntilSuccess() async throws {
        let first = ProxyEntry(host: "round-first.invalid", port: 1080)
        let second = ProxyEntry(host: "round-second.invalid", port: 1080)
        var attempts: [UUID?] = []
        let model = try model { proxy, _ in
            attempts.append(proxy?.id)
            let attempt = attempts.count
            return { request in
                if attempt <= 2 { throw URLError(.cannotConnectToHost) }
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithoutEmail : #"{"success":true}"#)
            }
        }
        defer { model.stop() }
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [first, second]
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(attempts, [first.id, second.id, first.id])
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertEqual(model.records.count, 1)
        XCTAssertNil(model.alert)
    }

    func testEmptyProxyPoolKeepsTaskRunningAndAutomaticallyUsesAddedProxy() async throws {
        let expired = ProxyEntry(host: "expired.invalid", port: 1080)
        let added = ProxyEntry(host: "added.invalid", port: 1080)
        var attempts: [UUID?] = []
        let model = try model { proxy, _ in
            attempts.append(proxy?.id)
            return { request in
                if proxy?.id == expired.id { throw URLError(.timedOut) }
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithoutEmail : #"{"success":true}"#)
            }
        }
        defer { model.stop() }
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [expired]
        model.start()
        try await until { model.proxyConfiguration.entries.isEmpty }
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.isPaused)
        XCTAssertNil(model.alert)
        model.proxyConfiguration.entries.append(added)
        try await until { !model.isRunning }
        XCTAssertEqual(attempts, [expired.id, added.id])
        XCTAssertEqual(model.records.first?.status, .succeeded)
    }

    func testAmbiguousSubmissionIsRecordedAndNextAccountUsesNextProxy() async throws {
        let first = ProxyEntry(host: "unknown-first.invalid", port: 1080)
        let second = ProxyEntry(host: "unknown-second.invalid", port: 1080)
        var posts: [(String, UUID?)] = []
        let model = try model { proxy, _ in
            return { request in
                if request.url!.path == "/api/status" { return self.response(request, self.statusWithoutEmail) }
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                posts.append((body["username"]!, proxy?.id))
                if posts.count == 1 { return self.response(request, "Bad Gateway", status: 502) }
                return self.response(request, #"{"success":true}"#)
            }
        }
        defer { model.stop() }
        model.configuration.count = 2
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [first, second]
        model.proxyConfiguration.switchEvery = 10
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(posts.map(\.0), [model.configuration.username(176), model.configuration.username(177)])
        XCTAssertEqual(posts.map(\.1), [first.id, second.id])
        XCTAssertEqual(model.records.map(\.status), [.uncertain, .succeeded])
        XCTAssertEqual(model.completedInRun, 2)
        XCTAssertFalse(model.isPaused)
        XCTAssertNil(model.alert)
    }

    func testMailboxPollingFailureSwitchesProxyAndStillAutomaticallyRegisters() async throws {
        let first = ProxyEntry(host: "mail-first.invalid", port: 1080)
        let second = ProxyEntry(host: "mail-second.invalid", port: 1080)
        var inboxReads: [UUID: Int] = [:]
        var mailboxProxies: [UUID?] = []
        var posts: [UUID?] = []
        let model = try model { proxy, _ in
            return { request in
                switch request.url!.path {
                case "/api/status": return self.response(request, self.statusWithEmail)
                case "/captcha/status":
                    mailboxProxies.append(proxy?.id)
                    return self.response(request, #"{"turnstile_enabled":false}"#)
                case "/messages":
                    let id = proxy?.id ?? first.id
                    inboxReads[id, default: 0] += 1
                    if inboxReads[id] == 1 { return self.response(request, #"{"result":[]}"#) }
                    if id == first.id { throw URLError(.networkConnectionLost) }
                    return self.response(request, "{\"result\":[{\"id\":\"fresh-code\",\"subject\":\"韭菜盒子邮箱验证邮件\",\"from\":\"jiucai\",\"createdAt\":\(Date().timeIntervalSince1970)}]}")
                case "/message": return self.response(request, #""\u003cp\u003e验证码为: \u003cstrong\u003eNEW123\u003c/strong\u003e\u003c/p\u003e""#)
                case "/api/user/register":
                    posts.append(proxy?.id)
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                    XCTAssertEqual(body["verification_code"], "NEW123")
                    return self.response(request, #"{"success":true}"#)
                default: return self.response(request, #"{"success":true}"#)
                }
            }
        }
        defer { model.stop() }
        model.autoReadMailbox = true
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [first, second]
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(mailboxProxies, [first.id, second.id])
        XCTAssertEqual(posts, [second.id])
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertFalse(model.isPaused)
        XCTAssertNil(model.alert)
    }

    func testDirectConnectionFailuresAutomaticallyRetryEvenWhenCooldownIsZero() async throws {
        var attempts = 0
        let model = try model { proxy, _ in
            XCTAssertNil(proxy); attempts += 1
            let attempt = attempts
            return { request in
                if attempt == 1 { throw URLError(.cannotConnectToHost) }
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithoutEmail : #"{"success":true}"#)
            }
        }
        defer { model.stop() }
        model.configuration.cooldownMinutes = 0
        model.start()
        try await until { !model.isRunning }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertNil(model.alert)
    }

    func testPersistentFailuresRemainActiveUntilUserStops() async throws {
        var attempts = 0
        let model = try model { _, _ in
            attempts += 1
            return { _ in throw URLError(.cannotConnectToHost) }
        }
        defer { model.stop() }
        model.proxyConfiguration.enabled = true
        model.proxyConfiguration.entries = [ProxyEntry(host: "offline.invalid", port: 1080)]
        model.start()
        try await until { attempts >= 3 }
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.isPaused)
        XCTAssertNil(model.alert)
        model.stop()
        try await until { !model.isRunning }
        XCTAssertEqual(model.records.first?.status, .cancelled)
    }

    func testPreflightExhaustionKeepsTaskAliveUntilNewProxyArrives() async throws {
        let bad = ProxyEntry(host: "bad-preflight.invalid", port: 1080)
        let added = ProxyEntry(host: "new-preflight.invalid", port: 1080)
        var attempts: [UUID?] = []
        let model = try model(factory: { proxy, _ in
            attempts.append(proxy?.id)
            return { request in
                return self.response(request, request.url!.path == "/api/status" ? self.statusWithoutEmail : #"{"success":true}"#)
            }
        }, proxyTest: { proxy, _ in
            .init(verdict: proxy.id == bad.id ? .unreachable : .usable, status: 200,
                  milliseconds: 10, exit: nil, error: nil)
        })
        defer { model.stop() }
        model.proxyConfiguration.enabled = true; model.proxyConfiguration.entries = [bad]
        model.start()
        try await until { model.proxyConfiguration.entries.isEmpty }
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.isPaused)
        model.proxyConfiguration.entries.append(added)
        try await until { !model.isRunning }
        XCTAssertEqual(attempts, [added.id])
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertNil(model.alert)
    }

    func testConfirmedSuccessWaitsForStorageRecoveryWithoutSubmittingAgain() async throws {
        var activeModel: RegistrationModel?
        var posts = 0
        let model = try model { _, _ in
            return { request in
                if request.url!.path == "/api/status" { return self.response(request, self.statusWithoutEmail) }
                posts += 1
                let directory = activeModel!.store.directory
                try FileManager.default.removeItem(at: directory)
                try Data("blocks-save-after-success".utf8).write(to: directory)
                return self.response(request, #"{"success":true}"#)
            }
        }
        activeModel = model
        defer { activeModel = nil; model.stop() }
        model.start()
        try await until { model.phase == "等待本地记录恢复" }
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.records.first?.status, .succeeded)
        XCTAssertEqual(posts, 1)
        XCTAssertNil(model.alert)
        try FileManager.default.removeItem(at: model.store.directory)
        try await until { !model.isRunning }
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(model.completedInRun, 1)
        XCTAssertEqual(try model.store.load().records.first?.status, .succeeded)
    }
}
