import Foundation

enum RequestHeaderMode: String, Codable, CaseIterable, Identifiable {
    case safari, webKit
    var id: String { rawValue }
    var title: String { self == .safari ? "Safari 兼容" : "默认 WebKit" }
    var userAgent: String? {
        guard self == .safari else { return nil }
        let version = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "26.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }
}

enum RequestLanguage: String, Codable, CaseIterable, Identifiable {
    case automatic, chinese, english
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "网页 / 浏览器默认"; case .chinese: return "简体中文"; case .english: return "英文" }
    }
    var value: String? {
        switch self { case .automatic: return nil; case .chinese: return "zh-CN,zh;q=0.9,en;q=0.8"; case .english: return "en-US,en;q=0.9" }
    }
}

enum RequestAccept: String, Codable, CaseIterable, Identifiable {
    case automatic, json, general
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "网页默认"; case .json: return "JSON"; case .general: return "JSON / 文本" }
    }
    var value: String? {
        switch self { case .automatic: return nil; case .json: return "application/json"; case .general: return "application/json, text/plain, */*" }
    }
}

struct RequestHeaderConfiguration: Codable, Equatable {
    var mode: RequestHeaderMode = .safari
    var language: RequestLanguage = .english
    var accept: RequestAccept = .json
    /// User-defined extra headers. Keys and values are sent as-is; a key matching
    /// a built-in field ("Accept", "Accept-Language") overrides the picker value.
    var customHeaders: [String: String] = [:]
    /// Per-account variant overrides. When non-nil they win over the picker values,
    /// so a generated variant can differ from the base config without touching the
    /// pickers. Cleared when the variant strategy is `.fixed`.
    var userAgentOverride: String?
    var acceptLanguageOverride: String?
    var acceptOverride: String?
    static let webKit = Self(mode: .webKit, language: .automatic, accept: .automatic)
    var title: String { "\(mode.title) · \(language.title) · \(accept.title)" }

    var effectiveUserAgent: String? { userAgentOverride ?? mode.userAgent }
    var effectiveAcceptLanguage: String? { acceptLanguageOverride ?? language.value }
    var effectiveAccept: String? { acceptOverride ?? accept.value }

    var overrides: [String: String] {
        var result: [String: String] = [:]
        result["Accept"] = effectiveAccept
        result["Accept-Language"] = effectiveAcceptLanguage
        // Custom headers win over the picker values when keys collide.
        for (key, value) in customHeaders where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            result[key.trimmingCharacters(in: .whitespaces)] = value
        }
        return result
    }
    static func restore() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "requestHeaderConfiguration"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "requestHeaderConfiguration") }
    }
}

/// How a batch should vary request headers across accounts.
enum HeaderVariantStrategy: String, Codable, CaseIterable, Identifiable {
    case fixed, rotateLanguage, rotateUserAgent, rotateAll
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed: return "不差异化"
        case .rotateLanguage: return "轮换语言偏好"
        case .rotateUserAgent: return "轮换浏览器标识"
        case .rotateAll: return "语言 + 标识 全部轮换"
        }
    }
}

/// Produces a per-account `RequestHeaderConfiguration` from a base config and a
/// strategy. The same index always yields the same variant, so re-running a
/// failed account reuses its prior headers.
struct HeaderVariantGenerator {
    let strategy: HeaderVariantStrategy
    let base: RequestHeaderConfiguration

    private static let userAgents: [String] = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5_0; rv:131.0) Gecko/20100101 Firefox/131.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15",
    ]
    private static let languages: [String] = [
        "en-US,en;q=0.9",
        "en-GB,en;q=0.9",
        "en-US,en;q=0.9,zh-CN;q=0.8",
        "zh-CN,zh;q=0.9,en;q=0.8",
        "ja-JP,ja;q=0.9,en-US;q=0.8",
        "de-DE,de;q=0.9,en-US;q=0.8",
        "fr-FR,fr;q=0.9,en-US;q=0.8",
        "es-ES,es;q=0.9,en-US;q=0.8",
    ]

    func variant(forIndex index: Int) -> RequestHeaderConfiguration {
        guard strategy != .fixed else { return base }
        var v = base
        if strategy == .rotateUserAgent || strategy == .rotateAll {
            v.userAgentOverride = Self.userAgents[abs(index) % Self.userAgents.count]
        }
        if strategy == .rotateLanguage || strategy == .rotateAll {
            v.acceptLanguageOverride = Self.languages[abs(index) % Self.languages.count]
        }
        return v
    }
}

struct ObservedRequestHeader: Identifiable {
    var id: String { name }
    let name: String
    let value: String
    let source: String
}

struct RequestHeaderObservation: Identifiable {
    let id = UUID()
    let date = Date()
    let method: String
    let path: String
    let transport: String
    let profile: String
    let headers: [ObservedRequestHeader]
    static let names = ["User-Agent", "Accept", "Accept-Language", "Content-Type", "Cache-Control", "Pragma", "X-Requested-With", "Origin", "Referer"]
    static let paths = ["/", "/sign-up", "/sign-in", "/api/status", "/api/verification", "/api/user/register"]
}
