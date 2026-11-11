import Cocoa
import ApplicationServices
import CoreGraphics
import Darwin

public final class WeChatAXBridge {
    public init() {}

    public var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibilityPermission() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
    }

    public var isWeChatRunning: Bool {
        runningApp() != nil
    }

    public var weChatPID: pid_t? {
        runningApp()?.processIdentifier
    }

    public func hasInputField() -> Bool {
        guard let window = mainWindow() else { return false }
        return findInputField(window: window) != nil
    }

    public func currentSnapshot() -> ChatSnapshot? {
        guard let window = mainWindow() else { return nil }
        let chatName = currentChatName(window: window)
        let messages = readMessages(window: window, chatName: chatName)
        return ChatSnapshot(chatName: chatName, messages: messages)
    }

    public func sendMessage(_ text: String) -> Bool {
        guard !text.isEmpty, let app = runningApp() else { return false }
        let pid = app.processIdentifier
        app.unhide()
        app.activate(options: [.activateIgnoringOtherApps])
        usleep(650_000)

        guard let window = mainWindow(), let input = findInputField(window: window) else {
            return false
        }
        AXUIElementSetAttributeValue(input, "AXFocused" as CFString, kCFBooleanTrue)
        usleep(180_000)

        let source = CGEventSource(stateID: .hidSystemState)
        postKey(0x00, flags: .maskCommand, pid: pid, source: source)
        usleep(70_000)
        postKey(0x33, flags: [], pid: pid, source: source)
        usleep(90_000)

        for character in text {
            var units = Array(String(character).utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.postToPid(pid)
            }
            usleep(useconds_t(Double.random(in: 0.04...0.16) * 1_000_000))
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.postToPid(pid)
            }
            usleep(useconds_t(Double.random(in: 0.01...0.04) * 1_000_000))
            if Double.random(in: 0..<1) < 0.08 {
                usleep(useconds_t(Double.random(in: 0.25...0.70) * 1_000_000))
            }
        }

        // Best-effort read-back gate: if WeChat exposes the input value and it
        // does not contain the beginning of what we typed, clear and abort
        // instead of sending the wrong content.
        if let refreshedWindow = mainWindow(),
           let refreshedInput = findInputField(window: refreshedWindow),
           let typed = stringAttribute(refreshedInput, "AXValue")?
               .trimmingCharacters(in: .whitespacesAndNewlines) {
            let placeholder = (stringAttribute(refreshedInput, "AXPlaceholderValue") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let knownPlaceholders = ["输入消息", "发送消息", "输入", "Search", "搜索"]
            if !typed.isEmpty,
               typed != placeholder,
               !knownPlaceholders.contains(typed),
               typed.count >= 2,
               !typed.contains(String(text.prefix(min(2, text.count)))) {
                postKey(0x00, flags: .maskCommand, pid: pid, source: source)
                usleep(70_000)
                postKey(0x33, flags: [], pid: pid, source: source)
                return false
            }
        }

        usleep(useconds_t(Double.random(in: 0.45...1.10) * 1_000_000))
        postKey(0x24, flags: [], pid: pid, source: source)
        usleep(250_000)
        return true
    }

    public func dumpAccessibilityTree(maxDepth: Int = 12) -> String {
        guard let window = mainWindow() else {
            return "没有找到微信窗口。请先打开并登录微信，并保持一个聊天窗口可见。"
        }

        var lines: [String] = []
        var visited = 0

        func walk(_ element: AXUIElement, depth: Int) {
            guard visited < 5000 else { return }
            visited += 1

            let role = stringAttribute(element, "AXRole") ?? "?"
            let title = stringAttribute(element, "AXTitle") ?? ""
            let value = stringAttribute(element, "AXValue") ?? ""
            let description = stringAttribute(element, "AXDescription") ?? ""
            let rect = frame(of: element)
            let indent = String(repeating: "  ", count: depth)
            lines.append(
                "\(indent)\(role) title=\(quoted(title)) value=\(quoted(String(value.prefix(160)))) "
                    + "desc=\(quoted(String(description.prefix(100)))) "
                    + "frame=(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)))"
            )

            guard depth < maxDepth else { return }
            for child in children(of: element) {
                walk(child, depth: depth + 1)
            }
        }

        walk(window, depth: 0)
        return lines.joined(separator: "\n")
    }

    // MARK: - App and window

    private func runningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            let bundle = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return bundle == "com.tencent.xinWeChat"
                || bundle == "com.tencent.WeChat"
                || name == "WeChat"
                || name == "微信"
        }
    }

    private func appElement() -> AXUIElement? {
        guard let app = runningApp() else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func mainWindow() -> AXUIElement? {
        guard let app = appElement() else { return nil }
        if let raw = copyAttribute(app, "AXFocusedWindow"), let window = asElement(raw) {
            return window
        }
        if let raw = copyAttribute(app, "AXWindows"),
           let windows = raw as? [AXUIElement],
           let first = windows.first {
            return first
        }
        return nil
    }

    private func currentChatName(window: AXUIElement) -> String? {
        let genericTitles: Set<String> = ["WeChat", "微信", "WeChat (Beta)", "微信 (Beta)"]

        if let title = stringAttribute(window, "AXTitle")?.trimmed,
           !title.isEmpty,
           !genericTitles.contains(title) {
            return title
        }

        if let input = findInputField(window: window),
           let title = stringAttribute(input, "AXTitle")?.trimmed,
           !title.isEmpty,
           !genericTitles.contains(title),
           title != "Search",
           title != "搜索" {
            return title
        }

        let windowFrame = frame(of: window)
        let candidates = findElements(window, maxDepth: 10) { element in
            guard self.role(of: element) == "AXStaticText" else { return false }
            let rect = self.frame(of: element)
            let text = self.stringAttribute(element, "AXValue") ?? self.stringAttribute(element, "AXTitle") ?? ""
            return !text.isEmpty
                && text.count < 60
                && rect.minY >= windowFrame.minY
                && rect.minY < windowFrame.minY + 90
                && rect.minX > windowFrame.minX + windowFrame.width * 0.25
        }

        return candidates.compactMap { element in
            let text = (stringAttribute(element, "AXValue") ?? stringAttribute(element, "AXTitle") ?? "").trimmed
            guard !text.isEmpty, !genericTitles.contains(text), !looksLikeTimestamp(text) else { return nil }
            return text
        }.first
    }

    // MARK: - Input field

    private func findInputField(window: AXUIElement) -> AXUIElement? {
        let windowFrame = frame(of: window)
        let candidates = findElements(window, maxDepth: 35) { element in
            let role = self.role(of: element)
            guard role == "AXTextArea" || role == "AXTextField" else { return false }
            let title = self.stringAttribute(element, "AXTitle") ?? ""
            guard title != "Search", title != "搜索" else { return false }
            let rect = self.frame(of: element)
            if windowFrame.width > 0, rect.width > 0, rect.width < 80 { return false }
            return true
        }

        return candidates.max { lhs, rhs in
            let left = frame(of: lhs)
            let right = frame(of: rhs)
            return (left.width * left.height) < (right.width * right.height)
        }
    }

    // MARK: - Messages

    private func readMessages(window: AXUIElement, chatName: String?) -> [ChatMessage] {
        let windowFrame = frame(of: window)

        let titledLists = findElements(window, maxDepth: 30) { element in
            guard self.role(of: element) == "AXList" else { return false }
            let title = self.stringAttribute(element, "AXTitle") ?? ""
            return title == "Messages" || title == "消息" || title == "聊天消息"
        }

        let rightPanelLists = findElements(window, maxDepth: 30) { element in
            guard self.role(of: element) == "AXList" else { return false }
            let rect = self.frame(of: element)
            guard rect.width > 0, rect.height > 0 else { return false }
            if windowFrame.width > 0 {
                return rect.minX > windowFrame.minX + windowFrame.width * 0.20
                    && rect.width > windowFrame.width * 0.25
                    && rect.height > 120
            }
            return rect.height > 120
        }

        for list in titledLists + rightPanelLists {
            let parsed = parseMessageList(list, windowFrame: windowFrame, chatName: chatName)
            if !parsed.isEmpty { return parsed }
        }

        let scrollAreas = findElements(window, maxDepth: 20) { element in
            guard self.role(of: element) == "AXScrollArea" else { return false }
            let rect = self.frame(of: element)
            if windowFrame.width > 0 {
                return rect.minX > windowFrame.minX + windowFrame.width * 0.20
                    && rect.height > 200
            }
            return rect.height > 200
        }

        for scrollArea in scrollAreas {
            let lists = findElements(scrollArea, maxDepth: 8) { self.role(of: $0) == "AXList" }
            for list in lists {
                let parsed = parseMessageList(list, windowFrame: windowFrame, chatName: chatName)
                if !parsed.isEmpty { return parsed }
            }
        }

        return fallbackTextScan(window: window, windowFrame: windowFrame, chatName: chatName)
    }

    private func parseMessageList(
        _ list: AXUIElement,
        windowFrame: CGRect,
        chatName: String?
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for row in children(of: list) {
            let textElements = findElements(row, maxDepth: 8) { element in
                let role = self.role(of: element)
                return role == "AXStaticText" || role == "AXTextArea"
            }

            var bestText = ""
            var bestFrame = CGRect.zero
            for element in textElements {
                let candidate = (stringAttribute(element, "AXValue")
                    ?? stringAttribute(element, "AXTitle")
                    ?? "").trimmed
                guard !candidate.isEmpty else { continue }
                if candidate.count > bestText.count {
                    bestText = candidate
                    bestFrame = frame(of: element)
                }
            }

            if bestText.isEmpty {
                bestText = (stringAttribute(row, "AXValue") ?? stringAttribute(row, "AXTitle") ?? "").trimmed
                bestFrame = frame(of: row)
            }

            guard isMessageText(bestText, chatName: chatName) else { continue }
            let description = (stringAttribute(row, "AXDescription") ?? "").lowercased()
            let fromMe = senderIsMe(description: description, textFrame: bestFrame, windowFrame: windowFrame)

            if let last = messages.last, last.text == bestText, last.fromMe == fromMe {
                continue
            }
            messages.append(ChatMessage(text: bestText, fromMe: fromMe, frame: bestFrame))
        }
        return messages
    }

    private func fallbackTextScan(
        window: AXUIElement,
        windowFrame: CGRect,
        chatName: String?
    ) -> [ChatMessage] {
        let elements = findElements(window, maxDepth: 35) { element in
            let role = self.role(of: element)
            guard role == "AXStaticText" || role == "AXTextArea" else { return false }
            let rect = self.frame(of: element)
            guard rect.width > 20, rect.height > 10 else { return false }
            if windowFrame.width > 0 {
                return rect.minX > windowFrame.minX + windowFrame.width * 0.20
                    && rect.minY >= windowFrame.minY
                    && rect.maxY <= windowFrame.maxY
            }
            return true
        }

        var messages: [ChatMessage] = []
        for element in elements {
            let text = (stringAttribute(element, "AXValue")
                ?? stringAttribute(element, "AXTitle")
                ?? "").trimmed
            guard isMessageText(text, chatName: chatName) else { continue }
            let rect = frame(of: element)
            let fromMe = senderIsMe(description: "", textFrame: rect, windowFrame: windowFrame)
            if let last = messages.last, last.text == text, last.fromMe == fromMe { continue }
            messages.append(ChatMessage(text: text, fromMe: fromMe, frame: rect))
        }

        return messages.sorted { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > 2 {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    private func senderIsMe(description: String, textFrame: CGRect, windowFrame: CGRect) -> Bool {
        if description.hasPrefix("sent") || description.contains("发出") || description.contains("我说") {
            return true
        }
        if description.hasPrefix("received") || description.contains("收到") || description.contains("对方") {
            return false
        }
        guard textFrame.width > 0, windowFrame.width > 0 else { return false }
        return textFrame.midX > windowFrame.midX + 24
    }

    private func isMessageText(_ text: String, chatName: String?) -> Bool {
        guard !text.isEmpty, text.count <= 2000 else { return false }
        if text == chatName { return false }
        if looksLikeTimestamp(text) { return false }

        let noise: Set<String> = [
            "以下为新消息", "查看更多消息", "消息已发出，但被对方拒收了",
            "对方正在输入", "按住说话", "发送", "取消", "搜索",
            "图片", "视频", "语音", "文件", "表情", "更多",
        ]
        if noise.contains(text) { return false }
        if text.hasPrefix("撤回了一条消息") || text.hasPrefix("你撤回了一条消息") { return false }
        return true
    }

    private func looksLikeTimestamp(_ text: String) -> Bool {
        let patterns = [
            #"^\d{1,2}:\d{2}$"#,
            #"^(上午|下午|晚上|凌晨)?\s*\d{1,2}:\d{2}$"#,
            #"^(昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天])\s*\d{1,2}:\d{2}$"#,
            #"^\d{4}年\d{1,2}月\d{1,2}日"#,
            #"^\d{1,2}月\d{1,2}日"#,
            #"^(昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天])$"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - AX helpers

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private func role(of element: AXUIElement) -> String? {
        stringAttribute(element, "AXRole")
    }

    private func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyAttribute(element, "AXChildren") else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero

        if let raw = copyAttribute(element, "AXPosition"), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgPoint, &origin)
        }
        if let raw = copyAttribute(element, "AXSize"), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    private func findElements(
        _ root: AXUIElement,
        maxDepth: Int,
        matching: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, maxDepth)]

        while let (element, depth) = stack.popLast() {
            if matching(element) {
                results.append(element)
                if results.count >= 5000 { break }
            }
            guard depth > 0 else { continue }
            for child in children(of: element) {
                stack.append((child, depth - 1))
            }
        }
        return results
    }

    private func postKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags,
        pid: pid_t,
        source: CGEventSource?
    ) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.postToPid(pid)
        }
    }

    private func quoted(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(String(cleaned.prefix(160)))\""
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
