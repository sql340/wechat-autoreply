# WeChat Auto Reply (macOS MVP)

本地运行的微信 AI 自动回复原型。通过 macOS Accessibility API 读取当前聊天窗口，通过键盘事件发送回复；不注入微信进程、不修改客户端、不逆向通信协议。

> **重要：这不是微信官方功能。** 使用第三方自动化操作个人微信违反《微信个人账号使用规范》，可能导致警告、限制功能或封号。项目默认 `dry_run`，只生成草稿不发送。请先用小号、白名单和低频测试，并自行承担风险。详见 [风险说明](docs/risk.md)。

## 当前能力

- 读取当前打开的微信私聊窗口和最近消息。
- 只对配置白名单内的联系人回复。
- 支持 OpenAI 兼容接口（DeepSeek、Qwen、Kimi、OpenAI、Ollama 等）。
- 生成回复前有防抖、随机延迟、跳过概率、每小时/每天上限、活跃时段等限制。
- 支持 `dry_run`（只打印草稿）和 `auto`（真正发送）。
- 本地 JSONL 审计日志，默认不记录消息正文。
- `diagnose` 命令用于检查权限、微信窗口和消息读取是否正常。

## 环境

- macOS 14+（当前验证环境：macOS 27.0.1）
- 微信 Mac 版已登录并打开一个聊天窗口（当前验证版本：4.1.15）
- Swift 6 / Xcode Command Line Tools
- 一个 OpenAI 兼容的模型 API Key

## 快速开始

```bash
cd wechat-autoreply
cp config.example.json config.json

# 推荐用环境变量保存密钥
export DEEPSEEK_API_KEY='sk-...'

# 1. 检查权限和微信窗口
swift run wechat-autoreply diagnose

# 2. 只生成草稿，不发送
swift run wechat-autoreply run --config config.json --dry-run

# 3. 确认草稿质量和目标联系人后，再开启自动发送
#    先把 config.json 中 safety.dry_run 改成 false，并把 reply.mode 改成 "auto"
swift run wechat-autoreply run --config config.json
```

运行纯逻辑自检：

```bash
swift run self-test
```

构建稳定的 release 二进制（推荐，便于给固定路径授权辅助功能）：

```bash
bash scripts/build.sh
bin/wechat-autoreply diagnose
bin/wechat-autoreply run --config config.json
```

首次运行 `diagnose` 时，macOS 可能提示授予“辅助功能”权限。授权后需要完全退出并重新打开终端。权限授予对象是运行命令的终端（Terminal、iTerm）或编译后的二进制。

## 配置

复制 [config.example.json](config.example.json) 后修改。关键字段：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `reply.mode` | `draft` | `draft` 只生成草稿；`auto` 自动发送 |
| `contacts.whitelist` | `[]` | 为空时不回复任何人，失败关闭 |
| `reply.active_hours` | `09:00-23:00` | 只在指定时段回复 |
| `reply.max_replies_per_hour` | `8` | 每小时回复上限 |
| `reply.max_replies_per_day` | `40` | 每天回复上限 |
| `reply.skip_probability` | `0.15` | 随机跳过概率，避免“每句必回” |
| `safety.dry_run` | `true` | 总开关，优先级高于 `reply.mode` |

## 诊断与调试

```bash
# 查看微信是否运行、是否有辅助功能权限、当前聊天和最近消息
swift run wechat-autoreply diagnose

# 导出当前微信窗口的 Accessibility 树，便于适配新版本
swift run wechat-autoreply dump-ax --output ax-dump.txt
```

如果 `diagnose` 能读到聊天名但读不到消息，通常是微信版本更新导致 Accessibility 树变化。把 `ax-dump.txt` 保留下来再适配。

## 项目结构

```text
wechat-autoreply/
├── Sources/WeChatAutoReplyCore/   # 微信读取、回复引擎、安全限制、LLM 客户端
├── Sources/WeChatAutoReply/       # CLI 入口
├── Tests/WeChatAutoReplySelfTest/ # 无需 XCTest 的纯逻辑自检
├── docs/
│   ├── github-survey.md           # GitHub 同类项目调研
│   ├── risk.md                    # 封号风险与安全边界
│   ├── requirements.md            # 落地前需要确认的信息
│   └── architecture.md            # 架构与后续路线
└── config.example.json
```

## 已知限制

- 只处理**当前打开的一个聊天窗口**，不会自动扫描所有未读会话。
- 默认不处理群聊；白名单机制是主要边界。
- 微信更新可能改变 Accessibility 树，导致读取或发送失败。
- 发送依赖窗口焦点和键盘事件；发送前会二次校验聊天名，但仍不能完全排除误发的可能。
- 没有菜单栏 UI、审批队列、图片/语音/文件处理和多账号支持；这些在 [架构文档](docs/architecture.md) 的后续路线中。

## 当前验证状态

- `swift build` 和 `swift build -c release` 通过。
- `swift run self-test` 的消息去重、安全过滤、频率限制、白名单和配置默认值测试通过。
- 真实微信窗口的读取/发送尚未在本机验证：验证时微信未运行，且辅助功能权限未授权。授权并登录后，先跑 `diagnose`，再跑 `--dry-run`。

## 参考项目

- [JunxiBao/WeChatAutoReply](https://github.com/JunxiBao/WeChatAutoReply)：macOS Accessibility + CGEvent 的 MIT 原型。
- [Hello-Mr-Crab/pywechat](https://github.com/Hello-Mr-Crab/pywechat)：Windows UI Automation 方案，支持微信 4.x。
- [Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin)：微信官方 ClawBot 插件通道，但只能和机器人联系人对话，不能读取好友聊天。

本项目与腾讯、微信无关联。
