# ChatGPT Skin Studio / 冻结实施方案

> 状态：`v0.1.0 Public Beta` 已于 2026-07-18 完成 Developer ID 签名、Apple 公证、GitHub Release 与远程下载件复核；真实客户端 Production E2E 按用户要求延后。
> App 兼容策略：不绑定 ChatGPT 版本/build，由运行时结构协议探测决定。
>
> ChatGPT Bundle ID：`com.openai.codex`。
>
> Team ID：`2DC432GLL2`。

## 1. 产品目标

首发目标是可分发、但本机优先的 macOS Skin Studio。完整皮肤直接作用于 ChatGPT App 的 renderer，同时保留 ChatGPT 原生任务流、按钮行为、Composer、任务列表、Diff、Terminal、Settings 与审批语义。

首版产品验收合同（`v0.1.0 Public Beta` 已发布，真实客户端验收延后）：

- 图 2 级暗色沉浸 MVP；
- 首发安装包移除 `Original Night City`，保留其余 10 套主题；其中部分 fan theme 涉及第三方 IP，免责声明不替代分发授权；
- Home 完整 Hero、玻璃侧栏、现有原生建议卡和主题化 Composer；
- Thread 自动降噪，工具页回退到安全外观；
- 真实 ChatGPT App 中的截图、键盘、VoiceOver、resize 和清理回退验收仍需用户另行授权重启；该限制已在 `v0.1.0` Release Notes 中披露。

## 2. 已冻结的八项决定

1. 产品定位：可分发产品，本机优先；主题包与 runtime 解耦。
2. 首发视觉：用户于 2026-07-18 明确要求安装包移除 `Original Night City`、保留其余 10 套主题；第三方 IP 分发风险已告知并记录于 `THIRD_PARTY_NOTICES.md`。
3. 页面范围：完整 Hero 只出现在 Home；Thread 保留背景与 glass；工具页自动降噪。
4. 动作卡：保留 ChatGPT 现有原生建议卡的真实行为，只升级视觉，不假设卡片数量恒定。
5. 主题入口：App 内快速切换与原生 Controller 双入口；MVP 优先交付 Controller，App 内入口进入高级 adapter。
6. 响应式：完整结构皮肤最低支持宽度 1024px；1024–1180px 将原生建议卡布局收为 2×2，低于 1024px 时降级为 token-only 并隐藏 Hero 与装饰层。
7. 失配策略：App 更新导致 adapter 失配时 fail closed，清理增强层并恢复原生界面。
8. 成功标准：图 2 级 MVP + 原创主题 + 真实客户端验收。

## 3. 技术路线

```text
ChatGPT Skin Studio.app（SwiftUI / AppKit）
  ├─ Bundle 与签名验证
  ├─ 明确的重启授权
  ├─ 随机会话调试端口
  ├─ Theme Schema v3 发现、加载与校验
  ├─ CDP discovery / WebSocket session
  ├─ Structural Adapter Protocol
  ├─ 注入、诊断与完整 cleanup
  └─ 主题库与菜单栏控制
                │
                ▼
ChatGPT.app renderer
  ├─ Base Skin CSS
  ├─ 独立 Hero <img> 图层与图片解码门禁
  ├─ Home route enhancer
  ├─ 保留原生 actions / Composer
  └─ reload 恢复与失配回退
```

生产实现采用原生 Swift，无 npm runtime 依赖。上游 HeiGe 仓库只作为 CDP 行为、路径安全和测试思路的参考，不复制其安装器、watchdog、generic CSS、主题菜单和第三方 IP 资产。

## 4. 安全合同

- 注入前验证 App 路径、Bundle ID、Team ID 与代码签名；
- App 版本与 build 只记录为诊断信息，不参与拒绝、主题选择或 adapter 匹配；
- 调试 listener 只能绑定 loopback，且必须属于目标 ChatGPT 进程；Electron/Chromium 子进程（如 Computer Use 服务）会通过 FD 继承持有同一 listen socket，这类持有者必须是目标进程的同进程组后代（PGID 相同、启动时间不早于目标进程），否则 fail closed；
- 不读取对话、终端、仓库、剪贴板、API Key、localStorage 或网络请求；
- 主题包是纯数据，不允许携带 JavaScript、远程 URL 或任意 CSS；
- 图片只允许 PNG、JPG、WebP，校验真实格式、字节、像素、symlink 与 SHA-256；
- 图片字节不进入 CSS token；Full 仅在独立 Hero 图层解码成功、像素尺寸与 manifest 一致、owned stylesheet 已挂载且计算样式确实覆盖 viewport 后报告安装成功，Core/token-only 延迟 Hero 解码；
- 用户未明确确认时不退出或重启 ChatGPT；
- 不安装 watchdog，不在未经确认时主动发起换肤重启；
- 首次应用的 adapter hard probe 失败会立即清理增强层，并在本次已授权事务内回滚到正常启动模式；
- 运行中的 route/reload 失配先按签名去抖：相同失败签名连续 3 次且跨度 ≥600ms 才清除增强层，并通过随机 CDP runtime binding 向 native 上报固定、限长、无内容的结构事件；瞬态失配保持皮肤挂载并按 120ms 主动重试，成功或签名变化即重置计数；
- reload 新文档脚本只在 top frame 执行，iframe 不建立皮肤 binding 配置、bootstrap、listener、timer 或上报；
- native 在 250ms 后最多复探 5 次，只有连续 3 次内容盲结构签名相同的 hard failure 才自动回滚并把 Controller 置为“不兼容”；任一轮恢复即可重新应用增强；
- 结构签名不稳定、连续安装失败、pending 超时或 CDP 意外断连均按“运行环境不可用”单独降级，不伪装成版本不兼容；主动 restore 关闭连接不会触发异常上报；
- 自动回滚失败时保留受管 session 与“再次恢复”入口，不把仍在调试模式的实例误报为已恢复。

## 5. Theme Schema v3

当前 MVP 已实现并消费：

- `nativeTheme`：accent、secondary、surface、ink 与可选语义色；
- `hero`：本地图片、focalPoint 与 adaptive scrim；
- `sidebar`、`composer`：透明度和 blur；
- `compatibility`：结构 adapter protocol 与本产品自己的 API version 范围，不包含 ChatGPT 版本/build；
- `assets`：路径、格式、真实尺寸与内容哈希；runtime 另有固定字节上限；
- `features.motion`：控制主题自身的过渡与 hover 位移，系统 Reduced Motion 始终优先；
- schema v3.1 `brand`、`icons`、`texts`：主题品牌印记、导航/建议卡图标和 Composer 文案扩展。

Hero 的 data URL 通过经过二次格式与长度校验的独立 payload 传递给只读装饰 `<img>`，CSS 只携带颜色、位置与玻璃参数。每个新 renderer 或 native 运行期复检事务在首轮缓存经过校验的完整 payload，同一事务内的 pending 轮询和后续复检轮次使用 generation 绑定的轻量 resume 表达式，避免在轮询中反复跨 CDP 传输大图。这样既避开 Chromium 单条 CSS 声明的长度上限，也让图片或样式可见性失败可以独立归类为运行环境不可用。

已进入 schema 并严格校验、但尚未接入渲染：

- `hero.safeArea`；
- `features.homeEnhancer`、`features.routeAware`。

`polaroid`、`badge`、自由装饰层与字体配置仍属于后续 schema 扩展；当前加入这些未知字段会被严格校验拒绝。

## 6. MVP 页面合同

| Route | 外观模式 | 行为 |
|---|---|---|
| Home / New Task | Full | Hero、主题名、现有原生建议卡视觉、Sidebar、Composer |
| Thread | Core | 背景、侧栏、Composer、消息可读性 |
| Diff / Review | Token-only | 原生可见外观，不覆盖语义色 |
| Terminal | Token-only | 原生可见外观，不覆盖终端配色 |
| Settings | Token-only | 原生可见外观 |
| PR / Approval | Token-only | 原生界面与风险语义 |

## 7. 发布后仍待完成的产品验收

当前常规单元与合同测试可独立运行；真实 App E2E、完整 visual diff、VoiceOver 和多状态手工验收仍是完整产品验收门禁，不能以编译或单元测试通过替代。用户明确要求本次发版期间不重启 ChatGPT，因此 `v0.1.0 Public Beta` 未运行会中断当前会话的 Production E2E；Release Notes 已披露该限制。

空隔离 profile 不复制用户的 `auth.json`、cookies 或真实 profile，因此只用于验证 pre-app pending、onboarding token-only、进程隔离与 cleanup；已登录 Home / Full 的视觉验收必须由用户明确授权生产会话重启后单独执行。

- Home、Thread、Settings、Diff、Terminal、PR；
- 侧栏展开、折叠、滚动；
- 1024、1440、Retina 与超宽窗口；
- 中文、English、Light、Dark；
- Loading、Empty、Error、Disabled、Focus；
- Keyboard、VoiceOver、Reduced Motion；
- React 重绘、路由切换、reload 持久化与运行期失配原生状态联动；
- apply 幂等、restore 完整 cleanup、未知版本进入结构探测并在硬失配时安全回退；
- 参考图与真实客户端截图的 visual diff。

## 8. 不做的内容

- 不修改 `app.asar`、ChatGPT 二进制或代码签名；
- 不复制 HeiGe 主题素材、Logo、产品名或 storage namespace；
- 不把完整假 UI 烘进背景图；
- 不覆盖真实按钮或重建 ChatGPT 编辑器；
- 不承诺未来所有 ChatGPT App 版本永久零维护；
- 不在首版加入账号、云端主题商店或遥测；软件更新使用 Sparkle 2、HTTPS appcast、EdDSA 更新包签名、Developer ID 签名与 Apple notarization。
