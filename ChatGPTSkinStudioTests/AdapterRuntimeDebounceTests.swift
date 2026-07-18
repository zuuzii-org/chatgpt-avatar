import JavaScriptCore
import XCTest

/// Adversarial coverage for the bootstrap runtime-failure debounce (BOOTSTRAP_VERSION 6):
/// a refresh() mismatch may only tear the installed skin down after the same
/// failure signature appears on 3 consecutive samples spanning at least 600 ms.
final class AdapterRuntimeDebounceTests: XCTestCase {

    func testBootstrapRuntimeRefreshKeepsSkinThroughTransientProbeFailure() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluateHarnessAndInstall(in: context)
        context.evaluateScript(
            """
            globalThis.__now = 1_000;
            Date.now = () => globalThis.__now;
            const state = globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")];
            globalThis.__probeReady = false;
            globalThis.__flap1 = state.refresh("flap-1");
            globalThis.__now = 1_150;
            globalThis.__flap2 = state.refresh("flap-2");
            globalThis.__probeReady = true;
            globalThis.__now = 1_200;
            globalThis.__recovered1 = state.refresh("recover-1");
            globalThis.__probeReady = false;
            globalThis.__now = 2_000;
            globalThis.__flap3 = state.refresh("flap-3");
            globalThis.__now = 2_200;
            globalThis.__flap4 = state.refresh("flap-4");
            globalThis.__probeReady = true;
            globalThis.__now = 2_250;
            globalThis.__recovered2 = state.refresh("recover-2");
            globalThis.__final = {
              mounted: Boolean(globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]),
              reports: globalThis.__runtimeReports.length,
              removed: globalThis.__removedNodes,
            };
            """
        )

        XCTAssertNil(context.exception)
        for name in ["__flap1", "__flap2", "__flap3", "__flap4"] {
            XCTAssertFalse(
                context.objectForKeyedSubscript(name)?
                    .forProperty("ok").toBool() ?? true,
                "\(name) should stay non-ok"
            )
            XCTAssertTrue(
                context.objectForKeyedSubscript(name)?
                    .forProperty("pending").toBool() ?? false,
                "\(name) should report pending instead of tearing down"
            )
        }
        XCTAssertTrue(
            context.objectForKeyedSubscript("__recovered1")?
                .forProperty("ok").toBool() ?? false
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__recovered2")?
                .forProperty("ok").toBool() ?? false
        )
        // A success resets the debounce chain: without the reset, __flap3 would
        // have been the third sample of a chain started at t=1000 and would
        // have torn the skin down.
        XCTAssertTrue(
            context.objectForKeyedSubscript("__final")?
                .forProperty("mounted").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__final")?
                .forProperty("reports").toInt32(),
            0
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__final")?
                .forProperty("removed").toInt32(),
            0
        )
    }

    func testBootstrapRuntimeFailureDebounceResetsOnSignatureChange() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluateHarnessAndInstall(in: context)
        context.evaluateScript(
            """
            globalThis.__now = 1_000;
            Date.now = () => globalThis.__now;
            const state = globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")];
            globalThis.__probeReady = false;
            globalThis.__failureID = "electron-root";
            globalThis.__a1 = state.refresh("a1");
            globalThis.__now = 1_100;
            globalThis.__a2 = state.refresh("a2");
            globalThis.__failureID = "app-shell";
            globalThis.__now = 1_200;
            globalThis.__b1 = state.refresh("b1");
            globalThis.__now = 1_300;
            globalThis.__b2 = state.refresh("b2");
            globalThis.__mid = {
              mounted: Boolean(globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]),
              reports: globalThis.__runtimeReports.length,
              removed: globalThis.__removedNodes,
            };
            globalThis.__now = 2_000;
            globalThis.__b3 = state.refresh("b3");
            """
        )

        XCTAssertNil(context.exception)
        for name in ["__a1", "__a2", "__b1", "__b2"] {
            XCTAssertTrue(
                context.objectForKeyedSubscript(name)?
                    .forProperty("pending").toBool() ?? false,
                "\(name) should stay pending: alternating signatures never confirm"
            )
        }
        // Two samples of signature A followed by two of signature B: no
        // signature reached 3 consecutive samples, so nothing tears down.
        XCTAssertTrue(
            context.objectForKeyedSubscript("__mid")?
                .forProperty("mounted").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__mid")?
                .forProperty("reports").toInt32(),
            0
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__mid")?
                .forProperty("removed").toInt32(),
            0
        )
        // A third consecutive sample of signature B spanning >= 600 ms confirms.
        XCTAssertFalse(
            context.objectForKeyedSubscript("__b3")?
                .forProperty("ok").toBool() ?? true
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__b3")?
                .forProperty("failClosed").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__b3")?
                .forProperty("reason").toString(),
            "adapter-probe-failed"
        )
        XCTAssertEqual(
            context.evaluateScript("globalThis.__runtimeReports.length")?.toInt32(),
            1
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

    func testBootstrapRuntimeRenderVerificationFailureDebouncesBeforeTeardown() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluateHarnessAndInstall(in: context)
        context.evaluateScript(
            """
            globalThis.__now = 1_000;
            Date.now = () => globalThis.__now;
            const state = globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")];
            globalThis.__renderOK = false;
            globalThis.__r1 = state.refresh("render-1");
            globalThis.__now = 1_200;
            globalThis.__r2 = state.refresh("render-2");
            globalThis.__midRender = {
              mounted: Boolean(globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")]),
              reports: globalThis.__runtimeReports.length,
              removed: globalThis.__removedNodes,
            };
            globalThis.__now = 1_900;
            globalThis.__r3 = state.refresh("render-3");
            """
        )

        XCTAssertNil(context.exception)
        // A transient render-contract mismatch (host mid-commit styles) keeps
        // the skin mounted and reports nothing.
        XCTAssertTrue(
            context.objectForKeyedSubscript("__r1")?
                .forProperty("pending").toBool() ?? false
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__r2")?
                .forProperty("pending").toBool() ?? false
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__midRender")?
                .forProperty("mounted").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__midRender")?
                .forProperty("reports").toInt32(),
            0
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__midRender")?
                .forProperty("removed").toInt32(),
            0
        )
        // Sustained identical render failures confirm and tear down with the
        // runtime-install-failed native signal.
        XCTAssertFalse(
            context.objectForKeyedSubscript("__r3")?
                .forProperty("ok").toBool() ?? true
        )
        XCTAssertTrue(
            context.objectForKeyedSubscript("__r3")?
                .forProperty("failClosed").toBool() ?? false
        )
        XCTAssertEqual(
            context.objectForKeyedSubscript("__r3")?
                .forProperty("reason").toString(),
            "render-verification-failed"
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
        XCTAssertFalse(
            context.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.state')])"
            ).toBool()
        )
        XCTAssertEqual(context.objectForKeyedSubscript("__removedNodes")?.toInt32(), 2)
    }

    private func evaluateHarnessAndInstall(in context: JSContext) throws {
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
            globalThis.__failureID = "electron-root";
            globalThis.__renderOK = true;
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
              ? ({
                  position: globalThis.__renderOK ? "absolute" : "static",
                  objectFit: "cover",
                  opacity: "1",
                  display: "block",
                  visibility: "visible",
                })
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

            globalThis.__installResult =
              globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
                {
                  generation: "runtime-debounce-test",
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
                        failures: [{ id: globalThis.__failureID, severity: "hard", actualCount: 0 }],
                      }),
                }
              );
            """
        )

        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.objectForKeyedSubscript("__installResult")?
                .forProperty("ok").toBool() ?? false,
            "harness install must succeed before runtime scenarios run"
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
}
