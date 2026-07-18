# Privacy Policy / 隐私政策

Effective date: 2026-07-18

[English](#english) · [简体中文](#简体中文)

## English

### Summary

ChatGPT Skin Studio is a local macOS controller. The skin engine has no project-operated account system, analytics service, advertising SDK, telemetry endpoint, or cloud theme service. It is designed to style a verified local ChatGPT desktop process without collecting or sending conversation content to the project maintainers.

This policy describes ChatGPT Skin Studio only. The ChatGPT desktop app, GitHub, Apple, and any update-hosting provider operate under their own privacy terms.

### Data processed on your Mac

The app processes the minimum local information needed for its functions:

| Category | Purpose | Storage / transmission |
|---|---|---|
| ChatGPT app identity | Verify path, Bundle ID, Team ID, version, build, executable, and code signature | Used locally; version/build may appear in local diagnostics |
| Process and listener metadata | Verify that the random `127.0.0.1` CDP listener belongs to the managed ChatGPT process | Used locally during the session |
| Renderer structure | Classify route, viewport, entry-script count, and selector cardinality | Used locally for compatibility and fail-closed behavior |
| Short UI labels | Optional brand/icon extensions may compare visible navigation or suggestion labels to locate a visual anchor | Used in renderer memory; not designed to be persisted or sent to maintainers |
| Theme assets | Validate and render bundled or user-imported images and manifest fields | Stored in the app bundle or local Application Support |
| Diagnostics | Record bounded runtime event names and failure details | Stored locally in `diagnostics.log` and one rotated previous log |

### Conversation and workspace content

The compatibility adapter is designed not to inspect conversation text. ChatGPT Skin Studio is not designed to read, store, or export:

- chat messages or conversation identifiers;
- terminal output or repository file contents;
- clipboard contents;
- API keys, credentials, or environment secrets;
- `localStorage` contents;
- ChatGPT request or response bodies.

Optional schema v3.1 visual extensions do locally compare short button labels—such as navigation and suggestion titles—to position theme-owned graphics. This narrow label matching is separate from the structural compatibility probe and is not a chat-content collection mechanism.

### Custom image imports

When you import a theme image, the selected local file is decoded and re-encoded on your Mac. The importer accepts a single static image, removes source metadata during re-encoding, constrains output size, validates the result, and stores it under:

```text
~/Library/Application Support/ChatGPTSkinStudio/Themes
```

The project does not upload imported images. You are responsible for having the right to use any imported content.

### Local diagnostics

Runtime diagnostics are written to:

```text
~/Library/Application Support/ChatGPTSkinStudio/diagnostics.log
~/Library/Application Support/ChatGPTSkinStudio/diagnostics.prev.log
```

The active file rotates after approximately 2 MB. Diagnostic fields are length-limited and sanitized for line breaks. The logger is intended for state transitions, compatibility signatures, generations, and error details—not conversation content. Because operating-system or dependency error descriptions can contain unexpected context, review a log before sharing it publicly.

### Network connections

The skin session uses HTTP and WebSocket connections to a verified random port on `127.0.0.1`. The skin engine does not use that connection to proxy or inspect ChatGPT network traffic.

If a particular release enables automatic update checks, its updater contacts the appcast and release-hosting endpoints named by that release. Those providers can receive ordinary network metadata such as IP address, time, requested URL, and user agent. Automatic-update support and provider details are release-specific.

The ChatGPT desktop app continues to communicate with OpenAI independently. ChatGPT Skin Studio does not control OpenAI's processing or retention.

### Retention and deletion

The project maintainers do not receive local theme or diagnostic data through the app. Local files remain until you remove them. To delete user themes and diagnostics, quit ChatGPT Skin Studio and remove:

```text
~/Library/Application Support/ChatGPTSkinStudio
```

Removing that folder is separate from removing the application itself. It does not delete ChatGPT data.

### Changes and contact

Material policy changes will be recorded in this repository. For a privacy defect, open a GitHub Issue without attaching private logs or screenshots. For a vulnerability, use the private process in [SECURITY.md](SECURITY.md).

## 简体中文

### 摘要

ChatGPT Skin Studio 是本机 macOS Controller。皮肤引擎不包含项目方运营的账号系统、analytics、广告 SDK、telemetry 服务或云端主题服务。它的设计是在不向项目维护者收集或发送对话内容的前提下，为经过验证的本地 ChatGPT 桌面进程换肤。

本政策只适用于 ChatGPT Skin Studio。ChatGPT 桌面 App、GitHub、Apple 和更新托管服务各自适用其隐私条款。

### 在 Mac 上处理的数据

| 类别 | 用途 | 存储/传输 |
|---|---|---|
| ChatGPT App 身份 | 验证路径、Bundle ID、Team ID、版本、build、executable 和代码签名 | 本机使用；版本/build 可能进入本机诊断 |
| 进程与 listener 元数据 | 验证随机 `127.0.0.1` CDP listener 属于受管 ChatGPT 进程 | 会话内本机使用 |
| Renderer 结构 | 判断 route、viewport、entry script 数量和 selector cardinality | 本机用于兼容判断和 fail closed |
| 短 UI 标签 | 可选品牌/图标扩展可能比较可见导航或建议标题，以定位视觉锚点 | renderer 内存中使用；设计上不持久化或发送给维护者 |
| 主题资源 | 校验并渲染内置或用户导入图片及 manifest 字段 | App bundle 或本机 Application Support |
| 诊断 | 记录有长度限制的运行事件和失败信息 | 本机 `diagnostics.log` 及一个轮转旧日志 |

### 对话与工作区内容

兼容性 Adapter 的设计不读取对话文本。ChatGPT Skin Studio 的设计不读取、保存或导出：

- 聊天消息和对话标识；
- Terminal 输出和仓库文件内容；
- 剪贴板；
- API Key、凭据和环境机密；
- `localStorage` 内容；
- ChatGPT 网络请求或响应正文。

可选 schema v3.1 视觉扩展会在本机比较导航和建议标题等短按钮标签，用于定位主题自有图形。这一窄范围标签匹配与结构兼容性探测相互独立，不属于聊天内容采集机制。

### 自定义图片导入

导入主题图片时，所选本地文件会在 Mac 上解码和重新编码。导入器只接受单帧静态图片，在重新编码时移除源元数据，限制输出大小，校验结果，并保存到：

```text
~/Library/Application Support/ChatGPTSkinStudio/Themes
```

项目不会上传导入图片。用户需自行保证对导入内容拥有使用权。

### 本机诊断

运行诊断保存在：

```text
~/Library/Application Support/ChatGPTSkinStudio/diagnostics.log
~/Library/Application Support/ChatGPTSkinStudio/diagnostics.prev.log
```

当前日志约 2 MB 后轮转。字段有长度限制，并会清理换行。日志目标是记录状态转换、兼容签名、generation 和错误信息，而不是对话内容。但操作系统或依赖返回的错误描述可能包含意外上下文，因此公开分享前请先检查日志。

### 网络连接

皮肤会话通过 HTTP 和 WebSocket 连接经过验证的随机 `127.0.0.1` 端口。皮肤引擎不会借此代理或检查 ChatGPT 的网络流量。

如果某个 Release 启用了自动更新，Updater 会连接该 Release 指定的 appcast 和安装包托管地址。相关服务商可能收到 IP、时间、请求 URL 和 User-Agent 等普通网络元数据。自动更新能力和服务商以每个 Release 的说明为准。

ChatGPT 桌面 App 会独立与 OpenAI 通信；ChatGPT Skin Studio 不控制 OpenAI 的数据处理和保留。

### 保留与删除

项目维护者不会通过 App 收到本机主题或诊断数据。本机文件会保留到用户主动删除。删除用户主题和诊断时，请退出 ChatGPT Skin Studio，然后移除：

```text
~/Library/Application Support/ChatGPTSkinStudio
```

删除该目录与移除 App 本身相互独立，也不会删除 ChatGPT 数据。

### 变更与联系

重大政策变更会记录在本仓库。隐私缺陷可通过 GitHub Issue 反馈，但不要附带私人日志或截图；漏洞请按 [SECURITY.md](SECURITY.md) 私下报告。
