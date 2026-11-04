import Foundation

public enum VerificationRetry {
    public static let maximumRetries = 3

    /// Only an explicit 429 rejection can be retried. Unknown outcomes must not resend mail.
    public static func delay(for response: [String: Any], retry: Int) -> Int? {
        guard response["status"] as? Int == 429,
              response["success"] as? Bool != true,
              (1...maximumRetries).contains(retry) else { return nil }
        var required = max(0, (response["retryAfterSeconds"] as? NSNumber)?.doubleValue ?? 0)
        let message = response["message"] as? String ?? ""
        let pattern = #"(?:等待|wait|retry\s+after)\s*(\d+(?:\.\d+)?)\s*(分钟|秒|minutes?|seconds?)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let amountRange = Range(match.range(at: 1), in: message),
           let unitRange = Range(match.range(at: 2), in: message) {
            let amount = Double(message[amountRange]) ?? .infinity
            let unit = message[unitRange].lowercased()
            required = max(required, amount * (unit == "分钟" || unit.hasPrefix("minute") ? 60 : 1))
        }
        // Add a second of margin. Repeated rejections back off to at least 5, 10, then 20 seconds.
        let seconds = max(Double(5 * (1 << (retry - 1))), ceil(required) + 1)
        // A longer server cooldown requires the user to return later; never shorten it.
        guard seconds.isFinite, seconds <= 3600 else { return nil }
        return Int(seconds)
    }

    @MainActor
    public static func send(
        retryRateLimits: Bool = true,
        attempt: () async throws -> [String: Any],
        wait: (_ seconds: Int, _ retry: Int) async throws -> Void
    ) async throws {
        var retries = 0
        while true {
            try Task.checkCancellation()
            let response = try await attempt()
            if response["success"] as? Bool == true { return }
            guard retryRateLimits, let seconds = delay(for: response, retry: retries + 1) else {
                var message = ServerFailure.describe(response, operation: "发送验证码")
                if retryRateLimits, response["status"] as? Int == 429 {
                    message += retries == maximumRetries
                        ? "。已自动重试 \(maximumRetries) 次，请稍后再试。"
                        : "。冷却时间超出自动等待范围，请稍后再试。"
                }
                throw ClientError.message(message)
            }
            retries += 1
            try await wait(seconds, retries)
        }
    }
}
