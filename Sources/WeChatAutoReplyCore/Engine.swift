import Foundation

public final class ReplyEngine {
    private let config: AppConfig
    private let bridge: WeChatAXBridge
    private let logger: EventLogger
    private let llm: LLMClient

    private var limiter = RateLimiter()
    private var differ = MessageDiffer()
    private var disabledChats: Set<String> = []
    private var sentTexts: [String] = []
    private var lastSkipLog: [String: Date] = [:]
    private var lastChat: String?

    public init(config: AppConfig, bridge: WeChatAXBridge = WeChatAXBridge()) {
        self.config = config
        self.bridge = bridge
        self.logger = EventLogger(config: config.resolvedSafety)
        self.llm = LLMClient(config: config)
    }

    public func printBanner() {
        let whitelist = config.resolvedContacts.resolvedWhitelist
        let mode: String
        if config.resolvedSafety.resolvedDryRun {
            mode = "dry-run（只打印草稿，不发送）"
        } else {
            mode = config.resolvedReply.resolvedMode.rawValue
        }

        print("=== WeChat Auto Reply ===")
        print("模式: \(mode)")
        print("白名单: \(whitelist.isEmpty ? "（空，不会回复任何人）" : whitelist.joined(separator: ", "))")
        print("模型: \(config.resolvedLLM.resolvedModel) @ \(config.resolvedLLM.resolvedBaseURL)")
        print("轮询: \(config.resolvedPollInterval)s")
        print("上限: \(config.resolvedReply.resolvedMaxRepliesPerHour)/小时, \(config.resolvedReply.resolvedMaxRepliesPerDay)/天")
        print("活跃时段: \(config.resolvedReply.resolvedActiveHours.joined(separator: " - "))")
        print("日志: \(config.resolvedSafety.resolvedLogPath)")
        if whitelist.isEmpty {
            print("警告：白名单为空，按照失败关闭策略，不会回复任何消息。")
        }
        if !config.resolvedSafety.resolvedDryRun && config.resolvedReply.resolvedMode == .auto {
            print("警告：当前是自动发送模式。微信不允许第三方自动化，存在账号风险。")
        }
        print("按 Ctrl+C 停止。\n")
    }

    public func prime() {
        guard let snapshot = bridge.currentSnapshot() else {
            fputs("没有找到微信窗口。请先打开微信、登录，并打开一个聊天窗口。\n", stderr)
            logger.log("no_window")
            return
        }
        differ.reset(with: snapshot)
        lastChat = snapshot.chatName?.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.log("baseline", chat: snapshot.chatName, meta: ["messages": snapshot.messages.count])
        print("基线已建立：聊天=\(snapshot.chatName ?? "未知")，当前可见消息=\(snapshot.messages.count)")
    }

    public func runOnce(wait: TimeInterval? = nil) {
        prime()
        if let wait, wait > 0 {
            Thread.sleep(forTimeInterval: wait)
        }
        tick()
    }

    public func run(maxIterations: Int? = nil) {
        prime()
        var iterations = 0
        while true {
            if let maxIterations, iterations >= maxIterations { break }
            tick()
            iterations += 1
            if let maxIterations, iterations >= maxIterations { break }
            Thread.sleep(forTimeInterval: config.resolvedPollInterval)
        }
    }

    public func tick() {
        guard bridge.hasAccessibilityPermission else {
            logSkip("no_permission", chat: "?")
            return
        }
        guard let snapshot = bridge.currentSnapshot() else {
            logSkip("no_window", chat: "?")
            return
        }

        let currentChat = snapshot.chatName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentChat != lastChat {
            differ.reset(with: snapshot)
            lastChat = currentChat
            logger.log("chat_switch_baseline", chat: currentChat)
            return
        }

        guard !snapshot.messages.isEmpty else {
            logSkip("empty_messages", chat: currentChat ?? "?")
            return
        }

        let newMessages = differ.diff(snapshot: snapshot)
        guard !newMessages.isEmpty else { return }

        let incomingNew = newMessages.filter { !$0.fromMe && !isSentText($0.text) }
        guard !incomingNew.isEmpty else {
            if !newMessages.isEmpty {
                logger.log("outgoing_only", chat: snapshot.chatName)
            }
            return
        }

        guard let chat = snapshot.chatName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chat.isEmpty else {
            logSkip("unknown_chat", chat: "?")
            return
        }

        guard config.resolvedContacts.isAllowed(chatName: chat) else {
            logSkip("not_whitelisted", chat: chat)
            return
        }

        guard !disabledChats.contains(chat) else {
            logSkip("chat_disabled", chat: chat)
            return
        }

        let combinedIncoming = incomingNew.map(\.text).joined(separator: "\n")
        if Safety.containsOptOut(
            combinedIncoming,
            keywords: config.resolvedReply.resolvedOptOutKeywords
        ) {
            disabledChats.insert(chat)
            logger.log("opt_out", chat: chat, text: combinedIncoming)
            print("已关闭该会话的自动回复：\(chat)")
            return
        }

        guard Safety.isWithinActiveHours(
            Date(),
            activeHours: config.resolvedReply.resolvedActiveHours
        ) else {
            logSkip("outside_hours", chat: chat)
            return
        }

        let now = Date()
        guard limiter.canReply(
            now: now,
            maxPerHour: config.resolvedReply.resolvedMaxRepliesPerHour,
            maxPerDay: config.resolvedReply.resolvedMaxRepliesPerDay
        ) else {
            let counts = limiter.counts(now: now)
            logSkip("rate_limited", chat: chat, meta: ["hour": counts.hour, "day": counts.day])
            return
        }

        guard !Safety.shouldSkip(probability: config.resolvedReply.resolvedSkipProbability) else {
            logSkip("random_skip", chat: chat)
            return
        }

        Thread.sleep(forTimeInterval: 1.5)
        guard let latest = bridge.currentSnapshot(),
              latest.chatName?.trimmingCharacters(in: .whitespacesAndNewlines) == chat else {
            logger.log("chat_changed_before_reply", chat: chat)
            return
        }

        let moreMessages = differ.diff(snapshot: latest)
        let allIncoming = incomingNew + moreMessages.filter { !$0.fromMe && !isSentText($0.text) }
        guard !allIncoming.isEmpty else { return }
        let promptIncoming = allIncoming.map(\.text).joined(separator: "\n")
        let context = Array(latest.messages.suffix(10))

        print("\n[\(Self.timeString())] \(chat) 收到: \(Self.preview(promptIncoming))")

        let replyRaw: String
        do {
            replyRaw = try llm.generateReply(
                chatName: chat,
                incoming: promptIncoming,
                context: context
            )
        } catch {
            logger.log("llm_error", chat: chat, meta: ["error": error.localizedDescription])
            fputs("模型调用失败：\(error.localizedDescription)\n", stderr)
            return
        }

        guard let reply = Safety.sanitizeReply(
            replyRaw,
            maxChars: config.resolvedReply.resolvedMaxReplyChars
        ) else {
            logger.log("reply_rejected", chat: chat, text: replyRaw)
            print("模型回复被安全过滤丢弃。")
            return
        }

        let isDraft = config.resolvedSafety.resolvedDryRun || config.resolvedReply.resolvedMode == .draft
        if isDraft {
            logger.log("draft", chat: chat, text: reply, meta: ["incoming_chars": promptIncoming.count])
            print("[draft] \(reply)")
            return
        }

        let delay = Double.random(
            in: config.resolvedReply.resolvedMinDelay...config.resolvedReply.resolvedMaxDelay
        )
        print("将在 \(String(format: "%.1f", delay)) 秒后发送；期间切换聊天会自动取消。")

        guard sleepCheckingChat(delay, chat: chat) else {
            logger.log("abort_chat_changed", chat: chat)
            print("聊天窗口已切换，取消发送。")
            return
        }

        guard let beforeSend = bridge.currentSnapshot(),
              beforeSend.chatName?.trimmingCharacters(in: .whitespacesAndNewlines) == chat else {
            logger.log("abort_chat_changed", chat: chat)
            print("发送前校验失败：聊天窗口不是目标联系人。")
            return
        }

        guard limiter.canReply(
            now: Date(),
            maxPerHour: config.resolvedReply.resolvedMaxRepliesPerHour,
            maxPerDay: config.resolvedReply.resolvedMaxRepliesPerDay
        ) else {
            logger.log("abort_rate_limited", chat: chat)
            return
        }

        let success = bridge.sendMessage(reply)
        if success {
            limiter.record()
            sentTexts.append(reply)
            if sentTexts.count > 50 { sentTexts.removeFirst(sentTexts.count - 50) }
            logger.log("sent", chat: chat, text: reply, meta: ["incoming_chars": promptIncoming.count])
            print("[sent] \(reply)")

            if let after = bridge.currentSnapshot() {
                _ = differ.diff(snapshot: after)
            }
        } else {
            logger.log("send_failed", chat: chat, text: reply)
            fputs("发送失败：找不到输入框或微信窗口。\n", stderr)
        }
    }

    // MARK: - Helpers

    private func sleepCheckingChat(_ seconds: Double, chat: String) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            Thread.sleep(forTimeInterval: min(0.5, remaining))
            guard let current = bridge.currentSnapshot()?.chatName?
                .trimmingCharacters(in: .whitespacesAndNewlines), current == chat else {
                return false
            }
        }
        return true
    }

    private func isSentText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentTexts.contains(normalized)
    }

    private func logSkip(_ reason: String, chat: String, meta: [String: Any] = [:]) {
        let key = reason + "|" + chat
        let now = Date()
        if let last = lastSkipLog[key], now.timeIntervalSince(last) < 60 { return }
        lastSkipLog[key] = now
        logger.log("skip_\(reason)", chat: chat, meta: meta)
    }

    private static func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func preview(_ text: String, limit: Int = 120) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit)) + "…"
    }
}
