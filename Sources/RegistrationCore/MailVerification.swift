import Foundation

public struct MailboxMessage: Equatable {
    public let id: String
    public let subject: String
    public let sender: String
    public let createdAt: TimeInterval

    public init(id: String, subject: String, sender: String, createdAt: TimeInterval) {
        self.id = id
        self.subject = subject
        self.sender = sender
        self.createdAt = createdAt
    }
}

public enum MailVerification {
    public static func messages(from data: Data) throws -> [MailboxMessage] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw invalidMessageList()
        }
        guard let response = value as? [String: Any], let rows = response["result"] as? [Any] else {
            throw invalidMessageList()
        }

        return rows.compactMap { value in
            guard let row = value as? [String: Any],
                  let id = messageID(row["id"]),
                  let subject = row["subject"] as? String,
                  let sender = row["from"] as? String,
                  let createdAt = timestamp(row["createdAt"]) else { return nil }
            return MailboxMessage(id: id, subject: subject, sender: sender, createdAt: createdAt)
        }
    }

    public static func candidates(in messages: [MailboxMessage], excluding baseline: Set<String>,
                                  requestedAt: TimeInterval) -> [MailboxMessage] {
        guard requestedAt.isFinite else { return [] }
        let threshold = floor(requestedAt)
        return messages.enumerated().filter { _, message in
            !baseline.contains(message.id) && message.createdAt.isFinite && message.createdAt >= threshold
                && message.subject.range(of: "验证码|邮箱验证|邮件验证|verification|verify|registration",
                                         options: [.regularExpression, .caseInsensitive]) != nil
                && (message.subject + " " + message.sender).range(of: "jiucai|韭菜|new.?api",
                                                               options: [.regularExpression, .caseInsensitive]) != nil
        }.sorted { first, second in
            if first.element.createdAt != second.element.createdAt {
                return first.element.createdAt > second.element.createdAt
            }
            if first.element.id != second.element.id { return first.element.id < second.element.id }
            return first.offset < second.offset
        }.map(\.element)
    }

    public static func code(fromHTML html: String) -> String? {
        var text = replacing(#"(?s)<!--.*?(?:-->|\z)"#, in: html, with: "")
        text = replacing(#"(?is)<(script|style)\b(?:[^>"']|"[^"]*"|'[^']*')*>.*?(?:</\1\s*>|\z)"#,
                         in: text, with: "")
        // Block boundaries supply whitespace; inline styling can split individual code characters.
        text = replacing(#"(?i)</?(?:br|p|div|li|tr|td|th|table|section|h[1-6])\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
                         in: text, with: " ")
        text = replacing(#"<(?:[^>"']|"[^"]*"|'[^']*')*>"#, in: text, with: "")
        text = decodingEntities(in: text)

        // Case folding applies to the marker only, keeping the code strictly ASCII and preserving case.
        let pattern = #"(?i:验证码|verification\s+code|security\s+code|code\s+is)(?:\s*(?:是|为|(?i:is)))?\s*[:：]?\s*(?<![A-Za-z0-9])([A-Za-z0-9]{6})(?![A-Za-z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func invalidMessageList() -> ClientError {
        .message("邮箱服务返回了无法识别的邮件列表。")
    }

    private static func messageID(_ value: Any?) -> String? {
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        guard let number = jsonNumber(value), number.doubleValue.isFinite else { return nil }
        return number.stringValue
    }

    private static func timestamp(_ value: Any?) -> TimeInterval? {
        if let number = jsonNumber(value) { return normalizedTimestamp(number.doubleValue) }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) { return normalizedTimestamp(number) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)?.timeIntervalSince1970
    }

    private static func jsonNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber else { return nil }
        // JSONSerialization represents booleans as Objective-C char/bool values.
        let type = String(cString: number.objCType)
        return type == "c" || type == "B" ? nil : number
    }

    private static func normalizedTimestamp(_ value: Double) -> TimeInterval? {
        guard value.isFinite else { return nil }
        return abs(value) >= 100_000_000_000 ? value / 1_000 : value
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: replacement)
    }

    private static func decodingEntities(in text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "ensp": " ", "emsp": " ", "thinsp": " ", "colon": ":", "NewLine": "\n", "Tab": "\t"]
        guard let expression = try? NSRegularExpression(pattern: #"&(#(?:[xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]*);"#) else {
            return text
        }
        var decoded = text
        // Work backward so each original UTF-16 range stays valid as entities shrink.
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let contentRange = Range(match.range(at: 1), in: text),
                  let replacementRange = Range(match.range, in: decoded) else { continue }
            let entity = String(text[contentRange])
            let replacement: String?
            if entity.hasPrefix("#") {
                let hexadecimal = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                let digits = entity.dropFirst(hexadecimal ? 2 : 1)
                replacement = UInt32(digits, radix: hexadecimal ? 16 : 10)
                    .flatMap(Unicode.Scalar.init).map(String.init)
            } else {
                replacement = named[entity]
            }
            if let replacement { decoded.replaceSubrange(replacementRange, with: replacement) }
        }
        return decoded
    }
}
