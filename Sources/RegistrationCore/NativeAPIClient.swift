import Foundation
import CoreFoundation

public enum NativeAPIError: LocalizedError, Equatable {
    case invalidConfiguration, invalidInput(String), invalidResponse
    case timeout(TimeInterval), network(Int), interactionRequired(String), registrationUnavailable

    public var isTimeout: Bool { if case .timeout = self { return true }; return false }
    public var requiresInteraction: Bool { if case .interactionRequired = self { return true }; return false }
    public var stopsProxyRetry: Bool {
        switch self { case .interactionRequired, .registrationUnavailable, .invalidInput, .invalidConfiguration: return true; default: return false }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "接口地址或请求头配置无效，请检查设置。"
        case .invalidInput(let reason): return reason
        case .invalidResponse: return "接口未返回有效数据，请检查服务器状态。"
        case .timeout(let seconds): return "接口请求超过 \(seconds.formatted(.number.grouping(.never))) 秒。"
        case .network(let code): return "接口网络请求失败（错误 \(code)）。"
        case .interactionRequired(let service): return "\(service)要求网页人机验证，原生接口无法继续。请通过官网处理。"
        case .registrationUnavailable: return "网站当前未开放密码注册。"
        }
    }
}

private func nativeJSONBool(_ value: Any?) -> Bool? {
    guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return value.boolValue
}

public enum NativeRedaction {
    public static func text(_ input: String, secrets: [String] = []) -> String {
        var result = input
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[已隐藏]")
        }
        guard result.range(of: #"</?[A-Za-z][^>]*>"#, options: .regularExpression) == nil else { return "" }
        for (pattern, replacement) in [
            (#"[\w.+-]+@[\w.-]+\.[a-z]{2,}"#, "[邮箱已隐藏]"),
            (#"((?:password|密码|token|secret|api[_ -]?key|authorization)\s*[:=：]\s*)[\"']?[^\s\"',;]+"#, "$1[已隐藏]"),
            (#"\b(?:sk-|eyJ)[a-z0-9._-]{12,}\b"#, "[凭据已隐藏]")
        ] {
            if let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }
        return String(result.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct NativeAPIResponse {
    public let statusCode: Int
    public let data: Data
    public let success: Bool
    public let explicitlyRejected: Bool
    public let message: String
    public let retryAfterSeconds: Int?
    public let requiresInteraction: Bool
    public var object: [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    public var retryDictionary: [String: Any] {
        var value: [String: Any] = ["status": statusCode, "success": success, "message": message]
        if let retryAfterSeconds { value["retryAfterSeconds"] = retryAfterSeconds }
        return value
    }

    public init(statusCode: Int, data: Data, headers: [String: String] = [:], secrets: [String] = []) {
        self.statusCode = statusCode; self.data = data
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let result = nativeJSONBool(object?["success"])
        success = (200..<300).contains(statusCode) && result == true
        explicitlyRejected = !success && (((200..<300).contains(statusCode) && result == false)
            || ((400..<500).contains(statusCode) && statusCode != 408))
        let rawMessage = object?["message"] as? String ?? (object?["error"] as? [String: Any])?["message"] as? String ?? object?["error"] as? String ?? ""
        message = NativeRedaction.text(rawMessage, secrets: secrets)
        let header = { (name: String) in headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
        requiresInteraction = header("CF-Mitigated")?.lowercased() == "challenge"
        if let raw = header("Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines), let number = Int(raw), number >= 0 {
            retryAfterSeconds = number
        } else if let raw = header("Retry-After") {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) {
                let interval = ceil(max(0, date.timeIntervalSinceNow))
                retryAfterSeconds = interval < Double(Int.max) ? Int(interval) : nil
            } else { retryAfterSeconds = nil }
        } else { retryAfterSeconds = nil }
    }

    public func failure(operation: String) -> Error {
        if requiresInteraction { return NativeAPIError.interactionRequired(operation) }
        return ClientError.message(ServerFailure.describe(retryDictionary, operation: operation))
    }
}

private final class NativeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // API requests have fixed endpoints. Never replay credentials or send-code actions on redirects.
        completionHandler(nil)
    }
}

@MainActor
public final class NativeHTTPClient {
    public typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let baseURL: URL
    private let timeoutSeconds: TimeInterval
    private let headers: [String: String]
    private let transport: Transport
    private let onRecord: ((NetworkRecord) -> Void)?

    public init(baseURL: URL, timeoutSeconds: TimeInterval = 10, headers: [String: String] = [:],
                transport: @escaping Transport, onRecord: ((NetworkRecord) -> Void)? = nil) throws {
        guard let address = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), address.scheme == "https",
              address.host != nil, address.user == nil, address.password == nil,
              address.query == nil, address.fragment == nil, ["", "/"].contains(address.path),
              timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw NativeAPIError.invalidConfiguration }
        for (name, value) in headers {
            guard name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !["host", "content-length", "connection", "transfer-encoding", "proxy-authorization"].contains(name.lowercased()) else {
                throw NativeAPIError.invalidConfiguration
            }
        }
        self.baseURL = baseURL; self.timeoutSeconds = timeoutSeconds; self.headers = headers
        self.transport = transport; self.onRecord = onRecord
    }

    public static func urlSessionTransport(_ session: URLSession) -> Transport {
        { request in
            let (data, response) = try await session.data(for: request, delegate: NativeRedirectPolicy())
            guard let response = response as? HTTPURLResponse else { throw NativeAPIError.invalidResponse }
            return (data, response)
        }
    }

    public func request(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                        secrets: [String] = []) async throws -> NativeAPIResponse {
        try Task.checkCancellation()
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(":"), !path.contains("?"), !path.contains("#"),
              !path.contains("\\"), !path.split(separator: "/").contains("..") else { throw NativeAPIError.invalidConfiguration }
        var address = URLComponents(url: baseURL.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false)!
        address.queryItems = query.isEmpty ? nil : query
        // '+' is literal in email addresses, but server query decoders otherwise treat it as a space.
        address.percentEncodedQuery = address.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = address.url else { throw NativeAPIError.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        request.setValue(baseURL.appendingPathComponent("sign-up").absoluteString, forHTTPHeaderField: "Referer")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let safeRequestNames = ["User-Agent", "Accept", "Accept-Language", "Content-Type", "Cache-Control", "Pragma", "X-Requested-With", "Origin", "Referer"]
        let safeRequestHeaders = safeRequestNames.compactMap { name -> NetworkHeader? in
            guard var value = request.value(forHTTPHeaderField: name) else { return nil }
            if ["Origin", "Referer"].contains(name) {
                if var components = URLComponents(string: value), components.host != nil {
                    components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
                    let knownPaths = ["/", "/sign-up", "/sign-in", "/api/status", "/api/verification", "/api/user/register"]
                    if name == "Origin" { components.path = "" }
                    else if !knownPaths.contains(components.path) { components.path = "/" }
                    value = components.string ?? ""
                } else { value = "[地址已隐藏]" }
            }
            return NetworkHeader(name: name, value: NativeRedaction.text(value, secrets: secrets), source: "客户端配置")
        }
        do {
            let (data, response) = try await transport(request)
            let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
            let reply = NativeAPIResponse(statusCode: response.statusCode, data: data, headers: responseHeaders, secrets: secrets)
            let safeNames = ["content-type", "retry-after", "cf-ray", "cf-mitigated", "server", "date"]
            let safeHeaders = responseHeaders.filter { safeNames.contains($0.key.lowercased()) }
                .map { NetworkHeader(name: $0.key, value: NativeRedaction.text($0.value, secrets: secrets)) }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            onRecord?(NetworkRecord(method: method, path: path, transport: "原生接口", status: response.statusCode,
                                    requestHeaders: safeRequestHeaders, responseHeaders: safeHeaders,
                                    responseBody: reply.message, retryAfter: responseHeaders.first { $0.key.lowercased() == "retry-after" }?.value))
            return reply
        } catch {
            let failure: Error
            if error is CancellationError || Task.isCancelled { failure = CancellationError() }
            else if let error = error as? NativeAPIError { failure = error }
            else if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorTimedOut {
                failure = NativeAPIError.timeout(timeoutSeconds)
            } else { failure = NativeAPIError.network((error as NSError).code) }
            onRecord?(NetworkRecord(method: method, path: path, transport: "原生接口", status: 0,
                                    requestHeaders: safeRequestHeaders, responseHeaders: [],
                                    responseBody: failure is CancellationError ? "请求已取消。" : failure.localizedDescription, retryAfter: nil))
            throw failure
        }
    }
}

public struct NativeRegistrationInput: Equatable {
    public let username: String
    public let email: String
    public let password: String
    public let verificationCode: String
    public let invitation: String
    public init(username: String, email: String, password: String, verificationCode: String = "", invitation: String = "") {
        self.username = username; self.email = email; self.password = password
        self.verificationCode = verificationCode; self.invitation = invitation
    }
    public func validate(requireCode: Bool = true, requireEmail: Bool = true) throws {
        guard username.range(of: #"^[A-Za-z0-9_-]{1,20}$"#, options: .regularExpression) != nil else {
            throw NativeAPIError.invalidInput("用户名需为 1–20 位字母、数字、下划线或短横线。")
        }
        guard (8...128).contains(password.count) else { throw NativeAPIError.invalidInput("密码长度需为 8–128 位。") }
        if requireEmail || !email.isEmpty {
            guard email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { throw NativeAPIError.invalidInput("请输入有效的邮箱地址。") }
        }
        if requireCode {
            guard verificationCode.range(of: #"^[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil else { throw NativeAPIError.invalidInput("验证码必须是 6 位字母或数字。") }
        }
        guard invitation.count <= 64 else { throw NativeAPIError.invalidInput("邀请码过长。") }
    }
}

public struct NativeSiteStatus {
    public let emailVerificationEnabled: Bool
    public let turnstileRequired: Bool
    public let registrationEnabled: Bool
    public func validateNativeRegistration() throws {
        guard registrationEnabled else { throw NativeAPIError.registrationUnavailable }
        guard !turnstileRequired else { throw NativeAPIError.interactionRequired("注册站点") }
    }
    init(object: [String: Any]) throws {
        guard let email = nativeJSONBool(object["email_verification"]) else { throw NativeAPIError.invalidResponse }
        emailVerificationEnabled = email
        turnstileRequired = nativeJSONBool(object["turnstile_check"]) ?? false
        registrationEnabled = nativeJSONBool(object["register_enabled"]) != false && nativeJSONBool(object["password_register_enabled"]) != false
    }
}

@MainActor
public final class RegistrationAPI {
    private let client: NativeHTTPClient
    public init(client: NativeHTTPClient) { self.client = client }
    public func status() async throws -> NativeSiteStatus {
        let reply = try await client.request(path: "/api/status")
        guard reply.success else { throw reply.failure(operation: "连接注册接口") }
        guard let data = reply.object?["data"] as? [String: Any] else { throw NativeAPIError.invalidResponse }
        return try NativeSiteStatus(object: data)
    }
    public func sendVerification(email: String) async throws -> NativeAPIResponse {
        guard email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { throw NativeAPIError.invalidInput("请输入有效的邮箱地址。") }
        return try await client.request(path: "/api/verification", query: [URLQueryItem(name: "email", value: email)], secrets: [email])
    }
    public func register(_ input: NativeRegistrationInput, requireCode: Bool = true) async throws -> NativeAPIResponse {
        try input.validate(requireCode: requireCode, requireEmail: requireCode)
        let body = try JSONSerialization.data(withJSONObject: ["username": input.username, "email": input.email,
            "password": input.password, "verification_code": input.verificationCode, "aff_code": input.invitation])
        return try await client.request(path: "/api/user/register", method: "POST", body: body,
                                        secrets: [input.email, input.password, input.verificationCode])
    }
}

@MainActor
public final class MailboxAPI {
    private let client: NativeHTTPClient
    public init(client: NativeHTTPClient) { self.client = client }
    public func checkAvailability() async throws {
        let reply = try await client.request(path: "/captcha/status")
        guard (200..<300).contains(reply.statusCode), let enabled = nativeJSONBool(reply.object?["turnstile_enabled"]) else {
            throw reply.failure(operation: "连接邮箱接口")
        }
        if enabled { throw NativeAPIError.interactionRequired("邮箱服务") }
    }
    public func messages(username: String, domain: String = "fviainboxes.com") async throws -> [MailboxMessage] {
        let reply = try await client.request(path: "/messages", query: query(username, domain))
        guard (200..<300).contains(reply.statusCode) else { throw reply.failure(operation: "读取邮箱") }
        return try MailVerification.messages(from: reply.data)
    }
    public func messageHTML(username: String, domain: String = "fviainboxes.com", id: String) async throws -> String {
        let reply = try await client.request(path: "/message", query: query(username, domain) + [URLQueryItem(name: "id", value: id)])
        guard (200..<300).contains(reply.statusCode), !reply.requiresInteraction,
              let raw = String(data: reply.data, encoding: .utf8) else { throw reply.failure(operation: "读取验证码邮件") }
        // The deployed service wraps its HTML in a JSON string, including escaped '<' and '>' tags.
        // Decode the wire format before parsing HTML; also accept services returning raw HTML.
        return (try? JSONDecoder().decode(String.self, from: reply.data)) ?? raw
    }
    private func query(_ username: String, _ domain: String) -> [URLQueryItem] {
        [URLQueryItem(name: "username", value: username), URLQueryItem(name: "domain", value: domain)]
    }
}
