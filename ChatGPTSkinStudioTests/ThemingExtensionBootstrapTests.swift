import Foundation
import JavaScriptCore
import XCTest

@testable import ChatGPTSkinStudio

/// schema v3.1（BOOTSTRAP_VERSION 6）主题扩展的 JSContext 覆盖：
/// 品牌印记 owned 节点、data-zuuzii-anchor 锚点打标、实测槽位 CSS 变量段、
/// soft 锚点缺失降级、cleanup 完整性、refresh 幂等重放、payload 逐字段防御。
final class ThemingExtensionBootstrapTests: XCTestCase {

    // MARK: - 完整扩展：打标、owned 节点、动态样式段

    func testInstallWithExtensionsMarksAnchorsAndBuildsOwnedNodes() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluateBaseHarness(in: context, buildSidebar: true, buildSuggestions: true)
        context.evaluateScript(installExtensionPayloadScript(generation: "ext-full"))

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__installResult")?
                .forProperty("ok").toBool() ?? false,
            "带扩展 payload 的安装必须成功"
        )

        // (1) 字标按钮被打标（双属性 + generation 属主）
        XCTAssertEqual(
            context.evaluateScript(
                "__wordmark.getAttribute('data-zuuzii-anchor')"
            )?.toString(),
            "wordmark"
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__wordmark.getAttribute('data-zuuzii-anchor-generation')"
            )?.toString(),
            "ext-full"
        )

        // (2) owned 印记节点存在、带 generation 属主、glow 标记与实测几何
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-mark\"]').length"
            )?.toInt32(),
            1
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-mark\"]')[0]"
                    + ".getAttribute('data-zuuzii-skin-owner')"
            )?.toString(),
            "ext-full"
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-mark\"]')[0]"
                    + ".getAttribute('data-glow')"
            )?.toString(),
            "true"
        )
        // 槽位几何：left = 8 + (34-20)/2 = 15，top = 46 + 32/2 - 20/2 = 52
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-mark\"]')[0].style.left"
            )?.toString(),
            "15px"
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-mark\"]')[0].style.top"
            )?.toString(),
            "52px"
        )
        // 印记 SVG 由 payload 的 svgViewBox/svgBody 经 DOMParser 组装
        XCTAssertTrue(
            context.evaluateScript(
                "__lastParsedSVG.includes('viewBox=\"0 0 48 48\"')"
            )?.toBool() ?? false
        )
        XCTAssertTrue(
            context.evaluateScript(
                "__lastParsedSVG.includes('<circle cx=\"24\"')"
            )?.toBool() ?? false
        )

        // (3) owned 字标后缀节点：按钮下沿 +3px（46+32+3=81）
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-suffix\"]')[0]"
                    + ".textContent"
            )?.toString(),
            "NIGHT CITY"
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-suffix\"]')[0].style.top"
            )?.toString(),
            "81px"
        )

        // (4) nav 按钮被打标，样式表含静态 ::before 规则与实测 CSS 变量段
        XCTAssertEqual(
            context.evaluateScript("__nav0.getAttribute('data-zuuzii-anchor')")?.toString(),
            "nav-0"
        )
        XCTAssertEqual(
            context.evaluateScript("__nav1.getAttribute('data-zuuzii-anchor')")?.toString(),
            "nav-1"
        )
        let styleText = context.evaluateScript(
            "__queryAll(__html, '[data-zuuzii-skin-role=\"style\"]')[0].textContent"
        )?.toString() ?? ""
        XCTAssertTrue(styleText.contains("[data-zuuzii-anchor=\"nav-0\"]::before"))
        XCTAssertTrue(styleText.contains("url(\"data:image/svg+xml;base64,"))
        XCTAssertTrue(styleText.contains("--zuuzii-icon-x-0:0px"))
        XCTAssertTrue(styleText.contains("--zuuzii-icon-x-1:14px"))
        XCTAssertTrue(styleText.contains("--zuuzii-sug-icon-x-0:13px"))
        XCTAssertTrue(styleText.contains("--zuuzii-sug-icon-y-0:13px"))

        // (5) suggestions 断言：建议卡按前缀打标成功
        XCTAssertEqual(
            context.evaluateScript("__card.getAttribute('data-zuuzii-anchor')")?.toString(),
            "sug-0"
        )

        // (6) composer 文案断言：payload CSS 中的 placeholder 规则随样式表下发
        XCTAssertTrue(styleText.contains("[data-codex-composer-root] p.placeholder::after"))
        XCTAssertTrue(styleText.contains("content: \"夜色已就绪\" !important"))

        // (7) 不存在的 nav 锚点 soft 跳过并记日志，不影响安装
        XCTAssertTrue(
            context.evaluateScript(
                "__warnings.some(message => message.includes('nav-2'))"
            )?.toBool() ?? false,
            "缺失锚点必须产生 soft 日志"
        )
    }

    // MARK: - 锚点全部缺失：安装仍然 ok:true

    func testInstallWithExtensionsSucceedsWhenAllAnchorsMissing() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluateBaseHarness(in: context, buildSidebar: false, buildSuggestions: false)
        context.evaluateScript(installExtensionPayloadScript(generation: "ext-empty"))

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__installResult")?
                .forProperty("ok").toBool() ?? false,
            "锚点全缺失时安装仍必须 ok:true（soft 跳过）"
        )
        XCTAssertEqual(
            context.evaluateScript("__queryAll(__html, '[data-zuuzii-anchor]').length")?
                .toInt32(),
            0
        )
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-mark\"]').length"
            )?.toInt32(),
            0
        )
        XCTAssertTrue(
            context.evaluateScript(
                "__warnings.some(message => message.includes('wordmark'))"
            )?.toBool() ?? false
        )
        XCTAssertTrue(
            context.evaluateScript(
                "__warnings.some(message => message.includes('suggestion-cards'))"
            )?.toBool() ?? false
        )
    }

    // MARK: - cleanup：owned 节点与锚点属性全部消失

    func testCleanupRemovesOwnedExtensionNodesAndAnchorAttributes() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluateBaseHarness(in: context, buildSidebar: true, buildSuggestions: true)
        context.evaluateScript(installExtensionPayloadScript(generation: "ext-clean"))
        context.evaluateScript(
            """
            globalThis.__cleanupResult =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")].cleanup("unit-test");
            globalThis.__remainingAnchors =
              __queryAll(__html, '[data-zuuzii-anchor]').length;
            globalThis.__remainingOwned =
              __queryAll(__html, '[data-zuuzii-skin-owner]').length;
            globalThis.__wordmarkAnchorAfter =
              __wordmark.getAttribute('data-zuuzii-anchor');
            globalThis.__nav0AnchorAfter = __nav0.getAttribute('data-zuuzii-anchor');
            globalThis.__cardAnchorAfter = __card.getAttribute('data-zuuzii-anchor');
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__cleanupResult")?
                .forProperty("ok").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__remainingAnchors")?.toInt32(),
            0,
            "cleanup 后不得残留 data-zuuzii-anchor 属性"
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__remainingOwned")?.toInt32(),
            0,
            "cleanup 后不得残留 owned 节点"
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__wordmarkAnchorAfter")?.isNull ?? false
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__nav0AnchorAfter")?.isNull ?? false
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__cardAnchorAfter")?.isNull ?? false
        )
    }

    // MARK: - refresh 幂等：两次 refresh 后印记节点仍唯一

    func testRefreshReplaysExtensionsIdempotently() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluateBaseHarness(in: context, buildSidebar: true, buildSuggestions: true)
        context.evaluateScript(installExtensionPayloadScript(generation: "ext-idem"))
        context.evaluateScript(
            """
            const state = globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")];
            globalThis.__refresh1 = state.refresh("unit-test-1");
            globalThis.__refresh2 = state.refresh("unit-test-2");
            globalThis.__brandMarkCount =
              __queryAll(__html, '[data-zuuzii-skin-role="brand-mark"]').length;
            globalThis.__brandSuffixCount =
              __queryAll(__html, '[data-zuuzii-skin-role="brand-suffix"]').length;
            globalThis.__styleTextAfter =
              __queryAll(__html, '[data-zuuzii-skin-role="style"]')[0].textContent;
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__refresh1")?
                .forProperty("ok").toBool() ?? false
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__refresh2")?
                .forProperty("ok").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__brandMarkCount")?.toInt32(),
            1,
            "两次 refresh 后印记节点必须唯一（幂等重放）"
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__brandSuffixCount")?.toInt32(),
            1
        )
        let styleText = context
            .objectForKeyedSubscript("__styleTextAfter")?.toString() ?? ""
        XCTAssertTrue(styleText.contains("--zuuzii-icon-x-1:14px"))
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-anchor]').length"
            )?.toInt32(),
            4,
            "wordmark + nav-0 + nav-1 + sug-0 四个锚点应各出现一次"
        )
    }

    // MARK: - payload 逐字段防御：危险片段被丢弃，安装不失败

    func testPayloadNormalizationDropsUnsafeExtensionFragments() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluateBaseHarness(in: context, buildSidebar: true, buildSuggestions: false)
        context.evaluateScript(
            """
            globalThis.__installResult =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
                {
                  generation: "ext-defense",
                  themeID: "test-theme",
                  themeName: "Test Theme",
                  css: "",
                  hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                  adapterProbe: globalThis.__readyProbe,
                  brand: {
                    mark: {
                      anchorText: "Codex",
                      size: 20,
                      svgViewBox: "0 0 48 48",
                      svgBody: "<script>alert(1)</script>",
                      glow: true,
                    },
                  },
                  icons: {
                    nav: [
                      { match: "新建任务", path: "M12 3l1.8 4.6z" },
                      { match: "拉取请求", path: "javascript:alert(1)" },
                    ],
                  },
                  texts: { composerPlaceholder: "x".repeat(33) },
                }
              );
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__installResult")?
                .forProperty("ok").toBool() ?? false,
            "危险扩展片段被丢弃后安装必须继续成功"
        )
        // svgBody 含 <script> → 整个 brand 被丢弃：无印记节点、无字标锚点
        XCTAssertEqual(
            context.evaluateScript(
                "__queryAll(__html, '[data-zuuzii-skin-role=\"brand-mark\"]').length"
            )?.toInt32(),
            0
        )
        XCTAssertTrue(
            context.evaluateScript("__wordmark.getAttribute('data-zuuzii-anchor')")?
                .isNull ?? false
        )
        // 合法 nav 条目保留并打标；javascript: 条目被丢弃
        XCTAssertEqual(
            context.evaluateScript("__nav0.getAttribute('data-zuuzii-anchor')")?.toString(),
            "nav-0"
        )
        XCTAssertTrue(
            context.evaluateScript("__nav1.getAttribute('data-zuuzii-anchor')")?
                .isNull ?? false
        )
        // 丢弃动作留有防御日志
        XCTAssertTrue(
            context.evaluateScript(
                "__warnings.some(message => message.includes('brand.mark.svgBody'))"
            )?.toBool() ?? false
        )
        XCTAssertTrue(
            context.evaluateScript(
                "__warnings.some(message => message.includes('icons.nav[1]'))"
            )?.toBool() ?? false
        )
        XCTAssertTrue(
            context.evaluateScript(
                "__warnings.some(message => message.includes('texts.composerPlaceholder'))"
            )?.toBool() ?? false
        )
    }

    // MARK: - JS harness

    /// 模拟 Swift 侧 SkinCSSRenderer 产出的扩展 CSS（静态规则段）。
    private var extensionCSS: String {
        #"""
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-zuuzii-anchor="wordmark"] { padding-left: 34px !important; }
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-zuuzii-anchor="nav-0"] { position: relative !important; }
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-zuuzii-anchor="nav-0"]::before { content: ""; position: absolute; left: var(--zuuzii-icon-x-0, 0px); top: 50%; width: 16px; height: 16px; background: #43D8F5; -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjwvc3ZnPg==") center / contain no-repeat; mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjwvc3ZnPg==") center / contain no-repeat; }
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-codex-composer-root] p.placeholder::after { content: "夜色已就绪" !important; }
        """#
    }

    private func installExtensionPayloadScript(generation: String) -> String {
        """
        globalThis.__installResult =
          globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
            {
              generation: "\(generation)",
              themeID: "test-theme",
              themeName: "Test Theme",
              css: `\(extensionCSS)`,
              hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
              adapterProbe: globalThis.__readyProbe,
              brand: {
                mark: {
                  anchorText: "Codex",
                  size: 20,
                  svgViewBox: "0 0 48 48",
                  svgBody: '<circle cx="24" cy="24" r="20" fill="#0A1A2F"/>',
                  glow: true,
                },
                wordmarkSuffix: "NIGHT CITY",
                wordmarkSlotPadding: 34,
              },
              icons: {
                tint: "#43D8F5",
                nav: [
                  { match: "新建任务", path: "M12 3l1.8 4.6z" },
                  { match: "拉取请求", path: "M6 3a3 3z" },
                  { match: "不存在项", path: "M1 1h2z" },
                ],
                suggestions: [
                  { match: "探索", path: "M8 6l-5 6z" },
                ],
              },
              texts: { composerPlaceholder: "夜色已就绪" },
            }
          );
        """
    }

    /// 搭建带迷你选择器引擎的假 DOM：html/head/body 树、可选侧边栏与建议卡、
    /// DOMParser 桩、以及 bootstrap 运行所需的全部全局桩。
    private func evaluateBaseHarness(
        in context: JSContext,
        buildSidebar: Bool,
        buildSuggestions: Bool
    ) throws {
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__warnings = [];
            console.warn = (...args) => {
              globalThis.__warnings.push(args.map(String).join(" "));
            };
            globalThis.__removedNodes = 0;
            globalThis.__lastParsedSVG = "";

            // 迷你选择器引擎：支持 tag、.class、[attr]、[attr="value"] 与逗号分组
            globalThis.__matchesSimple = (el, selector) => {
              let rest = selector.trim();
              const attrs = [];
              rest = rest.replace(
                /\\[([^\\]=~]+?)(?:="([^"]*)")?\\]/g,
                (match, name, value) => {
                  attrs.push({ name: name.trim(), value: value === undefined ? null : value });
                  return "";
                }
              );
              const classes = [];
              rest = rest.replace(/\\.([A-Za-z0-9_-]+)/g, (match, cls) => {
                classes.push(cls);
                return "";
              });
              const tag = rest && rest !== "*" ? rest.toUpperCase() : null;
              if (tag && el.tagName !== tag) return false;
              const ownClasses = String(el.getAttribute("class") || "")
                .split(/\\s+/)
                .filter(Boolean);
              for (const cls of classes) if (!ownClasses.includes(cls)) return false;
              for (const attr of attrs) {
                const value = el.getAttribute(attr.name);
                if (value === null) return false;
                if (attr.value !== null && value !== attr.value) return false;
              }
              return true;
            };
            globalThis.__queryAll = (root, selector) => {
              const groups = String(selector).split(",").map(part => part.trim()).filter(Boolean);
              const out = [];
              const visit = (node) => {
                for (const child of node.children || []) {
                  if (groups.some(group => globalThis.__matchesSimple(child, group))) {
                    out.push(child);
                  }
                  visit(child);
                }
              };
              visit(root);
              return out;
            };

            const makeNode = (tagName) => {
              const attributes = {};
              const node = {
                tagName: String(tagName).toUpperCase(),
                dataset: {},
                style: {},
                children: [],
                parent: null,
                isConnected: false,
                textContent: "",
                sheet: tagName === "style" ? { cssRules: [{}] } : null,
                __rect: { x: 0, y: 0, width: 1440, height: 900 },
                setAttribute(name, value) { attributes[name] = String(value); },
                getAttribute(name) {
                  return Object.prototype.hasOwnProperty.call(attributes, name)
                    ? attributes[name]
                    : null;
                },
                removeAttribute(name) { delete attributes[name]; },
                appendChild(child) { child.parent = node; node.children.push(child); return child; },
                remove() {
                  if (node.parent) {
                    const index = node.parent.children.indexOf(node);
                    if (index >= 0) node.parent.children.splice(index, 1);
                    node.parent = null;
                  }
                  node.isConnected = false;
                  globalThis.__removedNodes += 1;
                },
                getBoundingClientRect() { return node.__rect; },
                querySelector(selector) {
                  return globalThis.__queryAll(node, selector)[0] || null;
                },
                querySelectorAll(selector) { return globalThis.__queryAll(node, selector); },
              };
              if (tagName === "img") {
                Object.assign(node, { complete: true, naturalWidth: 1, naturalHeight: 1 });
              }
              return node;
            };

            globalThis.__html = makeNode("html");
            globalThis.__headNode = makeNode("head");
            globalThis.__bodyNode = makeNode("body");
            __html.appendChild(__headNode);
            __html.appendChild(__bodyNode);
            const markConnected = (node) => {
              node.isConnected = true;
              for (const child of node.children) markConnected(child);
            };
            markConnected(__html);

            globalThis.document = {
              documentElement: __html,
              head: { appendChild: (node) => { __headNode.appendChild(node); markConnected(node); } },
              body: { appendChild: (node) => { __bodyNode.appendChild(node); markConnected(node); } },
              createElement: makeNode,
              createElementNS: (ns, tag) => makeNode(tag),
              querySelector: (selector) => globalThis.__queryAll(__html, selector)[0] || null,
              querySelectorAll: (selector) => globalThis.__queryAll(__html, selector),
            };
            globalThis.DOMParser = function () {
              this.parseFromString = (text) => {
                globalThis.__lastParsedSVG = text;
                const root = makeNode("svg");
                root.__parsedFrom = text;
                return { documentElement: root };
              };
            };
            globalThis.getComputedStyle = (node) => node.tagName === "IMG"
              ? ({ position: "absolute", objectFit: "cover", opacity: "1", display: "block", visibility: "visible" })
              : ({ position: "fixed", opacity: "1" });
            globalThis.innerWidth = 1440;
            globalThis.innerHeight = 900;
            globalThis.AbortController = function () {
              this.signal = {};
              this.abort = () => {};
            };
            globalThis.MutationObserver = function () {
              this.observe = () => {};
              this.disconnect = () => {};
            };
            globalThis.ResizeObserver = function () {
              this.observe = () => {};
              this.disconnect = () => {};
            };
            globalThis.setTimeout = () => 1;
            globalThis.clearTimeout = () => {};
            globalThis.setInterval = () => 1;
            globalThis.clearInterval = () => {};
            globalThis.requestAnimationFrame = () => 1;
            globalThis.cancelAnimationFrame = () => {};
            globalThis.addEventListener = () => {};
            globalThis.matchMedia = () => ({ matches: false, addEventListener: () => {} });
            globalThis.__readyProbe = () => ({
              ok: true,
              failClosed: false,
              pending: false,
              routeID: "home",
              effectiveMode: "full",
              reducedMotion: false,
              viewportWidth: 1440,
              entryScriptMatchCount: 1,
            });
            """
        )
        if buildSidebar {
            // 结构取自只读探测：aside.app-shell-left-panel 内的字标按钮
            // （文本 "Codex"）与 nav 按钮（svg 16×16 槽位）。
            context.evaluateScript(
                """
                (() => {
                  const aside = document.createElement("aside");
                  aside.setAttribute("class", "app-shell-left-panel");
                  __bodyNode.appendChild(aside);

                  globalThis.__wordmark = document.createElement("button");
                  __wordmark.textContent = "Codex";
                  __wordmark.setAttribute("aria-label", "切换模式，当前模式：Codex");
                  __wordmark.__rect = { x: 8, y: 46, width: 112, height: 32 };
                  const wordmarkSvg = document.createElement("svg");
                  wordmarkSvg.__rect = { x: 97, y: 55, width: 14, height: 14 };
                  __wordmark.appendChild(wordmarkSvg);
                  aside.appendChild(__wordmark);

                  globalThis.__nav0 = document.createElement("button");
                  __nav0.textContent = "新建任务";
                  __nav0.__rect = { x: 16, y: 90, width: 219, height: 21 };
                  const nav0Svg = document.createElement("svg");
                  nav0Svg.__rect = { x: 16, y: 92.5, width: 16, height: 16 };
                  __nav0.appendChild(nav0Svg);
                  aside.appendChild(__nav0);

                  globalThis.__nav1 = document.createElement("button");
                  __nav1.textContent = "拉取请求";
                  __nav1.__rect = { x: 8, y: 120, width: 259, height: 30 };
                  const nav1Svg = document.createElement("svg");
                  nav1Svg.__rect = { x: 22, y: 127, width: 16, height: 16 };
                  __nav1.appendChild(nav1Svg);
                  aside.appendChild(__nav1);
                })();
                """
            )
        } else {
            context.evaluateScript(
                """
                globalThis.__wordmark = null;
                globalThis.__nav0 = null;
                globalThis.__nav1 = null;
                """
            )
        }
        if buildSuggestions {
            context.evaluateScript(
                """
                (() => {
                  const container = document.createElement("div");
                  container.setAttribute("data-home-ambient-suggestions", "");
                  __bodyNode.appendChild(container);
                  globalThis.__card = document.createElement("button");
                  __card.textContent = "探索夜色";
                  __card.__rect = { x: 400, y: 500, width: 200, height: 116 };
                  const cardSvg = document.createElement("svg");
                  cardSvg.__rect = { x: 424, y: 524, width: 16, height: 16 };
                  __card.appendChild(cardSvg);
                  container.appendChild(__card);
                })();
                """
            )
        } else {
            context.evaluateScript("globalThis.__card = null;")
        }
        XCTAssertNil(context.exception)
    }

    private func injectedResource(named name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceURL =
            repositoryRoot
            .appendingPathComponent("ChatGPTSkinStudio", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Injected", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        return try String(contentsOf: resourceURL, encoding: .utf8)
    }
}
