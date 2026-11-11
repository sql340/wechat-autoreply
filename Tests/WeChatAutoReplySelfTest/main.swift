import Foundation
import Darwin
import WeChatAutoReplyCore

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

func snapshot(_ texts: [String]) -> ChatSnapshot {
    ChatSnapshot(
        chatName: "张三",
        messages: texts.map { ChatMessage(text: $0, fromMe: false) }
    )
}

func testMessageDiffer() {
    var differ = MessageDiffer()
    check(differ.diff(snapshot: snapshot(["a", "b"])).isEmpty, "首次快照不产生新消息")

    differ.reset(with: snapshot(["a", "b"]))
    check(
        differ.diff(snapshot: snapshot(["a", "b", "c", "d"])).map(\.text) == ["c", "d"],
        "追加消息"
    )

    differ.reset(with: snapshot(["a", "b", "c"]))
    check(
        differ.diff(snapshot: snapshot(["b", "c", "d"])).map(\.text) == ["d"],
        "窗口滚动后的重叠去重"
    )

    differ.reset(with: snapshot(["a", "b"]))
    check(
        differ.diff(snapshot: snapshot(["a", "b", "c", "b"])).map(\.text) == ["c", "b"],
        "尾部重复文本"
    )

    differ.reset(with: snapshot(["a", "b"]))
    check(differ.diff(snapshot: snapshot(["a", "b"])).isEmpty, "无变化")
}

func testSafety() {
    check(Safety.sanitizeReply("  “你好呀”  ", maxChars: 80) == "你好呀", "去除引号")
    check(Safety.sanitizeReply("回复：好的\n明天见", maxChars: 80) == "好的 明天见", "去前缀与换行")
    check(Safety.sanitizeReply("作为 AI，我不能这样回复。", maxChars: 80) == nil, "拒绝 AI 自曝")

    let longText = String(repeating: "好", count: 100)
    let truncated = Safety.sanitizeReply(longText, maxChars: 20)
    check(truncated != nil && (truncated?.count ?? 0) <= 20, "截断长度")

    let keywords = ["人工", "别自动回复", "不要机器人"]
    check(Safety.containsOptOut("能不能别自动回复了", keywords: keywords), "退出词")
    check(Safety.containsOptOut("转 人工", keywords: keywords), "退出词含空格")
    check(!Safety.containsOptOut("今天吃什么", keywords: keywords), "普通消息不触发退出")

    let calendar = Calendar(identifier: .gregorian)
    let daytime = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 10))!
    check(Safety.isWithinActiveHours(daytime, activeHours: ["09:00", "23:00"], calendar: calendar), "日间活跃时段")

    let lateNight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 30))!
    check(!Safety.isWithinActiveHours(lateNight, activeHours: ["09:00", "23:00"], calendar: calendar), "夜间非活跃")

    let earlyMorning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 1))!
    check(Safety.isWithinActiveHours(earlyMorning, activeHours: ["23:00", "07:00"], calendar: calendar), "跨午夜活跃时段")

    check(!Safety.shouldSkip(probability: 0.2, randomValue: 0.5), "随机跳过：不跳过")
    check(Safety.shouldSkip(probability: 0.2, randomValue: 0.1), "随机跳过：跳过")
}

func testRateLimiter() {
    var limiter = RateLimiter()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    limiter.record(now)
    check(limiter.counts(now: now).hour == 1, "频率计数")
    check(!limiter.canReply(now: now, maxPerHour: 1, maxPerDay: 10), "小时上限")
    check(limiter.canReply(now: now.addingTimeInterval(3601), maxPerHour: 1, maxPerDay: 10), "小时窗口滚动")
}

func testContactPolicy() {
    var contacts = ContactConfig()
    check(!contacts.isAllowed(chatName: "张三"), "空白名单失败关闭")

    contacts.whitelist = ["张三"]
    check(contacts.isAllowed(chatName: "张三"), "白名单命中")
    check(!contacts.isAllowed(chatName: "李四"), "白名单未命中")

    contacts.blocklist = ["张三"]
    check(!contacts.isAllowed(chatName: "张三"), "黑名单优先")

    contacts = ContactConfig()
    contacts.whitelist = ["*"]
    check(contacts.isAllowed(chatName: "任何人"), "通配白名单")
}

func testConfigDefaults() {
    let json = #"{"reply":{"mode":"auto"},"contacts":{"whitelist":["张三"]}}"#
    do {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        check(config.resolvedReply.resolvedMode.rawValue == "auto", "配置 mode")
        check(config.resolvedSafety.resolvedDryRun, "默认 dry_run")
        check(!config.resolvedSafety.resolvedStoreMessageContent, "默认不记录正文")
        check(config.resolvedContacts.isAllowed(chatName: "张三"), "配置白名单")
    } catch {
        check(false, "配置解析：\(error.localizedDescription)")
    }
}

print("=== WeChat Auto Reply self-test ===")
testMessageDiffer()
testSafety()
testRateLimiter()
testContactPolicy()
testConfigDefaults()

if failures == 0 {
    print("\n全部通过。")
    exit(0)
} else {
    print("\n失败 \(failures) 项。")
    exit(1)
}
