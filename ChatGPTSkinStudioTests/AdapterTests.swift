import Foundation
import JavaScriptCore
import XCTest

@testable import ChatGPTSkinStudio

final class AdapterTests: XCTestCase {
    private let adapter = ChatGPTStructuralAdapterV1()

    func testProtocolContractUsesStableIdentityAndStructuralEntryPattern() {
        let contract = adapter.manifest.protocolContract

        XCTAssertEqual(contract.identifier, "chatgpt-macos-renderer")
        XCTAssertEqual(contract.apiVersion, 1)
        XCTAssertTrue(contract.accepts(bundleIdentifier: "com.openai.codex"))
        XCTAssertFalse(contract.accepts(bundleIdentifier: "com.openai.chatgpt"))
        XCTAssertEqual(
            contract.entryScriptPathPattern,
            #"^/assets/index-[A-Za-z0-9_-]+\.js$"#
        )
        XCTAssertNotNil(
            "/assets/index-DEq4V6UZ.js".range(
                of: contract.entryScriptPathPattern,
                options: .regularExpression
            )
        )
        XCTAssertNotNil(
            "/assets/index-another_future_hash.js".range(
                of: contract.entryScriptPathPattern,
                options: .regularExpression
            )
        )
        XCTAssertFalse(contract.entryScriptPathPattern.contains("D9dVhigH"))
    }

    func testRoutesUseFullCoreAndTokenOnlyTiers() {
        XCTAssertEqual(adapter.route(for: "/")?.id, "home")
        XCTAssertEqual(adapter.route(for: "/")?.mode, .full)
        XCTAssertEqual(adapter.route(for: "/local/thread-1")?.mode, .core)
        XCTAssertEqual(adapter.route(for: "/remote/task-1")?.mode, .core)
        XCTAssertEqual(adapter.route(for: "/work/conversation/chat-1")?.mode, .core)
        XCTAssertEqual(adapter.route(for: "/settings/appearance")?.mode, .tokenOnly)
        XCTAssertEqual(adapter.route(for: "/diff")?.mode, .tokenOnly)
        XCTAssertEqual(adapter.route(for: "/projects")?.mode, .tokenOnly)
        XCTAssertEqual(adapter.route(for: "/login")?.id, "onboarding")
        XCTAssertEqual(adapter.route(for: "/login")?.mode, .tokenOnly)
        XCTAssertEqual(adapter.route(for: "/welcome")?.id, "onboarding")
        XCTAssertEqual(adapter.route(for: "/welcome")?.mode, .tokenOnly)
        XCTAssertEqual(adapter.route(for: "/future-route")?.id, "fallback")
        XCTAssertEqual(adapter.route(for: "/")?.rendererTargetRole, .primary)
        XCTAssertEqual(
            adapter.route(for: "/avatar-overlay")?.rendererTargetRole,
            .auxiliary
        )
        XCTAssertEqual(
            adapter.route(for: "/hotkey-window")?.rendererTargetRole,
            .auxiliary
        )
        XCTAssertEqual(adapter.manifest.minimumStructuralWidth, 1_024)
    }

    func testCardinalityModelsKnownPanelMultiplicityAndPrimaryComposerScope() throws {
        let probes = Dictionary(
            uniqueKeysWithValues: adapter.manifest.cardinalityProbes.map { ($0.id, $0) }
        )

        XCTAssertEqual(probes["app-shell-active-tabs"]?.minimumCount, 0)
        XCTAssertEqual(probes["app-shell-active-tabs"]?.maximumCount, 2)
        XCTAssertEqual(probes["right-active-tab"]?.maximumCount, 1)
        XCTAssertEqual(probes["bottom-active-tab"]?.maximumCount, 1)
        XCTAssertEqual(
            probes["primary-composer-home"]?.scopeSelector,
            "[data-app-shell-main-content-layout]"
        )
        XCTAssertTrue(
            try XCTUnwrap(probes["primary-composer-home"]?.rejectedAncestorSelector)
                .contains("right-panel")
        )
    }

    func testThemingExtensionProbesAreSoftAndNeverFailClosed() {
        let probes = Dictionary(
            uniqueKeysWithValues: adapter.manifest.cardinalityProbes.map { ($0.id, $0) }
        )

        // schema v3.1：扩展锚点探针一律 soft 级，缺失不失败、不产出 hard 签名
        XCTAssertEqual(probes["brand-wordmark"]?.severity, .soft)
        XCTAssertEqual(probes["brand-wordmark"]?.minimumCount, 0)
        XCTAssertEqual(
            probes["brand-wordmark"]?.selector,
            "aside.app-shell-left-panel"
        )
        XCTAssertEqual(probes["suggestion-cards"]?.severity, .soft)
        XCTAssertEqual(probes["suggestion-cards"]?.minimumCount, 0)
        XCTAssertEqual(
            probes["suggestion-cards"]?.selector,
            "[data-home-ambient-suggestions]"
        )

        let missingAnchors = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "home",
            viewportWidth: 1_440,
            entryScriptMatchCount: 1,
            counts: [
                "electron-root": 1,
                "root-mount": 1,
                "main-viewport": 1,
                "primary-composer-home": 1,
                "brand-wordmark": 0,
                "suggestion-cards": 0,
            ]
        )
        XCTAssertTrue(missingAnchors.ok)
        XCTAssertFalse(missingAnchors.failClosed)
        XCTAssertFalse(missingAnchors.failures.contains { $0.id == "brand-wordmark" })
        XCTAssertFalse(missingAnchors.failures.contains { $0.id == "suggestion-cards" })

        // 即使数量超上限也只产生 soft 失败（warning），不影响 ok/failClosed 判定
        let duplicatedAnchors = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "home",
            viewportWidth: 1_440,
            entryScriptMatchCount: 1,
            counts: [
                "electron-root": 1,
                "root-mount": 1,
                "main-viewport": 1,
                "primary-composer-home": 1,
                "brand-wordmark": 2,
                "suggestion-cards": 2,
            ]
        )
        XCTAssertTrue(duplicatedAnchors.ok)
        XCTAssertFalse(duplicatedAnchors.failClosed)
        XCTAssertTrue(
            duplicatedAnchors.failures.contains {
                $0.id == "brand-wordmark" && $0.severity == .soft
            }
        )
        XCTAssertTrue(
            duplicatedAnchors.failures.contains {
                $0.id == "suggestion-cards" && $0.severity == .soft
            }
        )
        XCTAssertFalse(duplicatedAnchors.failures.contains { $0.severity == .hard })
    }

    func testProbeEvaluatorPassesCompatibleHomeStructure() {
        let result = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "home",
            viewportWidth: 1_440,
            entryScriptMatchCount: 1,
            counts: [
                "electron-root": 1,
                "root-mount": 1,
                "main-viewport": 1,
                "primary-composer-home": 1,
                "app-shell-active-tabs": 2,
                "right-active-tab": 1,
                "bottom-active-tab": 1,
            ]
        )

        XCTAssertTrue(result.ok)
        XCTAssertFalse(result.failClosed)
        XCTAssertFalse(result.pending)
        XCTAssertEqual(result.requestedMode, .full)
        XCTAssertEqual(result.effectiveMode, .full)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testProbeEvaluatorTreatsPreAppHomeAsPendingWithoutWeakeningHardBaseline() {
        let pending = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "home",
            viewportWidth: 1_440,
            entryScriptMatchCount: 1,
            counts: [
                "electron-root": 1,
                "root-mount": 1,
                "main-viewport": 0,
            ],
            rawPath: "/index.html",
            path: "/"
        )

        XCTAssertFalse(pending.ok)
        XCTAssertFalse(pending.failClosed)
        XCTAssertTrue(pending.pending)
        XCTAssertEqual(pending.reason, "renderer-not-ready")
        XCTAssertEqual(pending.rawPath, "/index.html")
        XCTAssertEqual(pending.path, "/")
        XCTAssertTrue(pending.failures.isEmpty)

        let hardFailure = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "home",
            viewportWidth: 1_440,
            entryScriptMatchCount: 1,
            counts: [
                "electron-root": 2,
                "root-mount": 1,
                "main-viewport": 0,
            ],
            rawPath: "/index.html",
            path: "/"
        )

        XCTAssertFalse(hardFailure.ok)
        XCTAssertTrue(hardFailure.failClosed)
        XCTAssertFalse(hardFailure.pending)
        XCTAssertTrue(hardFailure.failures.contains { $0.id == "electron-root" })

        let composerMissingAfterRendererReady = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "home",
            viewportWidth: 1_440,
            entryScriptMatchCount: 1,
            counts: [
                "electron-root": 1,
                "root-mount": 1,
                "main-viewport": 1,
                "primary-composer-home": 0,
            ]
        )

        XCTAssertFalse(composerMissingAfterRendererReady.ok)
        XCTAssertTrue(composerMissingAfterRendererReady.failClosed)
        XCTAssertFalse(composerMissingAfterRendererReady.pending)
        XCTAssertTrue(
            composerMissingAfterRendererReady.failures.contains {
                $0.id == "primary-composer-home"
            }
        )
    }

    func testProbeEvaluatorFailsClosedOnBaselineOrStructuralMismatch() {
        let missingEntry = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "settings",
            viewportWidth: 1_440,
            entryScriptMatchCount: 0,
            counts: ["electron-root": 1, "root-mount": 1]
        )
        XCTAssertFalse(missingEntry.ok)
        XCTAssertTrue(missingEntry.failClosed)
        XCTAssertTrue(missingEntry.failures.contains { $0.id == "entry-script" })

        let ambiguousElectronRoot = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "home",
            viewportWidth: 1_440,
            entryScriptMatchCount: 1,
            counts: [
                "electron-root": 2,
                "root-mount": 1,
                "main-viewport": 1,
                "primary-composer-home": 1,
            ]
        )
        XCTAssertFalse(ambiguousElectronRoot.ok)
        XCTAssertTrue(ambiguousElectronRoot.failClosed)
        XCTAssertTrue(ambiguousElectronRoot.failures.contains { $0.id == "electron-root" })
    }

    func testNarrowViewportDowngradesToTokenOnlyBeforeStructuralProbes() {
        let result = ChatGPTAdapterProbeEvaluator.evaluate(
            adapter: adapter,
            routeID: "home",
            viewportWidth: 1_023,
            entryScriptMatchCount: 1,
            counts: ["electron-root": 1, "root-mount": 1]
        )

        XCTAssertTrue(result.ok)
        XCTAssertFalse(result.failClosed)
        XCTAssertEqual(result.requestedMode, .full)
        XCTAssertEqual(result.effectiveMode, .tokenOnly)
        XCTAssertFalse(result.failures.contains { $0.id == "main-viewport" })
        XCTAssertFalse(result.failures.contains { $0.id == "primary-composer-home" })
    }

    func testProbeJavaScriptIsSelfContainedAndContentBlind() throws {
        let javaScript = try adapter.makeProbeJavaScript()

        XCTAssertTrue(javaScript.contains("(function zuuziiChatGPTAdapterProbe()"))
        XCTAssertTrue(javaScript.contains("entryScriptPathPattern"))
        XCTAssertFalse(javaScript.contains("index-D9dVhigH.js"))
        XCTAssertTrue(javaScript.contains("failClosed"))
        XCTAssertTrue(javaScript.contains("getClientRects"))
        XCTAssertTrue(javaScript.contains("initialRoute"))
        XCTAssertTrue(javaScript.contains("meta[name=\"initial-route\"]"))
        XCTAssertTrue(javaScript.contains("rawPath === \"/index.html\""))
        XCTAssertTrue(javaScript.contains("rawPath,"))
        XCTAssertTrue(javaScript.contains("renderer-not-ready"))
        XCTAssertTrue(javaScript.contains("origin !== \"null\""))
        XCTAssertTrue(javaScript.contains("prefers-reduced-motion"))
        XCTAssertFalse(javaScript.contains("localStorage"))
        XCTAssertFalse(javaScript.contains("sessionStorage"))
        XCTAssertFalse(javaScript.contains("innerText"))
        XCTAssertFalse(javaScript.contains("textContent"))
        XCTAssertFalse(javaScript.contains("fetch("))
    }

    func testProbeJavaScriptReturnsPendingForPreAppHomeShell() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            """
            globalThis.location = { pathname: "/index.html", search: "", origin: "null" };
            globalThis.innerWidth = 1440;
            globalThis.matchMedia = () => ({ matches: false });
            globalThis.getComputedStyle = () => ({ display: "block", visibility: "visible" });
            const structuralNode = {
              isConnected: true,
              getClientRects: () => [{}],
              closest: () => null,
              querySelectorAll: () => []
            };
            globalThis.document = {
              baseURI: "app://-/index.html",
              scripts: [{
                getAttribute: (name) => name === "src"
                  ? "app://-/assets/index-FutureBuildHash_5440.js"
                  : ""
              }],
              documentElement: { clientWidth: 1440 },
              querySelector: () => null,
              querySelectorAll: (selector) => {
                if (selector === ':root[data-codex-window-type="electron"]') return [structuralNode];
                if (selector === "#root") return [structuralNode];
                if (selector === "[data-app-shell-main-content-layout]") return [];
                return [];
              }
            };
            """
        )
        XCTAssertNil(context.exception)

        let result = context.evaluateScript("\(try adapter.makeProbeJavaScript())()")

        XCTAssertNil(context.exception)
        XCTAssertFalse(try XCTUnwrap(result).forProperty("ok").toBool())
        XCTAssertFalse(result?.forProperty("failClosed").toBool() ?? true)
        XCTAssertTrue(result?.forProperty("pending").toBool() ?? false)
        XCTAssertEqual(result?.forProperty("reason").toString(), "renderer-not-ready")
        XCTAssertEqual(result?.forProperty("rawPath").toString(), "/index.html")
        XCTAssertEqual(result?.forProperty("path").toString(), "/")
        XCTAssertEqual(
            result?.forProperty("counts").forProperty("main-viewport").toInt32(),
            0
        )
    }

    func testInstallJavaScriptUsesOnlyTheSymbolEntryAndRequiredPayload() throws {
        let javaScript = try adapter.makeInstallJavaScript(
            generation: "generation-1",
            themeID: "original-night-city",
            themeName: "Original Night City",
            css: ":root { --zuuzii-accent: #65D8E8; }",
            hero: .init(
                dataURL: "data:image/png;base64,iVBORw==",
                focalPointX: 0.74,
                focalPointY: 0.34,
                pixelWidth: 1,
                pixelHeight: 1
            )
        )

        XCTAssertTrue(
            javaScript.contains(
                "globalThis[Symbol.for(\"com.zuuzii.chatgpt-skin.install\")]("
            ))
        XCTAssertTrue(javaScript.contains("\"generation\":\"generation-1\""))
        XCTAssertTrue(javaScript.contains("\"themeID\":\"original-night-city\""))
        XCTAssertTrue(javaScript.contains("\"themeName\":\"Original Night City\""))
        XCTAssertTrue(javaScript.contains("\"css\":"))
        XCTAssertTrue(javaScript.contains("\"hero\":"))
        XCTAssertTrue(javaScript.contains("\"dataURL\":\"data:image/png;base64,iVBORw==\""))
        XCTAssertTrue(javaScript.contains("adapterProbe: (function zuuziiChatGPTAdapterProbe()"))
        XCTAssertEqual(javaScript.occurrenceCount(of: "com.zuuzii.chatgpt-skin.install"), 1)
    }

    func testInstallJavaScriptCarriesOptionalThemingExtensions() throws {
        let javaScript = try adapter.makeInstallJavaScript(
            generation: "generation-ext",
            themeID: "original-night-city",
            themeName: "Original Night City",
            css: ":root { --zuuzii-accent: #43D8F5; }",
            hero: .init(
                dataURL: "data:image/png;base64,iVBORw==",
                focalPointX: 0.74,
                focalPointY: 0.34,
                pixelWidth: 1,
                pixelHeight: 1
            ),
            brand: ThemeBrandConfiguration(
                mark: ThemeBrandMark(
                    anchorText: "Codex",
                    size: 20,
                    svgViewBox: "0 0 48 48",
                    svgBody: "<circle cx=\"24\" cy=\"24\" r=\"20\"/>",
                    glow: true
                ),
                wordmarkSuffix: "NIGHT CITY",
                wordmarkSlotPadding: 34
            ),
            icons: ThemeIconConfiguration(
                tint: "#43D8F5",
                nav: [ThemeIconOverride(match: "新建任务", path: "M12 3z")],
                suggestions: nil
            ),
            texts: ThemeTextConfiguration(composerPlaceholder: "夜色已就绪")
        )

        XCTAssertTrue(javaScript.contains("\"brand\":{"))
        XCTAssertTrue(javaScript.contains("\"anchorText\":\"Codex\""))
        XCTAssertTrue(javaScript.contains("\"svgViewBox\":\"0 0 48 48\""))
        XCTAssertTrue(javaScript.contains("\"wordmarkSuffix\":\"NIGHT CITY\""))
        XCTAssertTrue(javaScript.contains("\"icons\":{"))
        XCTAssertTrue(javaScript.contains("\"tint\":\"#43D8F5\""))
        XCTAssertTrue(javaScript.contains("\"texts\":{"))
        XCTAssertTrue(javaScript.contains("\"composerPlaceholder\":\"夜色已就绪\""))
    }

    func testBootstrapHasSingleIdempotentEntryAndCompleteCleanupContract() throws {
        let javaScript = try injectedResource(named: "bootstrap.js")

        XCTAssertTrue(javaScript.contains("const BOOTSTRAP_VERSION = 7;"))
        XCTAssertTrue(javaScript.contains("const HERO_LOAD_TIMEOUT_MS = 12_000;"))
        XCTAssertTrue(
            javaScript.contains(
                "Symbol.for(\"com.zuuzii.chatgpt-skin.install\")"
            ))
        XCTAssertTrue(javaScript.contains("payload.generation"))
        XCTAssertTrue(javaScript.contains("payload.themeID"))
        XCTAssertTrue(javaScript.contains("payload.themeName"))
        XCTAssertTrue(javaScript.contains("payload.css"))
        XCTAssertTrue(javaScript.contains("payload.hero"))
        XCTAssertTrue(javaScript.contains("payload.adapterProbe"))
        XCTAssertTrue(javaScript.contains("activeState.generation === payload.generation"))
        XCTAssertTrue(javaScript.contains("activeState.refresh(\"idempotent\")"))
        XCTAssertTrue(javaScript.contains("cleanup(\"replace-generation\")"))
        XCTAssertTrue(javaScript.contains("AbortController"))
        XCTAssertTrue(javaScript.contains("MutationObserver"))
        XCTAssertTrue(javaScript.contains("ResizeObserver"))
        XCTAssertTrue(javaScript.contains("reportRuntimeRevalidation(payload.generation"))
        XCTAssertTrue(javaScript.contains("runtime-install-failed"))
        XCTAssertTrue(javaScript.contains("com.zuuzii.chatgpt-skin.runtime-binding-name"))
        XCTAssertTrue(javaScript.contains("clearTimeout"))
        XCTAssertTrue(javaScript.contains("clearInterval"))
        XCTAssertTrue(javaScript.contains("cancelAnimationFrame"))
        XCTAssertTrue(javaScript.contains("prefers-reduced-motion"))
        XCTAssertTrue(javaScript.contains("max-width: 1023px"))
        XCTAssertTrue(javaScript.contains("never-reparent-native-nodes"))
        XCTAssertTrue(javaScript.contains("data-zuuzii-skin-owner"))
        XCTAssertTrue(javaScript.contains("data-zuuzii-skin-overlay"))
        XCTAssertTrue(javaScript.contains("data-zuuzii-skin-role\", \"hero"))
        XCTAssertTrue(javaScript.contains("max-width: none !important"))
        XCTAssertTrue(javaScript.contains("height: 100% !important"))
        XCTAssertTrue(javaScript.contains("object-fit: cover !important"))
        XCTAssertTrue(javaScript.contains("opacity: 1 !important"))
        XCTAssertTrue(
            javaScript.contains(
                #"body > [data-zuuzii-skin-overlay][data-skin-mode="full"] {"#
            )
        )
        XCTAssertTrue(javaScript.contains("opacity: 0 !important"))
        XCTAssertTrue(javaScript.contains("event?.persisted !== true"))
        XCTAssertTrue(javaScript.contains("asset-render-pending"))
        XCTAssertTrue(javaScript.contains("asset-render-failed"))
        XCTAssertEqual(javaScript.occurrenceCount(of: "document.createElement("), 6)
        XCTAssertFalse(javaScript.contains("data:image/png;base64,"))
        XCTAssertFalse(javaScript.contains("insertBefore("))
        XCTAssertFalse(javaScript.contains("replaceChildren("))
        XCTAssertFalse(javaScript.contains("innerHTML"))
        XCTAssertFalse(javaScript.contains("data-zuuzii-skin-active"))
    }

    func testBootstrapPendingCleansOwnedStateAndCreatesNoNodes() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__createdCount = 0;
            globalThis.__removedCount = 0;
            globalThis.__cleanupCount = 0;
            const staleOwnedNode = { remove: () => { globalThis.__removedCount += 1; } };
            globalThis.document = {
              querySelectorAll: () => [staleOwnedNode],
              createElement: () => { globalThis.__createdCount += 1; return {}; }
            };
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")] = {
              active: true,
              cleanup: () => { globalThis.__cleanupCount += 1; }
            };
            """
        )
        XCTAssertNil(context.exception)

        let result = context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              {
                generation: "pending-test",
                themeID: "test-theme",
                themeName: "Test Theme",
                css: "",
                hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                adapterProbe: () => ({
                  ok: false,
                  failClosed: false,
                  pending: true,
                  reason: "renderer-not-ready",
                  rawPath: "/index.html",
                  path: "/",
                  routeID: "home",
                  viewportWidth: 1440,
                  entryScriptMatchCount: 1,
                  counts: { "main-viewport": 0 },
                  failures: []
                })
              }
            )
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(try XCTUnwrap(result).forProperty("ok").toBool())
        XCTAssertFalse(result?.forProperty("failClosed").toBool() ?? true)
        XCTAssertTrue(result?.forProperty("pending").toBool() ?? false)
        XCTAssertEqual(result?.forProperty("reason").toString(), "renderer-not-ready")
        XCTAssertEqual(context.objectForKeyedSubscript("__createdCount")?.toInt32(), 0)
        XCTAssertEqual(context.objectForKeyedSubscript("__cleanupCount")?.toInt32(), 1)
        XCTAssertEqual(context.objectForKeyedSubscript("__removedCount")?.toInt32(), 1)
        XCTAssertFalse(
            context.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.state')])"
            ).toBool()
        )
    }

    func testBootstrapHardProbeFailureStillFailsClosedWithoutCreatingNodes() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__createdCount = 0;
            globalThis.document = {
              querySelectorAll: () => [],
              createElement: () => { globalThis.__createdCount += 1; return {}; }
            };
            """
        )
        XCTAssertNil(context.exception)

        let result = context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              {
                generation: "hard-failure-test",
                themeID: "test-theme",
                themeName: "Test Theme",
                css: "",
                hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                adapterProbe: () => ({
                  ok: false,
                  failClosed: true,
                  pending: false,
                  routeID: "home",
                  effectiveMode: "full",
                  failures: [{ id: "electron-root", severity: "hard" }]
                })
              }
            )
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(try XCTUnwrap(result).forProperty("ok").toBool())
        XCTAssertTrue(result?.forProperty("failClosed").toBool() ?? false)
        XCTAssertFalse(result?.forProperty("pending").toBool() ?? true)
        XCTAssertEqual(result?.forProperty("reason").toString(), "adapter-probe-failed")
        XCTAssertEqual(context.objectForKeyedSubscript("__createdCount")?.toInt32(), 0)

        let contradictoryResult = context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              {
                generation: "contradictory-state-test",
                themeID: "test-theme",
                themeName: "Test Theme",
                css: "",
                hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                adapterProbe: () => ({
                  ok: true,
                  failClosed: false,
                  pending: true,
                  reason: "invalid-ready-state",
                  routeID: "home",
                  effectiveMode: "full"
                })
              }
            )
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(try XCTUnwrap(contradictoryResult).forProperty("ok").toBool())
        XCTAssertTrue(contradictoryResult?.forProperty("failClosed").toBool() ?? false)
        XCTAssertEqual(
            contradictoryResult?.forProperty("reason").toString(),
            "adapter-probe-failed"
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__createdCount")?.toInt32(), 0)
    }

    func testBootstrapRuntimeHardFailureCleansAndReportsAfterSustainedFailure() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__runtimeReports = [];
            globalThis.__testRuntimeBinding = (payload) => {
              globalThis.__runtimeReports.push(payload);
            };
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.runtime-binding-name")] =
              "__testRuntimeBinding";
            globalThis.__probeReady = true;
            globalThis.__removedNodes = 0;
            const makeNode = (tagName) => ({
              tagName,
              attributes: {},
              dataset: {},
              isConnected: false,
              sheet: tagName === "style" ? { cssRules: [{}] } : null,
              children: [],
              getBoundingClientRect: () => ({ width: 1440, height: 900 }),
              setAttribute(name, value) { this.attributes[name] = value; },
              getAttribute(name) { return this.attributes[name]; },
              removeAttribute(name) { delete this.attributes[name]; },
              appendChild(child) { this.children.push(child); },
              remove: () => { globalThis.__removedNodes += 1; },
            });
            globalThis.document = {
              querySelectorAll: () => [],
              createElement: (tagName) => Object.assign(
                makeNode(tagName),
                tagName === "img"
                  ? { complete: true, naturalWidth: 1, naturalHeight: 1 }
                  : {}
              ),
              head: { appendChild: (node) => { node.isConnected = true; } },
              body: { appendChild: (node) => {
                node.isConnected = true;
                for (const child of node.children || []) child.isConnected = true;
              } },
              documentElement: {},
            };
            globalThis.getComputedStyle = (node) => node.tagName === "img"
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
            globalThis.matchMedia = () => ({
              matches: false,
              addEventListener: () => {},
            });

            globalThis.__runtimeInstallResult =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
                {
                  generation: "runtime-hard-test",
                  themeID: "test-theme",
                  themeName: "Test Theme",
                  css: "",
                  hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                  adapterProbe: () => globalThis.__probeReady
                    ? ({
                        ok: true,
                        failClosed: false,
                        pending: false,
                        routeID: "home",
                        effectiveMode: "full",
                        reducedMotion: false,
                        viewportWidth: 1440,
                      })
                    : ({
                        ok: false,
                        failClosed: true,
                        pending: false,
                        routeID: "home",
                        effectiveMode: "full",
                        failures: [{ id: "electron-root", severity: "hard" }],
                      }),
                }
              );
            globalThis.__now = 1_000;
            Date.now = () => globalThis.__now;
            globalThis.__probeReady = false;
            const refreshState = globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")];
            globalThis.__firstRefresh = refreshState.refresh("unit-test");
            globalThis.__afterFirst = {
              mounted: Boolean(globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]),
              reports: globalThis.__runtimeReports.length,
              removed: globalThis.__removedNodes,
            };
            globalThis.__now = 1_300;
            globalThis.__secondRefresh = refreshState.refresh("unit-test");
            globalThis.__afterSecond = {
              mounted: Boolean(globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]),
              reports: globalThis.__runtimeReports.length,
              removed: globalThis.__removedNodes,
            };
            globalThis.__now = 1_700;
            globalThis.__thirdRefresh = refreshState.refresh("unit-test");
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__runtimeInstallResult")?
                .forProperty("ok").toBool() ?? false
        )

        // Transient failures must keep the installed skin mounted: the first
        // two samples return pending, report nothing, and remove nothing.
        XCTAssertFalse(
            context.objectForKeyedSubscript("__firstRefresh")?
                .forProperty("ok").toBool() ?? true
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__firstRefresh")?
                .forProperty("pending").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__firstRefresh")?
                .forProperty("reason").toString(),
            "renderer-not-ready"
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__afterFirst")?
                .forProperty("mounted").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__afterFirst")?
                .forProperty("reports").toInt32(),
            0
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__afterFirst")?
                .forProperty("removed").toInt32(),
            0
        )

        XCTAssertTrue(
            context.objectForKeyedSubscript("__secondRefresh")?
                .forProperty("pending").toBool() ?? false
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__afterSecond")?
                .forProperty("mounted").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__afterSecond")?
                .forProperty("reports").toInt32(),
            0
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__afterSecond")?
                .forProperty("removed").toInt32(),
            0
        )

        // The third consecutive identical failure spanning >= 600 ms confirms
        // the mismatch: teardown, one native report, state and nodes removed.
        XCTAssertFalse(
            context.objectForKeyedSubscript("__thirdRefresh")?
                .forProperty("ok").toBool() ?? true
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__thirdRefresh")?
                .forProperty("failClosed").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__thirdRefresh")?
                .forProperty("reason").toString(),
            "adapter-probe-failed"
        )
        XCTAssertEqual(
            context.evaluateScript("globalThis.__runtimeReports.length")?.toInt32(),
            1
        )
        XCTAssertEqual(
            context.evaluateScript(
                "JSON.parse(globalThis.__runtimeReports[0]).generation"
            )?.toString(),
            "runtime-hard-test"
        )
        XCTAssertEqual(
            context.evaluateScript(
                "JSON.parse(globalThis.__runtimeReports[0]).event"
            )?.toString(),
            "adapter-probe-failed"
        )
        XCTAssertFalse(
            context.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.state')])"
            ).toBool()
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__removedNodes")?.toInt32(), 2)
    }

    func testBootstrapWaitsForHeroDecodeBeforeReportingFull() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__createdNodes = [];
            globalThis.__appendCount = 0;
            const makeNode = (tagName) => {
              const node = {
                tagName,
                dataset: {},
                setAttribute: () => {},
                removeAttribute: () => {},
              children: [],
              isConnected: false,
              sheet: tagName === "style" ? { cssRules: [{}] } : null,
              getBoundingClientRect: () => ({ width: 1440, height: 900 }),
              appendChild(child) { this.children.push(child); },
                remove: () => {},
              };
              if (tagName === "img") {
                Object.assign(node, { complete: false, naturalWidth: 0, naturalHeight: 0 });
              }
              globalThis.__createdNodes.push(node);
              return node;
            };
            globalThis.document = {
              querySelectorAll: () => [],
              createElement: makeNode,
              head: { appendChild: (node) => {
                node.isConnected = true;
                globalThis.__appendCount += 1;
              } },
              body: { appendChild: (node) => {
                node.isConnected = true;
                for (const child of node.children) child.isConnected = true;
                globalThis.__appendCount += 1;
              } },
              documentElement: {},
            };
            globalThis.getComputedStyle = (node) => node.tagName === "img"
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
            globalThis.__heroPayload = {
              dataURL: "data:image/png;base64,iVBORw==",
              focalPointX: 0.74,
              focalPointY: 0.34,
              pixelWidth: 1920,
              pixelHeight: 1200,
            };
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
            const install = globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")];
            globalThis.__heroPendingResult = install({
              generation: "hero-ready-test",
              themeID: "test-theme",
              themeName: "Test Theme",
              css: "",
              hero: globalThis.__heroPayload,
              adapterProbe: globalThis.__readyProbe,
            });
            globalThis.__appendCountWhilePending = globalThis.__appendCount;
            globalThis.__heroNode = globalThis.__createdNodes.find(node => node.tagName === "img");
            globalThis.__heroNode.complete = true;
            globalThis.__heroNode.naturalWidth = 1920;
            globalThis.__heroNode.naturalHeight = 1200;
            globalThis.__heroNode.onload();
            globalThis.__heroReadyResult = install({
              resumeGeneration: "hero-ready-test",
            });
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(
            context.objectForKeyedSubscript("__heroPendingResult")?
                .forProperty("ok").toBool() ?? true
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__heroPendingResult")?
                .forProperty("pending").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__heroPendingResult")?
                .forProperty("reason").toString(),
            "asset-render-pending"
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__appendCountWhilePending")?.toInt32(),
            0
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__heroReadyResult")?
                .forProperty("ok").toBool() ?? false
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__heroReadyResult")?
                .forProperty("hero").forProperty("ready").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__heroNode")?
                .forProperty("dataset").forProperty("imageState").toString(),
            "ready"
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__appendCount")?.toInt32(), 2)
    }

    func testBootstrapFailsClosedWhenOwnedStylesheetDoesNotRender() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__removedNodes = 0;
            const makeNode = (tagName) => ({
              tagName,
              dataset: {},
              children: [],
              isConnected: false,
              sheet: null,
              setAttribute: () => {},
              removeAttribute: () => {},
              appendChild(child) { this.children.push(child); },
              getBoundingClientRect: () => ({ width: 1440, height: 900 }),
              remove() { this.isConnected = false; globalThis.__removedNodes += 1; },
            });
            globalThis.document = {
              querySelectorAll: () => [],
              createElement: (tagName) => Object.assign(
                makeNode(tagName),
                tagName === "img"
                  ? { complete: true, naturalWidth: 1, naturalHeight: 1 }
                  : {}
              ),
              head: { appendChild: (node) => { node.isConnected = true; } },
              body: { appendChild: (node) => {
                node.isConnected = true;
                for (const child of node.children) child.isConnected = true;
              } },
              documentElement: { clientWidth: 1440, clientHeight: 900 },
            };
            globalThis.innerWidth = 1440;
            globalThis.innerHeight = 900;
            globalThis.getComputedStyle = () => ({ position: "static", opacity: "1" });
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

            globalThis.__blockedStyleResult =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
                {
                  generation: "blocked-style-test",
                  themeID: "test-theme",
                  themeName: "Test Theme",
                  css: "",
                  hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                  adapterProbe: () => ({
                    ok: true,
                    failClosed: false,
                    pending: false,
                    routeID: "home",
                    effectiveMode: "full",
                    reducedMotion: false,
                    viewportWidth: 1440,
                  }),
                }
              );
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(
            context.objectForKeyedSubscript("__blockedStyleResult")?
                .forProperty("ok").toBool() ?? true
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__blockedStyleResult")?
                .forProperty("failClosed").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__blockedStyleResult")?
                .forProperty("reason").toString(),
            "render-verification-failed"
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__removedNodes")?.toInt32(), 2)
        XCTAssertFalse(
            context.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.state')])"
            ).toBool()
        )
    }

    func testBootstrapDefersHeroDecodeOutsideFullMode() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__heroSourceWrites = 0;
            const makeNode = (tagName) => {
              const node = {
                tagName,
                dataset: {},
                children: [],
                isConnected: false,
                sheet: tagName === "style" ? { cssRules: [{}] } : null,
                setAttribute: () => {},
                removeAttribute: () => {},
                appendChild(child) { this.children.push(child); },
                getBoundingClientRect: () => ({ width: 1440, height: 900 }),
                remove() { this.isConnected = false; },
              };
              if (tagName === "img") {
                Object.assign(node, { complete: false, naturalWidth: 0, naturalHeight: 0 });
                Object.defineProperty(node, "src", {
                  set() { globalThis.__heroSourceWrites += 1; },
                });
              }
              return node;
            };
            globalThis.document = {
              querySelectorAll: () => [],
              createElement: makeNode,
              head: { appendChild: (node) => { node.isConnected = true; } },
              body: { appendChild: (node) => {
                node.isConnected = true;
                for (const child of node.children) child.isConnected = true;
              } },
              documentElement: { clientWidth: 1440, clientHeight: 900 },
            };
            globalThis.innerWidth = 1440;
            globalThis.innerHeight = 900;
            globalThis.getComputedStyle = () => ({ position: "fixed", opacity: "0.72" });
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

            globalThis.__coreResult =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
                {
                  generation: "core-deferred-test",
                  themeID: "test-theme",
                  themeName: "Test Theme",
                  css: "",
                  hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                  adapterProbe: () => ({
                    ok: true,
                    failClosed: false,
                    pending: false,
                    routeID: "thread",
                    effectiveMode: "core",
                    reducedMotion: false,
                    viewportWidth: 1440,
                  }),
                }
              );
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__coreResult")?
                .forProperty("ok").toBool() ?? false
        )
        XCTAssertFalse(
            context.objectForKeyedSubscript("__coreResult")?
                .forProperty("hero").forProperty("ready").toBool() ?? true
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__coreResult")?
                .forProperty("hero").forProperty("deferred").toBool() ?? false
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__heroSourceWrites")?.toInt32(), 0)
    }

    func testBootstrapTimesOutCoreToFullExactlyOnceAndIgnoresLateHeroEvents() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        installDeferredHeroLifecycleHarness(in: context)
        context.evaluateScript(
            """
            globalThis.__mode = "full";
            globalThis.__transitionResult = globalThis.__state.refresh("route-to-full");
            globalThis.__heroTimeout = globalThis.__timeouts.find(
              record => record.delay === 12000 && record.cleared === false
            );
            globalThis.__lateHeroOnload = globalThis.__heroNode.onload;
            globalThis.__lateHeroOnerror = globalThis.__heroNode.onerror;
            globalThis.__heroTimeout.callback();
            globalThis.__heroTimeout.callback();
            globalThis.__heroNode.complete = true;
            globalThis.__heroNode.naturalWidth = 1;
            globalThis.__heroNode.naturalHeight = 1;
            globalThis.__lateHeroOnload();
            globalThis.__lateHeroOnerror();
            globalThis.__stateAfterLateEvents = Boolean(
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]
            );
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__coreInstallResult")?
                .forProperty("ok").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__transitionResult")?
                .forProperty("reason").toString(),
            "asset-render-pending"
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__heroTimeout")?
                .forProperty("delay").toInt32(),
            12_000
        )
        XCTAssertEqual(
            context.evaluateScript("globalThis.__runtimeReports.length")?.toInt32(),
            1
        )
        XCTAssertEqual(
            context.evaluateScript(
                "JSON.parse(globalThis.__runtimeReports[0]).event"
            )?.toString(),
            "runtime-install-failed"
        )
        XCTAssertEqual(
            context.evaluateScript(
                "JSON.parse(globalThis.__runtimeReports[0]).generation"
            )?.toString(),
            "hero-lifecycle-test"
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__removedNodes")?.toInt32(), 2)
        XCTAssertEqual(context.objectForKeyedSubscript("__heroSourceWrites")?.toInt32(), 1)
        XCTAssertEqual(
            context.objectForKeyedSubscript("__heroNode")?
                .forProperty("dataset").forProperty("imageState").toString(),
            "failed"
        )
        XCTAssertFalse(
            context.objectForKeyedSubscript("__stateAfterLateEvents")?.toBool() ?? true
        )
    }

    func testBootstrapRevalidatesRenderingAfterDeferredHeroBecomesReady() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        installDeferredHeroLifecycleHarness(in: context)
        context.evaluateScript(
            """
            globalThis.__mode = "full";
            globalThis.__transitionResult = globalThis.__state.refresh("route-to-full");
            globalThis.__heroTimeout = globalThis.__timeouts.find(
              record => record.delay === 12000 && record.cleared === false
            );
            globalThis.__heroNode.complete = true;
            globalThis.__heroNode.naturalWidth = 1;
            globalThis.__heroNode.naturalHeight = 1;
            globalThis.__heroNode.onload();
            globalThis.__heroTimeoutClearedAfterReady = globalThis.__heroTimeout.cleared;
            globalThis.__now = 1_000;
            Date.now = () => globalThis.__now;
            globalThis.__heroOpacity = "0";
            globalThis.__heroReadyRefresh = globalThis.__timeouts.find(
              record => record.delay === 48 && record.cleared === false
            );
            globalThis.__heroReadyRefresh.callback();
            globalThis.__heroReadyFrame = globalThis.__animationFrames.find(
              record => record.cancelled === false
            );
            globalThis.__heroReadyFrame.callback(0);
            globalThis.__afterFirstSample = {
              mounted: Boolean(globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]),
              reports: globalThis.__runtimeReports.length,
              removed: globalThis.__removedNodes,
            };
            globalThis.__now = 1_300;
            globalThis.__retry2 = globalThis.__state.refresh("unit-test-2");
            globalThis.__now = 1_700;
            globalThis.__retry3 = globalThis.__state.refresh("unit-test-3");
            globalThis.__stateAfterHeroReadyRevalidation = Boolean(
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]
            );
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertEqual(
            context.objectForKeyedSubscript("__transitionResult")?
                .forProperty("reason").toString(),
            "asset-render-pending"
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__heroTimeoutClearedAfterReady")?.toBool()
                ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__heroReadyRefresh")?
                .forProperty("delay").toInt32(),
            48
        )
        XCTAssertGreaterThan(
            context.objectForKeyedSubscript("__heroComputedStyleChecks")?.toInt32() ?? 0,
            0
        )
        // The first failing sample only opens the debounce window: the skin
        // stays mounted, nothing is reported, nothing is removed.
        XCTAssertTrue(
            context.objectForKeyedSubscript("__afterFirstSample")?
                .forProperty("mounted").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__afterFirstSample")?
                .forProperty("reports").toInt32(),
            0
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__afterFirstSample")?
                .forProperty("removed").toInt32(),
            0
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__retry2")?
                .forProperty("pending").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__retry3")?
                .forProperty("reason").toString(),
            "render-verification-failed"
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__removedNodes")?.toInt32(), 2)
        XCTAssertEqual(
            context.evaluateScript("globalThis.__runtimeReports.length")?.toInt32(),
            1
        )
        XCTAssertEqual(
            context.evaluateScript(
                "JSON.parse(globalThis.__runtimeReports[0]).event"
            )?.toString(),
            "runtime-install-failed"
        )
        XCTAssertFalse(
            context.objectForKeyedSubscript("__stateAfterHeroReadyRevalidation")?.toBool()
                ?? true
        )
    }

    func testBootstrapPreservesSkinAcrossBFCacheButCleansNormalPagehide() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__events = {};
            globalThis.__removedNodes = 0;
            const makeNode = (tagName) => ({
              tagName,
              dataset: {},
              children: [],
              isConnected: false,
              sheet: tagName === "style" ? { cssRules: [{}] } : null,
              setAttribute: () => {},
              getAttribute: () => "bfcache-test",
              removeAttribute: () => {},
              appendChild(child) { this.children.push(child); },
              getBoundingClientRect: () => ({ width: 1440, height: 900 }),
              remove() { this.isConnected = false; globalThis.__removedNodes += 1; },
            });
            globalThis.document = {
              querySelectorAll: () => [],
              createElement: makeNode,
              head: { appendChild: (node) => { node.isConnected = true; } },
              body: { appendChild: (node) => {
                node.isConnected = true;
                for (const child of node.children) child.isConnected = true;
              } },
              documentElement: { clientWidth: 1440, clientHeight: 900 },
            };
            globalThis.innerWidth = 1440;
            globalThis.innerHeight = 900;
            globalThis.getComputedStyle = () => ({ position: "fixed", opacity: "0.72" });
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
            globalThis.addEventListener = (name, listener) => {
              globalThis.__events[name] = listener;
            };
            globalThis.matchMedia = () => ({ matches: false, addEventListener: () => {} });

            globalThis.__bfcacheInstallResult =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
                {
                  generation: "bfcache-test",
                  themeID: "test-theme",
                  themeName: "Test Theme",
                  css: "",
                  hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                  adapterProbe: () => ({
                    ok: true,
                    failClosed: false,
                    pending: false,
                    routeID: "thread",
                    effectiveMode: "core",
                    reducedMotion: false,
                    viewportWidth: 1440,
                  }),
                }
              );
            globalThis.__events.pagehide({ persisted: true });
            globalThis.__stateAfterPersistedHide = Boolean(
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]
            );
            globalThis.__events.pageshow({ persisted: true });
            globalThis.__events.pagehide({ persisted: false });
            globalThis.__stateAfterNormalHide = Boolean(
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]
            );
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__bfcacheInstallResult")?
                .forProperty("ok").toBool() ?? false
        )
        XCTAssertTrue(context.objectForKeyedSubscript("__stateAfterPersistedHide")?.toBool() ?? false)
        XCTAssertFalse(context.objectForKeyedSubscript("__stateAfterNormalHide")?.toBool() ?? true)
        XCTAssertEqual(context.objectForKeyedSubscript("__removedNodes")?.toInt32(), 2)
    }

    func testBootstrapFailsClosedWhenHeroCannotDecode() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript(
            """
            globalThis.__removedNodes = 0;
            globalThis.__createdNodes = [];
            const makeNode = (tagName) => {
              const node = {
                tagName,
                dataset: {},
                setAttribute: () => {},
                removeAttribute: () => {},
                appendChild: () => {},
                remove: () => { globalThis.__removedNodes += 1; },
              };
              if (tagName === "img") {
                Object.assign(node, { complete: false, naturalWidth: 0, naturalHeight: 0 });
              }
              globalThis.__createdNodes.push(node);
              return node;
            };
            globalThis.document = {
              querySelectorAll: () => [],
              createElement: makeNode,
              head: { appendChild: () => {} },
              body: { appendChild: () => {} },
              documentElement: {},
            };
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
            const hero = {
              dataURL: "data:image/png;base64,iVBORw==",
              focalPointX: 0.5,
              focalPointY: 0.5,
              pixelWidth: 1,
              pixelHeight: 1,
            };
            const probe = () => ({
              ok: true,
              failClosed: false,
              pending: false,
              routeID: "home",
              effectiveMode: "full",
              reducedMotion: false,
              viewportWidth: 1440,
              entryScriptMatchCount: 1,
            });
            const install = globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")];
            globalThis.__firstHeroResult = install({
              generation: "hero-failure-test",
              themeID: "test-theme",
              themeName: "Test Theme",
              css: "",
              hero,
              adapterProbe: probe,
            });
            globalThis.__createdNodes.find(node => node.tagName === "img").onerror();
            globalThis.__failedHeroResult = install({
              generation: "hero-failure-test",
              themeID: "test-theme",
              themeName: "Test Theme",
              css: "",
              hero,
              adapterProbe: probe,
            });
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertEqual(
            context.objectForKeyedSubscript("__firstHeroResult")?
                .forProperty("reason").toString(),
            "asset-render-pending"
        )
        XCTAssertFalse(
            context.objectForKeyedSubscript("__failedHeroResult")?
                .forProperty("ok").toBool() ?? true
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__failedHeroResult")?
                .forProperty("failClosed").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__failedHeroResult")?
                .forProperty("reason").toString(),
            "asset-render-failed"
        )
        XCTAssertFalse(
            context.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.state')])"
            ).toBool()
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__removedNodes")?.toInt32(), 2)
    }

    func testBootstrapRejectsCSSLargerThanOneMiB() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        XCTAssertNil(context.exception)

        let result = context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              {
                generation: "oversize-test",
                themeID: "test-theme",
                themeName: "Test Theme",
                css: "x".repeat((1024 * 1024) + 1),
                hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                adapterProbe: () => ({ ok: true, failClosed: false, effectiveMode: "full", routeID: "home" })
              }
            )
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(try XCTUnwrap(result).forProperty("ok").toBool())
        XCTAssertEqual(result?.forProperty("reason").toString(), "invalid-payload")
    }

    func testBootstrapMeasuresCSSLimitInUTF8Bytes() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        XCTAssertNil(context.exception)

        let result = context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              {
                generation: "unicode-size-test",
                themeID: "test-theme",
                themeName: "Test Theme",
                css: "汉".repeat(350000),
                hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                adapterProbe: () => ({ ok: true, failClosed: false, effectiveMode: "full", routeID: "home" })
              }
            )
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(try XCTUnwrap(result).forProperty("ok").toBool())
        XCTAssertEqual(result?.forProperty("reason").toString(), "invalid-payload")
    }

    func testBootstrapRejectsRemoteCSSURL() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        XCTAssertNil(context.exception)

        let result = context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              {
                generation: "remote-url-test",
                themeID: "test-theme",
                themeName: "Test Theme",
                css: "body { background-image: url(https://example.com/hero.png); }",
                hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                adapterProbe: () => ({ ok: true, failClosed: false, effectiveMode: "full", routeID: "home" })
              }
            )
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(try XCTUnwrap(result).forProperty("ok").toBool())
        XCTAssertEqual(result?.forProperty("reason").toString(), "invalid-payload")
    }

    func testBootstrapRejectsEscapedRemoteCSSURL() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        XCTAssertNil(context.exception)

        let result = context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              {
                generation: "escaped-remote-url-test",
                themeID: "test-theme",
                themeName: "Test Theme",
                css: String.raw`body { background-image: url("\\68 ttps://evil.invalid/hero.png"); }`,
                hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                adapterProbe: () => ({ ok: true, failClosed: false, effectiveMode: "full", routeID: "home" })
              }
            )
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertFalse(try XCTUnwrap(result).forProperty("ok").toBool())
        XCTAssertEqual(result?.forProperty("reason").toString(), "invalid-payload")
    }

    func testBootstrapRejectsDataImageInsideCSS() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try injectedResource(named: "bootstrap.js"))
        context.evaluateScript("globalThis.document = { querySelectorAll: () => [] };")
        XCTAssertNil(context.exception)

        let result = context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              {
                generation: "data-image-test",
                themeID: "test-theme",
                themeName: "Test Theme",
                css: 'body { background-image: url(  "data:image/png;base64,////"  ); }',
                hero: { dataURL: "data:image/png;base64,iVBORw==", focalPointX: 0.5, focalPointY: 0.5, pixelWidth: 1, pixelHeight: 1 },
                adapterProbe: () => ({ ok: false, failClosed: true, effectiveMode: "token-only", routeID: "fallback" })
              }
            )
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.forProperty("reason").toString(), "invalid-payload")
    }

    func testCleanupTargetsOnlyOwnedGenerationResources() throws {
        let javaScript = try injectedResource(named: "cleanup.js")

        XCTAssertTrue(
            javaScript.contains(
                "Symbol.for(\"com.zuuzii.chatgpt-skin.state\")"
            ))
        XCTAssertTrue(javaScript.contains("state.cleanup(\"external-cleanup\")"))
        XCTAssertTrue(javaScript.contains("com.zuuzii.chatgpt-skin.reload"))
        XCTAssertTrue(javaScript.contains("reloadState.cancel(\"external-cleanup\")"))
        XCTAssertTrue(javaScript.contains("com.zuuzii.chatgpt-skin.payload"))
        XCTAssertTrue(javaScript.contains("data-zuuzii-skin-owner"))
        XCTAssertTrue(javaScript.contains("removedNodes"))
        XCTAssertFalse(javaScript.contains("#root"))
        XCTAssertFalse(javaScript.contains("document.body.remove"))
    }

    func testCleanupContinuesWhenGenerationCleanupThrows() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            """
            globalThis.__removedNodes = 0;
            globalThis.__ownedNode = { remove: () => { globalThis.__removedNodes += 1; } };
            globalThis.document = { querySelectorAll: () => [globalThis.__ownedNode] };
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")] = {
              cleanup: () => { throw new Error("planned cleanup failure"); }
            };
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.payload")] = { generation: "stale" };
            """
        )

        let result = context.evaluateScript(try injectedResource(named: "cleanup.js"))

        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.forProperty("removedNodes").toInt32(), 1)
        XCTAssertEqual(context.objectForKeyedSubscript("__removedNodes")?.toInt32(), 1)
        XCTAssertFalse(
            context.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.state')])"
            ).toBool()
        )
        XCTAssertFalse(
            context.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.payload')])"
            ).toBool()
        )
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

    private func installDeferredHeroLifecycleHarness(in context: JSContext) {
        context.evaluateScript(
            """
            globalThis.__mode = "core";
            globalThis.__heroOpacity = "1";
            globalThis.__heroSourceWrites = 0;
            globalThis.__heroComputedStyleChecks = 0;
            globalThis.__removedNodes = 0;
            globalThis.__createdNodes = [];
            globalThis.__timeouts = [];
            globalThis.__animationFrames = [];
            globalThis.__runtimeReports = [];
            globalThis.__nextTimeoutID = 1;
            globalThis.__nextAnimationFrameID = 1;

            const makeNode = (tagName) => {
              const attributes = {};
              const node = {
                tagName,
                dataset: {},
                children: [],
                isConnected: false,
                sheet: tagName === "style" ? { cssRules: [{}] } : null,
                setAttribute(name, value) { attributes[name] = String(value); },
                getAttribute(name) { return attributes[name] ?? null; },
                removeAttribute(name) {
                  delete attributes[name];
                  if (name === "src") this.__source = "";
                },
                appendChild(child) { this.children.push(child); },
                getBoundingClientRect: () => ({ width: 1440, height: 900 }),
                remove() {
                  if (!this.isConnected) return;
                  this.isConnected = false;
                  for (const child of this.children) child.isConnected = false;
                  globalThis.__removedNodes += 1;
                },
              };
              if (tagName === "img") {
                Object.assign(node, {
                  complete: false,
                  naturalWidth: 0,
                  naturalHeight: 0,
                  __source: "",
                });
                Object.defineProperty(node, "src", {
                  get() { return this.__source; },
                  set(value) {
                    this.__source = value;
                    globalThis.__heroSourceWrites += 1;
                  },
                });
              }
              globalThis.__createdNodes.push(node);
              return node;
            };

            globalThis.document = {
              querySelectorAll: () => [],
              createElement: makeNode,
              head: { appendChild: (node) => { node.isConnected = true; } },
              body: { appendChild: (node) => {
                node.isConnected = true;
                for (const child of node.children) child.isConnected = true;
              } },
              documentElement: { clientWidth: 1440, clientHeight: 900 },
            };
            globalThis.innerWidth = 1440;
            globalThis.innerHeight = 900;
            globalThis.getComputedStyle = (node) => {
              if (node.tagName === "img") {
                globalThis.__heroComputedStyleChecks += 1;
                return {
                  position: "absolute",
                  objectFit: "cover",
                  opacity: globalThis.__heroOpacity,
                  display: "block",
                  visibility: "visible",
                };
              }
              return {
                position: "fixed",
                opacity: globalThis.__mode === "full" ? "1" : "0.72",
              };
            };
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
            globalThis.setTimeout = (callback, delay) => {
              const record = {
                id: globalThis.__nextTimeoutID++,
                callback,
                delay,
                cleared: false,
              };
              globalThis.__timeouts.push(record);
              return record.id;
            };
            globalThis.clearTimeout = (id) => {
              const record = globalThis.__timeouts.find(candidate => candidate.id === id);
              if (record) record.cleared = true;
            };
            globalThis.setInterval = () => 1;
            globalThis.clearInterval = () => {};
            globalThis.requestAnimationFrame = (callback) => {
              const record = {
                id: globalThis.__nextAnimationFrameID++,
                callback,
                cancelled: false,
              };
              globalThis.__animationFrames.push(record);
              return record.id;
            };
            globalThis.cancelAnimationFrame = (id) => {
              const record = globalThis.__animationFrames.find(candidate => candidate.id === id);
              if (record) record.cancelled = true;
            };
            globalThis.addEventListener = () => {};
            globalThis.matchMedia = () => ({ matches: false, addEventListener: () => {} });

            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.runtime-binding-name")] =
              "__heroRuntimeBinding";
            globalThis.__heroRuntimeBinding = (payload) => {
              globalThis.__runtimeReports.push(payload);
            };
            globalThis.__heroProbe = () => ({
              ok: true,
              failClosed: false,
              pending: false,
              routeID: globalThis.__mode === "full" ? "home" : "thread",
              effectiveMode: globalThis.__mode,
              reducedMotion: false,
              viewportWidth: 1440,
              entryScriptMatchCount: 1,
            });

            globalThis.__coreInstallResult =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
                {
                  generation: "hero-lifecycle-test",
                  themeID: "test-theme",
                  themeName: "Test Theme",
                  css: "",
                  hero: {
                    dataURL: "data:image/png;base64,iVBORw==",
                    focalPointX: 0.5,
                    focalPointY: 0.5,
                    pixelWidth: 1,
                    pixelHeight: 1,
                  },
                  adapterProbe: globalThis.__heroProbe,
                }
              );
            globalThis.__state =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")];
            globalThis.__heroNode = globalThis.__createdNodes.find(
              node => node.tagName === "img"
            );
            """
        )
    }
}

extension String {
    fileprivate func occurrenceCount(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return components(separatedBy: needle).count - 1
    }
}
