# Security Policy / 安全政策

[English](#english) · [简体中文](#简体中文)

## English

### Supported releases

Security fixes are provided on a best-effort basis for the latest published GitHub Release. Development builds, forks, self-signed packages, modified theme bundles, and older releases are not guaranteed to receive fixes.

The compatibility policy is deliberately independent of the ChatGPT version number. That does not make every ChatGPT build supported: the controller performs runtime structural checks and fails closed when the required contract cannot be established.

### Report a vulnerability privately

Do not publish vulnerability details in a public Issue. When GitHub Private Vulnerability Reporting is enabled, use:

<https://github.com/zuuzii-org/chatgpt-avatar/security/advisories/new>

If that page reports that private reporting is unavailable, open a minimal Issue asking the maintainers to enable a private security channel. Include no reproduction details, logs, screenshots, or impact analysis in that public request.

Include:

- affected ChatGPT Skin Studio version and build;
- macOS version and hardware architecture;
- the minimal reproduction sequence;
- expected and observed behavior;
- security impact and whether it requires a malicious local file, process, theme, or network actor;
- sanitized diagnostics, if relevant;
- proof-of-concept material that does not expose unrelated user data.

Do not attach chats, credentials, repository content, unsanitized logs, or private screenshots. Allow a reasonable remediation window before public disclosure. No response-time or bounty commitment is currently offered.

### Security boundaries

ChatGPT Skin Studio is designed around these controls:

- exact canonical target path: `/Applications/ChatGPT.app`;
- expected Bundle ID and OpenAI Team ID verification;
- strict code-signature validation across architectures and nested code;
- explicit, one-use user confirmation before the initial apply and restoration restart;
- random loopback CDP port with listener ownership and process-group validation;
- a single trusted renderer target and structural adapter contract;
- local-only, schema-validated theme data with remote URLs and arbitrary CSS/JavaScript rejected;
- file type, byte count, pixel count, dimensions, SHA-256, symlink, and traversal checks;
- generation-scoped owned nodes, scripts, payloads, and bindings;
- cleanup and normal-launch recovery when installation or runtime validation fails;
- no modification of `app.asar`, the official binary, official signature, or real profile content.

The project intentionally does not force-quit an unresponsive ChatGPT process or install a persistent watchdog. Those choices reduce destructive recovery behavior but can require manual recovery after a failure.

### Theme security

Bundled and imported themes are data packages, not executable plugins. A theme must not be treated as trusted merely because it renders successfully. The validator rejects unknown schema fields, remote resource values, path traversal, symlinks, format disguises, unsupported animation/multi-frame inputs, unsafe SVG constructs, arbitrary CSS, and JavaScript.

Only import images and theme packages from sources you trust. The project cannot grant rights to third-party artwork and does not make copyright or trademark risk a technical security property.

### Artifact verification

Only assets attached to this repository's [GitHub Releases](https://github.com/zuuzii-org/chatgpt-avatar/releases) are project distribution candidates. GitHub-generated source archives are not macOS installers.

Signing, notarization, checksums, and automatic-update status are release-specific and must be stated in the individual Release notes. Do not disable Gatekeeper or remove quarantine attributes merely to run an unverified package. If the stated signature or checksum does not verify, stop and report it privately.

### Out of scope

- vulnerabilities in ChatGPT, macOS, GitHub, or an update-hosting provider that do not arise from this project;
- a user's lack of rights to imported or bundled artwork;
- visual differences without a confidentiality, integrity, availability, or authorization impact;
- modified binaries, private forks, or themes that bypass the validator;
- social engineering that does not exploit project behavior.

## 简体中文

### 支持范围

安全修复以 best-effort 方式支持最新的 GitHub Release。开发版、fork、自签名安装包、被修改的主题包和旧版本不保证获得修复。

兼容策略不绑定 ChatGPT 版本号，但这不代表支持所有 ChatGPT build。Controller 会执行运行时结构检查，无法建立必要合同时 fail closed。

### 私下报告漏洞

不要在公开 Issue 中披露漏洞细节。GitHub Private Vulnerability Reporting 启用时，请使用：

<https://github.com/zuuzii-org/chatgpt-avatar/security/advisories/new>

如果页面提示私下报告尚未启用，可创建一个不含技术细节的最小 Issue，请维护者提供私下安全沟通渠道。公开请求中不要附带复现、日志、截图或影响分析。

报告请包含受影响版本/build、macOS 与硬件架构、最小复现步骤、预期/实际结果、安全影响、攻击前提，以及必要的脱敏诊断。不要附带聊天、凭据、仓库内容、未脱敏日志或私人截图。请在公开披露前预留合理修复时间；当前不承诺固定响应时限或漏洞奖金。

### 主要安全边界

- 只接受 `/Applications/ChatGPT.app` 的 canonical path；
- 验证预期 Bundle ID、OpenAI Team ID 和严格代码签名；
- 首次应用与恢复分别要求一次性明确确认；
- 随机 loopback CDP 端口，并验证 listener 和受管进程关系；
- 只选择可信 renderer target，并执行结构 Adapter 合同；
- 主题是经过 schema 校验的本地数据，拒绝远程 URL、任意 CSS 和 JavaScript；
- 校验文件类型、字节数、像素数、尺寸、SHA-256、symlink 和路径穿越；
- owned 节点、脚本、payload 和 binding 均绑定 generation；
- 安装或运行验证失败时执行 cleanup 和正常启动恢复；
- 不修改 `app.asar`、官方二进制、官方签名或真实 profile 内容。

项目不会强杀无响应的 ChatGPT，也不安装持久 watchdog。这降低了破坏性恢复风险，但失败后可能需要用户手动恢复。

### 安装包验证

只有本仓库 [GitHub Releases](https://github.com/zuuzii-org/chatgpt-avatar/releases) 附带的资产才是项目分发候选；GitHub 自动生成的源码压缩包不是 macOS 安装包。

签名、notarization、checksum 和自动更新状态以每个 Release 的说明为准。不要为了运行未验证安装包而关闭 Gatekeeper 或移除 quarantine。声明的签名或 checksum 无法验证时，请停止安装并私下报告。
