import Foundation

enum ChatGPTSkinRouteMode: String, Codable, CaseIterable, Sendable {
    case full
    case core
    case tokenOnly = "token-only"
}

enum ChatGPTSkinCapability: String, Codable, Sendable {
    case themeTokens = "theme-tokens"
    case decorativeOverlay = "decorative-overlay"
    case homeHero = "home-hero"
    case sidebarGlass = "sidebar-glass"
    case composerGlass = "composer-glass"
    case threadBackdrop = "thread-backdrop"
}

enum ChatGPTProbeSeverity: String, Codable, Sendable {
    case hard
    case soft
}

enum ChatGPTRendererTargetRole: String, Codable, Sendable {
    case primary
    case auxiliary
}

/// Stable native-to-renderer contract. App version/build metadata is deliberately
/// absent: an official update is accepted or rejected by the runtime structure
/// probes, not by a release-number allowlist.
struct ChatGPTAdapterProtocolContract: Codable, Equatable, Sendable {
    let identifier: String
    let apiVersion: Int
    let bundleIdentifier: String
    let entryScriptPathPattern: String

    func accepts(bundleIdentifier: String) -> Bool {
        self.bundleIdentifier == bundleIdentifier
    }
}

struct ChatGPTRouteCapability: Codable, Equatable, Sendable {
    let id: String
    let pathPattern: String
    let mode: ChatGPTSkinRouteMode
    let capabilities: [ChatGPTSkinCapability]
    let rendererTargetRole: ChatGPTRendererTargetRole

    func matches(path: String) -> Bool {
        path.range(of: pathPattern, options: .regularExpression) != nil
    }
}

struct ChatGPTCardinalityProbe: Codable, Equatable, Sendable {
    let id: String
    let selector: String
    let scopeSelector: String?
    let rejectedAncestorSelector: String?
    let minimumCount: Int
    let maximumCount: Int?
    let visibleOnly: Bool
    let severity: ChatGPTProbeSeverity
    let routeIDs: [String]
    let modes: [ChatGPTSkinRouteMode]

    func applies(routeID: String, mode: ChatGPTSkinRouteMode) -> Bool {
        (routeIDs.isEmpty || routeIDs.contains(routeID)) && modes.contains(mode)
    }
}

struct ChatGPTAdapterManifest: Codable, Equatable, Sendable {
    let identifier: String
    let protocolContract: ChatGPTAdapterProtocolContract
    let minimumStructuralWidth: Int
    let selectors: [String: String]
    let routeCapabilities: [ChatGPTRouteCapability]
    let cardinalityProbes: [ChatGPTCardinalityProbe]

    func route(for path: String) -> ChatGPTRouteCapability? {
        routeCapabilities.first { $0.matches(path: path) }
    }
}

protocol ChatGPTAdapter: Sendable {
    var manifest: ChatGPTAdapterManifest { get }

    /// Returns a JavaScript function expression. The caller owns when that trusted
    /// function is invoked; theme packages never provide executable probe code.
    func makeProbeJavaScript() throws -> String

    /// Builds the single bootstrap entry call. `css` is trusted output from the
    /// native theme renderer; the adapter probe remains adapter-owned executable code.
    /// schema v3.1 的可选扩展（brand/icons/texts）随 payload 透传给 bootstrap，
    /// 缺省时 payload 结构与旧版完全一致。
    func makeInstallJavaScript(
        generation: String,
        themeID: String,
        themeName: String,
        css: String,
        hero: SkinHeroRenderAsset,
        brand: ThemeBrandConfiguration?,
        icons: ThemeIconConfiguration?,
        texts: ThemeTextConfiguration?
    ) throws -> String
}

enum StructuralAdapterProbeReadiness: String, Sendable, Equatable {
    case ready
    case pending
    case rejected
    case indeterminate
}

struct StructuralAdapterProbeObservation: Sendable {
    let target: CDPTarget
    let adapter: any ChatGPTAdapter
    let readiness: StructuralAdapterProbeReadiness
    let structuralFailureSignature: String?

    var identity: String {
        "\(target.id)|\(adapter.manifest.identifier)"
    }
}

struct StructuralAdapterSelection: Sendable {
    let target: CDPTarget
    let adapter: any ChatGPTAdapter
    let readiness: StructuralAdapterProbeReadiness
}

private struct StructuralAdapterObservationKey: Hashable, Sendable {
    let targetID: String
    let adapterIdentifier: String
}

enum StructuralAdapterRegistryError: LocalizedError, Sendable, Equatable {
    case emptyRegistry
    case duplicateAdapterIdentifier(String)
    case noCompatibleAdapter
    case noStructuralMatch
    case ambiguousStructuralMatches(Int)

    var errorDescription: String? {
        switch self {
        case .emptyRegistry:
            "没有注册可信的 ChatGPT structural adapter。"
        case .duplicateAdapterIdentifier(let identifier):
            "Structural adapter identifier 重复：\(identifier)"
        case .noCompatibleAdapter:
            "没有本地可信 adapter 支持当前主题协议。"
        case .noStructuralMatch:
            "没有 renderer 与本地可信 adapter 的结构协议匹配。"
        case .ambiguousStructuralMatches(let count):
            "发现 \(count) 个 renderer/adapter 结构匹配，已安全停止。"
        }
    }
}

/// Registry entries are executable app code, never theme-provided JavaScript.
/// App version/build metadata is intentionally absent from registration and
/// selection: runtime structure observations are the only matching input.
struct StructuralAdapterRegistry: Sendable {
    static let production: StructuralAdapterRegistry = {
        do {
            return try StructuralAdapterRegistry(
                trustedAdapters: [ChatGPTStructuralAdapterV1()]
            )
        } catch {
            preconditionFailure("Invalid production structural adapter registry: \(error)")
        }
    }()

    private let trustedAdapters: [any ChatGPTAdapter]

    init(trustedAdapters: [any ChatGPTAdapter]) throws {
        guard !trustedAdapters.isEmpty else {
            throw StructuralAdapterRegistryError.emptyRegistry
        }
        var identifiers = Set<String>()
        for adapter in trustedAdapters {
            let identifier = adapter.manifest.identifier
            guard identifiers.insert(identifier).inserted else {
                throw StructuralAdapterRegistryError.duplicateAdapterIdentifier(identifier)
            }
        }
        self.trustedAdapters = trustedAdapters
    }

    func compatibleAdapters(
        themeCompatibility: ThemeCompatibility,
        verifiedBundle: VerifiedChatGPTBundle
    ) throws -> [any ChatGPTAdapter] {
        let compatible = trustedAdapters.filter { adapter in
            let contract = adapter.manifest.protocolContract
            return contract.accepts(bundleIdentifier: verifiedBundle.bundleIdentifier)
                && themeCompatibility.supports(contract)
        }
        guard !compatible.isEmpty else {
            throw StructuralAdapterRegistryError.noCompatibleAdapter
        }
        return compatible
    }

    func select(
        from observations: [StructuralAdapterProbeObservation]
    ) throws -> StructuralAdapterSelection {
        var viableByIdentity: [
            StructuralAdapterObservationKey: StructuralAdapterProbeObservation
        ] = [:]
        for observation in observations
        where observation.readiness == .ready || observation.readiness == .pending
        {
            guard let trustedAdapter = trustedAdapter(
                identifier: observation.adapter.manifest.identifier
            ) else {
                continue
            }
            let key = StructuralAdapterObservationKey(
                targetID: observation.target.id,
                adapterIdentifier: trustedAdapter.manifest.identifier
            )
            let canonicalObservation = StructuralAdapterProbeObservation(
                target: observation.target,
                adapter: trustedAdapter,
                readiness: observation.readiness,
                structuralFailureSignature: observation.structuralFailureSignature
            )
            if let existing = viableByIdentity[key] {
                if existing.readiness == .pending && observation.readiness == .ready {
                    viableByIdentity[key] = canonicalObservation
                }
            } else {
                viableByIdentity[key] = canonicalObservation
            }
        }

        let viable = viableByIdentity.values.sorted { lhs, rhs in
            lhs.identity < rhs.identity
        }
        guard !viable.isEmpty else {
            throw StructuralAdapterRegistryError.noStructuralMatch
        }
        guard viable.count == 1, let match = viable.first else {
            throw StructuralAdapterRegistryError.ambiguousStructuralMatches(viable.count)
        }
        return StructuralAdapterSelection(
            target: match.target,
            adapter: match.adapter,
            readiness: match.readiness
        )
    }

    func structuralRejectionSignature(
        from observations: [StructuralAdapterProbeObservation]
    ) -> String? {
        let trustedObservations = observations.filter {
            trustedAdapter(identifier: $0.adapter.manifest.identifier) != nil
        }
        guard !trustedObservations.isEmpty,
              trustedObservations.allSatisfy({
                  $0.readiness == .rejected && $0.structuralFailureSignature != nil
              })
        else {
            return nil
        }
        return trustedObservations.compactMap { observation in
            observation.structuralFailureSignature.map {
                "\(observation.identity)|\($0)"
            }
        }
        .sorted()
        .joined(separator: "||")
    }

    private func trustedAdapter(identifier: String) -> (any ChatGPTAdapter)? {
        trustedAdapters.first { $0.manifest.identifier == identifier }
    }
}

extension ChatGPTAdapter {
    func route(for path: String) -> ChatGPTRouteCapability? {
        manifest.route(for: path)
    }

    func makeProbeJavaScript() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard let manifestJSON = String(data: data, encoding: .utf8) else {
            throw ChatGPTAdapterJavaScriptError.invalidUTF8
        }

        return #"""
            (function zuuziiChatGPTAdapterProbe() {
              "use strict";

              const manifest = \#(manifestJSON);

                function routePaths() {
                    const rawPath = globalThis.location?.pathname || "/";
                    let path = rawPath === "/index.html" ? "/" : rawPath;
                    try {
                        const metaRoute = document.querySelector('meta[name="initial-route"]')
                            ?.getAttribute("content")?.trim();
                        const queryRoute = new URLSearchParams(globalThis.location?.search || "")
                            .get("initialRoute")?.trim();
                        const initialRoute = metaRoute || queryRoute;
                        if (initialRoute && initialRoute.startsWith("/") && initialRoute !== "/") {
                            const origin = globalThis.location?.origin;
                            const baseURL = origin && origin !== "null" ? origin : "app://chatgpt";
                            path = new URL(initialRoute, baseURL).pathname;
                        }
                        if (initialRoute === "/") path = "/";
                    } catch (_) {
                        // A malformed optional route must not prevent the conservative fallback.
                    }
                    // Electron loads the main shell from /index.html before the app router
                    // normalizes Home to /. Treat only that exact shell URL as Home.
                    return Object.freeze({ rawPath, path });
                }

              function classify(path) {
                for (const rule of manifest.routeCapabilities) {
                  try {
                    if (new RegExp(rule.pathPattern).test(path)) return rule;
                  } catch (_) {
                    return null;
                  }
                }
                return null;
              }

              function isVisible(element) {
                if (!element || !element.isConnected || element.getClientRects().length === 0) {
                  return false;
                }
                if (element.closest('[hidden],[aria-hidden="true"],[inert]')) return false;
                const style = globalThis.getComputedStyle(element);
                return style.display !== "none" && style.visibility !== "hidden";
              }

              function nodesFor(probe) {
                let scopes;
                try {
                  scopes = probe.scopeSelector
                    ? Array.from(document.querySelectorAll(probe.scopeSelector))
                    : [document];
                } catch (_) {
                  return [];
                }

                const nodes = new Set();
                for (const scope of scopes) {
                  let matches;
                  try {
                    matches = scope.querySelectorAll(probe.selector);
                  } catch (_) {
                    return [];
                  }
                  for (const node of matches) {
                    if (
                      probe.rejectedAncestorSelector
                      && node.closest(probe.rejectedAncestorSelector)
                    ) {
                      continue;
                    }
                    if (probe.visibleOnly && !isVisible(node)) continue;
                    nodes.add(node);
                  }
                }
                return Array.from(nodes);
              }

              function entryScriptCount() {
                let pathPattern;
                try {
                  pathPattern = new RegExp(manifest.protocolContract.entryScriptPathPattern);
                } catch (_) {
                  return 0;
                }
                return Array.from(document.scripts || []).filter((script) => {
                  const source = script.getAttribute("src") || "";
                  try {
                    return pathPattern.test(new URL(source, document.baseURI).pathname);
                  } catch (_) {
                    const withoutQuery = source.split(/[?#]/, 1)[0];
                    const schemeOffset = withoutQuery.indexOf("://");
                    if (schemeOffset >= 0) {
                      const pathOffset = withoutQuery.indexOf("/", schemeOffset + 3);
                      return pathPattern.test(pathOffset >= 0 ? withoutQuery.slice(pathOffset) : "/");
                    }
                    return pathPattern.test(
                      withoutQuery.startsWith("/") ? withoutQuery : `/${withoutQuery}`
                    );
                  }
                }).length;
              }

              const { rawPath, path } = routePaths();
              const route = classify(path);
              const viewportWidth = Math.max(
                0,
                Math.floor(globalThis.innerWidth || document.documentElement?.clientWidth || 0)
              );
              const requestedMode = route?.mode || "token-only";
              const effectiveMode = viewportWidth < manifest.minimumStructuralWidth
                ? "token-only"
                : requestedMode;
              const reducedMotion = Boolean(
                globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches
              );
              const counts = Object.create(null);
              const failures = [];
              const matchedEntryScripts = entryScriptCount();

              function probeApplies(probe) {
                const routeApplies = probe.routeIDs.length === 0 || probe.routeIDs.includes(route.id);
                return routeApplies && probe.modes.includes(effectiveMode);
              }

              function measureProbe(probe) {
                const count = nodesFor(probe).length;
                counts[probe.id] = count;
                return count;
              }

              function recordProbeFailure(probe, count) {
                if (
                  count < probe.minimumCount
                  || (probe.maximumCount !== null && count > probe.maximumCount)
                ) {
                  failures.push({
                    id: probe.id,
                    severity: probe.severity,
                    actualCount: count,
                    minimumCount: probe.minimumCount,
                    maximumCount: probe.maximumCount
                  });
                }
              }

              if (matchedEntryScripts !== 1) {
                failures.push({
                  id: "entry-script",
                  severity: "hard",
                  actualCount: matchedEntryScripts,
                  minimumCount: 1,
                  maximumCount: 1
                });
              }

              if (!route) {
                failures.push({
                  id: "route-classification",
                  severity: "hard",
                  actualCount: 0,
                  minimumCount: 1,
                  maximumCount: 1
                });
              } else {
                const applicableProbes = manifest.cardinalityProbes.filter(probeApplies);
                const baselineProbes = applicableProbes.filter((probe) => probe.routeIDs.length === 0);
                for (const probe of baselineProbes) {
                  recordProbeFailure(probe, measureProbe(probe));
                }

                const mainViewportProbe = applicableProbes.find(
                  (probe) => probe.id === "main-viewport"
                );
                const mainViewportCount = mainViewportProbe
                  ? measureProbe(mainViewportProbe)
                  : null;
                const baselineFailed = failures.some((failure) => failure.severity === "hard");
                const pending = route.id === "home"
                  && effectiveMode === "full"
                  && mainViewportCount === 0
                  && !baselineFailed;

                if (pending) {
                  return Object.freeze({
                    adapterId: manifest.identifier,
                    ok: false,
                    failClosed: false,
                    pending: true,
                    reason: "renderer-not-ready",
                    routeID: route.id,
                    rawPath,
                    path,
                    requestedMode,
                    effectiveMode,
                    viewportWidth,
                    minimumStructuralWidth: manifest.minimumStructuralWidth,
                    reducedMotion,
                    entryScriptMatchCount: matchedEntryScripts,
                    counts: Object.freeze(counts),
                    failures: Object.freeze(failures)
                  });
                }

                for (const probe of applicableProbes) {
                  if (baselineProbes.includes(probe)) continue;
                  if (probe === mainViewportProbe) {
                    recordProbeFailure(probe, mainViewportCount);
                  } else {
                    recordProbeFailure(probe, measureProbe(probe));
                  }
                }
              }

              const failClosed = failures.some((failure) => failure.severity === "hard");
              return Object.freeze({
                adapterId: manifest.identifier,
                ok: !failClosed,
                failClosed,
                pending: false,
                routeID: route?.id || "unclassified",
                rawPath,
                path,
                requestedMode,
                effectiveMode,
                viewportWidth,
                minimumStructuralWidth: manifest.minimumStructuralWidth,
                reducedMotion,
                entryScriptMatchCount: matchedEntryScripts,
                counts: Object.freeze(counts),
                failures: Object.freeze(failures)
              });
            })
            """#
    }

    func makeInstallJavaScript(
        generation: String,
        themeID: String,
        themeName: String,
        css: String,
        hero: SkinHeroRenderAsset,
        brand: ThemeBrandConfiguration? = nil,
        icons: ThemeIconConfiguration? = nil,
        texts: ThemeTextConfiguration? = nil
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            ChatGPTSkinInstallDataPayload(
                generation: generation,
                themeID: themeID,
                themeName: themeName,
                css: css,
                hero: hero,
                brand: brand,
                icons: icons,
                texts: texts
            ))
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw ChatGPTAdapterJavaScriptError.invalidUTF8
        }
        let probeJavaScript = try makeProbeJavaScript()

        return #"""
            globalThis[Symbol.for("com.zuuzii.chatgpt-skin.install")](
              Object.assign(\#(payloadJSON), { adapterProbe: \#(probeJavaScript) })
            )
            """#
    }
}

enum ChatGPTAdapterJavaScriptError: Error, Equatable, Sendable {
    case invalidUTF8
}

private struct ChatGPTSkinInstallDataPayload: Encodable {
    let generation: String
    let themeID: String
    let themeName: String
    let css: String
    let hero: SkinHeroRenderAsset
    // schema v3.1 可选扩展；nil 时编码结果与旧 payload 完全一致（键被省略）。
    let brand: ThemeBrandConfiguration?
    let icons: ThemeIconConfiguration?
    let texts: ThemeTextConfiguration?
}

struct ChatGPTProbeFailure: Equatable, Sendable {
    let id: String
    let severity: ChatGPTProbeSeverity
    let actualCount: Int
    let minimumCount: Int
    let maximumCount: Int?
}

struct ChatGPTProbeEvaluation: Equatable, Sendable {
    let ok: Bool
    let failClosed: Bool
    let pending: Bool
    let reason: String?
    let routeID: String
    let rawPath: String
    let path: String
    let requestedMode: ChatGPTSkinRouteMode
    let effectiveMode: ChatGPTSkinRouteMode
    let viewportWidth: Int
    let entryScriptMatchCount: Int
    let failures: [ChatGPTProbeFailure]
}

enum ChatGPTAdapterProbeEvaluator {
    static func evaluate(
        adapter: any ChatGPTAdapter,
        routeID: String,
        viewportWidth: Int,
        entryScriptMatchCount: Int,
        counts: [String: Int],
        rawPath: String = "/",
        path: String? = nil
    ) -> ChatGPTProbeEvaluation {
        let manifest = adapter.manifest
        let processedPath = path ?? (rawPath == "/index.html" ? "/" : rawPath)
        guard let route = manifest.routeCapabilities.first(where: { $0.id == routeID }) else {
            let failure = ChatGPTProbeFailure(
                id: "route-classification",
                severity: .hard,
                actualCount: 0,
                minimumCount: 1,
                maximumCount: 1
            )
            return ChatGPTProbeEvaluation(
                ok: false,
                failClosed: true,
                pending: false,
                reason: nil,
                routeID: routeID,
                rawPath: rawPath,
                path: processedPath,
                requestedMode: .tokenOnly,
                effectiveMode: .tokenOnly,
                viewportWidth: viewportWidth,
                entryScriptMatchCount: entryScriptMatchCount,
                failures: [failure]
            )
        }

        let effectiveMode: ChatGPTSkinRouteMode =
            viewportWidth < manifest.minimumStructuralWidth
            ? .tokenOnly
            : route.mode
        var failures: [ChatGPTProbeFailure] = []

        if entryScriptMatchCount != 1 {
            failures.append(
                ChatGPTProbeFailure(
                    id: "entry-script",
                    severity: .hard,
                    actualCount: entryScriptMatchCount,
                    minimumCount: 1,
                    maximumCount: 1
                ))
        }

        func recordFailure(for probe: ChatGPTCardinalityProbe) {
            let actualCount = counts[probe.id, default: 0]
            if actualCount < probe.minimumCount
                || probe.maximumCount.map({ actualCount > $0 }) == true
            {
                failures.append(
                    ChatGPTProbeFailure(
                        id: probe.id,
                        severity: probe.severity,
                        actualCount: actualCount,
                        minimumCount: probe.minimumCount,
                        maximumCount: probe.maximumCount
                    ))
            }
        }

        let applicableProbes = manifest.cardinalityProbes.filter {
            $0.applies(routeID: routeID, mode: effectiveMode)
        }
        let baselineProbes = applicableProbes.filter { $0.routeIDs.isEmpty }
        for probe in baselineProbes {
            recordFailure(for: probe)
        }

        let baselineFailed = failures.contains { $0.severity == .hard }
        let mainViewportCount = counts["main-viewport", default: 0]
        if route.id == "home",
            effectiveMode == .full,
            mainViewportCount == 0,
            !baselineFailed
        {
            return ChatGPTProbeEvaluation(
                ok: false,
                failClosed: false,
                pending: true,
                reason: "renderer-not-ready",
                routeID: routeID,
                rawPath: rawPath,
                path: processedPath,
                requestedMode: route.mode,
                effectiveMode: effectiveMode,
                viewportWidth: viewportWidth,
                entryScriptMatchCount: entryScriptMatchCount,
                failures: failures
            )
        }

        for probe in applicableProbes where !probe.routeIDs.isEmpty {
            recordFailure(for: probe)
        }

        let failClosed = failures.contains { $0.severity == .hard }
        return ChatGPTProbeEvaluation(
            ok: !failClosed,
            failClosed: failClosed,
            pending: false,
            reason: nil,
            routeID: routeID,
            rawPath: rawPath,
            path: processedPath,
            requestedMode: route.mode,
            effectiveMode: effectiveMode,
            viewportWidth: viewportWidth,
            entryScriptMatchCount: entryScriptMatchCount,
            failures: failures
        )
    }
}
