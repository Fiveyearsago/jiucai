import Foundation

public struct TaskConfiguration: Codable, Equatable {
    public var prefix = "xiaorange"
    public var startIndex = 176
    public var count = 1
    public var digits = 3
    public var invitation = "WAI1"
    public var intervalSeconds = 60
    /// Minutes to wait after a 429 error before automatically retrying.
    /// 0 = do not auto-retry (stop on 429, original behaviour).
    public var cooldownMinutes = 0
    // Preserve the previous single-proxy settings when older journals are opened.
    // The new proxy configuration is managed independently and remains disabled by default.
    private var legacyProxyHost: String?
    private var legacyProxyPort: Int?
    private var legacyProxyUser: String?
    private var legacyProxyPassword: String?
    private var legacyProxyRotateSession: Bool?
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case prefix, startIndex, count, digits, invitation, intervalSeconds, cooldownMinutes
        case legacyProxyHost = "proxyHost", legacyProxyPort = "proxyPort", legacyProxyUser = "proxyUser"
        case legacyProxyPassword = "proxyPassword", legacyProxyRotateSession = "proxyRotateSession"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        prefix = try values.decode(String.self, forKey: .prefix)
        startIndex = try values.decode(Int.self, forKey: .startIndex)
        count = try values.decode(Int.self, forKey: .count)
        digits = try values.decode(Int.self, forKey: .digits)
        invitation = try values.decode(String.self, forKey: .invitation)
        intervalSeconds = try values.decode(Int.self, forKey: .intervalSeconds)
        cooldownMinutes = try values.decodeIfPresent(Int.self, forKey: .cooldownMinutes) ?? 0
        legacyProxyHost = try values.decodeIfPresent(String.self, forKey: .legacyProxyHost)
        legacyProxyPort = try values.decodeIfPresent(Int.self, forKey: .legacyProxyPort)
        legacyProxyUser = try values.decodeIfPresent(String.self, forKey: .legacyProxyUser)
        legacyProxyPassword = try values.decodeIfPresent(String.self, forKey: .legacyProxyPassword)
        legacyProxyRotateSession = try values.decodeIfPresent(Bool.self, forKey: .legacyProxyRotateSession)
    }
    public func username(_ index: Int) -> String {
        let number = String(index)
        return prefix + String(repeating: "0", count: max(0, min(digits, 6) - number.count)) + number
    }
    public func email(_ index: Int) -> String { username(index) + "@fviainboxes.com" }
    public var registrationURL: URL {
        var c = URLComponents(string: "https://api.jiucaihezi.studio/sign-up")!
        if !invitation.isEmpty { c.queryItems = [URLQueryItem(name: "aff", value: invitation)] }
        return c.url!
    }
    public func validate(password: String) throws {
        guard prefix.range(of: "^[A-Za-z0-9_-]{1,16}$", options: .regularExpression) != nil else {
            throw ClientError.message("用户名前缀需为 1–16 位字母、数字、下划线或短横线。")
        }
        let (endIndex, overflow) = startIndex.addingReportingOverflow(count)
        guard startIndex > 0, count > 0, !overflow else {
            throw ClientError.message("起始编号和注册数量必须是正整数，编号范围不能超出整数容量。")
        }
        guard (1...6).contains(digits), username(endIndex - 1).count <= 20 else {
            throw ClientError.message("用户名总长度不得超过 20 位，补零位数需在 1–6 之间。")
        }
        guard (8...128).contains(password.count) else { throw ClientError.message("密码长度需为 8–128 位。") }
        guard (3...3600).contains(intervalSeconds) else { throw ClientError.message("账号间隔需在 3–3600 秒之间。") }
        guard (0...60).contains(cooldownMinutes) else { throw ClientError.message("429 冷却时间需在 0–60 分钟之间。") }
        guard invitation.count <= 64 else { throw ClientError.message("邀请码过长。") }
    }
}

/// The range stays lazy; only existing records are examined when planning a batch.
public struct RegistrationBatch {
    public let indices: Range<Int>
    public let blockedIndices: Set<Int>
    public var count: Int { indices.count - blockedIndices.count }

    public init(configuration: TaskConfiguration, records: [AccountRecord]) {
        indices = configuration.startIndex..<(configuration.startIndex + configuration.count)
        var blocked = Set<Int>()
        for record in records where [.succeeded, .submitting, .uncertain].contains(record.status) {
            guard record.username.hasPrefix(configuration.prefix),
                  let index = Int(record.username.dropFirst(configuration.prefix.count)),
                  indices.contains(index), configuration.username(index) == record.username else { continue }
            blocked.insert(index)
        }
        blockedIndices = blocked
    }
}

public enum ClientError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// One SOCKS5 proxy entry parsed from a `host:port:user:password` line.
public struct ProxyEntry: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var enabled: Bool = true

    public init(host: String, port: Int, user: String = "", password: String = "") {
        self.host = host; self.port = port; self.user = user; self.password = password
    }

    /// Parse a single `host:port[:user[:password]]` line. Returns nil for blank/malformed lines.
    public static func parse(_ line: String) -> ProxyEntry? {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard parts.count >= 2,
              let port = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else { return nil }
        let host = parts[0].trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        let user = parts.count >= 3 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        let password = parts.count >= 4 ? parts[3...].joined(separator: ":").trimmingCharacters(in: .whitespaces) : ""
        return ProxyEntry(host: host, port: port, user: user, password: password)
    }

    public var displayName: String { "\(host):\(port)\(user.isEmpty ? "" : " (\(user))")" }
}

/// Proxy pool configuration stored alongside the journal.
public struct ProxyConfiguration: Codable, Equatable {
    public var entries: [ProxyEntry] = []
    /// Switch to the next proxy after this many successfully completed accounts. 0 = don't rotate.
    public var switchEvery: Int = 1
    public var enabled: Bool = false

    public init() {}

    public var activeEntries: [ProxyEntry] { entries.filter(\.enabled) }

    /// Returns the proxy to use for account at position `completedCount` (0-based completions so far).
    public func proxy(forCompletedCount count: Int) -> ProxyEntry? {
        let pool = activeEntries
        guard enabled, !pool.isEmpty else { return nil }
        let step = max(1, switchEvery)
        return pool[(count / step) % pool.count]
    }
}

public enum RecordStatus: String, Codable, CaseIterable {
    case pending, running, submitting, succeeded, failed, uncertain, cancelled
    public var title: String {
        switch self {
        case .pending: return "待处理"
        case .running: return "处理中"
        case .submitting: return "已提交，待确认"
        case .succeeded: return "注册成功"
        case .failed: return "未完成"
        case .uncertain: return "结果待核对"
        case .cancelled: return "已停止"
        }
    }
}

public struct AccountRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var username: String
    public var email: String
    public var status: RecordStatus
    public var updatedAt: Date
    public var note: String
    public var screenshot: String?
    /// Step-by-step log entries appended during registration.
    public var logs: [String]
    /// Requests observed on the registration page while this account was running.
    public var network: [NetworkRecord]
    public init(username: String, email: String, status: RecordStatus = .pending) {
        id = UUID(); self.username = username; self.email = email; self.status = status
        updatedAt = Date(); note = ""; screenshot = nil; logs = []; network = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, username, email, status, updatedAt, note, screenshot, logs, network
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        username = try values.decode(String.self, forKey: .username)
        email = try values.decode(String.self, forKey: .email)
        status = try values.decode(RecordStatus.self, forKey: .status)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        note = try values.decode(String.self, forKey: .note)
        screenshot = try values.decodeIfPresent(String.self, forKey: .screenshot)
        logs = try values.decodeIfPresent([String].self, forKey: .logs) ?? []
        network = try values.decodeIfPresent([NetworkRecord].self, forKey: .network) ?? []
    }
}

public struct NetworkHeader: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var value: String
    public var source: String
    public init(name: String, value: String, source: String = "") {
        self.name = name; self.value = value; self.source = source
    }
}

/// One request/response pair, redacted by the page bridge: path only (no query
/// string), no request body, no Cookie / Authorization / Set-Cookie.
public struct NetworkRecord: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var method: String
    public var path: String
    public var transport: String
    public var status: Int
    public var requestHeaders: [NetworkHeader]
    public var responseHeaders: [NetworkHeader]
    public var responseBody: String
    public var retryAfter: String?
    public init(method: String, path: String, transport: String, status: Int,
                requestHeaders: [NetworkHeader], responseHeaders: [NetworkHeader],
                responseBody: String, retryAfter: String?) {
        self.method = method; self.path = path; self.transport = transport; self.status = status
        self.requestHeaders = requestHeaders; self.responseHeaders = responseHeaders
        self.responseBody = responseBody; self.retryAfter = retryAfter
    }
}

public struct Journal: Codable {
    public var configuration = TaskConfiguration()
    public var records: [AccountRecord] = []
    public var proxyConfiguration = ProxyConfiguration()
    public init() {}

    private enum CodingKeys: String, CodingKey { case configuration, records, proxyConfiguration }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try values.decode(TaskConfiguration.self, forKey: .configuration)
        records = try values.decode([AccountRecord].self, forKey: .records)
        proxyConfiguration = try values.decodeIfPresent(ProxyConfiguration.self, forKey: .proxyConfiguration) ?? ProxyConfiguration()
    }
    public mutating func recoverInterruptedRun() {
        for i in records.indices {
            if records[i].status == .submitting {
                records[i].status = .uncertain
                records[i].note = "上次运行在提交后中断，请先在官网核对，避免重复注册。"
            } else if records[i].status == .running || records[i].status == .pending {
                records[i].status = .cancelled
                records[i].note = "上次运行已中断，可重新创建任务。"
            }
        }
    }
    public func blocksAutomaticRegistration(username: String) -> Bool {
        records.contains { $0.username == username && [.succeeded, .submitting, .uncertain].contains($0.status) }
    }
    public static func csv(_ records: [AccountRecord]) -> String {
        func cell(_ value: String) -> String {
            let safe = ["=", "+", "-", "@", "\t", "\r", "\n"].contains(String(value.first ?? " ")) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        let rows = records.map { r in
            [r.username, r.email, r.status.title, formatter.string(from: r.updatedAt), r.note].map(cell).joined(separator: ",")
        }
        return "\u{FEFF}用户名,邮箱,状态,更新时间,备注\r\n" + rows.joined(separator: "\r\n") + "\r\n"
    }
}

public struct JournalStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("records.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> Journal {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Journal() }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: fileURL))
    }
    public func save(_ journal: Journal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
