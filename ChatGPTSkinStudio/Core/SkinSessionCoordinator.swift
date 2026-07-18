import Foundation

actor SkinSessionCoordinator {
    typealias ProgressHandler = @Sendable (SkinSessionState) async -> Void

    private struct ManagedSession {
        enum Phase: Equatable {
            case applying
            case active
            case recovering
            case recoveryFailed
        }

        let session: ProductionDebugSession
        let progress: ProgressHandler
        var theme: LoadedTheme
        var generation: String?
        var monitorTask: Task<Void, Never>?
        var phase: Phase
    }

    private let restartGate: ProductionRestartGate
    private let restarter: any ProductionChatGPTRestarting
    private let injector: any SkinInjecting
    private let adapterRegistry: StructuralAdapterRegistry
    private let sessionValidator: any ProductionDebugSessionValidating
    private var activeSession: ManagedSession?

    init(
        restartGate: ProductionRestartGate = ProductionRestartGate(),
        restarter: any ProductionChatGPTRestarting = ProductionChatGPTRestarter(),
        injector: any SkinInjecting = SkinInjector(),
        adapterRegistry: StructuralAdapterRegistry = .production,
        sessionValidator: any ProductionDebugSessionValidating =
            ProductionDebugSessionValidator()
    ) {
        self.restartGate = restartGate
        self.restarter = restarter
        self.injector = injector
        self.adapterRegistry = adapterRegistry
        self.sessionValidator = sessionValidator
    }

    init(
        restartGate: ProductionRestartGate = ProductionRestartGate(),
        restarter: any ProductionChatGPTRestarting = ProductionChatGPTRestarter(),
        injector: any SkinInjecting = SkinInjector(),
        adapter: any ChatGPTAdapter,
        sessionValidator: any ProductionDebugSessionValidating =
            ProductionDebugSessionValidator()
    ) throws {
        self.restartGate = restartGate
        self.restarter = restarter
        self.injector = injector
        self.adapterRegistry = try StructuralAdapterRegistry(
            trustedAdapters: [adapter]
        )
        self.sessionValidator = sessionValidator
    }

    func apply(
        theme: LoadedTheme,
        verifiedBundle: VerifiedChatGPTBundle,
        consent: ExplicitRestartConsent,
        progress: @escaping ProgressHandler
    ) async throws -> SkinInjectionSnapshot {
        DiagnosticsLogger.shared.log("apply-begin", "theme=\(theme.manifest.id)")
        guard activeSession == nil else {
            throw SkinError.invalidConfiguration("已有受管皮肤会话，请先恢复原生界面。")
        }
        try Task.checkCancellation()
        _ = try adapterRegistry.compatibleAdapters(
            themeCompatibility: theme.manifest.compatibility,
            verifiedBundle: verifiedBundle
        )
        DiagnosticsLogger.shared.log("apply-compatibility-ok", "theme=\(theme.manifest.id)")

        await progress(.launchingDebugSession)
        let request = try restartGate.makeRequest(
            bundle: verifiedBundle,
            consent: consent
        )
        try Task.checkCancellation()
        DiagnosticsLogger.shared.log("apply-consent-ok", "theme=\(theme.manifest.id)")
        let session: ProductionDebugSession
        do {
            session = try await restarter.restartForDebugging(request)
        } catch {
            DiagnosticsLogger.shared.log(
                "apply-restart-failed",
                "theme=\(theme.manifest.id) error=\(error.localizedDescription)"
            )
            throw error
        }
        DiagnosticsLogger.shared.log(
            "apply-debug-session-started",
            "theme=\(theme.manifest.id) port=\(session.endpoint.port)"
        )
        activeSession = ManagedSession(
            session: session,
            progress: progress,
            theme: theme,
            generation: nil,
            monitorTask: nil,
            phase: .applying
        )

        do {
            try Task.checkCancellation()
            await progress(.discoveringRenderer)
            await progress(.injecting(themeID: theme.manifest.id))
            try Task.checkCancellation()
            let preInstallValidator = self.sessionValidator
            try await Task.detached {
                try await preInstallValidator.validate(session)
            }.value
            try Task.checkCancellation()
            let handle = try await injector.install(
                port: Int(session.endpoint.port),
                theme: theme,
                verifiedBundle: session.bundle,
                registry: adapterRegistry
            )
            let postInstallValidator = self.sessionValidator
            try await Task.detached {
                try await postInstallValidator.validate(session)
            }.value
            try Task.checkCancellation()

            guard var managed = activeSession,
                  managed.session.id == session.id,
                  managed.phase == .applying
            else {
                throw SkinError.cancelled
            }
            managed.generation = handle.snapshot.generation
            managed.phase = .active
            managed.monitorTask = monitorInvalidations(
                handle.invalidations,
                sessionID: session.id
            )
            activeSession = managed
            DiagnosticsLogger.shared.log(
                "apply-succeeded",
                "generation=\(handle.snapshot.generation) theme=\(theme.manifest.id)"
            )
            return handle.snapshot
        } catch {
            let injectionError = error
            DiagnosticsLogger.shared.log(
                "apply-failed",
                "theme=\(theme.manifest.id) error=\(injectionError.localizedDescription)"
            )
            let injector = self.injector
            let restarter = self.restarter
            do {
                _ = try await Task.detached {
                    try? await injector.restore()
                    return try await restarter.rollbackToNormal(session)
                }.value
                if activeSession?.session.id == session.id {
                    activeSession?.monitorTask?.cancel()
                    activeSession = nil
                }
                DiagnosticsLogger.shared.log("apply-rollback-ok", "theme=\(theme.manifest.id)")
            } catch let rollbackError {
                DiagnosticsLogger.shared.log(
                    "apply-rollback-failed",
                    "theme=\(theme.manifest.id) error=\(rollbackError.localizedDescription)"
                )
                if var managed = activeSession,
                   managed.session.id == session.id
                {
                    managed.monitorTask?.cancel()
                    managed.monitorTask = nil
                    managed.phase = .recoveryFailed
                    activeSession = managed
                }
                throw RuntimeSecurityError.automaticRollbackFailed(
                    primary: injectionError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw injectionError
        }
    }

    func switchTheme(
        to theme: LoadedTheme,
        verifiedBundle: VerifiedChatGPTBundle
    ) async throws -> SkinInjectionSnapshot {
        guard var managed = activeSession else {
            throw SkinError.invalidConfiguration("没有可热切换的受管皮肤会话。")
        }
        guard managed.session.bundle.stableIdentity == verifiedBundle.stableIdentity else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "受管 session 与当前已验证 ChatGPT bundle 不一致"
            )
        }
        guard managed.phase == .active else {
            throw SkinError.invalidConfiguration("ChatGPT 皮肤会话正忙，请稍后重试。")
        }
        guard managed.theme.manifest.id != theme.manifest.id else {
            throw SkinError.invalidConfiguration("所选主题已在当前受管会话中启用。")
        }
        _ = try adapterRegistry.compatibleAdapters(
            themeCompatibility: theme.manifest.compatibility,
            verifiedBundle: verifiedBundle
        )

        let previousTheme = managed.theme
        let session = managed.session
        let previousGeneration = managed.generation
        try await sessionValidator.validate(session)
        // A validator may deliberately finish its identity checks after its
        // caller was cancelled. Reject that cancellation before mutating the
        // active phase, monitor, generation, or renderer state.
        try Task.checkCancellation()
        guard let current = activeSession,
              current.session.id == session.id,
              current.phase == .active,
              current.generation == previousGeneration,
              current.theme.manifest.id == previousTheme.manifest.id
        else {
            throw SkinError.cancelled
        }
        managed = current
        managed.phase = .applying
        managed.monitorTask?.cancel()
        managed.monitorTask = nil
        activeSession = managed
        await managed.progress(.switchingTheme(themeID: theme.manifest.id))

        do {
            try await injector.restore()
        } catch {
            let terminalError = await transitionToThemeSwitchRecoveryRequired(
                sessionID: session.id,
                previousTheme: previousTheme,
                failedTheme: theme,
                cause: "主题切换前无法确认旧主题 cleanup 完整",
                restorationFailure: error.localizedDescription,
                progress: managed.progress
            )
            throw terminalError
        }

        do {
            try Task.checkCancellation()
            let handle = try await injector.install(
                port: Int(session.endpoint.port),
                theme: theme,
                verifiedBundle: session.bundle,
                registry: adapterRegistry
            )
            try Task.checkCancellation()
            let postInstallValidator = self.sessionValidator
            do {
                try await Task.detached {
                    try await postInstallValidator.validate(session)
                }.value
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                let postValidationFailure = error
                let cleanupSummary = await detachedStrictCleanupSummary(
                    context: "新主题后验验证失败后的"
                )
                let terminalError = await transitionToThemeSwitchRecoveryRequired(
                    sessionID: session.id,
                    previousTheme: previousTheme,
                    failedTheme: theme,
                    cause: "新主题安装后的受管 session 后验验证失败："
                        + postValidationFailure.localizedDescription,
                    restorationFailure: cleanupSummary,
                    progress: managed.progress
                )
                throw terminalError
            }
            try Task.checkCancellation()
            guard var current = activeSession,
                  current.session.id == session.id,
                  current.phase == .applying
            else {
                throw SkinError.cancelled
            }
            current.theme = theme
            current.generation = handle.snapshot.generation
            current.phase = .active
            current.monitorTask = monitorInvalidations(
                handle.invalidations,
                sessionID: session.id
            )
            activeSession = current
            return handle.snapshot
        } catch {
            let switchFailure = error
            if let terminalError = switchFailure as? ThemeSwitchError,
               case .recoveryRequired = terminalError
            {
                throw terminalError
            }
            if let skinError = switchFailure as? SkinError,
               case .cleanupFailed = skinError
            {
                let terminalError = await transitionToThemeSwitchRecoveryRequired(
                    sessionID: session.id,
                    previousTheme: previousTheme,
                    failedTheme: theme,
                    cause: switchFailure.localizedDescription,
                    restorationFailure: "新主题失败清理无法确认零残留，已禁止自动重装旧主题。",
                    progress: managed.progress
                )
                throw terminalError
            }
            let injector = self.injector
            let sessionValidator = self.sessionValidator
            let adapterRegistry = self.adapterRegistry
            let restoredHandle: SkinInjectionHandle
            do {
                restoredHandle = try await Task.detached {
                    try await sessionValidator.validate(session)
                    try await injector.restore()
                    return try await injector.install(
                        port: Int(session.endpoint.port),
                        theme: previousTheme,
                        verifiedBundle: session.bundle,
                        registry: adapterRegistry
                    )
                }.value
            } catch {
                let restorationFailure = error
                let terminalError = await transitionToThemeSwitchRecoveryRequired(
                    sessionID: session.id,
                    previousTheme: previousTheme,
                    failedTheme: theme,
                    cause: switchFailure.localizedDescription,
                    restorationFailure: restorationFailure.localizedDescription,
                    progress: managed.progress
                )
                throw terminalError
            }

            do {
                try await Task.detached {
                    try await sessionValidator.validate(session)
                }.value
            } catch {
                let postValidationFailure = error
                let cleanupSummary = await detachedStrictCleanupSummary(
                    context: "旧主题补偿安装后验验证失败后的"
                )
                let terminalError = await transitionToThemeSwitchRecoveryRequired(
                    sessionID: session.id,
                    previousTheme: previousTheme,
                    failedTheme: theme,
                    cause: "旧主题补偿安装后的受管 session 后验验证失败："
                        + postValidationFailure.localizedDescription,
                    restorationFailure: cleanupSummary,
                    progress: managed.progress
                )
                throw terminalError
            }

            guard var current = activeSession,
                  current.session.id == session.id,
                  current.phase == .applying
            else {
                throw SkinError.cancelled
            }
            current.theme = previousTheme
            current.generation = restoredHandle.snapshot.generation
            current.phase = .active
            current.monitorTask = monitorInvalidations(
                restoredHandle.invalidations,
                sessionID: session.id
            )
            activeSession = current
            throw ThemeSwitchError.previousThemeRestored(
                snapshot: restoredHandle.snapshot,
                failedThemeID: theme.manifest.id,
                cause: switchFailure.localizedDescription
            )
        }
    }

    func restore(
        verifiedBundle: VerifiedChatGPTBundle,
        consent: ExplicitRestartConsent
    ) async throws {
        guard var managed = activeSession else {
            if try await restarter.recoverPendingToNormal(
                verifiedBundle: verifiedBundle,
                consent: consent
            ) != nil {
                return
            }
            try await injector.restore()
            return
        }
        guard managed.session.bundle.stableIdentity == verifiedBundle.stableIdentity else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "受管 session 与当前已验证 ChatGPT bundle 不一致"
            )
        }
        guard managed.phase == .active || managed.phase == .recoveryFailed else {
            throw SkinError.invalidConfiguration("ChatGPT 正在恢复中，请稍后重试。")
        }

        managed.phase = .recovering
        managed.monitorTask?.cancel()
        managed.monitorTask = nil
        activeSession = managed

        // A normal process restart clears renderer state even if the best-effort
        // in-page cleanup cannot complete because the target is already closing.
        try? await injector.restore()
        do {
            _ = try await restarter.restoreToNormal(
                managed.session,
                consent: consent
            )
            if activeSession?.session.id == managed.session.id {
                activeSession = nil
            }
        } catch {
            if var current = activeSession,
               current.session.id == managed.session.id
            {
                current.phase = .recoveryFailed
                activeSession = current
            }
            throw error
        }
    }

    func snapshot() async -> SkinInjectionSnapshot? {
        await injector.snapshot()
    }

    func isActive(generation: String) -> Bool {
        guard let activeSession else { return false }
        return activeSession.phase == .active
            && activeSession.generation == generation
    }

    func managedProcessIdentifier() -> Int32? {
        activeSession?.session.process.pid
    }

    private func transitionToThemeSwitchRecoveryRequired(
        sessionID: UUID,
        previousTheme: LoadedTheme,
        failedTheme: LoadedTheme,
        cause: String,
        restorationFailure: String,
        progress: ProgressHandler
    ) async -> ThemeSwitchError {
        if var current = activeSession,
           current.session.id == sessionID
        {
            current.theme = previousTheme
            current.generation = nil
            current.monitorTask?.cancel()
            current.monitorTask = nil
            current.phase = .recoveryFailed
            activeSession = current
        }
        let terminalError = ThemeSwitchError.recoveryRequired(
            previousThemeID: previousTheme.manifest.id,
            failedThemeID: failedTheme.manifest.id,
            cause: cause,
            restorationFailure: restorationFailure
        )
        await progress(
            .recoveryRequired(message: terminalError.localizedDescription)
        )
        return terminalError
    }

    private func detachedStrictCleanupSummary(context: String) async -> String {
        let injector = self.injector
        do {
            try await Task.detached {
                try await injector.restore()
            }.value
            return "\(context) strict cleanup 已完成，但受管 session 已失去信任，仍需用户显式恢复。"
        } catch {
            return "\(context) strict cleanup 无法确认零残留：\(error.localizedDescription)"
        }
    }

    private func monitorInvalidations(
        _ invalidations: AsyncStream<SkinRuntimeInvalidation>,
        sessionID: UUID
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await invalidation in invalidations {
                guard !Task.isCancelled else { return }
                await self?.handleRuntimeInvalidation(
                    invalidation,
                    sessionID: sessionID
                )
            }
        }
    }

    private func handleRuntimeInvalidation(
        _ invalidation: SkinRuntimeInvalidation,
        sessionID: UUID
    ) async {
        guard var managed = activeSession,
              managed.session.id == sessionID,
              managed.phase == .active,
              managed.generation == invalidation.generation
        else {
            return
        }

        DiagnosticsLogger.shared.log(
            "invalidation-handling",
            "generation=\(invalidation.generation) kind=\(invalidation.kind.rawValue) "
                + "message=\(invalidation.message)"
        )
        managed.phase = .recovering
        activeSession = managed
        await managed.progress(.cleaningUp)
        try? await injector.restore()

        do {
            _ = try await restarter.rollbackToNormal(managed.session)
            DiagnosticsLogger.shared.log(
                "invalidation-rollback-ok",
                "generation=\(invalidation.generation)"
            )
            guard activeSession?.session.id == sessionID else { return }
            activeSession = nil

            switch invalidation.kind {
            case .incompatible:
                await managed.progress(
                    .incompatible(
                        message: invalidation.message
                            + " 皮肤已撤销，ChatGPT 已恢复正常启动。"
                    )
                )
            case .runtimeUnavailable:
                await managed.progress(
                    .degraded(
                        message: invalidation.message
                            + " ChatGPT 已恢复正常启动。"
                    )
                )
            }
        } catch {
            DiagnosticsLogger.shared.log(
                "invalidation-rollback-failed",
                "generation=\(invalidation.generation) error=\(error.localizedDescription)"
            )
            let recoveryError = RuntimeSecurityError.automaticRollbackFailed(
                primary: invalidation.message,
                rollback: error.localizedDescription
            )
            if var current = activeSession,
               current.session.id == sessionID
            {
                current.monitorTask = nil
                current.phase = .recoveryFailed
                activeSession = current
            }
            await managed.progress(
                .recoveryRequired(message: recoveryError.localizedDescription)
            )
        }
    }
}
