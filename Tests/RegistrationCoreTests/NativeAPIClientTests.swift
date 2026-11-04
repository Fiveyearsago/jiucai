import XCTest
@testable import RegistrationCore

final class NativeAPIClientTests: XCTestCase {
    @MainActor
    private func http(replies: [(Int, String, [String: String])], records: ((NetworkRecord) -> Void)? = nil,
                      inspect: ((URLRequest) throws -> Void)? = nil) throws -> NativeHTTPClient {
        var replies = replies
        return try NativeHTTPClient(baseURL: URL(string: "https://registration.test")!, timeoutSeconds: 17,
                                    headers: ["Accept-Language": "zh-CN", "Authorization": "private-header"],
                                    transport: { request in
            try inspect?(request)
            let reply = replies.removeFirst()
            return (Data(reply.1.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.0,
                                                       httpVersion: nil, headerFields: reply.2)!)
        }, onRecord: records)
    }

    @MainActor
    func testStatusAndVerificationUseNativeEndpointsAndEncodedEmail() async throws {
        var requests: [URLRequest] = []
        let client = try http(replies: [(200, #"{"success":true,"data":{"email_verification":true,"turnstile_check":false,"register_enabled":true,"password_register_enabled":true}}"#, [:]),
                                        (200, #"{"success":true}"#, [:])], inspect: { requests.append($0) })
        let api = RegistrationAPI(client: client)
        let status = try await api.status()
        XCTAssertTrue(status.emailVerificationEnabled)
        XCTAssertNoThrow(try status.validateNativeRegistration())
        let reply = try await api.sendVerification(email: "fixture+tag@test.invalid")
        XCTAssertTrue(reply.success)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/status", "/api/verification"])
        XCTAssertEqual(requests.last?.httpMethod, "GET")
        XCTAssertTrue(requests.last?.url?.absoluteString.contains("%2B") == true)
        XCTAssertEqual(requests.last?.timeoutInterval, 17)
        XCTAssertEqual(requests.last?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    @MainActor
    func testRegistrationSendsExpectedJSONAndKeepsSecretsOutOfRecords() async throws {
        var records: [NetworkRecord] = []
        var request: URLRequest?
        let client = try http(replies: [(200, #"{"success":true,"message":"registered"}"#, ["Set-Cookie": "session=private-cookie"])],
                              records: { records.append($0) }, inspect: { request = $0 })
        let input = NativeRegistrationInput(username: "fixture176", email: "fixture@test.invalid", password: "private-password",
                                            verificationCode: "a7F91c", invitation: "fixture-invite")
        let reply = try await RegistrationAPI(client: client).register(input)
        XCTAssertTrue(reply.success)
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/api/user/register")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: String])
        XCTAssertEqual(body["username"], input.username)
        XCTAssertEqual(body["password"], input.password)
        XCTAssertEqual(body["verification_code"], input.verificationCode)
        XCTAssertEqual(body["aff_code"], input.invitation)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let saved = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        for secret in ["private-password", "fixture@test.invalid", "a7F91c", "private-header", "private-cookie"] {
            XCTAssertFalse(saved.contains(secret), secret)
        }
        XCTAssertEqual(records.first?.transport, "原生接口")
    }

    func testOnlyBooleanSuccessAndExplicitRejectionsAreDecisive() throws {
        for body in [#"{"success":"true"}"#, #"{"success":1}"#, "<html>Sign in</html>", "{}"] {
            let reply = NativeAPIResponse(statusCode: 200, data: Data(body.utf8))
            XCTAssertFalse(reply.success)
            XCTAssertFalse(reply.explicitlyRejected)
        }
        XCTAssertTrue(NativeAPIResponse(statusCode: 200, data: Data(#"{"success":false}"#.utf8)).explicitlyRejected)
        XCTAssertFalse(NativeAPIResponse(statusCode: 502, data: Data(#"{"success":false}"#.utf8)).explicitlyRejected)
        XCTAssertFalse(NativeAPIResponse(statusCode: 408, data: Data()).explicitlyRejected)
        XCTAssertTrue(NativeAPIResponse(statusCode: 429, data: Data()).explicitlyRejected)
    }

    func testServerDiagnosticsRedactEchoedCredentialsAndParseRetryAfter() {
        let response = NativeAPIResponse(statusCode: 429,
            data: Data(#"{"success":false,"message":"private-password fixture@test.invalid a7F91c token=private-token"}"#.utf8),
            headers: ["Retry-After": "45"], secrets: ["private-password", "fixture@test.invalid", "a7F91c"])
        XCTAssertEqual(response.retryAfterSeconds, 45)
        XCTAssertFalse(response.message.contains("private-"))
        XCTAssertFalse(response.message.contains("fixture@test.invalid"))
        XCTAssertFalse(response.message.contains("a7F91c"))
        XCTAssertEqual(response.retryDictionary["status"] as? Int, 429)
    }

    @MainActor
    func testHumanVerificationAndClosedRegistrationStopBeforeSendingMail() async throws {
        for data in [#"{"email_verification":true,"turnstile_check":true}"#,
                     #"{"email_verification":true,"register_enabled":false}"#] {
            let client = try http(replies: [(200, "{\"success\":true,\"data\":\(data)}", [:])])
            let status = try await RegistrationAPI(client: client).status()
            XCTAssertThrowsError(try status.validateNativeRegistration())
        }
    }

    @MainActor
    func testNativeTimeoutIsTypedAndCancellationIsPreserved() async throws {
        let client = try NativeHTTPClient(baseURL: URL(string: "https://registration.test")!, timeoutSeconds: 3,
                                         transport: { _ in throw URLError(.timedOut) })
        do { _ = try await client.request(path: "/api/status"); XCTFail("Expected timeout") }
        catch let error as NativeAPIError { XCTAssertTrue(error.isTimeout) }
        let cancelled = try NativeHTTPClient(baseURL: URL(string: "https://registration.test")!, transport: { _ in throw CancellationError() })
        do { _ = try await cancelled.request(path: "/api/status"); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testRequestValidationPreventsCrossOriginAndHeaderInjection() async throws {
        XCTAssertThrowsError(try NativeHTTPClient(baseURL: URL(string: "http://registration.test")!, transport: { _ in fatalError() }))
        XCTAssertThrowsError(try NativeHTTPClient(baseURL: URL(string: "https://registration.test")!, headers: ["Accept": "ok\r\nInjected: value"], transport: { _ in fatalError() }))
        let client = try http(replies: [])
        do { _ = try await client.request(path: "https://other.invalid/api/user/register"); XCTFail("Expected invalid path") }
        catch { XCTAssertTrue(error is NativeAPIError) }
    }
    @MainActor
    func testMailboxChecksServicePolicyAndUsesNativeInboxEndpoints() async throws {
        var paths: [String] = []
        let client = try http(replies: [(200, #"{"turnstile_enabled":false}"#, [:]),
                                        (200, #"{"result":[]}"#, [:]),
                                        (200, "<p>验证码：a7F91c</p>", [:])], inspect: { paths.append($0.url!.path) })
        let mailbox = MailboxAPI(client: client)
        try await mailbox.checkAvailability()
        let messages = try await mailbox.messages(username: "fixture176")
        XCTAssertTrue(messages.isEmpty)
        let html = try await mailbox.messageHTML(username: "fixture176", id: "message-id")
        XCTAssertEqual(MailVerification.code(fromHTML: html), "a7F91c")
        XCTAssertEqual(paths, ["/captcha/status", "/messages", "/message"])
        let blocked = MailboxAPI(client: try http(replies: [(200, #"{"turnstile_enabled":true}"#, [:])]))
        do { try await blocked.checkAvailability(); XCTFail("Must require human interaction") }
        catch let error as NativeAPIError { XCTAssertTrue(error.requiresInteraction) }
    }

    @MainActor
    func testMailboxDecodesJSONEncodedHTMLBeforeExtractingCode() async throws {
        let payload = #""\u003cp\u003e您好，你正在进行韭菜盒子邮箱验证。\u003c/p\u003e\u003cp\u003e您的验证码为: \u003cstrong\u003eAb12C3\u003c/strong\u003e\u003c/p\u003e\r\n""#
        let mailbox = MailboxAPI(client: try http(replies: [(200, payload, ["Content-Type": "application/json; charset=UTF-8"])]))
        let html = try await mailbox.messageHTML(username: "fixture176", id: "message-id")
        XCTAssertEqual(html, "<p>您好，你正在进行韭菜盒子邮箱验证。</p><p>您的验证码为: <strong>Ab12C3</strong></p>\r\n")
        XCTAssertEqual(MailVerification.code(fromHTML: html), "Ab12C3")
    }

    @MainActor
    func testRecordedOriginAndRefererRemoveCredentialsQueriesAndUnknownPaths() async throws {
        var records: [NetworkRecord] = []
        let client = try NativeHTTPClient(baseURL: URL(string: "https://registration.test")!,
            headers: ["Origin": "https://private-user:private-password@registration.test/private-origin?token=private-query",
                      "Referer": "https://private-user:private-password@registration.test/private-referer?code=private-query#private-fragment"],
            transport: { request in
                (Data(#"{"success":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, onRecord: { records.append($0) })
        _ = try await client.request(path: "/api/status")
        let saved = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        for secret in ["private-user", "private-password", "private-origin", "private-referer", "private-query", "private-fragment"] {
            XCTAssertFalse(saved.contains(secret), secret)
        }
    }

}
