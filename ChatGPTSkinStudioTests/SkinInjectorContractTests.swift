import Foundation
import JavaScriptCore
import XCTest

@testable import ChatGPTSkinStudio

private struct RegistryFakeAdapter: ChatGPTAdapter {
    let manifest: ChatGPTAdapterManifest

    init(identifier: String) {
        let base = ChatGPTStructuralAdapterV1().manifest
        manifest = ChatGPTAdapterManifest(
            identifier: identifier,
            protocolContract: base.protocolContract,
            minimumStructuralWidth: base.minimumStructuralWidth,
            selectors: base.selectors,
            routeCapabilities: base.routeCapabilities,
            cardinalityProbes: base.cardinalityProbes
        )
    }
}

private func registryTarget(id: String, path: String) -> CDPTarget {
    CDPTarget(
        id: id,
        type: "page",
        title: "ignored-title-\(id)",
        url: "app://-\(path)",
        webSocketDebuggerUrl: "ws://127.0.0.1:9222/devtools/page/\(id)"
    )
}

final class SkinInjectorContractTests: XCTestCase {
    func testRendererCandidateEnumerationUsesTrustedAppSchemeWithoutBindingWindowTitle() {
        let main = CDPTarget(
            id: "main",
            type: "page",
            title: "Future ChatGPT Title",
            url: "app://-/index.html",
            webSocketDebuggerUrl: "ws://127.0.0.1:9222/devtools/page/main"
        )
        let overlay = CDPTarget(
            id: "overlay",
            type: "page",
            title: "Overlay",
            url: "app://-/avatar-overlay",
            webSocketDebuggerUrl: "ws://127.0.0.1:9222/devtools/page/overlay"
        )
        let external = CDPTarget(
            id: "external",
            type: "page",
            title: "External",
            url: "https://example.com/",
            webSocketDebuggerUrl: "ws://127.0.0.1:9222/devtools/page/external"
        )

        XCTAssertEqual(
            ChatGPTRendererTargetPolicy.candidates(from: [overlay, external, main]),
            [overlay, main]
        )

        let futureShell = CDPTarget(
            id: "future",
            type: "page",
            title: "Renamed",
            url: "app://new-shell/home.html",
            webSocketDebuggerUrl: "ws://127.0.0.1:9222/devtools/page/future"
        )
        XCTAssertEqual(
            ChatGPTRendererTargetPolicy.candidates(from: [external, futureShell]),
            [futureShell]
        )
    }

    func testStructuralAdapterRegistrySelectsUniqueReadyMatch() throws {
        let adapter = RegistryFakeAdapter(identifier: "adapter-a")
        let registry = try StructuralAdapterRegistry(trustedAdapters: [adapter])
        let main = registryTarget(id: "main", path: "/index.html")
        let auxiliary = registryTarget(id: "overlay", path: "/avatar-overlay")

        let selection = try registry.select(from: [
            .init(
                target: auxiliary,
                adapter: adapter,
                readiness: .rejected,
                structuralFailureSignature: nil
            ),
            .init(
                target: main,
                adapter: adapter,
                readiness: .ready,
                structuralFailureSignature: nil
            ),
        ])

        XCTAssertEqual(selection.target, main)
        XCTAssertEqual(selection.adapter.manifest.identifier, "adapter-a")
        XCTAssertEqual(selection.readiness, .ready)
    }

    func testStructuralAdapterRegistryAllowsOnePendingRendererObservation() throws {
        let adapter = RegistryFakeAdapter(identifier: "adapter-a")
        let registry = try StructuralAdapterRegistry(trustedAdapters: [adapter])
        let pending = registryTarget(id: "pending-main", path: "/index.html")

        let selection = try registry.select(from: [
            .init(
                target: pending,
                adapter: adapter,
                readiness: .pending,
                structuralFailureSignature: nil
            )
        ])

        XCTAssertEqual(selection.target, pending)
        XCTAssertEqual(selection.readiness, .pending)
    }

    func testStructuralAdapterRegistryFailsClosedWhenNothingMatches() throws {
        let adapter = RegistryFakeAdapter(identifier: "adapter-a")
        let registry = try StructuralAdapterRegistry(trustedAdapters: [adapter])
        let target = registryTarget(id: "main", path: "/index.html")
        let observations: [StructuralAdapterProbeObservation] = [
            .init(
                target: target,
                adapter: adapter,
                readiness: .rejected,
                structuralFailureSignature: "route=home|main=0"
            )
        ]

        XCTAssertThrowsError(try registry.select(from: observations)) { error in
            XCTAssertEqual(
                error as? StructuralAdapterRegistryError,
                .noStructuralMatch
            )
        }
        XCTAssertEqual(
            registry.structuralRejectionSignature(from: observations),
            "main|adapter-a|route=home|main=0"
        )

        let partiallyUnavailable = observations + [
            .init(
                target: registryTarget(id: "starting", path: "/index.html"),
                adapter: adapter,
                readiness: .indeterminate,
                structuralFailureSignature: nil
            )
        ]
        XCTAssertNil(
            registry.structuralRejectionSignature(from: partiallyUnavailable)
        )
        XCTAssertThrowsError(try registry.select(from: partiallyUnavailable)) { error in
            XCTAssertEqual(
                error as? StructuralAdapterRegistryError,
                .noStructuralMatch
            )
        }
    }

    func testStructuralAdapterRegistryIgnoresUnregisteredAdapterObservations() throws {
        let trusted = RegistryFakeAdapter(identifier: "trusted-adapter")
        let unregistered = RegistryFakeAdapter(identifier: "unregistered-adapter")
        let registry = try StructuralAdapterRegistry(trustedAdapters: [trusted])

        XCTAssertThrowsError(
            try registry.select(from: [
                .init(
                    target: registryTarget(id: "main", path: "/index.html"),
                    adapter: unregistered,
                    readiness: .ready,
                    structuralFailureSignature: nil
                )
            ])
        ) { error in
            XCTAssertEqual(
                error as? StructuralAdapterRegistryError,
                .noStructuralMatch
            )
        }
    }

    func testStructuralAdapterRegistryFailsClosedForMultipleTargetsOrAdapters() throws {
        let adapterA = RegistryFakeAdapter(identifier: "adapter-a")
        let adapterB = RegistryFakeAdapter(identifier: "adapter-b")
        let registry = try StructuralAdapterRegistry(
            trustedAdapters: [adapterA, adapterB]
        )
        let first = registryTarget(id: "main-a", path: "/index.html")
        let second = registryTarget(id: "main-b", path: "/home.html")

        let multipleTargets: [StructuralAdapterProbeObservation] = [
            .init(
                target: first,
                adapter: adapterA,
                readiness: .ready,
                structuralFailureSignature: nil
            ),
            .init(
                target: second,
                adapter: adapterA,
                readiness: .pending,
                structuralFailureSignature: nil
            ),
        ]
        XCTAssertThrowsError(try registry.select(from: multipleTargets)) { error in
            XCTAssertEqual(
                error as? StructuralAdapterRegistryError,
                .ambiguousStructuralMatches(2)
            )
        }

        let multipleAdapters: [StructuralAdapterProbeObservation] = [
            .init(
                target: first,
                adapter: adapterA,
                readiness: .ready,
                structuralFailureSignature: nil
            ),
            .init(
                target: first,
                adapter: adapterB,
                readiness: .ready,
                structuralFailureSignature: nil
            ),
        ]
        XCTAssertThrowsError(try registry.select(from: multipleAdapters)) { error in
            XCTAssertEqual(
                error as? StructuralAdapterRegistryError,
                .ambiguousStructuralMatches(2)
            )
        }
    }

    func testCompatibilityPolicyAdmitsArbitraryAppVersionsAndBuilds() throws {
        let adapter = ChatGPTStructuralAdapterV1()
        let themeCompatibility = ThemeCompatibility(
            adapterProtocol: "chatgpt-macos-renderer",
            minimumAPIVersion: 1,
            maximumAPIVersion: 1
        )
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")

        for (version, build) in [
            ("26.707.72221", "5307"),
            ("99.999.99999", "future-build-not-numeric"),
        ] {
            let bundle = VerifiedChatGPTBundle(
                appURL: appURL,
                executableURL: appURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                bundleIdentifier: "com.openai.codex",
                teamIdentifier: "2DC432GLL2",
                shortVersion: version,
                buildVersion: build
            )
            XCTAssertNoThrow(
                try ChatGPTSkinCompatibilityPolicy.validate(
                    adapter: adapter,
                    themeCompatibility: themeCompatibility,
                    verifiedBundle: bundle
                )
            )
        }
    }

    func testInstallProbePolicyRetriesOnlyKnownPendingStates() {
        let installed: [String: JSONValue] = [
            "ok": .bool(true),
            "failClosed": .bool(false),
            "pending": .bool(false),
        ]
        let pending: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(false),
            "pending": .bool(true),
            "reason": .string("renderer-not-ready"),
        ]
        let hardFailure: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(true),
            "pending": .bool(false),
            "reason": .string("adapter-probe-failed"),
        ]
        let incompletePending: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(false),
            "pending": .bool(true),
            "reason": .string("adapter-probe-failed"),
        ]
        let assetPending: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(false),
            "pending": .bool(true),
            "reason": .string("asset-render-pending"),
        ]
        let malformedInstalledPending: [String: JSONValue] = [
            "ok": .bool(true),
            "failClosed": .bool(false),
            "pending": .bool(true),
        ]
        let malformedMissingFailClosed: [String: JSONValue] = [
            "ok": .bool(true),
            "pending": .bool(false),
        ]
        let malformedMissingPending: [String: JSONValue] = [
            "ok": .bool(true),
            "failClosed": .bool(false),
        ]

        XCTAssertEqual(SkinInstallProbePolicy.disposition(installed), .installed)
        XCTAssertEqual(SkinInstallProbePolicy.disposition(pending), .pending)
        XCTAssertEqual(SkinInstallProbePolicy.disposition(assetPending), .pending)
        XCTAssertEqual(SkinInstallProbePolicy.disposition(hardFailure), .hardFailure)
        XCTAssertEqual(SkinInstallProbePolicy.disposition(incompletePending), .hardFailure)
        XCTAssertEqual(
            SkinInstallProbePolicy.disposition(malformedInstalledPending),
            .hardFailure
        )
        XCTAssertEqual(
            SkinInstallProbePolicy.disposition(malformedMissingFailClosed),
            .hardFailure
        )
        XCTAssertEqual(
            SkinInstallProbePolicy.disposition(malformedMissingPending),
            .hardFailure
        )
    }

    func testInstallFailureCleanupTrackerDistinguishesVerifiedAndUncertainScriptState() {
        var tracker = SkinInstallFailureCleanupTracker()
        XCTAssertEqual(tracker.newDocumentScriptDisposition, .notRequired)

        tracker.newDocumentScriptRequestSent = true
        XCTAssertEqual(tracker.newDocumentScriptDisposition, .uncertain)

        tracker.newDocumentScriptIdentifier = "new-document-script-1"
        XCTAssertEqual(
            tracker.newDocumentScriptDisposition,
            .remove(identifier: "new-document-script-1")
        )
    }

    func testCleanupVerificationPolicyRequiresEveryResidueToBeAbsent() throws {
        let verified: [String: JSONValue] = [
            "remainingOwnedNodes": .number(0),
            "statePresent": .bool(false),
            "reloadPresent": .bool(false),
            "payloadPresent": .bool(false),
            "bindingNamePresent": .bool(false),
            "runtimeBindingPresent": .bool(false),
        ]
        XCTAssertNoThrow(try SkinCleanupVerificationPolicy.validate(verified))

        let residuals: [(String, JSONValue)] = [
            ("remainingOwnedNodes", .number(1)),
            ("statePresent", .bool(true)),
            ("reloadPresent", .bool(true)),
            ("payloadPresent", .bool(true)),
            ("bindingNamePresent", .bool(true)),
            ("runtimeBindingPresent", .bool(true)),
        ]
        for (key, value) in residuals {
            var invalid = verified
            invalid[key] = value
            XCTAssertThrowsError(
                try SkinCleanupVerificationPolicy.validate(invalid),
                "Expected residual rejection for \(key)"
            ) { error in
                guard case SkinError.protocolFailure = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        var missingField = verified
        missingField.removeValue(forKey: "reloadPresent")
        XCTAssertThrowsError(
            try SkinCleanupVerificationPolicy.validate(missingField)
        )
    }

    func testCleanupVerificationDetectsFalseySymbolProperties() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            """
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.state")] = null;
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.reload")] = 0;
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.payload")] = false;
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.runtime-binding-name")] = "";
            globalThis.document = { querySelectorAll: () => [] };
            """
        )
        XCTAssertNil(context.exception)

        let result = context.evaluateScript(
            try SkinCleanupVerificationPolicy.expression(runtimeBindingName: nil)
        )
        XCTAssertNil(context.exception)
        XCTAssertTrue(result?.forProperty("statePresent").toBool() == true)
        XCTAssertTrue(result?.forProperty("reloadPresent").toBool() == true)
        XCTAssertTrue(result?.forProperty("payloadPresent").toBool() == true)
        XCTAssertTrue(result?.forProperty("bindingNamePresent").toBool() == true)
        XCTAssertFalse(result?.forProperty("runtimeBindingPresent").toBool() == true)
    }

    func testCleanupResultPolicyRejectsAnyReportedTeardownFailure() throws {
        let verified: [String: JSONValue] = [
            "ok": .bool(true),
            "failures": .array([]),
        ]
        XCTAssertNoThrow(try SkinCleanupResultPolicy.validate(verified))

        let reportedFailure: JSONValue = .object([
            "step": .string("reload.cancel"),
            "message": .string("planned cancel failure"),
        ])
        XCTAssertThrowsError(
            try SkinCleanupResultPolicy.validate([
                "ok": .bool(false),
                "failures": .array([reportedFailure]),
            ])
        )
        XCTAssertThrowsError(
            try SkinCleanupResultPolicy.validate([
                "ok": .bool(true),
                "failures": .array([reportedFailure]),
            ]),
            "A non-empty failure audit must override a misleading ok=true."
        )
        XCTAssertThrowsError(
            try SkinCleanupResultPolicy.validate(["ok": .bool(true)]),
            "Missing teardown audit data must fail closed."
        )
    }

    func testHardStructuralProbeFailureReportsIncompatibleApp() {
        let structuralFailure: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(true),
            "pending": .bool(false),
            "reason": .string("adapter-probe-failed"),
            "detail": .string("electron-root=0"),
        ]
        let installationFailure: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(true),
            "pending": .bool(false),
            "reason": .string("installation-error"),
        ]
        let heroFailure: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(true),
            "pending": .bool(false),
            "reason": .string("asset-render-failed"),
            "detail": .string("must-not-surface-renderer-detail"),
        ]
        let styleFailure: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(true),
            "pending": .bool(false),
            "reason": .string("render-verification-failed"),
        ]

        guard case .incompatibleApp(let structuralMessage) =
            SkinInstallProbePolicy.hardFailureError(structuralFailure)
        else {
            return XCTFail("结构探测硬失配必须映射为 incompatibleApp")
        }
        XCTAssertTrue(structuralMessage.contains("renderer 结构"))
        XCTAssertTrue(structuralMessage.contains("electron-root=0"))
        XCTAssertEqual(
            SkinInstallProbePolicy.hardFailureError(installationFailure),
            .injectionFailed("installation-error")
        )
        XCTAssertEqual(
            SkinInstallProbePolicy.hardFailureError(heroFailure),
            .injectionFailed("主题图片渲染失败，已停止应用并回退到原生界面。")
        )
        XCTAssertEqual(
            SkinInstallProbePolicy.hardFailureError(styleFailure),
            .injectionFailed("主题样式未能在 ChatGPT renderer 中完整生效，已停止应用并回退到原生界面。")
        )
        XCTAssertNotNil(
            SkinInstallProbePolicy.structuralFailureSignature(structuralFailure)
        )
        XCTAssertNil(
            SkinInstallProbePolicy.structuralFailureSignature(installationFailure)
        )

        let directProbeFailure: [String: JSONValue] = [
            "adapterId": .string("chatgpt-macos-structural-v1"),
            "ok": .bool(false),
            "failClosed": .bool(true),
            "pending": .bool(false),
            "routeID": .string("home"),
            "viewportWidth": .number(1_440),
            "entryScriptMatchCount": .number(0),
            "counts": .object(["electron-root": .number(0)]),
            "failures": .array([]),
        ]
        XCTAssertNotNil(
            SkinInstallProbePolicy.directStructuralProbeFailureSignature(
                directProbeFailure
            )
        )
        XCTAssertNil(
            SkinInstallProbePolicy.directStructuralProbeFailureSignature(
                structuralFailure
            )
        )
    }

    func testStructuralFailureConfirmationRequiresThreeConsecutiveMatchingSignatures() {
        func failure(routeID: String, count: Int) -> [String: JSONValue] {
            [
                "ok": .bool(false),
                "failClosed": .bool(true),
                "pending": .bool(false),
                "reason": .string("adapter-probe-failed"),
                "routeID": .string(routeID),
                "viewportWidth": .number(1_440),
                "entryScriptMatchCount": .number(1),
                "counts": .object(["main-viewport": .number(Double(count))]),
                "failures": .array([
                    .object([
                        "id": .string("main-viewport"),
                        "severity": .string("hard"),
                        "actualCount": .number(Double(count)),
                        "minimumCount": .number(1),
                        "maximumCount": .number(1),
                    ])
                ]),
                "detail": .string("must-not-participate-in-content-blind-signature"),
            ]
        }

        let signatureA = failure(routeID: "home", count: 0)
        let signatureB = failure(routeID: "home", count: 2)
        var stable = SkinStructuralFailureConfirmation()
        XCTAssertFalse(stable.record(signatureA))
        XCTAssertFalse(stable.record(signatureA))
        XCTAssertTrue(stable.record(signatureA))

        var changing = SkinStructuralFailureConfirmation()
        XCTAssertFalse(changing.record(signatureA))
        XCTAssertFalse(changing.record(signatureB))
        XCTAssertFalse(changing.record(signatureB))
        XCTAssertTrue(changing.record(signatureB))

        var unstable = SkinStructuralFailureConfirmation()
        XCTAssertFalse(unstable.record(signatureA))
        XCTAssertFalse(unstable.record(signatureB))
        XCTAssertFalse(unstable.record(signatureA))
        XCTAssertFalse(unstable.record(signatureB))
        XCTAssertFalse(unstable.record(signatureA))

        let runtimeFailure: [String: JSONValue] = [
            "ok": .bool(false),
            "failClosed": .bool(true),
            "pending": .bool(false),
            "reason": .string("installation-error"),
        ]
        XCTAssertFalse(unstable.record(runtimeFailure))
        XCTAssertEqual(unstable.consecutiveMatches, 0)
        XCTAssertNil(unstable.lastSignature)
    }

    func testUnconfirmedStartupStructuralFailureIsNotReportedAsIncompatible() {
        guard case .timedOut(let message) =
            SkinInstallProbePolicy.unconfirmedStructuralFailureError()
        else {
            return XCTFail("未确认的启动期结构失配必须按可恢复超时处理")
        }

        XCTAssertTrue(message.contains("未能连续确认"))
        XCTAssertTrue(message.contains("不会判定为不兼容"))
    }

    func testPendingTimeoutMessageUsesOnlyStructuralDiagnostics() {
        let result: [String: JSONValue] = [
            "rawPath": .string("/index.html"),
            "path": .string("/"),
            "routeID": .string("home"),
            "viewportWidth": .number(1_440),
            "entryScriptMatchCount": .number(1),
            "counts": .object([
                "electron-root": .number(1),
                "main-viewport": .number(0),
            ]),
            "failures": .array([
                .object([
                    "id": .string("main-viewport"),
                    "severity": .string("hard"),
                    "actualCount": .number(0),
                    "minimumCount": .number(1),
                    "maximumCount": .number(1),
                    "bodyText": .string("must-not-leak"),
                ])
            ]),
            "bodyText": .string("private conversation text"),
            "detail": .string("private renderer detail"),
        ]

        let message = SkinInstallProbePolicy.pendingTimeoutMessage(result)

        XCTAssertTrue(message.contains("renderer-not-ready"))
        XCTAssertTrue(message.contains("rawPath=/index.html"))
        XCTAssertTrue(message.contains("path=/"))
        XCTAssertTrue(message.contains("routeID=home"))
        XCTAssertTrue(message.contains("main-viewport=0"))
        XCTAssertFalse(message.contains("private conversation text"))
        XCTAssertFalse(message.contains("private renderer detail"))
        XCTAssertFalse(message.contains("must-not-leak"))
        XCTAssertEqual(SkinInstallProbePolicy.pendingTimeoutError(result), .timedOut(message))
    }

    func testReloadScriptRetriesPendingButStopsOnHardFailure() throws {
        func outcome(
            for resultLiteral: String,
            executeRetries: Bool = false
        ) throws -> (retries: Int32, reports: Int32) {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript(
                """
                globalThis.__scheduledRetries = 0;
                globalThis.__executeRetries = \(executeRetries ? "true" : "false");
                globalThis.__runtimeReports = [];
                globalThis.__testRuntimeBinding = (payload) => {
                  globalThis.__runtimeReports.push(payload);
                };
                globalThis.__installResult = \(resultLiteral);
                globalThis.document = {
                  readyState: "complete",
                  querySelectorAll: () => [],
                  removeEventListener: () => {},
                };
                globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")] = () =>
                  globalThis.__installResult;
                globalThis.setTimeout = (callback) => {
                  globalThis.__scheduledRetries += 1;
                  if (globalThis.__executeRetries) callback();
                };
                """
            )
            context.evaluateScript(
                try SkinReloadScriptBuilder.make(
                    bootstrap: "",
                    initialInstallExpression: "globalThis.__installResult",
                    generation: "generation-1",
                    bindingName: "__testRuntimeBinding"
                )
            )
            XCTAssertNil(context.exception)
            return (
                context.objectForKeyedSubscript("__scheduledRetries")?.toInt32() ?? -1,
                context.evaluateScript("globalThis.__runtimeReports.length")?.toInt32() ?? -1
            )
        }

        XCTAssertEqual(
            try outcome(
                for: "{ ok: false, failClosed: false, pending: true, reason: 'renderer-not-ready' }"
            ).retries,
            1
        )
        XCTAssertEqual(
            try outcome(
                for: "{ ok: false, failClosed: false, pending: true, reason: 'asset-render-pending' }"
            ).retries,
            1
        )
        let hardFailure = try outcome(
            for: "{ ok: false, failClosed: true, pending: false, reason: 'adapter-probe-failed' }"
        )
        XCTAssertEqual(hardFailure.retries, 0)
        XCTAssertEqual(hardFailure.reports, 1)
        XCTAssertEqual(
            try outcome(
                for: "{ ok: false, failClosed: false, pending: true, reason: 'adapter-probe-failed' }"
            ).reports,
            1
        )
        XCTAssertEqual(
            try outcome(
                for: "{ ok: false, failClosed: true, pending: false, reason: 'installation-error' }"
            ).reports,
            1
        )
        XCTAssertEqual(
            try outcome(
                for: "{ ok: true, failClosed: false, pending: true, reason: 'malformed-success' }"
            ).reports,
            1
        )
        XCTAssertEqual(
            try outcome(
                for: "{ ok: true, failClosed: false, reason: 'malformed-success' }"
            ).reports,
            1
        )
        let exhaustedPending = try outcome(
            for: "{ ok: false, failClosed: false, pending: true, reason: 'renderer-not-ready' }",
            executeRetries: true
        )
        XCTAssertEqual(exhaustedPending.retries, 79)
        XCTAssertEqual(exhaustedPending.reports, 1)
    }

    func testReloadRetryCannotReviveSkinAfterCleanup() throws {
        let reloadSource = try SkinReloadScriptBuilder.make(
            bootstrap: "",
            initialInstallExpression: "globalThis.__install()",
            generation: "generation-1",
            bindingName: "__testRuntimeBinding"
        )
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cleanupSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("ChatGPTSkinStudio/Resources/Injected/cleanup.js"),
            encoding: .utf8
        )

        let timerContext = try XCTUnwrap(JSContext())
        timerContext.evaluateScript(
            """
            globalThis.__installCalls = 0;
            globalThis.__clearedTimers = 0;
            globalThis.__timerCallbacks = [];
            globalThis.__install = () => {
              globalThis.__installCalls += 1;
              return { ok: false, failClosed: false, pending: true, reason: "renderer-not-ready" };
            };
            globalThis.__testRuntimeBinding = () => {};
            globalThis.document = {
              readyState: "complete",
              querySelectorAll: () => [],
              addEventListener: () => {},
              removeEventListener: () => {},
            };
            globalThis.setTimeout = (callback) => {
              globalThis.__timerCallbacks.push(callback);
              return globalThis.__timerCallbacks.length;
            };
            globalThis.clearTimeout = () => { globalThis.__clearedTimers += 1; };
            """
        )
        timerContext.evaluateScript(reloadSource)
        XCTAssertNil(timerContext.exception)
        XCTAssertEqual(timerContext.objectForKeyedSubscript("__installCalls")?.toInt32(), 1)
        XCTAssertTrue(
            timerContext.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.reload')])"
            ).toBool()
        )

        timerContext.evaluateScript(reloadSource)
        XCTAssertNil(timerContext.exception)
        XCTAssertEqual(timerContext.objectForKeyedSubscript("__installCalls")?.toInt32(), 2)
        XCTAssertEqual(timerContext.objectForKeyedSubscript("__clearedTimers")?.toInt32(), 1)
        timerContext.evaluateScript("globalThis.__timerCallbacks[0]()")
        XCTAssertNil(timerContext.exception)
        XCTAssertEqual(timerContext.objectForKeyedSubscript("__installCalls")?.toInt32(), 2)

        timerContext.evaluateScript(cleanupSource)
        XCTAssertNil(timerContext.exception)
        XCTAssertEqual(timerContext.objectForKeyedSubscript("__clearedTimers")?.toInt32(), 2)
        XCTAssertFalse(
            timerContext.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.reload')])"
            ).toBool()
        )
        timerContext.evaluateScript("globalThis.__timerCallbacks[1]()")
        XCTAssertNil(timerContext.exception)
        XCTAssertEqual(timerContext.objectForKeyedSubscript("__installCalls")?.toInt32(), 2)

        let loadingContext = try XCTUnwrap(JSContext())
        loadingContext.evaluateScript(
            """
            globalThis.__installCalls = 0;
            globalThis.__removedReadyListeners = 0;
            globalThis.__readyListener = null;
            globalThis.__install = () => {
              globalThis.__installCalls += 1;
              return { ok: true, failClosed: false, pending: false };
            };
            globalThis.__testRuntimeBinding = () => {};
            globalThis.document = {
              readyState: "loading",
              querySelectorAll: () => [],
              addEventListener: (_, listener) => { globalThis.__readyListener = listener; },
              removeEventListener: (_, listener) => {
                if (listener === globalThis.__readyListener) globalThis.__removedReadyListeners += 1;
              },
            };
            globalThis.setTimeout = () => 1;
            globalThis.clearTimeout = () => {};
            """
        )
        loadingContext.evaluateScript(reloadSource)
        XCTAssertNil(loadingContext.exception)
        XCTAssertEqual(loadingContext.objectForKeyedSubscript("__installCalls")?.toInt32(), 0)
        loadingContext.evaluateScript(cleanupSource)
        XCTAssertNil(loadingContext.exception)
        XCTAssertEqual(
            loadingContext.objectForKeyedSubscript("__removedReadyListeners")?.toInt32(),
            1
        )
        loadingContext.evaluateScript("globalThis.__readyListener()")
        XCTAssertNil(loadingContext.exception)
        XCTAssertEqual(loadingContext.objectForKeyedSubscript("__installCalls")?.toInt32(), 0)
    }

    func testReloadHydratesFreshRendererBeforeUsingResumeExpression() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            """
            globalThis.__fullInstallCalls = 0;
            globalThis.__resumeCalls = 0;
            globalThis.__runtimeReports = [];
            globalThis.__testRuntimeBinding = (payload) => {
              globalThis.__runtimeReports.push(payload);
            };
            globalThis.document = {
              readyState: "complete",
              querySelectorAll: () => [],
              removeEventListener: () => {},
            };
            globalThis.setTimeout = (callback) => { callback(); return 1; };
            globalThis.clearTimeout = () => {};
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")] = (payload) => {
              globalThis.__resumeCalls += 1;
              return payload?.resumeGeneration === "generation-1"
                ? { ok: true, failClosed: false, pending: false }
                : { ok: false, failClosed: true, pending: false, reason: "invalid-payload" };
            };
            """
        )
        let source = try SkinReloadScriptBuilder.make(
            bootstrap: "",
            initialInstallExpression: """
            (() => {
              globalThis.__fullInstallCalls += 1;
              return { ok: false, failClosed: false, pending: true, reason: "asset-render-pending" };
            })()
            """,
            generation: "generation-1",
            bindingName: "__testRuntimeBinding"
        )

        context.evaluateScript(source)

        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("__fullInstallCalls")?.toInt32(), 1)
        XCTAssertEqual(context.objectForKeyedSubscript("__resumeCalls")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("globalThis.__runtimeReports.length")?.toInt32(), 0)
        XCTAssertFalse(
            context.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.reload')])"
            ).toBool()
        )
    }

    func testReloadScriptRunsOnlyInTopFrame() throws {
        let source = try SkinReloadScriptBuilder.make(
            bootstrap: "globalThis.__bootstrapCalls += 1;",
            initialInstallExpression: """
            (() => {
              globalThis.__fullInstallCalls += 1;
              return { ok: true, failClosed: false, pending: false };
            })()
            """,
            generation: "generation-1",
            bindingName: "__testRuntimeBinding"
        )

        func makeContext(topFrame: Bool) throws -> JSContext {
            let context = try XCTUnwrap(JSContext())
            let topValue = topFrame ? "globalThis" : "{}"
            context.evaluateScript(
                """
                globalThis.__bootstrapCalls = 0;
                globalThis.__fullInstallCalls = 0;
                globalThis.__runtimeReports = [];
                globalThis.__testRuntimeBinding = (payload) => {
                  globalThis.__runtimeReports.push(payload);
                };
                globalThis.window = globalThis;
                globalThis.top = \(topValue);
                globalThis.document = {
                  readyState: "complete",
                  querySelectorAll: () => [],
                  addEventListener: () => {},
                  removeEventListener: () => {},
                };
                globalThis.setTimeout = () => 1;
                globalThis.clearTimeout = () => {};
                """
            )
            return context
        }

        let childFrame = try makeContext(topFrame: false)
        childFrame.evaluateScript(source)
        XCTAssertNil(childFrame.exception)
        XCTAssertEqual(childFrame.objectForKeyedSubscript("__bootstrapCalls")?.toInt32(), 0)
        XCTAssertEqual(childFrame.objectForKeyedSubscript("__fullInstallCalls")?.toInt32(), 0)
        XCTAssertEqual(childFrame.evaluateScript("globalThis.__runtimeReports.length")?.toInt32(), 0)
        XCTAssertEqual(
            childFrame.evaluateScript(
                "typeof globalThis[Symbol.for('com.zuuzii.chatgpt-skin.runtime-binding-name')]"
            ).toString(),
            "undefined"
        )
        XCTAssertFalse(
            childFrame.evaluateScript(
                "Boolean(globalThis[Symbol.for('com.zuuzii.chatgpt-skin.reload')])"
            ).toBool()
        )

        let topFrame = try makeContext(topFrame: true)
        topFrame.evaluateScript(source)
        XCTAssertNil(topFrame.exception)
        XCTAssertEqual(topFrame.objectForKeyedSubscript("__bootstrapCalls")?.toInt32(), 1)
        XCTAssertEqual(topFrame.objectForKeyedSubscript("__fullInstallCalls")?.toInt32(), 1)
        XCTAssertEqual(topFrame.evaluateScript("globalThis.__runtimeReports.length")?.toInt32(), 0)
    }

    func testRuntimeRevalidationHydratesFullPayloadOnlyOnFirstAttempt() {
        let fullExpression = "install({ hero: 'data:image/png;base64,large-payload' })"
        let resumeExpression = "install({ resumeGeneration: 'generation-1' })"
        let plan = SkinRuntimeRevalidationInstallPlan(
            initialInstallExpression: fullExpression,
            resumeExpression: resumeExpression
        )

        let attempts = (1...5).map(plan.scripts(forAttempt:))

        XCTAssertEqual(attempts[0].expression, fullExpression)
        XCTAssertEqual(attempts.dropFirst().map(\.expression), Array(repeating: resumeExpression, count: 4))
        XCTAssertEqual(attempts.map(\.retryExpression), Array(repeating: resumeExpression, count: 5))
        XCTAssertEqual(attempts.filter { $0.expression.contains("data:image") }.count, 1)
    }

    func testInstallResumeExpressionIsSmallAndGenerationBound() throws {
        let expression = try SkinInstallResumeScriptBuilder.make(
            generation: "generation-1"
        )

        XCTAssertLessThan(expression.utf8.count, 512)
        XCTAssertTrue(expression.contains("resumeGeneration"))
        XCTAssertTrue(expression.contains("generation-1"))
        XCTAssertFalse(expression.contains("data:image"))
    }

    func testRuntimeBindingPolicyAcceptsOnlyExpectedBoundedSignal() throws {
        let bindingName = "__zuuziiSkinRuntime_abc"
        let generation = "generation-1"
        let payload = #"{"schemaVersion":1,"event":"adapter-probe-failed","generation":"generation-1"}"#
        let valid = CDPEnvelope(
            id: nil,
            result: nil,
            error: nil,
            method: "Runtime.bindingCalled",
            params: [
                "name": .string(bindingName),
                "payload": .string(payload),
            ]
        )

        XCTAssertEqual(
            SkinRuntimeBindingPolicy.signal(
                from: valid,
                expectedBindingName: bindingName,
                expectedGeneration: generation
            ),
            SkinRuntimeBindingSignal(generation: generation, event: "adapter-probe-failed")
        )

        let runtimeInstallFailurePayload =
            #"{"schemaVersion":1,"event":"runtime-install-failed","generation":"generation-1"}"#
        let runtimeInstallFailure = CDPEnvelope(
            id: nil,
            result: nil,
            error: nil,
            method: "Runtime.bindingCalled",
            params: [
                "name": .string(bindingName),
                "payload": .string(runtimeInstallFailurePayload),
            ]
        )
        XCTAssertEqual(
            SkinRuntimeBindingPolicy.signal(
                from: runtimeInstallFailure,
                expectedBindingName: bindingName,
                expectedGeneration: generation
            ),
            SkinRuntimeBindingSignal(generation: generation, event: "runtime-install-failed")
        )

        let unknownEventPayload =
            #"{"schemaVersion":1,"event":"unknown","generation":"generation-1"}"#
        let unknownEvent = CDPEnvelope(
            id: nil,
            result: nil,
            error: nil,
            method: "Runtime.bindingCalled",
            params: [
                "name": .string(bindingName),
                "payload": .string(unknownEventPayload),
            ]
        )
        XCTAssertNil(
            SkinRuntimeBindingPolicy.signal(
                from: unknownEvent,
                expectedBindingName: bindingName,
                expectedGeneration: generation
            )
        )

        let wrongName = CDPEnvelope(
            id: nil,
            result: nil,
            error: nil,
            method: "Runtime.bindingCalled",
            params: [
                "name": .string("__unexpected"),
                "payload": .string(payload),
            ]
        )
        XCTAssertNil(
            SkinRuntimeBindingPolicy.signal(
                from: wrongName,
                expectedBindingName: bindingName,
                expectedGeneration: generation
            )
        )

        let stalePayload = payload.replacingOccurrences(
            of: "generation-1",
            with: "generation-old"
        )
        let stale = CDPEnvelope(
            id: nil,
            result: nil,
            error: nil,
            method: "Runtime.bindingCalled",
            params: [
                "name": .string(bindingName),
                "payload": .string(stalePayload),
            ]
        )
        XCTAssertNil(
            SkinRuntimeBindingPolicy.signal(
                from: stale,
                expectedBindingName: bindingName,
                expectedGeneration: generation
            )
        )

        let oversized = CDPEnvelope(
            id: nil,
            result: nil,
            error: nil,
            method: "Runtime.bindingCalled",
            params: [
                "name": .string(bindingName),
                "payload": .string(String(repeating: "x", count: 513)),
            ]
        )
        XCTAssertNil(
            SkinRuntimeBindingPolicy.signal(
                from: oversized,
                expectedBindingName: bindingName,
                expectedGeneration: generation
            )
        )

        let unexpectedFieldPayload = String(payload.dropLast())
            + ",\"bodyText\":\"must-not-cross-native-boundary\"}"
        let unexpectedField = CDPEnvelope(
            id: nil,
            result: nil,
            error: nil,
            method: "Runtime.bindingCalled",
            params: [
                "name": .string(bindingName),
                "payload": .string(String(unexpectedFieldPayload)),
            ]
        )
        XCTAssertNil(
            SkinRuntimeBindingPolicy.signal(
                from: unexpectedField,
                expectedBindingName: bindingName,
                expectedGeneration: generation
            )
        )
    }
}

final class SkinSessionCoordinatorRuntimeTests: XCTestCase {
    func testRuntimeIncompatibilityCleansRollsBackAndReportsFinalState() async throws {
        let fixture = try makeRuntimeFixture(rollbackFails: false)
        let states = RuntimeStateRecorder()

        let snapshot = try await fixture.coordinator.apply(
            theme: fixture.theme,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in
                await states.append(state)
            }
        )
        let activeAfterApply = await fixture.coordinator.isActive(
            generation: snapshot.generation
        )
        XCTAssertTrue(activeAfterApply)

        await fixture.injector.emit(
            SkinRuntimeInvalidation(
                generation: snapshot.generation,
                kind: .incompatible,
                message: "runtime adapter mismatch"
            )
        )
        try await waitForRollback(fixture.restarter)

        let restoreCount = await fixture.injector.restoreCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let activeAfterRollback = await fixture.coordinator.isActive(
            generation: snapshot.generation
        )
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertFalse(activeAfterRollback)
        let recorded = await states.values()
        XCTAssertTrue(recorded.contains(.cleaningUp))
        guard case .incompatible(let message) = recorded.last else {
            return XCTFail("Expected final incompatible state, got \(String(describing: recorded.last))")
        }
        XCTAssertTrue(message.contains("runtime adapter mismatch"))
        XCTAssertTrue(message.contains("恢复正常启动"))

        await fixture.injector.emit(
            SkinRuntimeInvalidation(
                generation: snapshot.generation,
                kind: .incompatible,
                message: "duplicate"
            )
        )
        try await Task.sleep(for: .milliseconds(30))
        let rollbackCountAfterDuplicate = await fixture.restarter.rollbackCount()
        XCTAssertEqual(rollbackCountAfterDuplicate, 1)
    }

    func testRuntimeRollbackFailureRemainsRecoverable() async throws {
        let fixture = try makeRuntimeFixture(rollbackFails: true)
        let states = RuntimeStateRecorder()
        let snapshot = try await fixture.coordinator.apply(
            theme: fixture.theme,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in
                await states.append(state)
            }
        )

        await fixture.injector.emit(
            SkinRuntimeInvalidation(
                generation: snapshot.generation,
                kind: .incompatible,
                message: "runtime adapter mismatch"
            )
        )
        try await waitForRollback(fixture.restarter)

        guard case .recoveryRequired(let message) = await states.values().last else {
            return XCTFail("Expected recoveryRequired after rollback failure")
        }
        XCTAssertTrue(message.contains("自动恢复"))
    }

    func testRuntimeUnavailableCleansRollsBackAndReportsDegradedState() async throws {
        let fixture = try makeRuntimeFixture(rollbackFails: false)
        let states = RuntimeStateRecorder()
        let snapshot = try await fixture.coordinator.apply(
            theme: fixture.theme,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in
                await states.append(state)
            }
        )

        await fixture.injector.emit(
            SkinRuntimeInvalidation(
                generation: snapshot.generation,
                kind: .runtimeUnavailable,
                message: "renderer connection unavailable"
            )
        )
        try await waitForRollback(fixture.restarter)

        let restoreCount = await fixture.injector.restoreCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let isActive = await fixture.coordinator.isActive(generation: snapshot.generation)
        let recordedStates = await states.values()
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertFalse(isActive)
        guard case .degraded(let message) = recordedStates.last else {
            return XCTFail("Expected final degraded state")
        }
        XCTAssertTrue(message.contains("renderer connection unavailable"))
        XCTAssertTrue(message.contains("恢复正常启动"))
    }

    private func makeRuntimeFixture(
        rollbackFails: Bool
    ) throws -> RuntimeCoordinatorFixture {
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/ChatGPT")
        let bundle = VerifiedChatGPTBundle(
            appURL: appURL,
            executableURL: executableURL,
            bundleIdentifier: "com.openai.codex",
            teamIdentifier: "2DC432GLL2",
            shortVersion: "99.0",
            buildVersion: "future-build"
        )
        let process = RuntimeProcessSnapshot(
            pid: 42_001,
            processGroupID: 42_001,
            startTime: .init(seconds: 42, microseconds: 1),
            executableURL: executableURL,
            arguments: []
        )
        let debugSession = ProductionDebugSession(
            id: UUID(),
            bundle: bundle,
            process: process,
            userDataDirectory: URL(fileURLWithPath: "/tmp/chatgpt-runtime-test"),
            userDataIdentity: .init(device: 1, inode: 2, owner: 0),
            endpoint: .init(
                port: 53_810,
                browserWebSocketPath: "/devtools/browser/runtime-test"
            ),
            listener: .init(pid: process.pid, address: "127.0.0.1", port: 53_810)
        )
        let snapshot = SkinInjectionSnapshot(
            generation: "runtime-generation-1",
            themeID: "original-night-city",
            appBuild: bundle.buildVersion,
            targetID: "renderer-1",
            routeID: "home",
            effectiveMode: .full
        )
        let injector = RuntimeFakeInjector(snapshot: snapshot)
        let restarter = RuntimeFakeRestarter(
            debugSession: debugSession,
            rollbackFails: rollbackFails
        )
        let themeDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ChatGPTSkinStudio/Resources/Themes/original-night-city")
        let theme = try ThemeValidator().validateAndLoad(
            themeDirectory: themeDirectory,
            source: .bundled
        )
        return RuntimeCoordinatorFixture(
            bundle: bundle,
            theme: theme,
            injector: injector,
            restarter: restarter,
            coordinator: SkinSessionCoordinator(
                restarter: restarter,
                injector: injector,
                sessionValidator: RuntimePassingSessionValidator()
            )
        )
    }

    private func waitForRollback(_ restarter: RuntimeFakeRestarter) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await restarter.rollbackCount() > 0 { return }
            try await clock.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for runtime rollback")
    }
}

private struct RuntimePassingSessionValidator: ProductionDebugSessionValidating {
    func validate(_ session: ProductionDebugSession) async throws {}
}

private struct RuntimeCoordinatorFixture {
    let bundle: VerifiedChatGPTBundle
    let theme: LoadedTheme
    let injector: RuntimeFakeInjector
    let restarter: RuntimeFakeRestarter
    let coordinator: SkinSessionCoordinator
}

private actor RuntimeStateRecorder {
    private var recorded: [SkinSessionState] = []

    func append(_ state: SkinSessionState) {
        recorded.append(state)
    }

    func values() -> [SkinSessionState] {
        recorded
    }
}

private actor RuntimeFakeInjector: SkinInjecting {
    private let installedSnapshot: SkinInjectionSnapshot
    private let stream: AsyncStream<SkinRuntimeInvalidation>
    private let continuation: AsyncStream<SkinRuntimeInvalidation>.Continuation
    private var restores = 0

    init(snapshot: SkinInjectionSnapshot) {
        installedSnapshot = snapshot
        let pair = AsyncStream<SkinRuntimeInvalidation>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func install(
        port: Int,
        theme: LoadedTheme,
        verifiedBundle: VerifiedChatGPTBundle,
        registry: StructuralAdapterRegistry
    ) async throws -> SkinInjectionHandle {
        SkinInjectionHandle(snapshot: installedSnapshot, invalidations: stream)
    }

    func restore() {
        restores += 1
        continuation.finish()
    }

    func snapshot() -> SkinInjectionSnapshot? {
        installedSnapshot
    }

    func emit(_ invalidation: SkinRuntimeInvalidation) {
        continuation.yield(invalidation)
    }

    func restoreCount() -> Int {
        restores
    }
}

private actor RuntimeFakeRestarter: ProductionChatGPTRestarting {
    private let debugSession: ProductionDebugSession
    private let rollbackFails: Bool
    private var rollbacks = 0

    init(debugSession: ProductionDebugSession, rollbackFails: Bool) {
        self.debugSession = debugSession
        self.rollbackFails = rollbackFails
    }

    func restartForDebugging(
        _ request: ProductionRestartRequest
    ) async throws -> ProductionDebugSession {
        debugSession
    }

    func rollbackToNormal(
        _ session: ProductionDebugSession
    ) async throws -> NormalChatGPTSession {
        rollbacks += 1
        if rollbackFails {
            throw SkinError.cleanupFailed("planned rollback failure")
        }
        return normalSession()
    }

    func restoreToNormal(
        _ session: ProductionDebugSession,
        consent: ExplicitRestartConsent
    ) async throws -> NormalChatGPTSession {
        normalSession()
    }

    func rollbackCount() -> Int {
        rollbacks
    }

    private func normalSession() -> NormalChatGPTSession {
        NormalChatGPTSession(
            id: UUID(),
            bundle: debugSession.bundle,
            process: debugSession.process
        )
    }
}
