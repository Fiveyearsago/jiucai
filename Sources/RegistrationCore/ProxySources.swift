import Foundation

public struct ProxySourceConfiguration: Codable, Equatable {
    public static let defaultURLs = [
        "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt",
        "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt",
        "https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt"
    ]
    public var automatic = true
    public var intervalMinutes = 60
    public var urls = defaultURLs
    /// Zero keeps probes exclusive with registration requests; 1...3 allow limited overlap.
    public var registrationConcurrency = 1
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case automatic, intervalMinutes, urls, registrationConcurrency
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
        intervalMinutes = try values.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
        urls = try values.decodeIfPresent([String].self, forKey: .urls) ?? Self.defaultURLs
        registrationConcurrency = try values.decodeIfPresent(Int.self, forKey: .registrationConcurrency) ?? 1
    }

    public func validate() throws {
        guard intervalMinutes > 0 else { throw ClientError.message("更新间隔须为大于 0 的整数（分钟）。") }
        guard (0...3).contains(registrationConcurrency) else { throw ClientError.message("注册时后台并发须为 0–3 个。") }
        for value in urls { _ = try ProxySources.url(from: value) }
    }
}

/// UUIDs identify rows; connection identity prevents duplicate entries from multiple lists.
public struct ProxyIdentity: Hashable {
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    public init(_ entry: ProxyEntry) {
        host = entry.host.lowercased(); port = entry.port
        user = entry.user; password = entry.password
    }
}

public enum ProxySources {
    public static func url(from value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, !host.contains(where: \.isWhitespace),
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else {
            throw ClientError.message("来源须为有效的 HTTP 或 HTTPS 地址，不能包含用户名、密码或片段。")
        }
        return url
    }

    public static func candidates(in lists: [String], excluding existing: [ProxyEntry]) -> [ProxyEntry] {
        var known = Set(existing.map(ProxyIdentity.init))
        var entries: [ProxyEntry] = []
        for list in lists {
            for line in list.components(separatedBy: .newlines) {
                guard let entry = ProxyEntry.parse(line), known.insert(ProxyIdentity(entry)).inserted else { continue }
                entries.append(entry)
            }
        }
        return entries
    }
}

public enum ProxySourceClient {
    private static let maximumBytes = 5_000_000

    public static func text(data: Data, response: HTTPURLResponse) throws -> String {
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.message("来源返回 HTTP \(response.statusCode)。")
        }
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"),
              !(response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") ?? false) else {
            throw ClientError.message("来源没有返回有效的代理文本列表。")
        }
        return text
    }

    /// Fetch lists independently of the proxy pool, including when the pool is empty.
    public static func fetch(from url: URL) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.networkServiceType = .background
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.networkServiceType = .background
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClientError.message("来源未返回 HTTP 响应。")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.message("来源返回 HTTP \(response.statusCode)。")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ClientError.message("来源代理列表过大。") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try text(data: data, response: response)
    }
}
