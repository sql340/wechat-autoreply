# GitHub 同类项目调研

调研日期：2026-11-10。Star 数为当日 GitHub API 读数，仅用于判断社区规模，不代表质量或安全性。

## 结论先行

1. **个人微信自动回复没有“官方允许 + 可读取好友消息”的通道。** 微信官方的 ClawBot 插件只能让你和“机器人联系人”对话，不能读取或代回好友聊天。
2. **老一代方案正在失效。** 基于网页协议的 itchat/Wechaty Web 方案对新账号基本不可用；WeChatFerry 已于 2026-07-10 归档；wxauto 公开文档仍以微信 3.9.x 为主。
3. **微信 4.x 之后，社区主流转向 UI Automation / OCR / Accessibility。** 这类方案不注入进程，技术风险低于 Hook，但仍然属于未经授权的自动化，违反微信使用规范，不能承诺不封号。
4. **macOS 原生方案很少。** 多数项目只支持 Windows。当前 macOS 微信 4.1.15 可用 Accessibility API 做 MVP，但需要自己处理窗口、消息去重和防误发。

## 项目对比

| 项目 | Star | 平台 | 实现方式 | 维护状态 | 许可证 | 风险 | 适合做什么 |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| [lich0821/WeChatFerry](https://github.com/lich0821/WeChatFerry) | 6.8k | Windows | Hook / DLL 注入 | 已归档（2026-07） | MIT | 很高：直接对应“外挂/非官方客户端” | 仅历史研究，不建议新项目 |
| [cluic/wxauto](https://github.com/cluic/wxauto) | 7.4k | Windows | UI Automation | 2026-04 仍有提交；文档主推 3.9.x | Apache-2.0 | 中高：UI 自动化仍违反规范 | Windows 3.9.x 自动化参考 |
| [LTEnjoy/easyChat](https://github.com/LTEnjoy/easyChat) | 1.5k | Windows | UI Automation + GUI | 活跃，支持微信 4.1.15 | 无明确许可证 | 中高 | 功能参考；无许可证不适合直接复用代码 |
| [Hello-Mr-Crab/pywechat](https://github.com/Hello-Mr-Crab/pywechat) | 2.1k | Windows | pywinauto / UI Automation，支持 4.x | 活跃（2026-11） | LGPL-2.1 | 中高 | Windows 上较完整的开源基础库 |
| [fanyuantaier/wechatauto-replica](https://github.com/fanyuantaier/wechatauto-replica) | 644 | Windows | 解密本地数据库 + 修改 Weixin.dll 可访问性开关 | 活跃（2026-11） | Apache-2.0 | 极高：改客户端/读数据库 | 不建议用于真实账号 |
| [wangrongding/wechat-bot](https://github.com/wangrongding/wechat-bot) | 11.5k | 跨平台 | Wechaty / 扫码 Web 协议 | 活跃（2026-09） | 需查看仓库 | 高：README 明确警告封号 | 多 IM 机器人集成参考 |
| [wechaty/wechaty](https://github.com/wechaty/wechaty) | 23.5k | 跨平台 | 会话 RPA SDK，依赖 puppet | 活跃 | Apache-2.0 | 取决于 puppet；个人号协议高风险 | 机器人框架，不是开箱方案 |
| [Luofeng-Cloud/WeChat-AI-AutoReply](https://github.com/Luofeng-Cloud/WeChat-AI-AutoReply) | 267 | Windows | Win32 窗口消息 + OCR + 离屏截图 | 新项目，活跃（2026-11） | MIT | 高；README 的“零封号风险”不可信 | 视觉/OCR 思路参考 |
| [JunxiBao/WeChatAutoReply](https://github.com/JunxiBao/WeChatAutoReply) | 2 | macOS | Accessibility API + CGEvent | 2026-07 后无更新 | MIT | 中高 | macOS MVP 的最佳参考原型 |
| [petryiy/AI-Auto-Reply-Chat-Bot-For-Wechat-On-Mac-](https://github.com/petryiy/AI-Auto-Reply-Chat-Bot-For-Wechat-On-Mac-) | 7 | macOS | 截图 + Tesseract OCR + 坐标点击 | 2025-09 后无更新 | 无 | 高 | 旧版思路参考，不建议直接用 |
| [Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin) | 1.0k | 官方插件 | 微信 ClawBot / iLink 消息通道 | 官方维护，活跃 | 需查看仓库 | 官方通道 | 只能和机器人联系人对话，不能代回好友 |
| [WecomTeam/wecom-openclaw-plugin](https://github.com/WecomTeam/wecom-openclaw-plugin) | — | 企业微信 | 官方企业微信插件 | 官方维护 | 需查看仓库 | 官方通道 | 企业客服/内部助手，合规首选 |

## 四条技术路线

### 1. 官方客服通道（公众号 / 企业微信）

**做法**：用户先关注公众号或添加企业微信客服，消息通过官方回调到达你的服务，你用客服消息接口回复。

**优点**：合规、稳定、可长期运行；适合真实业务。

**限制**：不能读取个人好友聊天；公众号客服消息有 48 小时窗口和条数限制（用户回复后通常 5 条）；需要认证主体、服务器和公网回调。

**适合**：电商客服、售后、预约、企业内外部服务。

### 2. 官方 ClawBot 插件

**做法**：微信“设置 → 插件”里绑定 ClawBot，把消息转发给你部署的 OpenClaw Agent。

**优点**：腾讯官方插件入口，不需要改客户端或模拟协议。

**限制**：ClawBot 是一个独立机器人联系人；官方明确它不自动操作微信、不获取聊天记录。它不能替你回复好友私聊，也不能扫描未读会话。

**适合**：把微信当作自己 AI Agent 的聊天入口，而不是“代回好友”。

### 3. UI 自动化 / Accessibility / OCR

**做法**：读取微信窗口的控件树或截图，模拟点击、输入、回车。

**优点**：不注入进程、不逆向协议；实现成本相对低；微信 4.x 仍可用。

**限制**：依赖窗口和版本；微信更新可能失效；仍属于未经授权的自动化；高频、群发、营销场景容易触发风控。

**适合**：个人白名单私聊、低频辅助回复、内部试验。

### 4. Hook / 协议逆向

**做法**：注入 DLL、修改内存、解密本地数据库，或自己实现微信通信协议。

**优点**：能拿到完整消息、联系人、群聊，能力强。

**限制**：直接落入“外挂/非官方客户端/非官方方式登录”的定义；封号风险最高；还可能引入恶意代码、账号被盗、数据泄露风险。

**结论**：不建议用于主账号或任何长期运行的项目。

## 对本项目的选择

当前机器是 macOS 27.0.1，已安装微信 4.1.15。GitHub 上没有成熟、活跃、可直接使用的 macOS 个人微信自动回复项目，因此本项目选择：

- **macOS Accessibility API** 读取当前聊天窗口；
- **CGEventPostToPid** 发送键盘事件；
- 不注入、不修改客户端、不读取本地数据库；
- 默认 `dry_run`，白名单为空时不回复；
- 先做单聊天 MVP，再评估菜单栏 UI、审批队列和多聊天扫描。

Windows 端如果后续要做，优先参考 `pywechat` 的 UI Automation 接口；不要使用 `wechatauto-replica` 的数据库解密/DLL 修改方案。
