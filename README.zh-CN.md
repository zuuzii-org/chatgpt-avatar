# ChatGPT Skin Studio

<p align="center">
  <img src="Assets/AppIcon.png" width="160" alt="ChatGPT Skin Studio macOS 桌面 App 图标">
</p>

**为经过验证的 ChatGPT macOS 桌面 App 应用可回退、完整界面皮肤的原生主题控制器。**

[English](README.md) · [最新版本](https://github.com/zuuzii-org/chatgpt-avatar/releases/latest) · [隐私](PRIVACY.md) · [安全](SECURITY.md)

> [!IMPORTANT]
> ChatGPT Skin Studio 是独立的非官方项目，与 OpenAI 没有隶属、认可或支持关系。“ChatGPT”“Codex”及相关名称和标志归各自权利人所有。

ChatGPT Skin Studio 是一款源码可见的 macOS 工具，面向希望定制 ChatGPT 桌面体验、但不愿修改 `app.asar`、替换 App 二进制或破坏官方代码签名的用户。皮肤通过用户授权的本机 Chrome DevTools Protocol（CDP）会话应用，并可通过“恢复原生界面”撤销。

## 效果图

<p align="center">
  <img src="docs/assets/screenshots/theme-library-01.png" width="820" alt="ChatGPT Skin Studio 主题库：雨夜耳机少女、深海守护者、DOTA 剑圣与梦幻西游剑侠客">
</p>

<p align="center"><em>主题库：当前选中主题有清晰状态标识，每张卡片同时展示主题画面与适用页面模式。</em></p>

<p align="center">
  <img src="docs/assets/screenshots/theme-library-02.png" width="820" alt="ChatGPT Skin Studio 主题库：草莓兔甜点屋、我的世界苦力怕、红月鼬神与轨道机甲">
</p>

<p align="center"><em>内置主题：图片驱动的本地主题保持纯数据形态，并在使用前完成验证。</em></p>

## 一览

| | v0.1.0 Public Beta |
|---|---|
| 运行系统 | macOS 14 或更高版本 |
| 目标 App | 经过验证的 `/Applications/ChatGPT.app` |
| Controller 界面 | 简体中文 |
| 兼容策略 | 运行时结构探测；不使用固定 ChatGPT 版本/build 白名单 |
| 主题范围 | Home Full、Thread Core、敏感页面 token-only |
| 更新 | 集成 Sparkle 2；只有 Release 包含有效 EdDSA 公钥并发布 appcast 时才启用 |
| 分发渠道 | [GitHub Releases](https://github.com/zuuzii-org/chatgpt-avatar/releases) |
| 许可证 | 当前未提供许可证文件；见[许可证状态](#许可证状态) |

## 它能做什么

- 为真实 ChatGPT 桌面界面换肤，不显示仿制的 mock 窗口。
- 在受支持的 Home 页面加入全屏 Hero、玻璃侧栏、原生建议卡主题化、Composer、品牌印记及可选图标/文案点缀。
- Thread 使用更克制的 Core 表现；Diff、Review、Terminal、Settings、Pull Request 和 Approval 保留原生语义。
- 首个主题激活后，只要受管会话仍有效，就能在不再次重启 ChatGPT 的情况下切换已验证主题。
- 可把本地静态图片导入为主题：在本机重新编码、移除图片元数据，并设置视觉焦点。
- 集成 Sparkle 2 更新 Controller；Release 公钥缺失或无效时会安全禁用。
- 恢复或 fail closed 时清理项目拥有的样式、节点、reload 脚本、payload 和 binding。

## 它不会做什么

- 不修改、重新分发或替换 `ChatGPT.app` 内的文件。
- 不承诺兼容每一个当前或未来 ChatGPT build。
- 不对每个页面做同等强度的深度换肤；敏感页面和窄窗口会主动保留更多原生 UI。
- 不安装 watchdog，也不会静默重启 ChatGPT。
- 不是 OpenAI 官方产品、插件、扩展或支持渠道。

## 工作原理

1. Controller 验证 `ChatGPT.app` 的精确路径、Bundle ID、OpenAI Team ID 和代码签名。
2. 用户明确确认后，它请求当前 ChatGPT 进程退出，并使用随机 loopback CDP 端口启动受管实例。
3. Structural Adapter 根据当前路由和 renderer 结构判断模式，不把 ChatGPT 版本号作为准入规则。
4. Injector 把经过校验的本地 CSS、图片数据和可选主题扩展挂载到项目拥有的 DOM 节点与属性。
5. 遇到稳定结构不兼容或运行故障时，系统执行清理，并尝试让 ChatGPT 正常启动。

版本号和 build 只作为诊断信息。ChatGPT 升级后仍会进入兼容性探测：结构兼容则继续；只有稳定重复的结构失配才报告不兼容。这属于安全降级，不代表承诺所有未来版本都能工作。

## 页面表现

| 页面/状态 | 模式 | 表现 |
|---|---|---|
| Home / New Task，宽度 `>= 1024px` | Full | Hero、氛围层、玻璃表面、原生卡片主题化、Composer，以及可选品牌/图标点缀 |
| Thread，宽度 `>= 1024px` | Core | 低噪背景、侧栏、Composer 和消息可读性处理 |
| Diff / Review / Terminal / Settings / PR / Approval | token-only | 只应用克制的颜色 token，保留原生语义色和控件 |
| 任意页面，宽度 `< 1024px` | token-only | 隐藏 Hero 和装饰，优先保证可用性 |

## 内置主题

v0.1.0 首发包准备内置以下 10 套主题：

- 雨夜耳机少女（`anime-rain-girl`）
- 深海守护者（`deep-sea-guardian`）
- DOTA 剑圣（`dota-juggernaut`）
- 梦幻西游剑侠客（`dream-westward-journey`）
- 水墨白鹿（`ink-white-deer`）
- 卡丁车夜赛道（`kartrider-dao`）
- 草莓兔甜点屋（`kawaii-strawberry-bunny`）
- 我的世界苦力怕（`minecraft-creeper`）
- 红月鼬神（`naruto-itachi`）
- 轨道机甲（`orbital-mecha`）

部分内置主题的名称和画面涉及第三方作品。它们均为非官方主题，不代表对相关名称、角色或作品拥有权利，也不代表获得授权、赞助或认可。再分发或商业使用前请先阅读 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 安装

### 从 Release 安装

1. 打开[最新 GitHub Release](https://github.com/zuuzii-org/chatgpt-avatar/releases/latest)。
2. 下载该 Release 附带的 DMG；GitHub 自动生成的“Source code”压缩包不是 App 安装包。
3. 打开 DMG，把 **ChatGPT Skin Studio** 拖到 `/Applications`。
4. 启动 App；皮肤会话激活期间请保留其菜单栏入口。

签名、notarization、checksum 和自动更新能力以每个 Release 的说明为准；只有 Release 明确确认的能力才视为受支持。不要为来源不明的安装包绕过 macOS 安全警告。

### 系统要求

- macOS 14 或更高版本。
- 官方桌面 App 位于 `/Applications/ChatGPT.app`。
- 首次应用皮肤或恢复原生界面时，允许中断并重新启动 ChatGPT。

> [!WARNING]
> 首次应用皮肤和恢复原生界面都会中断当前 ChatGPT 进程。确认前请完成或保存重要任务。Controller 不会强杀无响应的进程。

## 使用方法

1. 打开 ChatGPT Skin Studio，选择主题。
2. 点击**应用到 ChatGPT…**。
3. 阅读重启说明，只在当前 ChatGPT 任务可以中断时确认。
4. 激活后可选择另一主题，通过**无重启切换主题**在同一受管会话内切换。
5. 希望清理皮肤时，先点击**恢复原生界面**，再退出 Controller。

如果 ChatGPT 自身退出或重启后皮肤消失，请重新打开 Controller 并应用。视觉注入只属于当前会话，不会永久修改 ChatGPT。

## 导入自定义图片主题

点击**导入图片主题…**，选择静态 PNG、JPEG、WebP、HEIC 或 HEIF 图片。导入器会：

- 验证输入是本地普通文件和单帧静态图片；
- 在本机解码并重新编码为 PNG 或 JPEG；
- 在重新编码时移除源图片元数据；
- 保存前限制文件大小和像素数量；
- 把主题保存到 `~/Library/Application Support/ChatGPTSkinStudio/Themes`；
- 仅预览或保存导入主题时不重启 ChatGPT。

请只使用你有权使用的图片；导入内容的权利责任由用户承担。

## 隐私与安全模型

- 皮肤引擎不包含项目方运营的 analytics、广告、telemetry 服务或云端主题服务。
- CDP discovery 和 WebSocket 通信仅连接随机选择的 `127.0.0.1` listener，并验证 listener 所属进程。
- 结构兼容性探测使用 route、viewport、脚本数量和 selector cardinality，不读取对话文本。
- 可选视觉扩展可能在本机比较短的导航或建议卡标签，用于定位主题自有印记和图标；这些标签不会发送给项目维护者。
- Controller 的设计不读取或导出聊天、Terminal 输出、仓库内容、剪贴板、API Key、`localStorage` 或 ChatGPT 网络请求。
- 运行诊断保存在 `~/Library/Application Support/ChatGPTSkinStudio/diagnostics.log`，并保留一个有大小上限的旧日志。

完整说明见[隐私政策](PRIVACY.md)和[安全政策](SECURITY.md)。

## 兼容性 FAQ

### ChatGPT Skin Studio 支持最新版 ChatGPT 桌面 App 吗？

它不使用固定版本白名单。每个已安装 build 都会进入运行时结构探测：必要结构仍匹配时可以应用；出现稳定失配时，Controller 会清理并报告不兼容。因此，ChatGPT 升级后可能无需 Skin Studio 更新就能继续使用，但这不是兼容保证。

### 它会修改或重新签名 `ChatGPT.app` 吗？

不会。Controller 验证官方 App，通过本机调试连接应用会话级 renderer 样式，不修改 `app.asar`、不替换二进制，也不改变官方代码签名。

### 它会读取我的聊天吗？

兼容性探测不读取对话文本。可选主题扩展可能在本机匹配导航或建议标题等短 UI 标签，以定位视觉点缀；它的设计不会读取、保存或传输聊天内容。准确边界见 [PRIVACY.md](PRIVACY.md)。

### 为什么应用皮肤需要重启 ChatGPT？

Controller 需要通过 loopback CDP listener 启动一个经过验证的受管 ChatGPT 进程。无法把该 listener 安全地追加到已经运行的进程，因此首次应用和恢复都要求明确确认。

### 能否无重启切换主题？

可以。首个主题激活后，只要同一受管 ChatGPT 会话仍然有效，就能无重启切换。切换过程会严格清理；新主题失败时会尝试恢复之前的主题。

### 皮肤是永久的吗？

不是。它附着于当前受管 renderer 会话。恢复原生界面、退出/重启 ChatGPT 或 fail-closed 清理都会移除皮肤。

### 为什么有些页面换肤更克制？

Diff、Terminal、Settings、Approval、Pull Request 和窄窗口只使用 token-only 表现，以保留原生语义、对比度和风险提示。

### 自动更新如何工作？

App 集成 Sparkle 2；只有 Release build 注入有效 EdDSA 公钥时，才提供**检查更新…**。项目还必须发布该 Release 说明中的签名更新压缩包和 `appcast.xml`，更新才真正可用；任一条件缺失时，请从 GitHub Releases 手动更新。

## 从源码构建与测试

需要带 Swift 6 toolchain 的 Xcode，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
xcodegen generate
xcodebuild -project ChatGPTSkinStudio.xcodeproj \
  -scheme ChatGPTSkinStudio \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  test
```

常规测试会跳过需要启动 ChatGPT 的 live 测试。仍有重要 ChatGPT 任务运行时，不要执行 live 或 production E2E。构建成功不等于已登录 renderer 的视觉兼容性验收通过。

## 文档

- [架构与信任边界](docs/ARCHITECTURE.md)
- [隐私政策](PRIVACY.md)
- [安全政策](SECURITY.md)
- [变更记录](CHANGELOG.md)
- [第三方声明与商标](THIRD_PARTY_NOTICES.md)
- [实施合同](ChatGPT_Skin_Studio_实施方案.md)

## 许可证状态

本仓库当前**没有**许可证文件。公开可见源码本身不代表授予复制、修改、再分发或商业使用代码及内置图片的许可。第三方标志和所涉及作品仍归各自权利人所有。

缺陷、兼容问题和文档问题请通过 [GitHub Issues](https://github.com/zuuzii-org/chatgpt-avatar/issues) 反馈。疑似安全漏洞请按 [SECURITY.md](SECURITY.md) 私下报告，不要创建公开 Issue。
