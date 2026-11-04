import Foundation
import Network
import RegistrationCore

/// SOCKS5 support for URLSession and the legacy browser adapter (macOS 14+).
/// Each connection owns its proxy configuration; the rest of the Mac is untouched.
enum ProxyManager {
    static let defaultBatchConcurrency = 5
    static let maximumBatchConcurrency = 20
    private static let testURL = URL(string: "https://api.jiucaihezi.studio/api/status")!

    private final class TestRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    struct ExitInfo {
        let ip: String
        /// Cloudflare data-center code, e.g. "SIN", when the trace endpoint answered.
        let colo: String?
        let location: String?
        var summary: String {
            [ip, colo.map { "节点 \($0)" }, location.map { "地区 \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
    }

    static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    @available(macOS 14.0, *)
    static func configuration(for entry: ProxyEntry) -> Network.ProxyConfiguration? {
        let host = entry.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, (1...65_535).contains(entry.port),
              let port = NWEndpoint.Port(rawValue: UInt16(entry.port)) else { return nil }
        var proxy = Network.ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(host), port: port))
        proxy.allowFailover = false
        if !entry.user.isEmpty { proxy.applyCredential(username: entry.user, password: entry.password) }
        return proxy
    }

    struct TestResult {
        enum Verdict { case usable, blocked, unreachable }
        let verdict: Verdict
        let status: Int?
        let milliseconds: Int
        let exit: ExitInfo?
        let error: String?
        var summary: String {
            switch verdict {
            case .usable: return "可用 · HTTP \(status ?? 0) · \(milliseconds) ms" + (exit.map { " · \($0.summary)" } ?? "")
            case .blocked: return "接口不可用 · HTTP \(status ?? 0) · \(milliseconds) ms" + (error.map { " · \($0)" } ?? "")
            case .unreachable: return "不通 · " + (error ?? "无法连接")
            }
        }
    }

    static func poolTestTimeout(in configuration: RegistrationCore.ProxyConfiguration) -> TimeInterval {
        Double(configuration.poolTestLimitMilliseconds) / 1_000
    }

    static func acceptsPoolResult(_ result: TestResult, configuration: RegistrationCore.ProxyConfiguration) -> Bool {
        let limit = configuration.poolTestLimitMilliseconds
        return limit > 0 && result.verdict == .usable && result.milliseconds <= limit
    }

    enum SelectionError: LocalizedError {
        case exhausted
        case registrationFailed
        var errorDescription: String? {
            switch self {
            case .exhausted: return "当前没有可用代理，补充代理后会自动继续。"
            case .registrationFailed: return "当前账号已尝试本轮所有可用代理，稍后自动开始下一轮。"
            }
        }
    }

    @discardableResult
    static func discardIfNeeded(_ entry: ProxyEntry, result: TestResult,
                                configuration: inout RegistrationCore.ProxyConfiguration) -> Bool {
        guard !acceptsPoolResult(result, configuration: configuration) else { return false }
        let count = configuration.entries.count
        configuration.entries.removeAll { $0.id == entry.id }
        return configuration.entries.count != count
    }

    /// Capture the successor before removal changes the rotation indices.
    static func discardFailedProxy(_ entry: ProxyEntry, configuration: inout RegistrationCore.ProxyConfiguration) -> UUID? {
        let pool = configuration.activeEntries
        let next: UUID?
        if pool.count > 1, let index = pool.firstIndex(where: { $0.id == entry.id }) {
            next = pool[(index + 1) % pool.count].id
        } else { next = nil }
        configuration.entries.removeAll { $0.id == entry.id }
        return next
    }

    /// Selection never makes a network request. The registration flow handles connection failures.
    @MainActor
    static func selectProxy(configuration: RegistrationCore.ProxyConfiguration, completedCount: Int,
                            startingAfter previous: UUID? = nil, startingAt preferredID: UUID? = nil,
                            excluding excluded: Set<UUID> = []) throws -> ProxyEntry? {
        try Task.checkCancellation()
        guard configuration.enabled else { return nil }
        let pool = configuration.activeEntries
        let exhausted = excluded.isEmpty ? SelectionError.exhausted : .registrationFailed
        guard let preferred = configuration.proxy(forCompletedCount: completedCount),
              let preferredIndex = pool.firstIndex(where: { $0.id == preferred.id }) else {
            throw exhausted
        }
        let start = preferredID.flatMap { id in pool.firstIndex(where: { $0.id == id }) }
            ?? previous.flatMap { id in pool.firstIndex(where: { $0.id == id }).map { ($0 + 1) % pool.count } }
            ?? preferredIndex
        for offset in 0..<pool.count {
            try Task.checkCancellation()
            let entry = pool[(start + offset) % pool.count]
            guard !excluded.contains(entry.id) else { continue }
            return entry
        }
        throw exhausted
    }

    /// Only running requests occupy tasks; queued entries do not start sessions or latency clocks.
    @MainActor
    static func testBatch(_ entries: [ProxyEntry], concurrencyLimit: Int = ProxyManager.defaultBatchConcurrency,
                          test: @escaping @MainActor (ProxyEntry) async -> TestResult = { await ProxyManager.test($0) },
                          completed: @MainActor (ProxyEntry, TestResult) -> Void) async {
        let run: @Sendable (ProxyEntry) async -> (ProxyEntry, TestResult)? = { entry in
            guard !Task.isCancelled else { return nil }
            let result = await test(entry)
            guard !Task.isCancelled else { return nil }
            return (entry, result)
        }
        await withTaskGroup(of: (ProxyEntry, TestResult)?.self) { group in
            var iterator = entries.makeIterator()
            for _ in 0..<min(maximumBatchConcurrency, max(1, concurrencyLimit)) {
                guard !Task.isCancelled, let entry = iterator.next() else { break }
                group.addTask(priority: .utility) { await run(entry) }
            }
            while let next = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let (entry, result) = next { completed(entry, result) }
                if let entry = iterator.next() {
                    group.addTask(priority: .utility) { await run(entry) }
                }
            }
        }
    }

    static func session(through entry: ProxyEntry?, timeout: TimeInterval = 5, background: Bool = false) -> URLSession? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        if background { config.networkServiceType = .background }
        if let entry {
            guard #available(macOS 14.0, *), let proxy = configuration(for: entry) else { return nil }
            config.proxyConfigurations = [proxy]
        }
        return URLSession(configuration: config)
    }

    static func testRequest(timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: testURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.networkServiceType = .background
        return request
    }

    static func testResult(data: Data, response: URLResponse, milliseconds: Int) -> TestResult {
        guard let response = response as? HTTPURLResponse else {
            return TestResult(verdict: .blocked, status: nil, milliseconds: milliseconds, exit: nil, error: "响应不是 HTTP 接口数据")
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        }
        let reply = NativeAPIResponse(statusCode: response.statusCode, data: data, headers: headers)
        let error: String?
        if response.url != testURL || (300..<400).contains(response.statusCode) {
            error = "接口发生重定向"
        } else if reply.requiresInteraction {
            error = "接口要求网页验证"
        } else if reply.success, reply.object?["data"] is [String: Any] {
            return TestResult(verdict: .usable, status: response.statusCode, milliseconds: milliseconds, exit: nil, error: nil)
        } else {
            error = (200..<300).contains(response.statusCode) ? "接口响应不是有效的状态数据" : nil
        }
        return TestResult(verdict: .blocked, status: response.statusCode, milliseconds: milliseconds, exit: nil, error: error)
    }

    /// Use fixed descriptions rather than NSError text, which can contain URLs or credentials.
    static func networkFailureDescription(_ error: Error) -> String {
        let error = error as NSError
        let reason: String
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCannotFindHost): reason = "无法解析代理或目标网站域名"
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost): reason = "无法连接代理或目标网站"
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost): reason = "连接被中断"
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): reason = "网络连接不可用"
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed): reason = "TLS 握手失败"
        case (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid): reason = "TLS 证书校验失败"
        case (NSURLErrorDomain, NSURLErrorUserAuthenticationRequired): reason = "代理或网站认证失败"
        default: reason = "网络或网页加载错误"
        }
        return "\(reason)（错误 \(error.code)）"
    }

    /// Asks the registration site's own Cloudflare edge which IP it sees, through the
    /// same proxy the API will use. Falls back to ipify. Returns nil when unreachable.
    static func exitInfo(through entry: ProxyEntry?) async -> ExitInfo? {
        guard let session = session(through: entry, background: true) else { return nil }
        defer { session.invalidateAndCancel() }
        return await exitInfo(using: session)
    }

    private static func exitInfo(using session: URLSession) async -> ExitInfo? {
        if let (data, _) = try? await session.data(from: URL(string: "https://api.jiucaihezi.studio/cdn-cgi/trace")!) {
            var fields: [String: String] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            if let ip = fields["ip"] { return ExitInfo(ip: ip, colo: fields["colo"], location: fields["loc"]) }
        }
        if let (data, _) = try? await session.data(from: URL(string: "https://api.ipify.org")!) {
            let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty, ip.count <= 45 { return ExitInfo(ip: ip, colo: nil, location: nil) }
        }
        return nil
    }

    /// Time the uncached status API request. Exit-IP lookups are reserved for the selected proxy.
    static func test(_ entry: ProxyEntry,
                     configuration: RegistrationCore.ProxyConfiguration = .init()) async -> TestResult {
        do { try configuration.validateLatencyLimits() } catch {
            return TestResult(verdict: .unreachable, status: nil, milliseconds: 0, exit: nil, error: error.localizedDescription)
        }
        let timeout = poolTestTimeout(in: configuration)
        guard let session = session(through: entry, timeout: timeout, background: true) else {
            return TestResult(verdict: .unreachable, status: nil, milliseconds: 0, exit: nil,
                              error: isSupported ? "代理主机或端口无效" : "需要 macOS 14 或更高版本")
        }
        defer { session.invalidateAndCancel() }
        let request = testRequest(timeout: timeout)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let (data, response) = try await session.data(for: request, delegate: TestRedirectPolicy())
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            return testResult(data: data, response: response, milliseconds: elapsed)
        } catch {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let code = (error as NSError).code
            let reason: String
            switch code {
            case NSURLErrorTimedOut: reason = "连接超时（\(elapsed) ms）"
            default: reason = networkFailureDescription(error)
            }
            return TestResult(verdict: .unreachable, status: nil, milliseconds: elapsed, exit: nil, error: reason)
        }
    }
}
