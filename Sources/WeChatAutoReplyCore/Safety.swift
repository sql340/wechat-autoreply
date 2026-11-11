import Foundation

public struct RateLimiter: Sendable {
    private var timestamps: [Date] = []

    public init() {}

    public mutating func record(_ date: Date = Date()) {
        timestamps.append(date)
        prune(now: date)
    }

    public func counts(now: Date = Date()) -> (hour: Int, day: Int) {
        let hourCutoff = now.addingTimeInterval(-3600)
        let dayCutoff = now.addingTimeInterval(-86400)
        let inHour = timestamps.filter { $0 > hourCutoff }.count
        let inDay = timestamps.filter { $0 > dayCutoff }.count
        return (inHour, inDay)
    }

    public func canReply(now: Date = Date(), maxPerHour: Int, maxPerDay: Int) -> Bool {
        let current = counts(now: now)
        return current.hour < maxPerHour && current.day < maxPerDay
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-86400)
        timestamps.removeAll { $0 < cutoff }
    }
}

public enum Safety {
    public static func isWithinActiveHours(
        _ date: Date = Date(),
        activeHours: [String],
        calendar: Calendar = .current
    ) -> Bool {
        if activeHours.isEmpty { return true }
        guard activeHours.count >= 2,
              let start = parseMinutes(activeHours[0]),
              let end = parseMinutes(activeHours[1]) else {
            return false
        }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if start == end { return true }
        if start < end { return minuteOfDay >= start && minuteOfDay < end }
        return minuteOfDay >= start || minuteOfDay < end
    }

    public static func shouldSkip(probability: Double, randomValue: Double = Double.random(in: 0..<1)) -> Bool {
        let clamped = min(1.0, max(0.0, probability))
        return randomValue < clamped
    }

    public static func containsOptOut(_ text: String, keywords: [String]) -> Bool {
        let normalizedText = normalize(text)
        return keywords.contains { keyword in
            let normalizedKeyword = normalize(keyword)
            return !normalizedKeyword.isEmpty && normalizedText.contains(normalizedKeyword)
        }
    }

    public static func sanitizeReply(_ raw: String, maxChars: Int) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        text = text.replacingOccurrences(of: "```", with: "")
        text = text.replacingOccurrences(of: "\r", with: " ")
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\t", with: " ")
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

        let prefixes = ["回复：", "回复:", "微信回复：", "微信回复:", "Reply:", "reply:"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        text = stripWrappingQuotes(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let blockedPhrases = ["作为AI", "作为 AI", "我是AI", "我是 AI", "语言模型", "AI助手", "人工智能助手"]
        if blockedPhrases.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return nil
        }

        guard text.contains(where: { !$0.isWhitespace && !isPunctuationOnly($0) }) else {
            return nil
        }

        let limit = max(1, maxChars)
        if text.count <= limit { return text }

        let prefix = String(text.prefix(limit))
        let sentenceEnders = CharacterSet(charactersIn: "。！？.!?；;")
        if let lastEnd = prefix.rangeOfCharacter(from: sentenceEnders, options: .backwards) {
            let candidate = String(prefix[..<lastEnd.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= max(1, limit / 2) {
                return candidate
            }
        }

        if limit <= 1 { return String(text.prefix(limit)) }
        return String(text.prefix(limit - 1)) + "…"
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
    }

    private static func parseMinutes(_ raw: String) -> Int? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private static func stripWrappingQuotes(_ input: String) -> String {
        let pairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("‘", "’"),
            ("「", "」"),
            ("『", "』"),
        ]
        var text = input
        var changed = true
        while changed {
            changed = false
            for (open, close) in pairs where text.count >= 2 {
                if text.first == open && text.last == close {
                    text = String(text.dropFirst().dropLast())
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        return text
    }

    private static func isPunctuationOnly(_ character: Character) -> Bool {
        let punctuation = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return character.unicodeScalars.allSatisfy { punctuation.contains($0) }
    }
}
