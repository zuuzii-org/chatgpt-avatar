import Foundation

struct SkinInjectionSnapshot: Sendable, Equatable {
    let generation: String
    let themeID: String
    let appBuild: String
    let targetID: String
    let routeID: String
    let effectiveMode: ChatGPTSkinRouteMode
}

struct SkinRuntimeDiagnostics: Sendable, Equatable {
    let ownedNodeCount: Int
    let overlayCount: Int
    let styleCount: Int
    let ownedGeneration: String
    let ownedThemeID: String
    let heroState: String
    let heroImageState: String
    let heroObjectPosition: String
    let overlayPointerEventsNone: Bool
    let overlayAriaHidden: Bool
    let overlayInert: Bool
    let composerFocusAccepted: Bool
    let routeID: String
    let effectiveMode: ChatGPTSkinRouteMode
    let viewportWidth: Int
}

enum SkinRuntimeInvalidationKind: String, Sendable, Equatable {
    case incompatible
    case runtimeUnavailable
}

struct SkinRuntimeInvalidation: Sendable, Equatable {
    let generation: String
    let kind: SkinRuntimeInvalidationKind
    let message: String
}

struct SkinInjectionHandle: Sendable {
    let snapshot: SkinInjectionSnapshot
    let invalidations: AsyncStream<SkinRuntimeInvalidation>
}

private struct SkinRuntimeBindingPayload: Codable {
    let schemaVersion: Int
    let event: String
    let generation: String
}

struct SkinRuntimeBindingSignal: Sendable, Equatable {
    let generation: String
    let event: String
}

enum SkinRuntimeBindingPolicy {
    static let configurationSymbol = "com.zuuzii.chatgpt-skin.runtime-binding-name"
    static let eventName = "adapter-probe-failed"
    static let rendererNotReadyEventName = "renderer-not-ready"
    static let runtimeInstallFailedEventName = "runtime-install-failed"
    static let schemaVersion = 1
    static let maximumPayloadBytes = 512

    static func makeBindingName(generation: String) -> String {
        "__zuuziiSkinRuntime_" + generation.replacingOccurrences(of: "-", with: "")
    }

    static func configurationJavaScript(bindingName: String) throws -> String {
        let symbol = try javaScriptStringLiteral(configurationSymbol)
        let name = try javaScriptStringLiteral(bindingName)
        return "globalThis[Symbol.for(\(symbol))] = \(name);"
    }

    static func signal(
        from envelope: CDPEnvelope,
        expectedBindingName: String,
        expectedGeneration: String
    ) -> SkinRuntimeBindingSignal? {
        guard envelope.method == "Runtime.bindingCalled",
              let params = envelope.params,
              params["name"]?.stringValue == expectedBindingName,
              let payloadText = params["payload"]?.stringValue,
              !payloadText.isEmpty,
              payloadText.utf8.count <= maximumPayloadBytes,
              let payloadData = payloadText.data(using: .utf8),
              let payloadObject = try? JSONSerialization.jsonObject(with: payloadData),
              let payloadDictionary = payloadObject as? [String: Any],
              Set(payloadDictionary.keys) == Set(["schemaVersion", "event", "generation"]),
              let payload = try? JSONDecoder().decode(
                  SkinRuntimeBindingPayload.self,
                  from: payloadData
              ),
              payload.schemaVersion == schemaVersion,
              [eventName, rendererNotReadyEventName, runtimeInstallFailedEventName]
                  .contains(payload.event),
              payload.generation == expectedGeneration,
              isValidGeneration(payload.generation)
        else {
            return nil
        }
        return SkinRuntimeBindingSignal(generation: payload.generation, event: payload.event)
    }

    static func reportJavaScript(
        generation: String,
        bindingName: String,
        event: String = eventName
    ) throws -> String {
        guard [eventName, rendererNotReadyEventName, runtimeInstallFailedEventName]
            .contains(event)
        else {
            throw SkinError.invalidConfiguration("非法 renderer runtime signal 类型。")
        }
        let name = try javaScriptStringLiteral(bindingName)
        let payloadData = try JSONEncoder().encode(
            SkinRuntimeBindingPayload(
                schemaVersion: schemaVersion,
                event: event,
                generation: generation
            )
        )
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw SkinError.invalidConfiguration("无法编码 renderer runtime signal。")
        }
        let payload = try javaScriptStringLiteral(payloadText)
        return """
        (() => {
          const binding = globalThis[\(name)];
          if (typeof binding !== "function") return;
          try { binding(\(payload)); } catch (_) {}
        })();
        """
    }

    private static func javaScriptStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw SkinError.invalidConfiguration("无法编码 renderer runtime binding。")
        }
        return literal
    }

    private static func isValidGeneration(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

protocol SkinInjecting: Sendable {
    func install(
        port: Int,
        theme: LoadedTheme,
        verifiedBundle: VerifiedChatGPTBundle,
        registry: StructuralAdapterRegistry
    ) async throws -> SkinInjectionHandle

    func restore() async throws
    func snapshot() async -> SkinInjectionSnapshot?
}

struct SkinInjectionResources: Sendable {
    let bootstrapJavaScript: String
    let cleanupJavaScript: String

    static func live(bundle: Bundle = .main) throws -> SkinInjectionResources {
        func read(_ name: String) throws -> String {
            let candidates = [
                bundle.url(forResource: name, withExtension: "js", subdirectory: "Injected"),
                bundle.url(forResource: name, withExtension: "js", subdirectory: "Resources/Injected"),
                bundle.url(forResource: name, withExtension: "js"),
            ]
            guard let url = candidates.compactMap({ $0 }).first else {
                throw SkinError.invalidConfiguration("应用资源缺少 \(name).js")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        return try SkinInjectionResources(
            bootstrapJavaScript: read("bootstrap"),
            cleanupJavaScript: read("cleanup")
        )
    }
}

enum SkinNewDocumentScriptCleanupDisposition: Sendable, Equatable {
    case notRequired
    case remove(identifier: String)
    case uncertain
}

struct SkinInstallFailureCleanupTracker: Sendable, Equatable {
    var rendererMutationAttempted = false
    var runtimeBindingName: String?
    var newDocumentScriptRequestSent = false
    var newDocumentScriptIdentifier: String?

    var newDocumentScriptDisposition: SkinNewDocumentScriptCleanupDisposition {
        guard newDocumentScriptRequestSent else { return .notRequired }
        guard let newDocumentScriptIdentifier,
              !newDocumentScriptIdentifier.isEmpty
        else {
            return .uncertain
        }
        return .remove(identifier: newDocumentScriptIdentifier)
    }
}

enum SkinCleanupVerificationPolicy {
    static func expression(runtimeBindingName: String?) throws -> String {
        let bindingNameLiteral: String
        if let runtimeBindingName {
            let encoded = try JSONEncoder().encode(runtimeBindingName)
            guard let literal = String(data: encoded, encoding: .utf8) else {
                throw SkinError.invalidConfiguration(
                    "无法编码 cleanup runtime binding 名称。"
                )
            }
            bindingNameLiteral = literal
        } else {
            bindingNameLiteral = "null"
        }

        return #"""
            (() => {
              const runtimeBindingName = \#(bindingNameLiteral);
              return ({
                remainingOwnedNodes: document.querySelectorAll("[data-zuuzii-skin-owner]").length,
                statePresent: Object.prototype.hasOwnProperty.call(
                  globalThis,
                  Symbol.for("com.zuuzii.chatgpt-skin.state")
                ),
                reloadPresent: Object.prototype.hasOwnProperty.call(
                  globalThis,
                  Symbol.for("com.zuuzii.chatgpt-skin.reload")
                ),
                payloadPresent: Object.prototype.hasOwnProperty.call(
                  globalThis,
                  Symbol.for("com.zuuzii.chatgpt-skin.payload")
                ),
                bindingNamePresent: Object.prototype.hasOwnProperty.call(
                  globalThis,
                  Symbol.for("com.zuuzii.chatgpt-skin.runtime-binding-name")
                ),
                runtimeBindingPresent: Boolean(
                  typeof runtimeBindingName === "string"
                    && Object.prototype.hasOwnProperty.call(globalThis, runtimeBindingName)
                ),
              });
            })()
            """#
    }

    static func validate(_ verification: [String: JSONValue]) throws {
        guard verification["remainingOwnedNodes"]?.integerValue == 0,
              verification["statePresent"]?.boolValue == false,
              verification["reloadPresent"]?.boolValue == false,
              verification["payloadPresent"]?.boolValue == false,
              verification["bindingNamePresent"]?.boolValue == false,
              verification["runtimeBindingPresent"]?.boolValue == false
        else {
            throw SkinError.protocolFailure("皮肤 cleanup 后仍有增强状态残留。")
        }
    }
}

enum SkinCleanupResultPolicy {
    static func validate(_ result: [String: JSONValue]) throws {
        guard case .array(let failures)? = result["failures"] else {
            throw SkinError.protocolFailure(
                "cleanup.js 未返回可审计的 teardown failures。"
            )
        }
        guard result["ok"]?.boolValue == true, failures.isEmpty else {
            let details = failures.prefix(8).compactMap { failure -> String? in
                guard case .object(let object) = failure else { return nil }
                let step = object["step"]?.stringValue ?? "unknown"
                let message = object["message"]?.stringValue ?? "unknown error"
                return "\(step): \(message)"
            }
            let suffix = details.isEmpty
                ? "cleanup.js 报告 teardown 失败。"
                : details.joined(separator: "；")
            throw SkinError.protocolFailure(suffix)
        }
    }
}

enum SkinInstallProbeDisposition: Equatable {
    case installed
    case pending
    case hardFailure
}

enum SkinInstallProbePolicy {
    static func disposition(_ result: [String: JSONValue]) -> SkinInstallProbeDisposition {
        if result["ok"]?.boolValue == true,
            result["failClosed"]?.boolValue == false,
            result["pending"]?.boolValue == false
        {
            return .installed
        }
        if result["ok"]?.boolValue == false,
            result["failClosed"]?.boolValue == false,
            result["pending"]?.boolValue == true,
            ["renderer-not-ready", "asset-render-pending"]
                .contains(result["reason"]?.stringValue ?? "")
        {
            return .pending
        }
        return .hardFailure
    }

    static func pendingTimeoutMessage(_ result: [String: JSONValue]) -> String {
        if result["reason"]?.stringValue == "asset-render-pending" {
            return "主题图片解码超时；已停止应用皮肤，不会把纯色回退误报为 Full 成功。"
        }
        let rawPath = structuralString(result["rawPath"], fallback: "unknown")
        let path = structuralString(result["path"], fallback: "unknown")
        let routeID = structuralString(result["routeID"], fallback: "unclassified")
        let viewportWidth = result["viewportWidth"]?.integerValue.map(String.init) ?? "unknown"
        let entryScriptMatchCount =
            result["entryScriptMatchCount"]?.integerValue.map(String.init) ?? "unknown"

        let counts = (result["counts"]?.objectValue ?? [:])
            .compactMap { key, value -> String? in
                guard let count = value.integerValue else { return nil }
                return "\(key)=\(count)"
            }
            .sorted()
            .joined(separator: ",")

        let failures: String
        if case .array(let values)? = result["failures"] {
            failures = values.compactMap { value -> String? in
                guard let failure = value.objectValue,
                    let id = failure["id"]?.stringValue,
                    let severity = failure["severity"]?.stringValue,
                    let actualCount = failure["actualCount"]?.integerValue,
                    let minimumCount = failure["minimumCount"]?.integerValue
                else {
                    return nil
                }
                let maximumCount = failure["maximumCount"]?.integerValue.map(String.init) ?? "none"
                return "\(id):\(severity):\(actualCount)/\(minimumCount)/\(maximumCount)"
            }
            .sorted()
            .joined(separator: ",")
        } else {
            failures = ""
        }

        return "renderer-not-ready 超时：rawPath=\(rawPath); path=\(path); routeID=\(routeID); "
            + "viewportWidth=\(viewportWidth); entryScriptMatchCount=\(entryScriptMatchCount); "
            + "counts=[\(counts)]; failures=[\(failures)]"
    }

    static func pendingTimeoutError(_ result: [String: JSONValue]) -> SkinError {
        .timedOut(pendingTimeoutMessage(result))
    }

    static func hardFailureError(_ result: [String: JSONValue]) -> SkinError {
        let reason = structuralString(result["reason"], fallback: "adapter probe failed")
        let detail = structuralString(result["detail"], fallback: "")
        let message = detail.isEmpty ? reason : "\(reason): \(detail)"
        if result["failClosed"]?.boolValue == true,
            reason == "adapter-probe-failed"
        {
            return .incompatibleApp("ChatGPT renderer 结构与当前 adapter 不兼容。\(message)")
        }
        if reason == "asset-render-failed" {
            return .injectionFailed("主题图片渲染失败，已停止应用并回退到原生界面。")
        }
        if reason == "render-verification-failed" {
            return .injectionFailed("主题样式未能在 ChatGPT renderer 中完整生效，已停止应用并回退到原生界面。")
        }
        return .injectionFailed(message)
    }

    static func unconfirmedStructuralFailureError() -> SkinError {
        .timedOut(
            "ChatGPT renderer 启动期结构探测未能连续确认；已停止应用，"
                + "本次结果不会判定为不兼容。"
        )
    }

    static func structuralFailureSignature(
        _ result: [String: JSONValue]
    ) -> String? {
        guard result["failClosed"]?.boolValue == true,
              result["reason"]?.stringValue == "adapter-probe-failed"
        else {
            return nil
        }

        return contentBlindStructuralFailureSignature(result)
    }

    static func directStructuralProbeFailureSignature(
        _ result: [String: JSONValue]
    ) -> String? {
        guard let adapterID = result["adapterId"]?.stringValue,
              !adapterID.isEmpty,
              result["ok"]?.boolValue == false,
              result["failClosed"]?.boolValue == true,
              result["pending"]?.boolValue == false
        else {
            return nil
        }

        return contentBlindStructuralFailureSignature(result)
    }

    private static func contentBlindStructuralFailureSignature(
        _ result: [String: JSONValue]
    ) -> String {

        let routeID = structuralString(result["routeID"], fallback: "unclassified")
        let viewportWidth = result["viewportWidth"]?.integerValue.map(String.init) ?? "unknown"
        let entryScriptMatchCount =
            result["entryScriptMatchCount"]?.integerValue.map(String.init) ?? "unknown"
        let counts = (result["counts"]?.objectValue ?? [:])
            .compactMap { key, value -> String? in
                guard let count = value.integerValue else { return nil }
                return "\(key)=\(count)"
            }
            .sorted()
            .joined(separator: ",")
        let failures: String
        if case .array(let values)? = result["failures"] {
            failures = values.compactMap { value -> String? in
                guard let failure = value.objectValue,
                      let id = failure["id"]?.stringValue,
                      let severity = failure["severity"]?.stringValue,
                      let actualCount = failure["actualCount"]?.integerValue,
                      let minimumCount = failure["minimumCount"]?.integerValue
                else {
                    return nil
                }
                let maximumCount = failure["maximumCount"]?.integerValue.map(String.init) ?? "none"
                return "\(id):\(severity):\(actualCount)/\(minimumCount)/\(maximumCount)"
            }
            .sorted()
            .joined(separator: ",")
        } else {
            failures = ""
        }

        return "route=\(routeID)|width=\(viewportWidth)|entry=\(entryScriptMatchCount)"
            + "|counts=\(counts)|failures=\(failures)"
    }

    private static func structuralString(_ value: JSONValue?, fallback: String) -> String {
        guard let value = value?.stringValue, !value.isEmpty else { return fallback }
        return String(value.prefix(256))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

struct SkinStructuralFailureConfirmation {
    static let requiredConsecutiveMatches = 3
    static let minimumObservationDuration: Duration = .seconds(1)

    private(set) var consecutiveMatches = 0
    private(set) var lastSignature: String?

    mutating func record(_ result: [String: JSONValue]) -> Bool {
        guard let signature = SkinInstallProbePolicy.structuralFailureSignature(result) else {
            reset()
            return false
        }
        if lastSignature == signature {
            consecutiveMatches += 1
        } else {
            lastSignature = signature
            consecutiveMatches = 1
        }
        return consecutiveMatches >= Self.requiredConsecutiveMatches
    }

    mutating func reset() {
        consecutiveMatches = 0
        lastSignature = nil
    }
}

enum SkinReloadScriptBuilder {
    static func make(
        bootstrap: String,
        initialInstallExpression: String,
        generation: String,
        bindingName: String
    ) throws -> String {
        let configuration = try SkinRuntimeBindingPolicy.configurationJavaScript(
            bindingName: bindingName
        )
        let reportIncompatibility = try SkinRuntimeBindingPolicy.reportJavaScript(
            generation: generation,
            bindingName: bindingName
        )
        let reportRendererNotReady = try SkinRuntimeBindingPolicy.reportJavaScript(
            generation: generation,
            bindingName: bindingName,
            event: SkinRuntimeBindingPolicy.rendererNotReadyEventName
        )
        let reportRuntimeInstallFailed = try SkinRuntimeBindingPolicy.reportJavaScript(
            generation: generation,
            bindingName: bindingName,
            event: SkinRuntimeBindingPolicy.runtimeInstallFailedEventName
        )
        let resumeExpression = try SkinInstallResumeScriptBuilder.make(
            generation: generation
        )
        return """
        (() => {
          const isWindowContext = typeof globalThis.window !== "undefined"
            && globalThis.window === globalThis;
          if (isWindowContext) {
            try {
              if (globalThis.top !== globalThis) return;
            } catch (_) {
              return;
            }
          }

          \(configuration)
          \(bootstrap)
          (() => {
          const reloadSymbol = Symbol.for("com.zuuzii.chatgpt-skin.reload");
          const stateSymbol = Symbol.for("com.zuuzii.chatgpt-skin.state");
          const payloadSymbol = Symbol.for("com.zuuzii.chatgpt-skin.payload");
          const ownerAttribute = "data-zuuzii-skin-owner";
          const previousReload = globalThis[reloadSymbol];
          if (typeof previousReload?.cancel === "function") {
            try { previousReload.cancel("replace-reload-loop"); } catch (_) {}
          }

          let attempt = 0;
          const reloadState = {
            active: true,
            generation: \(try javaScriptStringLiteral(generation)),
            timeoutID: null,
            domReadyListener: null,
            cancel(reason = "cancelled") {
              if (!this.active) return false;
              this.active = false;
              if (this.timeoutID !== null) {
                globalThis.clearTimeout(this.timeoutID);
                this.timeoutID = null;
              }
              if (this.domReadyListener !== null) {
                document.removeEventListener("DOMContentLoaded", this.domReadyListener);
                this.domReadyListener = null;
              }
              if (globalThis[reloadSymbol] === this) delete globalThis[reloadSymbol];
              return true;
            },
          };
          globalThis[reloadSymbol] = reloadState;

          const cleanupInstalledSkin = (reason) => {
            const state = globalThis[stateSymbol];
            if (typeof state?.cleanup === "function") {
              try { state.cleanup(reason); } catch (_) {}
            }
            for (const node of document.querySelectorAll(`[${ownerAttribute}]`)) {
              try { node.remove(); } catch (_) {}
            }
            if (globalThis[stateSymbol] === state) delete globalThis[stateSymbol];
            try { delete globalThis[payloadSymbol]; } catch (_) {}
          };

          const installWhenReady = () => {
            if (!reloadState.active || globalThis[reloadSymbol] !== reloadState) return;
            attempt += 1;
            const result = (() => {
              try {
                return attempt === 1
                  ? \(initialInstallExpression)
                  : \(resumeExpression);
              } catch (_) {
                return { ok: false, failClosed: true, pending: false, reason: "reload-install-exception" };
              }
            })();
            if (
              result?.ok === true
              && result?.failClosed === false
              && result?.pending === false
            ) {
              reloadState.cancel("installed");
              return;
            }
            const retryablePending = result?.ok === false
              && result?.failClosed === false
              && result?.pending === true
              && ["renderer-not-ready", "asset-render-pending"].includes(result?.reason);
            if (!retryablePending) {
              cleanupInstalledSkin("reload-install-failed");
              reloadState.cancel("reload-install-failed");
              if (result?.failClosed === true && result?.reason === "adapter-probe-failed") {
                \(reportIncompatibility)
              } else {
                \(reportRuntimeInstallFailed)
              }
              return;
            }
            if (attempt >= 80) {
              cleanupInstalledSkin("reload-install-timeout");
              reloadState.cancel("reload-install-timeout");
              if (result?.reason === "renderer-not-ready") {
                \(reportRendererNotReady)
              } else {
                \(reportRuntimeInstallFailed)
              }
              return;
            }
            reloadState.timeoutID = globalThis.setTimeout(() => {
              reloadState.timeoutID = null;
              installWhenReady();
            }, 150);
          };
          if (document.readyState === "loading") {
            reloadState.domReadyListener = () => {
              reloadState.domReadyListener = null;
              installWhenReady();
            };
            document.addEventListener(
              "DOMContentLoaded",
              reloadState.domReadyListener,
              { once: true }
            );
          } else {
            installWhenReady();
          }
          })();
        })();
        """
    }

    private static func javaScriptStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw SkinError.invalidConfiguration("无法编码 reload generation。")
        }
        return literal
    }
}

enum SkinInstallResumeScriptBuilder {
    static func make(generation: String) throws -> String {
        let literal = try javaScriptStringLiteral(generation)
        return """
        globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
          { resumeGeneration: \(literal) }
        )
        """
    }

    private static func javaScriptStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw SkinError.invalidConfiguration("无法编码 install resume generation。")
        }
        return literal
    }
}

struct SkinRuntimeRevalidationInstallPlan: Equatable {
    struct Attempt: Equatable {
        let expression: String
        let retryExpression: String
    }

    let initialInstallExpression: String
    let resumeExpression: String

    func scripts(forAttempt attempt: Int) -> Attempt {
        Attempt(
            expression: attempt == 1 ? initialInstallExpression : resumeExpression,
            retryExpression: resumeExpression
        )
    }
}

enum ChatGPTRendererTargetPolicy {
    static func candidates(from targets: [CDPTarget]) -> [CDPTarget] {
        targets.filter { target in
            guard target.type == "page",
                  target.webSocketDebuggerUrl != nil,
                  let components = URLComponents(string: target.url)
            else {
                return false
            }
            return components.scheme?.lowercased() == "app"
        }
    }
}

protocol RendererStructuralProbeEvaluating: Sendable {
    func observations(
        targets: [CDPTarget],
        adapters: [any ChatGPTAdapter]
    ) async -> [StructuralAdapterProbeObservation]
}

struct CDPRendererStructuralProbeEvaluator: RendererStructuralProbeEvaluating {
    func observations(
        targets: [CDPTarget],
        adapters: [any ChatGPTAdapter]
    ) async -> [StructuralAdapterProbeObservation] {
        var collectedObservations: [StructuralAdapterProbeObservation] = []
        for target in targets {
            guard let endpointValue = target.webSocketDebuggerUrl,
                  let endpoint = URL(string: endpointValue)
            else {
                collectedObservations.append(
                    contentsOf: indeterminateObservations(
                        target: target,
                        adapters: adapters
                    )
                )
                continue
            }
            let targetObservations = await observations(
                target: target,
                endpoint: endpoint,
                adapters: adapters
            )
            collectedObservations.append(contentsOf: targetObservations)
        }
        return collectedObservations
    }

    private func observations(
        target: CDPTarget,
        endpoint: URL,
        adapters: [any ChatGPTAdapter]
    ) async -> [StructuralAdapterProbeObservation] {
        let session: CDPWebSocketSession
        do {
            session = try CDPWebSocketSession(endpoint: endpoint)
        } catch {
            return indeterminateObservations(target: target, adapters: adapters)
        }
        do {
            try await session.connect(timeout: .seconds(2))
            _ = try await session.command("Runtime.enable", timeout: .seconds(3))
        } catch {
            await session.close()
            return indeterminateObservations(target: target, adapters: adapters)
        }

        var observations: [StructuralAdapterProbeObservation] = []
        for adapter in adapters {
            do {
                let probe = try adapter.makeProbeJavaScript()
                let response = try await session.command(
                    "Runtime.evaluate",
                    params: [
                        "expression": .string("\(probe)()"),
                        "returnByValue": .bool(true),
                        "awaitPromise": .bool(true),
                        "userGesture": .bool(false),
                    ],
                    timeout: .seconds(3)
                )
                guard response["exceptionDetails"] == nil,
                      let remoteObject = response["result"]?.objectValue,
                      let result = remoteObject["value"]?.objectValue,
                      let routeID = result["routeID"]?.stringValue
                else {
                    observations.append(
                        indeterminateObservation(target: target, adapter: adapter)
                    )
                    continue
                }

                let readiness: StructuralAdapterProbeReadiness
                switch SkinInstallProbePolicy.disposition(result) {
                case .installed:
                    readiness = .ready
                case .pending:
                    readiness = .pending
                case .hardFailure:
                    readiness = .rejected
                }
                let route = adapter.manifest.routeCapabilities.first(where: {
                    $0.id == routeID
                })
                if route?.rendererTargetRole == .auxiliary {
                    continue
                }
                guard readiness == .rejected || route?.rendererTargetRole == .primary else {
                    continue
                }
                observations.append(
                    StructuralAdapterProbeObservation(
                        target: target,
                        adapter: adapter,
                        readiness: readiness,
                        structuralFailureSignature:
                            SkinInstallProbePolicy
                            .directStructuralProbeFailureSignature(result)
                    )
                )
            } catch {
                observations.append(
                    indeterminateObservation(target: target, adapter: adapter)
                )
            }
        }
        await session.close()
        return observations
    }

    private func indeterminateObservations(
        target: CDPTarget,
        adapters: [any ChatGPTAdapter]
    ) -> [StructuralAdapterProbeObservation] {
        adapters.map { adapter in
            indeterminateObservation(target: target, adapter: adapter)
        }
    }

    private func indeterminateObservation(
        target: CDPTarget,
        adapter: any ChatGPTAdapter
    ) -> StructuralAdapterProbeObservation {
        StructuralAdapterProbeObservation(
            target: target,
            adapter: adapter,
            readiness: .indeterminate,
            structuralFailureSignature: nil
        )
    }
}

actor SkinInjector: SkinInjecting {
    private struct ActiveInjection {
        let session: CDPWebSocketSession
        let newDocumentScriptIdentifier: String
        let runtimeBindingName: String
        let eventHandlerIdentifier: UUID
        let connectionMonitorTask: Task<Void, Never>
        let initialInstallExpression: String
        let resumeExpression: String
        let invalidationContinuation: AsyncStream<SkinRuntimeInvalidation>.Continuation
        let snapshot: SkinInjectionSnapshot
    }

    private let discoveryClient: CDPDiscoveryClient
    private let structuralProbeEvaluator: any RendererStructuralProbeEvaluating
    private let cssRenderer: SkinCSSRenderer
    private let resources: SkinInjectionResources
    private var activeInjection: ActiveInjection?
    private var installingGeneration: String?
    private var pendingRuntimeSignal: SkinRuntimeBindingSignal?
    private var runtimeRevalidationGeneration: String?
    private var runtimeRevalidationTask: Task<Void, Never>?
    private var terminalInvalidationGeneration: String?
    private var cleanupInProgress = false

    init(
        discoveryClient: CDPDiscoveryClient = CDPDiscoveryClient(),
        structuralProbeEvaluator: any RendererStructuralProbeEvaluating =
            CDPRendererStructuralProbeEvaluator(),
        cssRenderer: SkinCSSRenderer = SkinCSSRenderer(),
        resources: SkinInjectionResources? = nil
    ) {
        self.discoveryClient = discoveryClient
        self.structuralProbeEvaluator = structuralProbeEvaluator
        self.cssRenderer = cssRenderer
        self.resources =
            resources ?? (try? .live())
            ?? SkinInjectionResources(
                bootstrapJavaScript: "",
                cleanupJavaScript: ""
            )
    }

    func install(
        port: Int,
        theme: LoadedTheme,
        verifiedBundle: VerifiedChatGPTBundle,
        registry: StructuralAdapterRegistry
    ) async throws -> SkinInjectionHandle {
        guard !cleanupInProgress else {
            throw SkinError.cleanupFailed("已有皮肤 cleanup 尚未完成，拒绝叠加 install。")
        }
        guard !resources.bootstrapJavaScript.isEmpty, !resources.cleanupJavaScript.isEmpty else {
            throw SkinError.invalidConfiguration("注入资源未正确打包。")
        }
        let compatibleAdapters = try registry.compatibleAdapters(
            themeCompatibility: theme.manifest.compatibility,
            verifiedBundle: verifiedBundle
        )

        if activeInjection != nil {
            try await restore()
        }

        let selection = try await waitForRendererSelection(
            port: port,
            registry: registry,
            adapters: compatibleAdapters
        )
        let target = selection.target
        let adapter = selection.adapter
        try ChatGPTSkinCompatibilityPolicy.validate(
            adapter: adapter,
            themeCompatibility: theme.manifest.compatibility,
            verifiedBundle: verifiedBundle
        )
        guard let endpointValue = target.webSocketDebuggerUrl,
            let endpoint = URL(string: endpointValue)
        else {
            throw CDPClientError.invalidEndpoint(target.webSocketDebuggerUrl ?? "missing")
        }

        let session = try CDPWebSocketSession(endpoint: endpoint)
        do {
            try await session.connect()
        } catch {
            await session.close()
            throw error
        }

        var eventHandlerIdentifier: UUID?
        var invalidationContinuation: AsyncStream<SkinRuntimeInvalidation>.Continuation?
        var connectionMonitorTask: Task<Void, Never>?
        var cleanupTracker = SkinInstallFailureCleanupTracker()

        do {
            _ = try await session.command("Runtime.enable")
            _ = try await session.command("Page.enable")

            let renderedSkin = try cssRenderer.render(theme: theme)
            let generation = UUID().uuidString.lowercased()
            let bindingName = SkinRuntimeBindingPolicy.makeBindingName(
                generation: generation
            )
            let invalidationPair = AsyncStream<SkinRuntimeInvalidation>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            invalidationContinuation = invalidationPair.continuation
            installingGeneration = generation
            pendingRuntimeSignal = nil
            terminalInvalidationGeneration = nil

            let installExpression = try adapter.makeInstallJavaScript(
                generation: generation,
                themeID: theme.manifest.id,
                themeName: theme.manifest.name,
                css: renderedSkin.css,
                hero: renderedSkin.hero,
                brand: theme.manifest.brand,
                icons: theme.manifest.icons,
                texts: theme.manifest.texts
            )
            let resumeExpression = try SkinInstallResumeScriptBuilder.make(
                generation: generation
            )

            let handlerIdentifier = await session.addEventHandler { [weak self] envelope in
                guard let signal = SkinRuntimeBindingPolicy.signal(
                    from: envelope,
                    expectedBindingName: bindingName,
                    expectedGeneration: generation
                ) else {
                    return
                }
                await self?.receiveRuntimeSignal(signal)
            }
            eventHandlerIdentifier = handlerIdentifier

            cleanupTracker.runtimeBindingName = bindingName
            _ = try await session.command(
                "Runtime.addBinding",
                params: ["name": .string(bindingName)]
            )

            let bindingConfiguration = try SkinRuntimeBindingPolicy
                .configurationJavaScript(bindingName: bindingName)
            cleanupTracker.rendererMutationAttempted = true
            _ = try await evaluate(
                session: session,
                expression: bindingConfiguration,
                requireObjectValue: false
            )

            _ = try await evaluate(
                session: session,
                expression: resources.bootstrapJavaScript,
                requireObjectValue: false
            )

            let installResult = try await installWhenRendererReady(
                session: session,
                expression: installExpression,
                retryExpression: resumeExpression,
                confirmStructuralHardFailures: true
            )
            guard SkinInstallProbePolicy.disposition(installResult) == .installed,
                installResult["ok"]?.boolValue == true,
                installResult["failClosed"]?.boolValue == false,
                installResult["pending"]?.boolValue == false,
                let routeID = installResult["routeID"]?.stringValue,
                let modeValue = installResult["effectiveMode"]?.stringValue,
                let mode = ChatGPTSkinRouteMode(rawValue: modeValue)
            else {
                throw SkinInstallProbePolicy.hardFailureError(installResult)
            }

            let reloadSource = try SkinReloadScriptBuilder.make(
                bootstrap: resources.bootstrapJavaScript,
                initialInstallExpression: installExpression,
                generation: generation,
                bindingName: bindingName
            )
            cleanupTracker.newDocumentScriptRequestSent = true
            let addResult = try await session.command(
                "Page.addScriptToEvaluateOnNewDocument",
                params: ["source": .string(reloadSource)],
                timeout: .seconds(8)
            )
            guard let scriptIdentifier = addResult["identifier"]?.stringValue,
                !scriptIdentifier.isEmpty
            else {
                throw SkinError.injectionFailed("无法建立 renderer reload 恢复脚本。")
            }
            cleanupTracker.newDocumentScriptIdentifier = scriptIdentifier

            let snapshot = SkinInjectionSnapshot(
                generation: generation,
                themeID: theme.manifest.id,
                appBuild: verifiedBundle.buildVersion,
                targetID: target.id,
                routeID: routeID,
                effectiveMode: mode
            )
            let connectionTerminations = await session.connectionTerminations()
            let monitorTask = Task { [weak self] in
                for await termination in connectionTerminations {
                    guard !Task.isCancelled else { return }
                    switch termination {
                    case .unexpectedClosure:
                        await self?.receiveConnectionTermination(generation: generation)
                    }
                }
            }
            connectionMonitorTask = monitorTask
            activeInjection = ActiveInjection(
                session: session,
                newDocumentScriptIdentifier: scriptIdentifier,
                runtimeBindingName: bindingName,
                eventHandlerIdentifier: handlerIdentifier,
                connectionMonitorTask: monitorTask,
                initialInstallExpression: installExpression,
                resumeExpression: resumeExpression,
                invalidationContinuation: invalidationPair.continuation,
                snapshot: snapshot
            )
            installingGeneration = nil
            if pendingRuntimeSignal?.generation == generation {
                pendingRuntimeSignal = nil
                beginRuntimeRevalidation(generation: generation)
            }
            return SkinInjectionHandle(
                snapshot: snapshot,
                invalidations: invalidationPair.stream
            )
        } catch {
            let primaryError = error
            installingGeneration = nil
            pendingRuntimeSignal = nil
            runtimeRevalidationTask?.cancel()
            runtimeRevalidationTask = nil
            runtimeRevalidationGeneration = nil
            terminalInvalidationGeneration = nil
            connectionMonitorTask?.cancel()
            invalidationContinuation?.finish()
            cleanupInProgress = true
            let cleanupResources = resources
            let cleanupTrackerSnapshot = cleanupTracker
            let cleanupEventHandlerIdentifier = eventHandlerIdentifier
            let cleanupFailures = await Task.detached {
                await Self.performStrictCleanup(
                    session: session,
                    resources: cleanupResources,
                    tracker: cleanupTrackerSnapshot,
                    eventHandlerIdentifier: cleanupEventHandlerIdentifier
                )
            }.value
            cleanupInProgress = false
            guard cleanupFailures.isEmpty else {
                throw SkinError.cleanupFailed(
                    Self.installCleanupFailureDescription(
                        primary: primaryError,
                        cleanupFailures: cleanupFailures
                    )
                )
            }
            throw primaryError
        }
    }

    func restore() async throws {
        guard !cleanupInProgress else {
            throw SkinError.cleanupFailed("已有皮肤 cleanup 尚未完成，状态无法确认。")
        }
        guard let activeInjection else { return }
        cleanupInProgress = true
        self.activeInjection = nil
        activeInjection.connectionMonitorTask.cancel()
        installingGeneration = nil
        pendingRuntimeSignal = nil
        runtimeRevalidationTask?.cancel()
        runtimeRevalidationTask = nil
        runtimeRevalidationGeneration = nil
        terminalInvalidationGeneration = nil
        activeInjection.invalidationContinuation.finish()
        let cleanupResources = resources
        let cleanupTracker = SkinInstallFailureCleanupTracker(
            rendererMutationAttempted: true,
            runtimeBindingName: activeInjection.runtimeBindingName,
            newDocumentScriptRequestSent: true,
            newDocumentScriptIdentifier: activeInjection.newDocumentScriptIdentifier
        )
        let cleanupSession = activeInjection.session
        let cleanupEventHandlerIdentifier = activeInjection.eventHandlerIdentifier
        let cleanupFailures = await Task.detached {
            await Self.performStrictCleanup(
                session: cleanupSession,
                resources: cleanupResources,
                tracker: cleanupTracker,
                eventHandlerIdentifier: cleanupEventHandlerIdentifier
            )
        }.value
        cleanupInProgress = false
        guard cleanupFailures.isEmpty else {
            throw SkinError.cleanupFailed(
                "皮肤 cleanup 无法确认零残留：\(cleanupFailures.joined(separator: "；"))"
            )
        }
    }

    private static func performStrictCleanup(
        session: CDPWebSocketSession,
        resources: SkinInjectionResources,
        tracker: SkinInstallFailureCleanupTracker,
        eventHandlerIdentifier: UUID?
    ) async -> [String] {
        var failures: [String] = []

        if let eventHandlerIdentifier {
            await session.removeEventHandler(eventHandlerIdentifier)
        }

        switch tracker.newDocumentScriptDisposition {
        case .notRequired:
            break
        case .remove(let identifier):
            do {
                _ = try await session.command(
                    "Page.removeScriptToEvaluateOnNewDocument",
                    params: ["identifier": .string(identifier)]
                )
            } catch {
                failures.append(
                    "renderer reload script 移除失败：\(error.localizedDescription)"
                )
            }
        case .uncertain:
            failures.append(
                "Page.addScriptToEvaluateOnNewDocument 请求结果不确定，缺少可撤销 identifier"
            )
        }

        if tracker.rendererMutationAttempted {
            do {
                let cleanupResult = try await evaluateCommand(
                    session: session,
                    expression: resources.cleanupJavaScript,
                    requireObjectValue: true
                )
                try SkinCleanupResultPolicy.validate(cleanupResult)
            } catch {
                failures.append("cleanup.js 执行失败：\(error.localizedDescription)")
            }
        }

        if let runtimeBindingName = tracker.runtimeBindingName {
            do {
                _ = try await session.command(
                    "Runtime.removeBinding",
                    params: ["name": .string(runtimeBindingName)]
                )
            } catch {
                failures.append(
                    "runtime binding 移除失败：\(error.localizedDescription)"
                )
            }
        }

        do {
            let verification = try await evaluateCommand(
                session: session,
                expression: try SkinCleanupVerificationPolicy.expression(
                    runtimeBindingName: tracker.runtimeBindingName
                ),
                requireObjectValue: true
            )
            try SkinCleanupVerificationPolicy.validate(verification)
        } catch {
            failures.append("零残留验证失败：\(error.localizedDescription)")
        }

        await session.close()
        return failures
    }

    private static func installCleanupFailureDescription(
        primary: Error,
        cleanupFailures: [String]
    ) -> String {
        "皮肤安装失败：\(primary.localizedDescription)；失败清理无法确认零残留："
            + cleanupFailures.joined(separator: "；")
    }

    func snapshot() -> SkinInjectionSnapshot? {
        activeInjection?.snapshot
    }

    func captureScreenshotPNG() async throws -> Data {
        guard let activeInjection else {
            throw SkinError.protocolFailure("当前没有可截图的皮肤会话。")
        }
        let result = try await activeInjection.session.command(
            "Page.captureScreenshot",
            params: [
                "format": .string("png"),
                "fromSurface": .bool(true),
                "captureBeyondViewport": .bool(false),
            ],
            timeout: .seconds(12)
        )
        guard let encoded = result["data"]?.stringValue,
            let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
            data.count >= 8,
            data.count <= 32 * 1_024 * 1_024,
            Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        else {
            throw SkinError.protocolFailure("CDP 未返回有效的 PNG 截图。")
        }
        return data
    }

    func runDiagnostics() async throws -> SkinRuntimeDiagnostics {
        guard let activeInjection else {
            throw SkinError.protocolFailure("当前没有可诊断的皮肤会话。")
        }
        let result = try await evaluate(
            session: activeInjection.session,
            expression: #"""
                (() => {
                  const owned = Array.from(document.querySelectorAll("[data-zuuzii-skin-owner]"));
                  const overlays = owned.filter((node) => node.matches("[data-zuuzii-skin-overlay]"));
                  const styles = owned.filter((node) => node.matches("style[data-zuuzii-skin-role='style']"));
                  const overlay = overlays[0] || null;
                  const hero = overlay?.querySelector(
                    ":scope > [data-zuuzii-skin-role='hero']"
                  ) || null;
                  const heroStyle = hero ? globalThis.getComputedStyle(hero) : null;
                  const composer = document.querySelector("[data-codex-composer-root]");
                  const focusCandidate = composer?.querySelector(
                    "textarea, input:not([type='hidden']), [contenteditable='true'], [tabindex='0']"
                  ) || null;
                  focusCandidate?.focus();
                  const activeElement = document.activeElement;
                  return {
                    ownedNodeCount: owned.length,
                    overlayCount: overlays.length,
                    styleCount: styles.length,
                    ownedGeneration: overlay?.getAttribute("data-zuuzii-skin-owner") || "missing",
                    ownedThemeID: overlay?.dataset.themeId || "missing",
                    heroState: overlay?.dataset.heroState || "missing",
                    heroImageState: hero?.dataset.imageState || "missing",
                    heroObjectPosition: heroStyle?.objectPosition || "missing",
                    overlayPointerEventsNone: Boolean(
                      overlay && globalThis.getComputedStyle(overlay).pointerEvents === "none"
                    ),
                    overlayAriaHidden: overlay?.getAttribute("aria-hidden") === "true",
                    overlayInert: Boolean(overlay?.hasAttribute("inert")),
                    composerFocusAccepted: Boolean(
                      focusCandidate && (activeElement === focusCandidate || composer?.contains(activeElement))
                    ),
                    routeID: overlay?.dataset.routeId || "missing",
                    effectiveMode: overlay?.dataset.skinMode || "token-only",
                    viewportWidth: Math.max(0, Math.floor(globalThis.innerWidth || 0)),
                  };
                })()
                """#,
            requireObjectValue: true
        )
        guard let ownedNodeCount = result["ownedNodeCount"]?.integerValue,
            let overlayCount = result["overlayCount"]?.integerValue,
            let styleCount = result["styleCount"]?.integerValue,
            let ownedGeneration = result["ownedGeneration"]?.stringValue,
            let ownedThemeID = result["ownedThemeID"]?.stringValue,
            let heroState = result["heroState"]?.stringValue,
            let heroImageState = result["heroImageState"]?.stringValue,
            let heroObjectPosition = result["heroObjectPosition"]?.stringValue,
            let overlayPointerEventsNone = result["overlayPointerEventsNone"]?.boolValue,
            let overlayAriaHidden = result["overlayAriaHidden"]?.boolValue,
            let overlayInert = result["overlayInert"]?.boolValue,
            let composerFocusAccepted = result["composerFocusAccepted"]?.boolValue,
            let routeID = result["routeID"]?.stringValue,
            let modeValue = result["effectiveMode"]?.stringValue,
            let effectiveMode = ChatGPTSkinRouteMode(rawValue: modeValue),
            let viewportWidth = result["viewportWidth"]?.integerValue
        else {
            throw SkinError.protocolFailure("皮肤诊断返回值无效。")
        }
        return SkinRuntimeDiagnostics(
            ownedNodeCount: ownedNodeCount,
            overlayCount: overlayCount,
            styleCount: styleCount,
            ownedGeneration: ownedGeneration,
            ownedThemeID: ownedThemeID,
            heroState: heroState,
            heroImageState: heroImageState,
            heroObjectPosition: heroObjectPosition,
            overlayPointerEventsNone: overlayPointerEventsNone,
            overlayAriaHidden: overlayAriaHidden,
            overlayInert: overlayInert,
            composerFocusAccepted: composerFocusAccepted,
            routeID: routeID,
            effectiveMode: effectiveMode,
            viewportWidth: viewportWidth
        )
    }

    private func receiveRuntimeSignal(_ signal: SkinRuntimeBindingSignal) {
        DiagnosticsLogger.shared.log(
            "runtime-signal",
            "generation=\(signal.generation) event=\(signal.event)"
        )
        if activeInjection?.snapshot.generation == signal.generation {
            beginRuntimeRevalidation(generation: signal.generation)
            return
        }
        if installingGeneration == signal.generation {
            pendingRuntimeSignal = signal
        }
    }

    private func beginRuntimeRevalidation(generation: String) {
        guard activeInjection?.snapshot.generation == generation,
              runtimeRevalidationGeneration == nil,
              terminalInvalidationGeneration != generation
        else {
            return
        }
        runtimeRevalidationGeneration = generation
        runtimeRevalidationTask = Task { [weak self] in
            await self?.performRuntimeRevalidation(generation: generation)
        }
    }

    private func receiveConnectionTermination(generation: String) {
        guard activeInjection?.snapshot.generation == generation,
              terminalInvalidationGeneration != generation
        else {
            return
        }
        runtimeRevalidationTask?.cancel()
        publishRuntimeInvalidation(
            generation: generation,
            kind: .runtimeUnavailable,
            message: "ChatGPT renderer 调试连接意外中断，已停止增强。"
        )
    }

    private func performRuntimeRevalidation(generation: String) async {
        do {
            try await Task.sleep(for: .milliseconds(250))
            var structuralConfirmation = SkinStructuralFailureConfirmation()
            var consecutiveRuntimeFailures = 0
            let maximumProbeAttempts = 5
            guard let initialActiveInjection = activeInjection,
                  initialActiveInjection.snapshot.generation == generation
            else {
                clearRuntimeRevalidation(generation: generation)
                return
            }
            let installPlan = SkinRuntimeRevalidationInstallPlan(
                initialInstallExpression: initialActiveInjection.initialInstallExpression,
                resumeExpression: initialActiveInjection.resumeExpression
            )
            DiagnosticsLogger.shared.log(
                "revalidation-begin",
                "generation=\(generation)"
            )

            for attempt in 1...maximumProbeAttempts {
                try Task.checkCancellation()
                guard let activeInjection,
                      activeInjection.snapshot.generation == generation,
                      runtimeRevalidationGeneration == generation
                else {
                    clearRuntimeRevalidation(generation: generation)
                    return
                }

                let scripts = installPlan.scripts(forAttempt: attempt)
                let result = try await installWhenRendererReady(
                    session: activeInjection.session,
                    expression: scripts.expression,
                    retryExpression: scripts.retryExpression
                )
                try Task.checkCancellation()
                guard self.activeInjection?.snapshot.generation == generation,
                      runtimeRevalidationGeneration == generation
                else {
                    clearRuntimeRevalidation(generation: generation)
                    return
                }

                let disposition = SkinInstallProbePolicy.disposition(result)
                let attemptSummary = SkinInstallProbePolicy.structuralFailureSignature(result)
                    ?? result["reason"]?.stringValue
                    ?? "no-reason"
                DiagnosticsLogger.shared.log(
                    "revalidation-attempt",
                    "generation=\(generation) attempt=\(attempt)/\(maximumProbeAttempts) "
                        + "disposition=\(String(describing: disposition)) "
                        + "summary=\(attemptSummary)"
                )
                switch disposition {
                case .installed:
                    DiagnosticsLogger.shared.log(
                        "revalidation-recovered",
                        "generation=\(generation) attempt=\(attempt)"
                    )
                    clearRuntimeRevalidation(generation: generation)
                    return
                case .pending:
                    publishRuntimeInvalidation(
                        generation: generation,
                        kind: .runtimeUnavailable,
                        message: "ChatGPT renderer 在运行期长时间未就绪，已停止增强。"
                    )
                    return
                case .hardFailure:
                    if SkinInstallProbePolicy.structuralFailureSignature(result) != nil {
                        consecutiveRuntimeFailures = 0
                        if structuralConfirmation.record(result) {
                            publishRuntimeInvalidation(
                                generation: generation,
                                kind: .incompatible,
                                message: "ChatGPT renderer 结构已连续复检确认变化，当前 adapter 不兼容。"
                            )
                            return
                        }
                    } else {
                        structuralConfirmation.reset()
                        consecutiveRuntimeFailures += 1
                        if consecutiveRuntimeFailures >= 3 {
                            publishRuntimeInvalidation(
                                generation: generation,
                                kind: .runtimeUnavailable,
                                message: "ChatGPT renderer 运行期安装连续失败，已停止增强。"
                            )
                            return
                        }
                    }
                }

                if attempt < maximumProbeAttempts {
                    try await Task.sleep(for: .milliseconds(500))
                }
            }

            publishRuntimeInvalidation(
                generation: generation,
                kind: .runtimeUnavailable,
                message: "ChatGPT renderer 多次复检结果不稳定，已停止增强。"
            )
        } catch is CancellationError {
            clearRuntimeRevalidation(generation: generation)
        } catch let error as SkinError {
            switch error {
            case .timedOut:
                publishRuntimeInvalidation(
                    generation: generation,
                    kind: .runtimeUnavailable,
                    message: "ChatGPT renderer 在运行期长时间未就绪，已停止增强。"
                )
            default:
                publishRuntimeInvalidation(
                    generation: generation,
                    kind: .runtimeUnavailable,
                    message: "ChatGPT renderer 运行期复检失败，已停止增强。"
                )
            }
        } catch {
            publishRuntimeInvalidation(
                generation: generation,
                kind: .runtimeUnavailable,
                message: "ChatGPT renderer 连接中断，已停止增强。"
            )
        }
    }

    private func clearRuntimeRevalidation(generation: String) {
        guard runtimeRevalidationGeneration == generation else { return }
        runtimeRevalidationGeneration = nil
        runtimeRevalidationTask = nil
    }

    private func publishRuntimeInvalidation(
        generation: String,
        kind: SkinRuntimeInvalidationKind,
        message: String
    ) {
        guard let activeInjection,
              activeInjection.snapshot.generation == generation,
              terminalInvalidationGeneration != generation
        else {
            clearRuntimeRevalidation(generation: generation)
            return
        }
        terminalInvalidationGeneration = generation
        activeInjection.connectionMonitorTask.cancel()
        runtimeRevalidationTask?.cancel()
        runtimeRevalidationGeneration = nil
        runtimeRevalidationTask = nil
        DiagnosticsLogger.shared.log(
            "runtime-invalidation",
            "generation=\(generation) kind=\(kind.rawValue) message=\(message)"
        )
        activeInjection.invalidationContinuation.yield(
            SkinRuntimeInvalidation(
                generation: generation,
                kind: kind,
                message: message
            )
        )
        activeInjection.invalidationContinuation.finish()
    }

    private func waitForRendererSelection(
        port: Int,
        registry: StructuralAdapterRegistry,
        adapters: [any ChatGPTAdapter],
        timeout: Duration = .seconds(16),
        pollInterval: Duration = .milliseconds(160)
    ) async throws -> StructuralAdapterSelection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?
        var lastRejectionSignature: String?
        var consecutiveRejectionMatches = 0
        var rejectionStartedAt: ContinuousClock.Instant?

        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                let targets = try await discoveryClient.fetchTargets(port: port)
                let candidates = ChatGPTRendererTargetPolicy.candidates(from: targets)
                guard !candidates.isEmpty else {
                    lastError = CDPClientError.noRenderer
                    try await clock.sleep(for: pollInterval)
                    continue
                }
                let observations = await structuralProbeEvaluator.observations(
                    targets: candidates,
                    adapters: adapters
                )
                do {
                    return try registry.select(from: observations)
                } catch StructuralAdapterRegistryError.noStructuralMatch {
                    if let signature = registry.structuralRejectionSignature(
                        from: observations
                    ) {
                        if signature == lastRejectionSignature {
                            consecutiveRejectionMatches += 1
                        } else {
                            lastRejectionSignature = signature
                            consecutiveRejectionMatches = 1
                            rejectionStartedAt = clock.now
                        }
                        let observedLongEnough = rejectionStartedAt.map {
                            $0.duration(to: clock.now)
                                >= SkinStructuralFailureConfirmation.minimumObservationDuration
                        } ?? false
                        if consecutiveRejectionMatches
                            >= SkinStructuralFailureConfirmation.requiredConsecutiveMatches,
                            observedLongEnough
                        {
                            throw SkinError.incompatibleApp(
                                "ChatGPT renderer 没有与本地可信 structural adapter 唯一匹配。"
                            )
                        }
                    } else {
                        lastRejectionSignature = nil
                        consecutiveRejectionMatches = 0
                        rejectionStartedAt = nil
                    }
                    lastError = StructuralAdapterRegistryError.noStructuralMatch
                } catch StructuralAdapterRegistryError.ambiguousStructuralMatches(let count) {
                    throw SkinError.injectionFailed(
                        "发现 \(count) 个 renderer/adapter 结构匹配，已安全停止。"
                    )
                }
            } catch {
                if error is SkinError { throw error }
                lastError = error
            }
            try await clock.sleep(for: pollInterval)
        }

        if lastError is StructuralAdapterRegistryError {
            throw SkinError.timedOut(
                "renderer 结构探测未得到唯一稳定匹配；已安全停止，"
                    + "本次结果不会判定为版本不兼容。"
            )
        }
        if let lastError { throw lastError }
        throw CDPClientError.noRenderer
    }

    private func evaluate(
        session: CDPWebSocketSession,
        expression: String,
        requireObjectValue: Bool
    ) async throws -> [String: JSONValue] {
        try await Self.evaluateCommand(
            session: session,
            expression: expression,
            requireObjectValue: requireObjectValue
        )
    }

    private static func evaluateCommand(
        session: CDPWebSocketSession,
        expression: String,
        requireObjectValue: Bool
    ) async throws -> [String: JSONValue] {
        let response = try await session.command(
            "Runtime.evaluate",
            params: [
                "expression": .string(expression),
                "returnByValue": .bool(true),
                "awaitPromise": .bool(true),
                "userGesture": .bool(false),
            ],
            timeout: .seconds(12)
        )
        if response["exceptionDetails"] != nil {
            throw SkinError.injectionFailed("renderer JavaScript 执行异常。")
        }
        guard requireObjectValue else { return [:] }
        guard let remoteObject = response["result"]?.objectValue,
            let value = remoteObject["value"]?.objectValue
        else {
            throw SkinError.protocolFailure("Runtime.evaluate 未返回可解析对象。")
        }
        return value
    }

    private func installWhenRendererReady(
        session: CDPWebSocketSession,
        expression: String,
        retryExpression: String? = nil,
        confirmStructuralHardFailures: Bool = false,
        timeout: Duration = .seconds(12),
        pollInterval: Duration = .milliseconds(150)
    ) async throws -> [String: JSONValue] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastResult: [String: JSONValue] = [:]
        var structuralConfirmation = SkinStructuralFailureConfirmation()
        var structuralConfirmationStartedAt: ContinuousClock.Instant?
        var nextExpression = expression

        while true {
            try Task.checkCancellation()
            lastResult = try await evaluate(
                session: session,
                expression: nextExpression,
                requireObjectValue: true
            )
            if let retryExpression { nextExpression = retryExpression }
            switch SkinInstallProbePolicy.disposition(lastResult) {
            case .installed:
                return lastResult
            case .hardFailure:
                guard confirmStructuralHardFailures,
                      SkinInstallProbePolicy.structuralFailureSignature(lastResult) != nil
                else {
                    return lastResult
                }
                let previousSignature = structuralConfirmation.lastSignature
                let hasRequiredSamples = structuralConfirmation.record(lastResult)
                if structuralConfirmation.lastSignature != previousSignature {
                    structuralConfirmationStartedAt = clock.now
                }
                let hasMinimumObservationWindow = structuralConfirmationStartedAt.map {
                    $0.duration(to: clock.now)
                        >= SkinStructuralFailureConfirmation.minimumObservationDuration
                } ?? false
                if hasRequiredSamples && hasMinimumObservationWindow {
                    return lastResult
                }
                guard clock.now < deadline else {
                    throw SkinInstallProbePolicy.unconfirmedStructuralFailureError()
                }
            case .pending:
                structuralConfirmation.reset()
                structuralConfirmationStartedAt = nil
                guard clock.now < deadline else {
                    throw SkinInstallProbePolicy.pendingTimeoutError(lastResult)
                }
            }
            try await clock.sleep(for: pollInterval)
        }
    }
}
