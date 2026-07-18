import Foundation
import CryptoKit
import XCTest
@testable import ChatGPTSkinStudio

final class LiveChatGPTSkinE2ETests: XCTestCase {
    func testFreshIsolatedRealChatGPTFailsSafeWithoutBorrowingUserProfile() async throws {
        guard ProcessInfo.processInfo.environment["RUN_CHATGPT_SKIN_E2E"] == "1" else {
            throw XCTSkip("Set RUN_CHATGPT_SKIN_E2E=1 to launch the isolated real-App test.")
        }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesRoot = projectRoot
            .appendingPathComponent("ChatGPTSkinStudio/Resources", isDirectory: true)
        let themeDirectory = resourcesRoot
            .appendingPathComponent("Themes/original-night-city", isDirectory: true)
        let outputDirectory = projectRoot
            .appendingPathComponent(".build/e2e", isDirectory: true)
        let screenshotURL = outputDirectory
            .appendingPathComponent("chatgpt-isolated-token-only.png", isDirectory: false)

        let verifiedBundle = try ChatGPTBundleVerifier().verify(
            appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        )
        let theme = try ThemeValidator().validateAndLoad(
            themeDirectory: themeDirectory,
            source: .bundled
        )
        let resources = try SkinInjectionResources(
            bootstrapJavaScript: String(
                contentsOf: resourcesRoot.appendingPathComponent("Injected/bootstrap.js"),
                encoding: .utf8
            ),
            cleanupJavaScript: String(
                contentsOf: resourcesRoot.appendingPathComponent("Injected/cleanup.js"),
                encoding: .utf8
            )
        )
        guard let consent = ExplicitRestartConsent(userConfirmed: true) else {
            return XCTFail("Could not create explicit test consent.")
        }

        let launcher = IsolatedDebugLauncher()
        let injector = SkinInjector(resources: resources)
        let session: IsolatedDebugSession
        do {
            session = try await launcher.launch(
                verifiedBundle: verifiedBundle,
                consent: consent
            )
        } catch {
            let launchError = error
            let recoveryRecords = await launcher.recoveryRecords()
            var recoveryFailures: [String] = []
            for record in recoveryRecords {
                do {
                    try await launcher.retryRecovery(id: record.id)
                } catch {
                    let processIdentifier = record.processIdentifier.map(String.init)
                        ?? "unknown"
                    recoveryFailures.append(
                        "id=\(record.id.uuidString), pid=\(processIdentifier), "
                            + "root=\(record.storageRootURL.path), error=\(error.localizedDescription)"
                    )
                }
            }
            let remainingRecords = await launcher.recoveryRecords()
            guard recoveryFailures.isEmpty, remainingRecords.isEmpty else {
                throw LiveIsolatedLaunchRecoveryFailure(
                    launchError: launchError.localizedDescription,
                    recoveryFailures: recoveryFailures,
                    remainingRecords: remainingRecords
                )
            }
            throw launchError
        }

        let bodyFailureCountBefore = testRun?.failureCount ?? 0
        var bodyError: Error?
        var acceptedSafeOutcome = false
        do {
            let handle = try await injector.install(
                port: Int(session.endpoint.port),
                theme: theme,
                verifiedBundle: verifiedBundle,
                registry: .production
            )
            let snapshot = handle.snapshot
            XCTAssertEqual(snapshot.appBuild, verifiedBundle.buildVersion)
            XCTAssertEqual(snapshot.routeID, "onboarding")
            XCTAssertEqual(snapshot.effectiveMode, .tokenOnly)

            let diagnostics = try await injector.runDiagnostics()
            XCTAssertEqual(diagnostics.ownedNodeCount, 2)
            XCTAssertEqual(diagnostics.overlayCount, 1)
            XCTAssertEqual(diagnostics.styleCount, 1)
            XCTAssertTrue(diagnostics.overlayPointerEventsNone)
            XCTAssertTrue(diagnostics.overlayAriaHidden)
            XCTAssertTrue(diagnostics.overlayInert)
            XCTAssertFalse(diagnostics.composerFocusAccepted)
            XCTAssertEqual(diagnostics.routeID, "onboarding")
            XCTAssertEqual(diagnostics.effectiveMode, .tokenOnly)
            XCTAssertGreaterThan(diagnostics.viewportWidth, 0)

            let screenshot = try await injector.captureScreenshotPNG()
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try screenshot.write(to: screenshotURL, options: .atomic)
            acceptedSafeOutcome = true
        } catch SkinError.timedOut(let message) {
            XCTAssertTrue(message.contains("renderer-not-ready"))
            XCTAssertTrue(message.contains("rawPath="))
            XCTAssertTrue(message.contains("main-viewport=0"))
            let pendingSnapshot = await injector.snapshot()
            XCTAssertNil(pendingSnapshot)
            acceptedSafeOutcome = true
        } catch {
            bodyError = error
        }

        XCTAssertTrue(
            acceptedSafeOutcome,
            "Fresh isolated profile must either remain pending without injection or settle on token-only onboarding."
        )

        let bodyRecordedFailure = (testRun?.failureCount ?? 0) > bodyFailureCountBefore
        if bodyError != nil || bodyRecordedFailure {
            do {
                let artifacts = try await captureNativeFailureArtifacts(
                    port: Int(session.endpoint.port),
                    outputDirectory: outputDirectory,
                    cleanupJavaScript: resources.cleanupJavaScript,
                    theme: theme,
                    verifiedBundle: verifiedBundle
                )
                for artifactURL in artifacts {
                    let attachment = XCTAttachment(contentsOfFile: artifactURL)
                    attachment.name = artifactURL.lastPathComponent
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            } catch {
                XCTFail("Could not capture native failure diagnostics: \(error)")
            }
        }

        await assertCleanup(
            injector: injector,
            launcher: launcher,
            session: session
        )

        if let bodyError {
            throw bodyError
        }
    }

    private func captureNativeFailureArtifacts(
        port: Int,
        outputDirectory: URL,
        cleanupJavaScript: String,
        theme: LoadedTheme,
        verifiedBundle: VerifiedChatGPTBundle
    ) async throws -> [URL] {
        let screenshotURL = outputDirectory
            .appendingPathComponent("chatgpt-native-probe-failure.png", isDirectory: false)
        let summaryURL = outputDirectory
            .appendingPathComponent("chatgpt-native-probe-failure.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        for artifactURL in [screenshotURL, summaryURL]
            where FileManager.default.fileExists(atPath: artifactURL.path)
        {
            try FileManager.default.removeItem(at: artifactURL)
        }

        let targets = try await CDPDiscoveryClient().fetchTargets(port: port)
        let rendererCandidates = ChatGPTRendererTargetPolicy.candidates(from: targets)
        guard !rendererCandidates.isEmpty else {
            throw CDPClientError.noRenderer
        }
        let registry = StructuralAdapterRegistry.production
        let adapters = try registry.compatibleAdapters(
            themeCompatibility: theme.manifest.compatibility,
            verifiedBundle: verifiedBundle
        )
        let observations = await CDPRendererStructuralProbeEvaluator().observations(
            targets: rendererCandidates,
            adapters: adapters
        )
        let determinateTargets = observations
            .filter { $0.readiness != .indeterminate }
            .map(\.target)
        let diagnosticTargets = determinateTargets.isEmpty
            ? observations.map(\.target)
            : determinateTargets
        let uniqueTargets = Dictionary(
            diagnosticTargets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        guard !uniqueTargets.isEmpty else {
            throw CDPClientError.noRenderer
        }
        guard uniqueTargets.count == 1, let rendererTarget = uniqueTargets.first else {
            throw CDPClientError.ambiguousRenderer(uniqueTargets.count)
        }
        guard let endpointValue = rendererTarget.webSocketDebuggerUrl,
              let endpoint = URL(string: endpointValue)
        else {
            throw CDPClientError.invalidEndpoint(
                rendererTarget.webSocketDebuggerUrl ?? "missing"
            )
        }

        let diagnosticSession = try CDPWebSocketSession(endpoint: endpoint)
        do {
            try await diagnosticSession.connect()
            _ = try await diagnosticSession.command("Runtime.enable")
            _ = try await diagnosticSession.command("Page.enable")

            let cleanupResult = try await diagnosticSession.command(
                "Runtime.evaluate",
                params: [
                    "expression": .string(cleanupJavaScript),
                    "returnByValue": .bool(true),
                    "awaitPromise": .bool(true),
                    "userGesture": .bool(false),
                ],
                timeout: .seconds(8)
            )
            guard cleanupResult["exceptionDetails"] == nil else {
                throw SkinError.protocolFailure(
                    "Native diagnostic cleanup JavaScript raised an exception."
                )
            }

            let screenshotResult = try await diagnosticSession.command(
                "Page.captureScreenshot",
                params: [
                    "format": .string("png"),
                    "fromSurface": .bool(true),
                    "captureBeyondViewport": .bool(false),
                ],
                timeout: .seconds(12)
            )
            guard let encodedScreenshot = screenshotResult["data"]?.stringValue,
                  let screenshot = Data(
                      base64Encoded: encodedScreenshot,
                      options: [.ignoreUnknownCharacters]
                  ),
                  screenshot.count >= 8,
                  screenshot.count <= 32 * 1_024 * 1_024,
                  Array(screenshot.prefix(8))
                    == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            else {
                throw SkinError.protocolFailure(
                    "Native diagnostic did not return a valid PNG."
                )
            }
            try screenshot.write(to: screenshotURL, options: .atomic)

            let summaryResult = try await diagnosticSession.command(
                "Runtime.evaluate",
                params: [
                    "expression": .string(Self.nativeStructureSummaryJavaScript),
                    "returnByValue": .bool(true),
                    "awaitPromise": .bool(true),
                    "userGesture": .bool(false),
                ],
                timeout: .seconds(8)
            )
            guard summaryResult["exceptionDetails"] == nil,
                  let remoteObject = summaryResult["result"]?.objectValue,
                  let summary = remoteObject["value"]
            else {
                throw SkinError.protocolFailure(
                    "Native diagnostic did not return a structural summary."
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let summaryData = try encoder.encode(summary)
            guard summaryData.count <= 64 * 1_024 else {
                throw SkinError.protocolFailure(
                    "Native diagnostic structural summary exceeded 64 KiB."
                )
            }
            try summaryData.write(to: summaryURL, options: .atomic)
        } catch {
            await diagnosticSession.close()
            throw error
        }
        await diagnosticSession.close()
        return [screenshotURL, summaryURL]
    }

    private static let nativeStructureSummaryJavaScript = #"""
        (() => {
          "use strict";

          const bounded = (value, maximum) => String(value || "").slice(0, maximum);
          const root = document.querySelector("#root");
          const rootDirectChildren = root
            ? Array.from(root.children).slice(0, 64).map((element) => ({
                tag: bounded(element.tagName, 64).toLowerCase(),
                id: bounded(element.id, 256),
                class: Array.from(element.classList || [])
                  .slice(0, 64)
                  .map((name) => bounded(name, 256)),
                dataAttributes: Array.from(element.attributes || [])
                  .map((attribute) => attribute.name)
                  .filter((name) => name.startsWith("data-"))
                  .slice(0, 64)
                  .map((name) => bounded(name, 256)),
              }))
            : [];

          const selectorCounts = {
            electronRoot: document.querySelectorAll(
              ':root[data-codex-window-type="electron"]'
            ).length,
            rootMount: document.querySelectorAll("#root").length,
            mainViewport: document.querySelectorAll(
              "[data-app-shell-main-content-layout]"
            ).length,
            composerRoot: document.querySelectorAll("[data-codex-composer-root]").length,
            composer: document.querySelectorAll("[data-codex-composer]").length,
            activeTabs: document.querySelectorAll('[data-app-shell-tabs="true"]').length,
            rightPanel: document.querySelectorAll(
              '[data-app-shell-focus-area="right-panel"]'
            ).length,
            bottomPanel: document.querySelectorAll(
              '[data-app-shell-focus-area="bottom-panel"]'
            ).length,
            tabPanel: document.querySelectorAll(
              "[role=\"tabpanel\"][data-app-shell-tab-panel-controller][data-tab-id]"
            ).length,
            threadScroller: document.querySelectorAll(".thread-scroll-container").length,
            threadFooter: document.querySelectorAll('[data-thread-scroll-footer="true"]').length,
            turn: document.querySelectorAll(
              "[data-turn-key], [data-content-search-turn-key]"
            ).length,
            userMessage: document.querySelectorAll("[data-user-message-bubble]").length,
            chatGPTTurn: document.querySelectorAll(
              '[data-chatgpt-conversation-turn="true"]'
            ).length,
            threadTitle: document.querySelectorAll("[data-thread-title]").length,
            projectsHeader: document.querySelectorAll("[data-projects-header]").length,
            projectsRows: document.querySelectorAll("[data-projects-rows]").length,
            avatarFrame: document.querySelectorAll(
              '[data-avatar-overlay-content-frame="true"]'
            ).length,
            avatarAsset: document.querySelectorAll(
              "[data-avatar-asset-ref][data-avatar-state]"
            ).length,
            ownedNodes: document.querySelectorAll("[data-zuuzii-skin-owner]").length,
          };

          return {
            title: bounded(document.title, 512),
            path: bounded(globalThis.location?.pathname || "", 1_024),
            readyState: bounded(document.readyState, 32),
            viewport: {
              width: Math.max(0, Math.floor(globalThis.innerWidth || 0)),
              height: Math.max(0, Math.floor(globalThis.innerHeight || 0)),
              devicePixelRatio: Math.max(0, Number(globalThis.devicePixelRatio || 0)),
            },
            rootDirectChildren,
            selectorCounts,
          };
        })()
        """#

    private func assertCleanup(
        injector: SkinInjector,
        launcher: IsolatedDebugLauncher,
        session: IsolatedDebugSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await injector.restore()
        } catch {
            XCTFail(
                "SkinInjector.restore() failed during E2E cleanup: \(error)",
                file: file,
                line: line
            )
        }

        do {
            try await launcher.cleanup(session)
        } catch {
            XCTFail(
                "IsolatedDebugLauncher.cleanup() failed during E2E cleanup: \(error)",
                file: file,
                line: line
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: session.storage.rootURL.path),
            "Isolated storage root still exists after cleanup: \(session.storage.rootURL.path)",
            file: file,
            line: line
        )

        do {
            let canonicalRoot = session.storage.rootURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let remainingProcesses = try DarwinRuntimeProcessInspector()
                .allUserProcesses()
                .filter { candidate in
                    candidate.executableURL
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                        .isStrictDescendant(of: canonicalRoot)
                }
            let remainingDetail = remainingProcesses
                .map { "PID \($0.pid): \($0.executableURL.path)" }
                .joined(separator: ", ")

            XCTAssertTrue(
                remainingProcesses.isEmpty,
                "Processes remain under isolated storage root after cleanup: \(remainingDetail)",
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "Could not verify isolated process cleanup: \(error)",
                file: file,
                line: line
            )
        }
    }
}

private struct LiveIsolatedLaunchRecoveryFailure: LocalizedError {
    let launchError: String
    let recoveryFailures: [String]
    let remainingRecords: [IsolatedDebugRecoveryRecord]

    var errorDescription: String? {
        let failures = recoveryFailures.isEmpty
            ? "none"
            : recoveryFailures.joined(separator: " | ")
        let remaining = remainingRecords.isEmpty
            ? "none"
            : remainingRecords.map { record in
                let processIdentifier = record.processIdentifier.map(String.init)
                    ?? "unknown"
                return "id=\(record.id.uuidString), pid=\(processIdentifier), "
                    + "root=\(record.storageRootURL.path), primary=\(record.primaryReason)"
            }.joined(separator: " | ")
        return "Isolated launch failed and recovery was incomplete. launch=\(launchError); "
            + "retryFailures=\(failures); remaining=\(remaining)"
    }
}

/// Destructive, real-profile production verification. This test deliberately lives
/// beside the isolated Live E2E so it is part of the normal test bundle, but its
/// first executable branch is a separate, explicit opt-in gate. Never enable it in
/// a shared CI scheme: it terminates and relaunches the user's real ChatGPT app.
final class ProductionChatGPTSkinE2ETests: XCTestCase {
    private static let optInEnvironmentKey = "RUN_CHATGPT_SKIN_PRODUCTION_E2E"
    private static let officialChatGPTURL = URL(
        fileURLWithPath: "/Applications/ChatGPT.app",
        isDirectory: true
    )
    private static let importedThemeName = "Original Night City — Left Focus"
    private static let importedThemeFocalPoint = ThemeNormalizedPoint(x: 0.2, y: 0.34)
    private static let themeAHeroObjectPosition = "74% 34%"
    private static let themeBHeroObjectPosition = "20% 34%"

    func testProductionApplyHotSwitchAndRestore() async throws {
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.optInEnvironmentKey)=1 only after explicitly authorizing "
                    + "two real ChatGPT restarts."
            )
        }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesRoot = projectRoot
            .appendingPathComponent("ChatGPTSkinStudio/Resources", isDirectory: true)
        let artifacts = ProductionE2EArtifactURLs(
            root: projectRoot.appendingPathComponent(
                "QAArtifacts/production-e2e",
                isDirectory: true
            )
        )
        try prepareArtifacts(artifacts)

        var summary = ProductionE2ESummary(startedAt: Self.timestamp())
        let progressRecorder = ProductionE2EProgressRecorder()
        var coordinator: SkinSessionCoordinator?
        var verifiedBundle: VerifiedChatGPTBundle?
        var applyConsent: ExplicitRestartConsent?
        var applyWasInvoked = false
        var oldDebugPort: UInt16?
        var skipReason: String?
        var bodyError: Error?

        do {
            let bundle = try ChatGPTBundleVerifier().verify(
                appURL: Self.officialChatGPTURL
            )
            verifiedBundle = bundle
            summary.app = ProductionE2EAppSummary(
                path: bundle.appURL.path,
                bundleIdentifier: bundle.bundleIdentifier,
                teamIdentifier: bundle.teamIdentifier,
                shortVersion: bundle.shortVersion,
                buildVersion: bundle.buildVersion
            )

            let processInspector = DarwinRuntimeProcessInspector()
            let initialNormal = try await Self.normalChatGPTProcess(
                bundle: bundle,
                inspector: processInspector
            )
            summary.normalPIDBeforeImport = initialNormal.pid

            let themeDirectory = resourcesRoot.appendingPathComponent(
                "Themes/original-night-city",
                isDirectory: true
            )
            let themeA = try ThemeValidator().validateAndLoad(
                themeDirectory: themeDirectory,
                source: .bundled
            )
            summary.themeA = ProductionE2EThemeSummary(themeA)

            let repository = ThemeRepository(
                bundledThemesRoot: resourcesRoot.appendingPathComponent(
                    "Themes",
                    isDirectory: true
                ),
                userThemesRoot: Self.userThemesRoot()
            )
            let themeBResolution = try await resolveThemeB(
                repository: repository,
                sourceURL: themeA.heroAsset.fileURL
            )
            let afterImportNormal = try await Self.normalChatGPTProcess(
                bundle: bundle,
                inspector: processInspector
            )
            try require(
                afterImportNormal.pid == initialNormal.pid
                    && afterImportNormal.startTime == initialNormal.startTime
                    && afterImportNormal.executableURL == initialNormal.executableURL
                    && afterImportNormal.arguments == initialNormal.arguments,
                "主题导入期间真实 ChatGPT 进程身份发生变化。"
            )
            summary.normalPIDAfterImport = afterImportNormal.pid
            summary.themeBWasImported = themeBResolution.wasImported
            summary.themeBExpectedSHA256 = themeBResolution.expectedSHA256
            summary.themeB = ProductionE2EThemeSummary(themeBResolution.theme)

            try require(themeA.manifest.id != themeBResolution.theme.manifest.id,
                        "A/B 主题 ID 必须不同。")
            try require(themeBResolution.theme.source == .user,
                        "B 必须是通过用户主题仓库加载的主题。")
            try require(
                themeBResolution.theme.manifest.name == Self.importedThemeName
                    && themeBResolution.theme.manifest.hero.focalPoint
                        == Self.importedThemeFocalPoint
                    && themeBResolution.theme.heroAsset.sha256
                        == themeBResolution.expectedSHA256,
                "B 主题名称、focal point 或 hero SHA-256 与固定夹具不一致。"
            )

            let resources = try SkinInjectionResources(
                bootstrapJavaScript: String(
                    contentsOf: resourcesRoot.appendingPathComponent(
                        "Injected/bootstrap.js",
                        isDirectory: false
                    ),
                    encoding: .utf8
                ),
                cleanupJavaScript: String(
                    contentsOf: resourcesRoot.appendingPathComponent(
                        "Injected/cleanup.js",
                        isDirectory: false
                    ),
                    encoding: .utf8
                )
            )
            let retainedInjector = SkinInjector(resources: resources)
            let productionCoordinator = SkinSessionCoordinator(
                injector: retainedInjector
            )
            coordinator = productionCoordinator

            guard let consent = ExplicitRestartConsent(userConfirmed: true) else {
                throw ProductionE2EHarnessError("无法创建首次 apply consent。")
            }
            applyConsent = consent
            applyWasInvoked = true
            let snapshotA = try await productionCoordinator.apply(
                theme: themeA,
                verifiedBundle: bundle,
                consent: consent
            ) { state in
                await progressRecorder.record(state)
            }
            try require(
                snapshotA.themeID == themeA.manifest.id,
                "apply A 返回的 themeID 与请求主题不一致。"
            )
            summary.applySnapshot = ProductionE2ESnapshotSummary(snapshotA)

            let debugA = try await managedDebugObservation(
                coordinator: productionCoordinator,
                inspector: processInspector
            )
            oldDebugPort = debugA.endpoint.port
            summary.observedOldDebugPort = debugA.endpoint.port
            summary.debugBeforeSwitch = ProductionE2EDebugSummary(debugA)

            let diagnosticsA = try await retainedInjector.runDiagnostics()
            summary.diagnosticsA = ProductionE2EDiagnosticsSummary(diagnosticsA)
            if !Self.isHomeFullRoute(snapshot: snapshotA, diagnostics: diagnosticsA) {
                skipReason = Self.routeSkipReason(
                    stage: "apply A",
                    snapshot: snapshotA,
                    diagnostics: diagnosticsA
                )
            } else {
                try requireHomeFullStructure(
                    diagnosticsA,
                    snapshot: snapshotA,
                    expectedThemeID: themeA.manifest.id,
                    expectedHeroObjectPosition: Self.themeAHeroObjectPosition,
                    stage: "apply A"
                )
                let screenshotA = try await retainedInjector.captureScreenshotPNG()
                let diagnosticsAfterScreenshotA = try await retainedInjector.runDiagnostics()
                summary.diagnosticsAAfterScreenshot = ProductionE2EDiagnosticsSummary(
                    diagnosticsAfterScreenshotA
                )
                if !Self.isHomeFullRoute(
                    snapshot: snapshotA,
                    diagnostics: diagnosticsAfterScreenshotA
                ) {
                    skipReason = Self.routeSkipReason(
                        stage: "A screenshot",
                        snapshot: snapshotA,
                        diagnostics: diagnosticsAfterScreenshotA
                    )
                } else {
                    try requireHomeFullStructure(
                        diagnosticsAfterScreenshotA,
                        snapshot: snapshotA,
                        expectedThemeID: themeA.manifest.id,
                        expectedHeroObjectPosition: Self.themeAHeroObjectPosition,
                        stage: "A screenshot"
                    )
                    let dimensionsA = try writePNG(
                        screenshotA,
                        to: artifacts.screenshotA
                    )
                    summary.screenshotA = ProductionE2EScreenshotSummary(
                        fileName: artifacts.screenshotA.lastPathComponent,
                        data: screenshotA,
                        dimensions: dimensionsA
                    )

                    let snapshotB = try await productionCoordinator.switchTheme(
                        to: themeBResolution.theme,
                        verifiedBundle: bundle
                    )
                    try require(
                        snapshotB.themeID == themeBResolution.theme.manifest.id,
                        "switch B 返回的 themeID 与请求主题不一致。"
                    )
                    try require(
                        snapshotB.generation != snapshotA.generation,
                        "A/B 热切换后 generation 未更新。"
                    )
                    summary.switchSnapshot = ProductionE2ESnapshotSummary(snapshotB)
                    let debugB = try await managedDebugObservation(
                        coordinator: productionCoordinator,
                        inspector: processInspector
                    )
                    try require(
                        debugB.process.pid == debugA.process.pid
                            && debugB.process.processGroupID == debugA.process.processGroupID
                            && debugB.process.startTime == debugA.process.startTime
                            && debugB.process.executableURL == debugA.process.executableURL
                            && debugB.process.arguments == debugA.process.arguments,
                        "热切换改变了受管 ChatGPT process identity。"
                    )
                    try require(
                        debugB.endpoint == debugA.endpoint
                            && debugB.listener.pid == debugA.listener.pid,
                        "热切换改变了 ActivePort 或 loopback listener owner。"
                    )
                    summary.debugAfterSwitch = ProductionE2EDebugSummary(debugB)

                    let diagnosticsB = try await retainedInjector.runDiagnostics()
                    summary.diagnosticsB = ProductionE2EDiagnosticsSummary(diagnosticsB)
                    if !Self.isHomeFullRoute(
                        snapshot: snapshotB,
                        diagnostics: diagnosticsB
                    ) {
                        skipReason = Self.routeSkipReason(
                            stage: "switch B",
                            snapshot: snapshotB,
                            diagnostics: diagnosticsB
                        )
                    } else {
                        try requireHomeFullStructure(
                            diagnosticsB,
                            snapshot: snapshotB,
                            expectedThemeID: themeBResolution.theme.manifest.id,
                            expectedHeroObjectPosition: Self.themeBHeroObjectPosition,
                            stage: "switch B"
                        )
                        let screenshotB = try await retainedInjector.captureScreenshotPNG()
                        let diagnosticsAfterScreenshotB = try await retainedInjector
                            .runDiagnostics()
                        summary.diagnosticsBAfterScreenshot = ProductionE2EDiagnosticsSummary(
                            diagnosticsAfterScreenshotB
                        )
                        if !Self.isHomeFullRoute(
                            snapshot: snapshotB,
                            diagnostics: diagnosticsAfterScreenshotB
                        ) {
                            skipReason = Self.routeSkipReason(
                                stage: "B screenshot",
                                snapshot: snapshotB,
                                diagnostics: diagnosticsAfterScreenshotB
                            )
                        } else {
                            try requireHomeFullStructure(
                                diagnosticsAfterScreenshotB,
                                snapshot: snapshotB,
                                expectedThemeID: themeBResolution.theme.manifest.id,
                                expectedHeroObjectPosition: Self.themeBHeroObjectPosition,
                                stage: "B screenshot"
                            )
                            try require(
                                diagnosticsAfterScreenshotB.viewportWidth
                                    == diagnosticsAfterScreenshotA.viewportWidth,
                                "A/B 截图前的 CSS viewport width 不一致。"
                            )
                            try require(
                                screenshotA != screenshotB,
                                "A/B Home Full PNG 截图完全相同。"
                            )
                            let dimensionsB = try writePNG(
                                screenshotB,
                                to: artifacts.screenshotB
                            )
                            try require(
                                dimensionsB == dimensionsA,
                                "A/B PNG IHDR 像素尺寸不一致。"
                            )
                            summary.screenshotB = ProductionE2EScreenshotSummary(
                                fileName: artifacts.screenshotB.lastPathComponent,
                                data: screenshotB,
                                dimensions: dimensionsB
                            )
                            summary.screenshotsDiffer = true
                        }
                    }
                }
            }
        } catch {
            bodyError = error
        }

        var cleanupErrors: [String] = []
        if applyWasInvoked, let coordinator, let verifiedBundle {
            let cleanupApplyConsent = applyConsent
            let cleanupResult = await Self.runDetachedCleanupTransaction(
                oldDebugPort: oldDebugPort,
                shouldDiscoverOldDebugPort: summary.applySnapshot != nil,
                operations: ProductionE2ECleanupOperations(
                    discoverOldDebugPort: {
                        let endpoint = try await StrictDevToolsActivePortDiscoverer()
                            .waitForEndpoint(
                                in: ProductionChatGPTRestarter
                                    .defaultUserDataDirectory,
                                timeout: .seconds(1)
                            )
                        return endpoint.port
                    },
                    restoreNormal: {
                        await Self.restoreNormal(
                            coordinator: coordinator,
                            verifiedBundle: verifiedBundle,
                            applyConsent: cleanupApplyConsent
                        )
                    },
                    waitForNormalPID: {
                        try await Self.waitForNormalChatGPTProcess(
                            bundle: verifiedBundle,
                            timeout: .seconds(5)
                        ).pid
                    },
                    waitForListenerToClose: { port in
                        try await Self.waitForListenerToClose(
                            port: port,
                            timeout: .seconds(5)
                        )
                    }
                )
            )
            oldDebugPort = cleanupResult.oldDebugPort
            summary.observedOldDebugPort = cleanupResult.oldDebugPort
            summary.restoreAttempts = cleanupResult.restoreAttempts
            summary.restoredNormalPID = cleanupResult.restoredNormalPID
            summary.restoredWithoutRemoteDebugging =
                cleanupResult.restoredNormalPID != nil
            summary.oldDebugPortHasNoListener =
                cleanupResult.oldDebugPortHasNoListener
            cleanupErrors.append(contentsOf: cleanupResult.errors)
        }

        summary.progress = await progressRecorder.entries()
        summary.skipReason = skipReason
        summary.errors = [bodyError?.localizedDescription].compactMap { $0 }
            + cleanupErrors
        summary.finishedAt = Self.timestamp()
        if !cleanupErrors.isEmpty {
            summary.outcome = "failed-cleanup"
        } else if bodyError != nil {
            summary.outcome = "failed"
        } else if skipReason != nil {
            summary.outcome = "skipped-not-home-full"
        } else {
            summary.outcome = "passed"
        }

        var summaryWriteError: Error?
        do {
            try writeSummary(summary, to: artifacts.summary)
        } catch {
            summaryWriteError = error
        }

        if !cleanupErrors.isEmpty {
            throw ProductionE2EHarnessError(
                "production E2E cleanup 未能证明原生状态："
                    + cleanupErrors.joined(separator: "；")
            )
        }
        if let bodyError { throw bodyError }
        if let summaryWriteError { throw summaryWriteError }
        if let skipReason { throw XCTSkip(skipReason) }
    }

    func testCleanupTransactionDoesNotInheritCallerCancellation() async {
        let recorder = ProductionE2ECleanupCancellationRecorder()
        let operations = ProductionE2ECleanupOperations(
            discoverOldDebugPort: {
                await recorder.record(stage: "discover-old-port")
                try await Task.sleep(for: .milliseconds(1))
                return 41_234
            },
            restoreNormal: {
                for attempt in 1 ... 2 {
                    await recorder.record(stage: "restore-\(attempt)")
                    do {
                        try await Task.sleep(for: .milliseconds(1))
                    } catch {
                        return ProductionE2ERestoreResult(
                            attempts: attempt,
                            errors: ["restore inherited cancellation"]
                        )
                    }
                }
                return ProductionE2ERestoreResult(attempts: 2, errors: [])
            },
            waitForNormalPID: {
                await recorder.record(stage: "wait-normal")
                try await Task.sleep(for: .milliseconds(1))
                return 43_210
            },
            waitForListenerToClose: { port in
                await recorder.record(stage: "wait-listener-\(port)")
                try await Task.sleep(for: .milliseconds(1))
            }
        )

        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        await recorder.record(stage: "caller")
        let result = await Self.runDetachedCleanupTransaction(
            oldDebugPort: nil,
            shouldDiscoverOldDebugPort: true,
            operations: operations
        )
        let entries = await recorder.entries()

        XCTAssertEqual(entries.first, .init(stage: "caller", wasCancelled: true))
        XCTAssertEqual(
            entries.dropFirst().map(\.stage),
            [
                "discover-old-port",
                "restore-1",
                "restore-2",
                "wait-normal",
                "wait-listener-41234",
            ]
        )
        XCTAssertTrue(entries.dropFirst().allSatisfy { !$0.wasCancelled })
        XCTAssertEqual(result.oldDebugPort, 41_234)
        XCTAssertEqual(result.restoreAttempts, 2)
        XCTAssertEqual(result.restoredNormalPID, 43_210)
        XCTAssertEqual(result.oldDebugPortHasNoListener, true)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testProductionArtifactsUsePrivatePermissions() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let artifacts = ProductionE2EArtifactURLs(
            root: temporaryRoot.appendingPathComponent(
                "production-e2e",
                isDirectory: true
            )
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try prepareArtifacts(artifacts)
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        ])
        _ = try writePNG(png, to: artifacts.screenshotA)
        try writeSummary(
            ProductionE2ESummary(startedAt: Self.timestamp()),
            to: artifacts.summary
        )

        XCTAssertEqual(try permissions(at: artifacts.root), 0o700)
        XCTAssertEqual(try permissions(at: artifacts.screenshotA), 0o600)
        XCTAssertEqual(try permissions(at: artifacts.summary), 0o600)
    }

    func testHomeFullEvidenceRequiresOwnedThemeHeroAndFocalPoint() throws {
        let snapshot = SkinInjectionSnapshot(
            generation: "generation-a",
            themeID: "original-night-city",
            appBuild: "test",
            targetID: "target",
            routeID: "home",
            effectiveMode: .full
        )
        func diagnostics(objectPosition: String) -> SkinRuntimeDiagnostics {
            SkinRuntimeDiagnostics(
                ownedNodeCount: 2,
                overlayCount: 1,
                styleCount: 1,
                ownedGeneration: snapshot.generation,
                ownedThemeID: snapshot.themeID,
                heroState: "ready",
                heroImageState: "ready",
                heroObjectPosition: objectPosition,
                overlayPointerEventsNone: true,
                overlayAriaHidden: true,
                overlayInert: true,
                composerFocusAccepted: true,
                routeID: "home",
                effectiveMode: .full,
                viewportWidth: 1_440
            )
        }

        XCTAssertNoThrow(
            try requireHomeFullStructure(
                diagnostics(objectPosition: "74% 34%"),
                snapshot: snapshot,
                expectedThemeID: snapshot.themeID,
                expectedHeroObjectPosition: "74% 34%",
                stage: "contract"
            )
        )
        XCTAssertThrowsError(
            try requireHomeFullStructure(
                diagnostics(objectPosition: "20% 34%"),
                snapshot: snapshot,
                expectedThemeID: snapshot.themeID,
                expectedHeroObjectPosition: "74% 34%",
                stage: "contract"
            )
        )
    }

    private func resolveThemeB(
        repository: ThemeRepository,
        sourceURL: URL
    ) async throws -> ProductionE2EThemeResolution {
        let service = ThemeImportService(repository: repository)
        let draft = try await service.prepare(sourceURL: sourceURL)
        let expectedSHA256 = Self.sha256(draft.imageData)
        let existing = try repository.loadUserThemes()
            .filter { theme in
                theme.manifest.name == Self.importedThemeName
                    && theme.manifest.hero.focalPoint == Self.importedThemeFocalPoint
                    && theme.heroAsset.sha256 == expectedSHA256
            }
            .sorted { $0.manifest.id < $1.manifest.id }
        if let theme = existing.first {
            return ProductionE2EThemeResolution(
                theme: theme,
                wasImported: false,
                expectedSHA256: expectedSHA256
            )
        }

        let result = try await service.commit(
            draft: draft,
            displayName: Self.importedThemeName,
            focalPoint: Self.importedThemeFocalPoint
        )
        return ProductionE2EThemeResolution(
            theme: result.theme,
            wasImported: true,
            expectedSHA256: expectedSHA256
        )
    }

    private static func normalChatGPTProcess(
        bundle: VerifiedChatGPTBundle,
        inspector: DarwinRuntimeProcessInspector
    ) async throws -> RuntimeProcessSnapshot {
        let applications = await NSWorkspaceRunningChatGPTApplicationController()
            .runningApplications(bundleIdentifier: bundle.bundleIdentifier)
        guard applications.count == 1 else {
            throw ProductionE2EHarnessError(
                "production E2E 要求恰好一个正在运行的正常 ChatGPT；"
                    + "实际 \(applications.count) 个。"
            )
        }
        guard let application = applications.first else {
            throw ProductionE2EHarnessError("没有正在运行的 ChatGPT。")
        }
        guard application.executableURL?.resolvingSymlinksInPath().standardizedFileURL
            == bundle.executableURL.resolvingSymlinksInPath().standardizedFileURL
        else {
            throw ProductionE2EHarnessError(
                "运行中的 ChatGPT executable 与官方 bundle 不一致。"
            )
        }
        let process = try inspector.snapshot(pid: application.pid)
        guard !Self.hasRemoteDebuggingArgument(process.arguments) else {
            throw ProductionE2EHarnessError(
                "production E2E 要求 normal ChatGPT 不含 remote-debugging/"
                    + "user-data-dir 参数。"
            )
        }
        return process
    }

    private static func waitForNormalChatGPTProcess(
        bundle: VerifiedChatGPTBundle,
        timeout: Duration
    ) async throws -> RuntimeProcessSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?
        repeat {
            do {
                return try await Self.normalChatGPTProcess(
                    bundle: bundle,
                    inspector: DarwinRuntimeProcessInspector()
                )
            } catch {
                lastError = error
            }
            if clock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))
        } while clock.now < deadline
        throw lastError ?? ProductionE2EHarnessError(
            "等待恢复正常 ChatGPT 超时。"
        )
    }

    private func managedDebugObservation(
        coordinator: SkinSessionCoordinator,
        inspector: DarwinRuntimeProcessInspector
    ) async throws -> ProductionE2EDebugObservation {
        guard let pid = await coordinator.managedProcessIdentifier() else {
            throw ProductionE2EHarnessError("coordinator 未暴露受管 debug PID。")
        }
        let process = try inspector.snapshot(pid: pid)
        let profile = ProductionChatGPTRestarter.defaultUserDataDirectory
        try require(
            process.arguments.contains("--user-data-dir=\(profile.path)")
                && process.arguments.contains("--remote-debugging-address=127.0.0.1")
                && process.arguments.contains("--remote-debugging-port=0"),
            "受管 debug PID 缺少严格 loopback/ephemeral-port 参数。"
        )
        let endpoint = try await StrictDevToolsActivePortDiscoverer().waitForEndpoint(
            in: profile,
            timeout: .seconds(2)
        )
        let listener = try DebugListenerVerifier().verify(
            port: endpoint.port,
            belongsTo: pid,
            processInspector: inspector
        )
        try require(
            listener.address == "127.0.0.1"
                && listener.pid == pid
                && listener.port == endpoint.port,
            "ActivePort listener 未严格绑定到当前受管 PID 的 loopback。"
        )
        return ProductionE2EDebugObservation(
            process: process,
            endpoint: endpoint,
            listener: listener
        )
    }

    private static func runDetachedCleanupTransaction(
        oldDebugPort: UInt16?,
        shouldDiscoverOldDebugPort: Bool,
        operations: ProductionE2ECleanupOperations
    ) async -> ProductionE2ECleanupResult {
        let task = Task.detached {
            await Self.executeCleanupTransaction(
                oldDebugPort: oldDebugPort,
                shouldDiscoverOldDebugPort: shouldDiscoverOldDebugPort,
                operations: operations
            )
        }
        return await task.value
    }

    private static func executeCleanupTransaction(
        oldDebugPort initialOldDebugPort: UInt16?,
        shouldDiscoverOldDebugPort: Bool,
        operations: ProductionE2ECleanupOperations
    ) async -> ProductionE2ECleanupResult {
        var oldDebugPort = initialOldDebugPort
        var errors: [String] = []

        if oldDebugPort == nil, shouldDiscoverOldDebugPort {
            do {
                oldDebugPort = try await operations.discoverOldDebugPort()
            } catch {
                errors.append(
                    "apply 已成功，但恢复前无法重新读取旧 ActivePort："
                        + error.localizedDescription
                )
            }
        }

        let restoreResult = await operations.restoreNormal()
        errors.append(contentsOf: restoreResult.errors)

        var restoredNormalPID: Int32?
        do {
            restoredNormalPID = try await operations.waitForNormalPID()
        } catch {
            errors.append(
                "恢复后的原生 ChatGPT 身份/argv 复验失败："
                    + error.localizedDescription
            )
        }

        var oldDebugPortHasNoListener: Bool?
        if let oldDebugPort {
            do {
                try await operations.waitForListenerToClose(oldDebugPort)
                oldDebugPortHasNoListener = true
            } catch {
                errors.append(
                    "旧 CDP 端口 \(oldDebugPort) 仍不安全："
                        + error.localizedDescription
                )
            }
        }

        return ProductionE2ECleanupResult(
            oldDebugPort: oldDebugPort,
            restoreAttempts: restoreResult.attempts,
            restoredNormalPID: restoredNormalPID,
            oldDebugPortHasNoListener: oldDebugPortHasNoListener,
            errors: errors
        )
    }

    private static func restoreNormal(
        coordinator: SkinSessionCoordinator,
        verifiedBundle: VerifiedChatGPTBundle,
        applyConsent: ExplicitRestartConsent?
    ) async -> ProductionE2ERestoreResult {
        var errors: [String] = []
        for attempt in 1 ... 2 {
            guard let consent = ExplicitRestartConsent(userConfirmed: true) else {
                errors.append("第 \(attempt) 次恢复无法创建 fresh consent。")
                continue
            }
            if let applyConsent, consent.id == applyConsent.id {
                errors.append("第 \(attempt) 次恢复意外复用了 apply consent。")
                continue
            }
            do {
                try await coordinator.restore(
                    verifiedBundle: verifiedBundle,
                    consent: consent
                )
                return ProductionE2ERestoreResult(
                    attempts: attempt,
                    errors: errors
                )
            } catch {
                errors.append(
                    "第 \(attempt) 次 fresh-consent restore 失败：\(error.localizedDescription)"
                )
            }
        }
        return ProductionE2ERestoreResult(attempts: 2, errors: errors)
    }

    private static func waitForListenerToClose(
        port: UInt16,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastDetail = "旧端口仍有 listener。"
        repeat {
            let result = try FoundationCommandExecutor().run(
                executableURL: URL(
                    fileURLWithPath: "/usr/sbin/lsof",
                    isDirectory: false
                ),
                arguments: [
                    "-nP",
                    "-iTCP:\(port)",
                    "-sTCP:LISTEN",
                    "-FpnT",
                ]
            )
            if result.terminationStatus == 1,
               result.standardOutput.isEmpty,
               result.standardError.isEmpty
            {
                return
            }
            if result.terminationStatus == 0, !result.standardOutput.isEmpty {
                lastDetail = String(
                    data: result.standardOutput.prefix(4_096),
                    encoding: .utf8
                ) ?? "旧端口存在不可解析的 listener。"
            } else {
                let stderr = String(
                    data: result.standardError.prefix(4_096),
                    encoding: .utf8
                ) ?? ""
                throw ProductionE2EHarnessError(
                    "lsof 无法可靠证明端口已关闭（status="
                        + "\(result.terminationStatus)）：\(stderr)"
                )
            }
            if clock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))
        } while clock.now < deadline
        throw ProductionE2EHarnessError(lastDetail)
    }

    private func prepareArtifacts(_ artifacts: ProductionE2EArtifactURLs) throws {
        try FileManager.default.createDirectory(
            at: artifacts.root,
            withIntermediateDirectories: true
        )
        try enforcePrivatePermissions(
            at: artifacts.root,
            permissions: 0o700,
            expectedType: .typeDirectory
        )
        for url in [artifacts.screenshotA, artifacts.screenshotB, artifacts.summary]
            where FileManager.default.fileExists(atPath: url.path)
        {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func writePNG(
        _ data: Data,
        to url: URL
    ) throws -> ProductionE2EPNGDimensions {
        try require(
            data.count >= 24
                && Array(data.prefix(8))
                    == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "截图不是有效 PNG。"
        )
        try require(
            Array(data[12 ..< 16]) == [0x49, 0x48, 0x44, 0x52],
            "截图 PNG 首个 chunk 不是 IHDR。"
        )
        let width = data[16 ..< 20].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
        let height = data[20 ..< 24].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
        try require(width > 0 && height > 0, "截图 PNG IHDR 尺寸无效。")
        try data.write(to: url, options: [.atomic])
        try enforcePrivatePermissions(
            at: url,
            permissions: 0o600,
            expectedType: .typeRegular
        )
        return ProductionE2EPNGDimensions(
            width: Int(width),
            height: Int(height)
        )
    }

    private func writeSummary(
        _ summary: ProductionE2ESummary,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: url, options: [.atomic])
        try enforcePrivatePermissions(
            at: url,
            permissions: 0o600,
            expectedType: .typeRegular
        )
    }

    private func enforcePrivatePermissions(
        at url: URL,
        permissions: Int,
        expectedType: FileAttributeType
    ) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == expectedType,
              let actualPermissions = attributes[.posixPermissions] as? NSNumber,
              actualPermissions.intValue & 0o777 == permissions
        else {
            throw ProductionE2EHarnessError(
                "production E2E artifact 类型或权限复验失败：\(url.path)"
            )
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let value = attributes[.posixPermissions] as? NSNumber else {
            throw ProductionE2EHarnessError(
                "无法读取 production E2E artifact 权限：\(url.path)"
            )
        }
        return value.intValue & 0o777
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String
    ) throws {
        guard condition() else { throw ProductionE2EHarnessError(message()) }
    }

    private func requireHomeFullStructure(
        _ diagnostics: SkinRuntimeDiagnostics,
        snapshot: SkinInjectionSnapshot,
        expectedThemeID: String,
        expectedHeroObjectPosition: String,
        stage: String
    ) throws {
        try require(
            diagnostics.ownedNodeCount == 2
                && diagnostics.overlayCount == 1
                && diagnostics.styleCount == 1
                && diagnostics.ownedGeneration == snapshot.generation
                && diagnostics.ownedThemeID == expectedThemeID
                && diagnostics.heroState == "ready"
                && diagnostics.heroImageState == "ready"
                && diagnostics.heroObjectPosition == expectedHeroObjectPosition
                && diagnostics.overlayPointerEventsNone
                && diagnostics.overlayAriaHidden
                && diagnostics.overlayInert
                && diagnostics.composerFocusAccepted
                && diagnostics.viewportWidth >= 1_024,
            "\(stage) 已是 Home Full，但 owned/theme/hero/accessibility/focus/viewport "
                + "结构合同不满足。"
        )
    }

    private static func isHomeFullRoute(
        snapshot: SkinInjectionSnapshot,
        diagnostics: SkinRuntimeDiagnostics
    ) -> Bool {
        snapshot.routeID == "home"
            && snapshot.effectiveMode == .full
            && diagnostics.routeID == "home"
            && diagnostics.effectiveMode == .full
    }

    private static func routeSkipReason(
        stage: String,
        snapshot: SkinInjectionSnapshot,
        diagnostics: SkinRuntimeDiagnostics
    ) -> String {
        "\(stage) 当前不是 Home Full（snapshot="
            + "\(snapshot.routeID)/\(snapshot.effectiveMode.rawValue), diagnostics="
            + "\(diagnostics.routeID)/\(diagnostics.effectiveMode.rawValue)）；"
            + "未导航、未读取正文，已仅保留结构诊断并恢复原生 ChatGPT。"
    }

    private static func hasRemoteDebuggingArgument(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            argument == "--remote-debugging-pipe"
                || argument.hasPrefix("--remote-debugging-address")
                || argument.hasPrefix("--remote-debugging-port")
                || argument == "--user-data-dir"
                || argument.hasPrefix("--user-data-dir=")
        }
    }

    private static func userThemesRoot() -> URL {
        // E2E 导入必须落在 QA 产物目录内，绝不能写进真实用户主题库
        // （2026-07-17 曾把 "Left Focus" 测试主题污染进用户库）。
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("QAArtifacts/production-e2e/user-themes", isDirectory: true)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private actor ProductionE2EProgressRecorder {
    private var values: [String] = []

    func record(_ state: SkinSessionState) {
        values.append(state.title)
    }

    func entries() -> [String] {
        values
    }
}

private actor ProductionE2ECleanupCancellationRecorder {
    struct Entry: Sendable, Equatable {
        let stage: String
        let wasCancelled: Bool
    }

    private var values: [Entry] = []

    func record(stage: String) {
        values.append(
            Entry(stage: stage, wasCancelled: Task.isCancelled)
        )
    }

    func entries() -> [Entry] {
        values
    }
}

private struct ProductionE2EHarnessError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct ProductionE2EThemeResolution {
    let theme: LoadedTheme
    let wasImported: Bool
    let expectedSHA256: String
}

private struct ProductionE2EPNGDimensions: Equatable {
    let width: Int
    let height: Int
}

private struct ProductionE2EDebugObservation {
    let process: RuntimeProcessSnapshot
    let endpoint: DevToolsActivePort
    let listener: VerifiedDebugListener
}

private struct ProductionE2ERestoreResult: Sendable {
    let attempts: Int
    let errors: [String]
}

private struct ProductionE2ECleanupOperations: Sendable {
    let discoverOldDebugPort: @Sendable () async throws -> UInt16
    let restoreNormal: @Sendable () async -> ProductionE2ERestoreResult
    let waitForNormalPID: @Sendable () async throws -> Int32
    let waitForListenerToClose: @Sendable (UInt16) async throws -> Void
}

private struct ProductionE2ECleanupResult: Sendable {
    let oldDebugPort: UInt16?
    let restoreAttempts: Int
    let restoredNormalPID: Int32?
    let oldDebugPortHasNoListener: Bool?
    let errors: [String]
}

private struct ProductionE2EArtifactURLs {
    let root: URL
    let screenshotA: URL
    let screenshotB: URL
    let summary: URL

    init(root: URL) {
        self.root = root
        screenshotA = root.appendingPathComponent("theme-a-home-full.png")
        screenshotB = root.appendingPathComponent("theme-b-home-full.png")
        summary = root.appendingPathComponent("summary.json")
    }
}

private struct ProductionE2ESummary: Encodable {
    let schemaVersion = 1
    let startedAt: String
    var finishedAt: String?
    var outcome = "running"
    var app: ProductionE2EAppSummary?
    var normalPIDBeforeImport: Int32?
    var normalPIDAfterImport: Int32?
    var themeA: ProductionE2EThemeSummary?
    var themeB: ProductionE2EThemeSummary?
    var themeBWasImported: Bool?
    var themeBExpectedSHA256: String?
    var applySnapshot: ProductionE2ESnapshotSummary?
    var switchSnapshot: ProductionE2ESnapshotSummary?
    var debugBeforeSwitch: ProductionE2EDebugSummary?
    var debugAfterSwitch: ProductionE2EDebugSummary?
    var diagnosticsA: ProductionE2EDiagnosticsSummary?
    var diagnosticsAAfterScreenshot: ProductionE2EDiagnosticsSummary?
    var diagnosticsB: ProductionE2EDiagnosticsSummary?
    var diagnosticsBAfterScreenshot: ProductionE2EDiagnosticsSummary?
    var screenshotA: ProductionE2EScreenshotSummary?
    var screenshotB: ProductionE2EScreenshotSummary?
    var screenshotsDiffer: Bool?
    var observedOldDebugPort: UInt16?
    var restoreAttempts: Int?
    var restoredNormalPID: Int32?
    var restoredWithoutRemoteDebugging: Bool?
    var oldDebugPortHasNoListener: Bool?
    var progress: [String] = []
    var skipReason: String?
    var errors: [String] = []
}

private struct ProductionE2EAppSummary: Encodable {
    let path: String
    let bundleIdentifier: String
    let teamIdentifier: String
    let shortVersion: String
    let buildVersion: String
}

private struct ProductionE2EThemeSummary: Encodable {
    let id: String
    let name: String
    let source: String
    let focalX: Double
    let focalY: Double
    let heroSHA256: String

    init(_ theme: LoadedTheme) {
        id = theme.manifest.id
        name = theme.manifest.name
        source = theme.source.rawValue
        focalX = theme.manifest.hero.focalPoint.x
        focalY = theme.manifest.hero.focalPoint.y
        heroSHA256 = theme.heroAsset.sha256
    }
}

private struct ProductionE2ESnapshotSummary: Encodable {
    let generation: String
    let themeID: String
    let appBuild: String
    let targetID: String
    let routeID: String
    let effectiveMode: String

    init(_ snapshot: SkinInjectionSnapshot) {
        generation = snapshot.generation
        themeID = snapshot.themeID
        appBuild = snapshot.appBuild
        targetID = snapshot.targetID
        routeID = snapshot.routeID
        effectiveMode = snapshot.effectiveMode.rawValue
    }
}

private struct ProductionE2EDebugSummary: Encodable {
    let pid: Int32
    let processGroupID: Int32
    let port: UInt16
    let listenerAddress: String
    let listenerOwnerPID: Int32
    let hasLoopbackArgument: Bool
    let hasEphemeralPortArgument: Bool

    init(_ observation: ProductionE2EDebugObservation) {
        pid = observation.process.pid
        processGroupID = observation.process.processGroupID
        port = observation.endpoint.port
        listenerAddress = observation.listener.address
        listenerOwnerPID = observation.listener.pid
        hasLoopbackArgument = observation.process.arguments.contains(
            "--remote-debugging-address=127.0.0.1"
        )
        hasEphemeralPortArgument = observation.process.arguments.contains(
            "--remote-debugging-port=0"
        )
    }
}

private struct ProductionE2EDiagnosticsSummary: Encodable {
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
    let effectiveMode: String
    let viewportWidth: Int

    init(_ diagnostics: SkinRuntimeDiagnostics) {
        ownedNodeCount = diagnostics.ownedNodeCount
        overlayCount = diagnostics.overlayCount
        styleCount = diagnostics.styleCount
        ownedGeneration = diagnostics.ownedGeneration
        ownedThemeID = diagnostics.ownedThemeID
        heroState = diagnostics.heroState
        heroImageState = diagnostics.heroImageState
        heroObjectPosition = diagnostics.heroObjectPosition
        overlayPointerEventsNone = diagnostics.overlayPointerEventsNone
        overlayAriaHidden = diagnostics.overlayAriaHidden
        overlayInert = diagnostics.overlayInert
        composerFocusAccepted = diagnostics.composerFocusAccepted
        routeID = diagnostics.routeID
        effectiveMode = diagnostics.effectiveMode.rawValue
        viewportWidth = diagnostics.viewportWidth
    }
}

private struct ProductionE2EScreenshotSummary: Encodable {
    let fileName: String
    let byteCount: Int
    let sha256: String
    let pixelWidth: Int
    let pixelHeight: Int

    init(
        fileName: String,
        data: Data,
        dimensions: ProductionE2EPNGDimensions
    ) {
        self.fileName = fileName
        byteCount = data.count
        sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        pixelWidth = dimensions.width
        pixelHeight = dimensions.height
    }
}
