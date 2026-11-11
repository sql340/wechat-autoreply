import Foundation

public enum LLMError: LocalizedError {
    case missingAPIKey
    case invalidURL(String)
    case timeout
    case http(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "缺少模型 API Key"
        case .invalidURL(let value):
            return "模型接口地址无效：\(value)"
        case .timeout:
            return "模型请求超时"
        case .http(let code, let body):
            return "模型接口返回 HTTP \(code)：\(body)"
        case .invalidResponse(let detail):
            return "模型响应无法解析：\(detail)"
        }
    }
}

public final class LLMClient {
    private let config: AppConfig
    private let session: URLSession

    public init(config: AppConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = config.resolvedLLM.resolvedTimeout
        sessionConfig.timeoutIntervalForResource = config.resolvedLLM.resolvedTimeout + 5
        self.session = URLSession(configuration: sessionConfig)
    }

    public func generateReply(
        chatName: String,
        incoming: String,
        context: [ChatMessage]
    ) throws -> String {
        guard let apiKey = config.resolvedLLM.resolvedAPIKey else {
            throw LLMError.missingAPIKey
        }

        let base = config.resolvedLLM.resolvedBaseURL
        let endpoint = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidURL(endpoint)
        }

        let maxChars = config.resolvedReply.resolvedMaxReplyChars
        let transcript = context.suffix(10).map { message -> String in
            let speaker = message.fromMe ? "我" : "对方"
            return "\(speaker)：\(message.text)"
        }.joined(separator: "\n")

        let userPrompt = """
        你正在代替账号主人回复微信联系人「\(chatName)」。

        最近对话：
        \(transcript.isEmpty ? "（无）" : transcript)

        对方刚刚说：
        \(incoming)

        要求：
        - 只输出要发送的回复正文。
        - 1-3 句，不超过 \(maxChars) 个汉字。
        - 不要加引号、前缀、解释或括号动作。
        - 不要提自己是 AI、机器人或助手。
        - 不要编造事实；不确定时自然地说晚点确认。
        """

        let body: [String: Any] = [
            "model": config.resolvedLLM.resolvedModel,
            "messages": [
                ["role": "system", "content": config.resolvedPersona.resolvedSystemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": config.resolvedLLM.resolvedTemperature,
            "max_tokens": config.resolvedLLM.resolvedMaxTokens,
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        request.timeoutInterval = config.resolvedLLM.resolvedTimeout

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error>?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(LLMError.invalidResponse("没有 HTTP 状态码"))
                return
            }
            let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard (200..<300).contains(http.statusCode) else {
                outcome = .failure(LLMError.http(http.statusCode, String(bodyText.prefix(500))))
                return
            }
            outcome = .success(data ?? Data())
        }
        task.resume()

        let wait = config.resolvedLLM.resolvedTimeout + 2
        if semaphore.wait(timeout: .now() + wait) == .timedOut {
            task.cancel()
            throw LLMError.timeout
        }

        guard let outcome else {
            throw LLMError.invalidResponse("没有返回结果")
        }
        let data: Data
        switch outcome {
        case .success(let value):
            data = value
        case .failure(let error):
            if let llmError = error as? LLMError { throw llmError }
            throw LLMError.invalidResponse(error.localizedDescription)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LLMError.invalidResponse(String(raw.prefix(500)))
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMError.invalidResponse("模型返回了空内容")
        }
        return trimmed
    }
}
