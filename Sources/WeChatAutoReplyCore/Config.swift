import Foundation

public enum ConfigError: LocalizedError {
    case missingFile(String)
    case invalidJSON(String)
    case missingAPIKey(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "配置文件不存在：\(path)"
        case .invalidJSON(let message):
            return "配置文件解析失败：\(message)"
        case .missingAPIKey(let envName):
            return "缺少模型 API Key：请设置环境变量 \(envName)，或在配置文件中填写 llm.api_key"
        }
    }
}

public struct LLMConfig: Codable, Sendable {
    public var baseURL: String?
    public var apiKeyEnv: String?
    public var apiKey: String?
    public var model: String?
    public var temperature: Double?
    public var maxTokens: Int?
    public var timeoutSeconds: Double?

    public init() {}

    public var resolvedBaseURL: String {
        let raw = (baseURL ?? "https://api.deepseek.com/v1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    public var resolvedAPIKeyEnv: String {
        let raw = (apiKeyEnv ?? "DEEPSEEK_API_KEY").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "DEEPSEEK_API_KEY" : raw
    }

    public var resolvedAPIKey: String? {
        if let explicit = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let envValue = ProcessInfo.processInfo.environment[resolvedAPIKeyEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envValue.isEmpty {
            return envValue
        }
        return nil
    }

    public var resolvedModel: String {
        let raw = (model ?? "deepseek-chat").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "deepseek-chat" : raw
    }

    public var resolvedTemperature: Double { temperature ?? 0.7 }
    public var resolvedMaxTokens: Int { maxTokens ?? 300 }
    public var resolvedTimeout: Double { timeoutSeconds ?? 30 }
}

public struct ReplyConfig: Codable, Sendable {
    public var mode: String?
    public var minDelaySeconds: Double?
    public var maxDelaySeconds: Double?
    public var skipProbability: Double?
    public var maxRepliesPerHour: Int?
    public var maxRepliesPerDay: Int?
    public var activeHours: [String]?
    public var optOutKeywords: [String]?
    public var maxReplyChars: Int?

    public init() {}

    public var resolvedMode: ReplyMode {
        ReplyMode(rawValue: (mode ?? "draft").lowercased()) ?? .draft
    }

    public var resolvedMinDelay: Double { max(0.5, minDelaySeconds ?? 4.0) }
    public var resolvedMaxDelay: Double { max(resolvedMinDelay, maxDelaySeconds ?? 12.0) }
    public var resolvedSkipProbability: Double { min(1.0, max(0.0, skipProbability ?? 0.15)) }
    public var resolvedMaxRepliesPerHour: Int { max(1, maxRepliesPerHour ?? 8) }
    public var resolvedMaxRepliesPerDay: Int { max(1, maxRepliesPerDay ?? 40) }
    public var resolvedActiveHours: [String] { activeHours ?? ["09:00", "23:00"] }
    public var resolvedOptOutKeywords: [String] {
        optOutKeywords ?? ["人工", "别自动回复", "关闭自动回复", "不要机器人", "本人呢"]
    }
    public var resolvedMaxReplyChars: Int { max(10, maxReplyChars ?? 80) }
}

public struct ContactConfig: Codable, Sendable {
    public var whitelist: [String]?
    public var blocklist: [String]?
    public var allowGroups: Bool?

    public init() {}

    public var resolvedWhitelist: [String] {
        (whitelist ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public var resolvedBlocklist: [String] {
        (blocklist ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public var resolvedAllowGroups: Bool { allowGroups ?? false }

    public func isAllowed(chatName: String?) -> Bool {
        guard let chatName else { return false }
        let normalized = chatName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if resolvedBlocklist.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return false
        }
        let allowList = resolvedWhitelist
        if allowList.isEmpty { return false }
        if allowList.contains("*") { return true }
        return allowList.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame })
    }
}

public struct PersonaConfig: Codable, Sendable {
    public var systemPrompt: String?

    public init() {}

    public var resolvedSystemPrompt: String {
        let raw = (systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        return "你正在代替账号主人回复微信。语气自然、简短、像真人，不要提自己是 AI 或机器人。只输出回复正文，1-3 句，不超过 80 个汉字。不要编造事实；不确定时用“我晚点确认一下”之类的自然说法。"
    }
}

public struct SafetyConfig: Codable, Sendable {
    public var dryRun: Bool?
    public var storeMessageContent: Bool?
    public var logPath: String?

    public init() {}

    public var resolvedDryRun: Bool { dryRun ?? true }
    public var resolvedStoreMessageContent: Bool { storeMessageContent ?? false }
    public var resolvedLogPath: String {
        let raw = (logPath ?? "~/Library/Logs/WeChatAutoReply/events.jsonl")
        return NSString(string: raw).expandingTildeInPath
    }
}

public struct AppConfig: Codable, Sendable {
    public var pollIntervalSeconds: Double?
    public var llm: LLMConfig?
    public var reply: ReplyConfig?
    public var contacts: ContactConfig?
    public var persona: PersonaConfig?
    public var safety: SafetyConfig?

    public init() {}

    public var resolvedPollInterval: Double { max(0.5, pollIntervalSeconds ?? 2.0) }
    public var resolvedLLM: LLMConfig { llm ?? LLMConfig() }
    public var resolvedReply: ReplyConfig { reply ?? ReplyConfig() }
    public var resolvedContacts: ContactConfig { contacts ?? ContactConfig() }
    public var resolvedPersona: PersonaConfig { persona ?? PersonaConfig() }
    public var resolvedSafety: SafetyConfig { safety ?? SafetyConfig() }

    public static func load(path: String) throws -> AppConfig {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ConfigError.missingFile(expanded)
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.invalidJSON(error.localizedDescription)
        }
    }

    public func requireAPIKey() throws -> String {
        guard let key = resolvedLLM.resolvedAPIKey else {
            throw ConfigError.missingAPIKey(resolvedLLM.resolvedAPIKeyEnv)
        }
        return key
    }

    public mutating func forceDryRun() {
        var safety = resolvedSafety
        safety.dryRun = true
        self.safety = safety
    }
}
