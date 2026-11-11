import Foundation
import Darwin
import WeChatAutoReplyCore

let arguments = Array(CommandLine.arguments.dropFirst())

func optionValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func hasFlag(_ name: String) -> Bool {
    arguments.contains(name)
}

func printUsage() {
    print("""
    WeChat Auto Reply (macOS)

    用法:
      wechat-autoreply diagnose [--config config.json]
      wechat-autoreply dump-ax [--output ax-dump.txt] [--depth 12]
      wechat-autoreply run [--config config.json] [--dry-run] [--once]

    命令:
      diagnose   检查辅助功能权限、微信运行状态，并读取当前聊天
      dump-ax    导出微信窗口的 Accessibility 树，用于适配新版本
      run        开始轮询；默认使用配置中的 dry_run 设置

    安全提示:
      个人微信自动化违反微信使用规范，可能导致警告、限制或封号。
      建议先用小号、白名单和 dry-run 验证。
    """)
}

func fail(_ message: String, code: Int32) -> Never {
    fputs(message + "\n", stderr)
    exit(code)
}

func preview(_ text: String, limit: Int = 120) -> String {
    let oneLine = text.replacingOccurrences(of: "\n", with: " ")
    return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit)) + "…"
}

func runDiagnose() {
    let bridge = WeChatAXBridge()
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("微信进程: \(bridge.isWeChatRunning ? "运行中" : "未运行")")

    if !bridge.hasAccessibilityPermission {
        print("辅助功能权限: 未授权")
        bridge.requestAccessibilityPermission()
        print("已请求权限。请在“系统设置 → 隐私与安全性 → 辅助功能”中授权当前终端，然后完全退出并重新打开终端。")
        exit(2)
    }
    print("辅助功能权限: 已授权")

    guard bridge.isWeChatRunning else {
        fail("微信未运行。请先打开并登录微信。", code: 3)
    }

    guard let snapshot = bridge.currentSnapshot() else {
        fail("没有找到微信窗口。请打开一个聊天窗口后重试。", code: 4)
    }

    print("当前聊天: \(snapshot.chatName ?? "未知（可能是群聊或窗口标题未暴露）")")
    print("可见消息: \(snapshot.messages.count)")
    print("输入框: \(bridge.hasInputField() ? "找到" : "未找到（自动发送会失败）")")

    if snapshot.messages.isEmpty {
        print("消息读取: 未读到消息。请确认聊天窗口在右侧、窗口未被最小化，并查看 dump-ax 输出。")
    } else {
        print("最近消息:")
        for message in snapshot.messages.suffix(8) {
            print("  [\(message.fromMe ? "我" : "对方")] \(preview(message.text, limit: 80))")
        }
    }

    if let configPath = optionValue("--config") {
        do {
            let config = try AppConfig.load(path: configPath)
            let allowed = config.resolvedContacts.isAllowed(chatName: snapshot.chatName)
            print("白名单匹配: \(allowed ? "是" : "否")")
            print("配置模式: \(config.resolvedSafety.resolvedDryRun ? "dry-run" : config.resolvedReply.resolvedMode.rawValue)")
        } catch {
            print("配置读取失败: \(error.localizedDescription)")
        }
    }
}

func runDumpAX() {
    let bridge = WeChatAXBridge()
    guard bridge.hasAccessibilityPermission else {
        bridge.requestAccessibilityPermission()
        fail("缺少辅助功能权限。授权后重新打开终端再试。", code: 2)
    }
    guard bridge.isWeChatRunning else {
        fail("微信未运行。请先打开并登录微信。", code: 3)
    }

    let output = optionValue("--output") ?? "ax-dump.txt"
    let depth = Int(optionValue("--depth") ?? "12") ?? 12
    let tree = bridge.dumpAccessibilityTree(maxDepth: max(1, min(30, depth)))
    let path = NSString(string: output).expandingTildeInPath

    do {
        try tree.write(toFile: path, atomically: true, encoding: .utf8)
        print("已写入 \(path)（\(tree.count) 字符）")
    } catch {
        fail("写入失败：\(error.localizedDescription)", code: 5)
    }
}

func runEngine() {
    let configPath = optionValue("--config") ?? "config.json"
    var config: AppConfig
    do {
        config = try AppConfig.load(path: configPath)
    } catch {
        fail("读取配置失败：\(error.localizedDescription)", code: 1)
    }

    if hasFlag("--dry-run") {
        config.forceDryRun()
    }

    do {
        _ = try config.requireAPIKey()
    } catch {
        fail("\(error.localizedDescription)", code: 1)
    }

    let bridge = WeChatAXBridge()
    guard bridge.hasAccessibilityPermission else {
        bridge.requestAccessibilityPermission()
        fail("缺少辅助功能权限。请在系统设置中授权当前终端，完全退出后重新打开终端。", code: 2)
    }
    guard bridge.isWeChatRunning else {
        fail("微信未运行。请先打开并登录微信，并打开一个聊天窗口。", code: 3)
    }

    let engine = ReplyEngine(config: config, bridge: bridge)
    engine.printBanner()

    if hasFlag("--once") {
        engine.runOnce(wait: config.resolvedPollInterval)
    } else {
        engine.run()
    }
}

guard let command = arguments.first else {
    printUsage()
    exit(0)
}

switch command {
case "diagnose":
    runDiagnose()
case "dump-ax":
    runDumpAX()
case "run":
    runEngine()
case "help", "--help", "-h":
    printUsage()
default:
    fputs("未知命令：\(command)\n\n", stderr)
    printUsage()
    exit(1)
}
