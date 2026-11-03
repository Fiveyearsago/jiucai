import Foundation
import Network
import RegistrationCore

/// SOCKS5 support built on WebKit / URLSession proxy configurations (macOS 14+).
/// The proxy is scoped to one website data store, so the rest of the Mac is untouched.
enum ProxyManager {
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
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: entry.port)) else { return nil }
        var proxy = Network.ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(entry.host), port: port))
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
            case .blocked: return "可连通，但注册页返回 HTTP \(status ?? 0) · \(milliseconds) ms" + (exit.map { " · \($0.summary)" } ?? "")
            case .unreachable: return "不通 · " + (error ?? "无法连接")
            }
        }
    }

    private static func session(through entry: ProxyEntry?) -> URLSession? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        if let entry {
            guard #available(macOS 14.0, *), let proxy = configuration(for: entry) else { return nil }
            config.proxyConfigurations = [proxy]
        }
        return URLSession(configuration: config)
    }

    /// Asks the registration site's own Cloudflare edge which IP it sees, through the
    /// same proxy the page will use. Falls back to ipify. Returns nil when unreachable.
    static func exitInfo(through entry: ProxyEntry?) async -> ExitInfo? {
        guard let session = session(through: entry) else { return nil }
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

    /// Loads the registration page through the proxy and reports whether it answers.
    static func test(_ entry: ProxyEntry) async -> TestResult {
        guard let session = session(through: entry) else {
            return TestResult(verdict: .unreachable, status: nil, milliseconds: 0, exit: nil, error: "需要 macOS 14 或更高版本")
        }
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.jiucaihezi.studio/sign-up")!)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let exit = await exitInfo(using: session)
            return TestResult(verdict: (200..<400).contains(status) ? .usable : .blocked,
                              status: status, milliseconds: elapsed, exit: exit, error: nil)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let code = (error as NSError).code
            let reason: String
            switch code {
            case NSURLErrorTimedOut: reason = "连接超时（\(elapsed) ms）"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: reason = "无法连接代理或目标网站"
            case NSURLErrorNetworkConnectionLost: reason = "连接被中断"
            case NSURLErrorSecureConnectionFailed: reason = "TLS 握手失败"
            default: reason = "网络错误 \(code)"
            }
            return TestResult(verdict: .unreachable, status: nil, milliseconds: elapsed, exit: nil, error: reason)
        }
    }
}
