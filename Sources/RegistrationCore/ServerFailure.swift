import Foundation

public enum ServerFailure {
    /// Only accepts the bridge's limited, redacted response summary.
    /// Returns the raw 429 response body for diagnostic logging. Returns a
    /// placeholder when the bridge reported a 429 but the body was absent or empty.
    public static func rawBody429(_ response: [String: Any]?) -> String? {
        guard response?["status"] as? Int == 429 else { return nil }
        let raw = (response?["rawBody429"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "(body empty — Cloudflare 未返回说明)" : String(raw.prefix(500))
    }

    public static func describe(_ response: [String: Any]?, operation: String) -> String {
        let status = response?["status"] as? Int
        let message = (response?["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reason: String
        if !message.isEmpty {
            reason = String(message.prefix(500))
        } else {
            switch status ?? 0 {
            case 429: reason = "网站限制了请求频率，请等待限制解除后再试。"
            case 403: reason = "网站拒绝访问，请检查网页验证或联系网站管理员。"
            case 500...599: reason = "网站服务异常，请稍后重试。"
            default: reason = "网站未提供具体错误说明，请查看注册页提示。"
            }
        }
        let code = status.map { "（HTTP \($0)）" } ?? ""
        return "\(operation)失败\(code)：\(reason)"
    }
}
