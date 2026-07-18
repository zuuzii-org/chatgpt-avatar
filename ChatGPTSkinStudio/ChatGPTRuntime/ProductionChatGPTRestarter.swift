import AppKit
import Darwin
import Foundation

struct RunningChatGPTApplication: Sendable, Equatable {
    let pid: pid_t
    let bundleIdentifier: String
    let executableURL: URL?
}

protocol RunningChatGPTApplicationControlling: Sendable {
    @MainActor
    func runningApplications(bundleIdentifier: String) -> [RunningChatGPTApplication]

    @MainActor
    func requestTermination(of application: RunningChatGPTApplication) -> Bool
}

struct NSWorkspaceRunningChatGPTApplicationController:
    RunningChatGPTApplicationControlling
{
    @MainActor
    func runningApplications(bundleIdentifier: String) -> [RunningChatGPTApplication] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  application.bundleIdentifier == bundleIdentifier
            else {
                return nil
            }
            return RunningChatGPTApplication(
                pid: application.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                executableURL: application.executableURL
            )
        }
    }

    @MainActor
    func requestTermination(of reference: RunningChatGPTApplication) -> Bool {
        guard reference.pid > 1,
              let application = NSRunningApplication(
                processIdentifier: reference.pid
              ),
              !application.isTerminated,
              application.bundleIdentifier == reference.bundleIdentifier,
              Self.sameExecutable(application.executableURL, reference.executableURL)
        else {
            return false
        }
        return application.terminate()
    }

    private static func sameExecutable(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.resolvingSymlinksInPath().standardizedFileURL
            == rhs.resolvingSymlinksInPath().standardizedFileURL
    }
}

actor ProductionChatGPTRestarter: ProductionChatGPTRestarting {
    struct Timing: Sendable, Equatable {
        let processDiscoveryTimeout: Duration
        let activePortTimeout: Duration
        let gracefulTerminationTimeout: Duration
        let terminationRetryInterval: Duration
        let pollInterval: Duration

        init(
            processDiscoveryTimeout: Duration,
            activePortTimeout: Duration,
            gracefulTerminationTimeout: Duration,
            terminationRetryInterval: Duration = .seconds(2),
            pollInterval: Duration
        ) {
            self.processDiscoveryTimeout = processDiscoveryTimeout
            self.activePortTimeout = activePortTimeout
            self.gracefulTerminationTimeout = gracefulTerminationTimeout
            self.terminationRetryInterval = terminationRetryInterval
            self.pollInterval = pollInterval
        }

        static let production = Timing(
            processDiscoveryTimeout: .seconds(5),
            activePortTimeout: .seconds(10),
            // ChatGPT accepts but defers quit AppleEvents while it is still
            // starting up (observed: ignored at 20-28s process age, honored by
            // ~36s; a busy instance kept deferring past 75s and only quit by
            // ~3min). A 10s window therefore guaranteed failure against any
            // recently launched instance. 90s with 2s retries covers startup
            // contention; steady-state quits still complete in 1-3s.
            gracefulTerminationTimeout: .seconds(90),
            terminationRetryInterval: .seconds(2),
            pollInterval: .milliseconds(50)
        )
    }

    private struct VerifiedUserDataDirectory: Sendable, Equatable {
        let url: URL
        let identity: FileIdentity
    }

    private struct ExistingMainInstance: Sendable, Equatable {
        let application: RunningChatGPTApplication
        let process: RuntimeProcessSnapshot
    }

    private struct PendingRestartRecovery: Sendable, Equatable, Identifiable {
        let id: UUID
        let bundle: VerifiedChatGPTBundle
        let profile: VerifiedUserDataDirectory
        let returnedPID: pid_t?
        let primaryFailure: String
        let originatingSessionID: UUID?
    }

    private struct NormalInstanceRecoveryFailure: LocalizedError, Sendable {
        let returnedPID: pid_t?
        let cause: String

        var errorDescription: String? {
            if let returnedPID {
                return "normal 启动返回 PID \(returnedPID) 后身份验收失败：\(cause)"
            }
            return "normal 实例恢复失败且没有可关联的返回 PID：\(cause)"
        }
    }

    private let bundleVerifier: any ChatGPTBundleVerifying
    private let applicationController: any RunningChatGPTApplicationControlling
    private let workspaceLauncher: any WorkspaceApplicationLaunching
    private let processInspector: any RuntimeProcessInspecting
    private let endpointDiscoverer: any FreshDevToolsActivePortDiscovering
    private let listenerVerifier: DebugListenerVerifier
    private let userDataDirectory: URL
    private let timing: Timing
    private var activeSessions: [UUID: ProductionDebugSession] = [:]
    private var consumedConsentIDs: Set<UUID> = []
    private var pendingRecovery: PendingRestartRecovery?
    private var recoveryInProgressID: UUID?
    private var restartTransactionInProgress = false
    private var managedRecoveryInProgressSessionIDs: Set<UUID> = []

    init(
        bundleVerifier: any ChatGPTBundleVerifying = ChatGPTBundleVerifier(),
        applicationController: any RunningChatGPTApplicationControlling =
            NSWorkspaceRunningChatGPTApplicationController(),
        workspaceLauncher: any WorkspaceApplicationLaunching =
            NSWorkspaceApplicationLauncher(),
        processInspector: any RuntimeProcessInspecting = DarwinRuntimeProcessInspector(),
        endpointDiscoverer: any FreshDevToolsActivePortDiscovering =
            StrictDevToolsActivePortDiscoverer(),
        listenerVerifier: DebugListenerVerifier = DebugListenerVerifier(),
        userDataDirectory: URL = ProductionChatGPTRestarter.defaultUserDataDirectory,
        timing: Timing = .production
    ) {
        self.bundleVerifier = bundleVerifier
        self.applicationController = applicationController
        self.workspaceLauncher = workspaceLauncher
        self.processInspector = processInspector
        self.endpointDiscoverer = endpointDiscoverer
        self.listenerVerifier = listenerVerifier
        self.userDataDirectory = userDataDirectory.standardized
        self.timing = timing
    }

    static var defaultUserDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)
            .standardized
    }

    func restartForDebugging(
        _ request: ProductionRestartRequest
    ) async throws -> ProductionDebugSession {
        guard !restartTransactionInProgress else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "另一个生产重启事务正在执行；本次未消费授权，也未执行进程操作。"
            )
        }
        guard activeSessions.isEmpty else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "已有受管生产调试会话，拒绝开始第二个重启事务。"
            )
        }
        if let pendingRecovery {
            throw RuntimeSecurityError.automaticRollbackFailed(
                primary: pendingRecovery.primaryFailure,
                rollback: "上一次生产重启仍需恢复；请先使用新的明确授权执行恢复。"
            )
        }
        restartTransactionInProgress = true
        defer { restartTransactionInProgress = false }
        try consume(request.consent)
        let bundle = try reverify(request.bundle)
        let profile = try ensureUserDataDirectory()

        var transactionStarted = false
        var launchedPID: pid_t?
        do {
            let existingMain = try await existingMainInstanceIfPresent(
                bundle: bundle
            )
            try Task.checkCancellation()
            if let existingMain {
                // From this point onward a termination request may be accepted.
                // Any error, including caller cancellation while waiting for
                // exit, must therefore run detached transactional recovery.
                transactionStarted = true
                try await gracefullyTerminate(
                    existingMain.application,
                    process: existingMain.process
                )
            }

            try Task.checkCancellation()
            // LaunchServices may create a process even when its async call
            // later throws, so authorization becomes transactional before the
            // launch request crosses that boundary.
            let baseline = try endpointDiscoverer.captureBaseline(in: profile.url)
            try Task.checkCancellation()
            transactionStarted = true
            let launchRequest = WorkspaceApplicationLaunchRequest(
                appURL: bundle.appURL,
                arguments: Self.debugArguments(userDataDirectory: profile.url),
                environment: [:]
            )
            let pid = try await workspaceLauncher.launch(launchRequest)
            launchedPID = pid
            try Task.checkCancellation()
            let process = try await waitForProcess(pid: pid)
            try validateDebugProcess(
                process,
                bundle: bundle,
                userDataDirectory: profile.url
            )
            try validateUserDataDirectory(profile)

            let endpoint = try await endpointDiscoverer.waitForFreshEndpoint(
                in: profile.url,
                differentFrom: baseline,
                timeout: timing.activePortTimeout
            )
            let listener = try listenerVerifier.verify(
                port: endpoint.port,
                belongsTo: process.pid,
                processInspector: processInspector
            )
            let session = ProductionDebugSession(
                id: UUID(),
                bundle: bundle,
                process: process,
                userDataDirectory: profile.url,
                userDataIdentity: profile.identity,
                endpoint: endpoint,
                listener: listener
            )
            activeSessions[session.id] = session
            return session
        } catch {
            guard transactionStarted else { throw error }

            let pending = PendingRestartRecovery(
                id: UUID(),
                bundle: bundle,
                profile: profile,
                returnedPID: launchedPID,
                primaryFailure: error.localizedDescription,
                originatingSessionID: nil
            )
            pendingRecovery = pending
            do {
                _ = try await executePendingRecovery(pending)
                completePendingRecovery(pending)
            } catch let rollbackError {
                throw RuntimeSecurityError.automaticRollbackFailed(
                    primary: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    /// Transactional rollback used when injection fails after a debug session
    /// was created. The original apply consent authorizes this recovery only.
    func rollbackToNormal(
        _ session: ProductionDebugSession
    ) async throws -> NormalChatGPTSession {
        try await executeManagedRecovery(session, consent: nil)
    }

    /// User-initiated restore. Unlike transactional rollback, it always consumes
    /// a fresh, one-use consent before restarting the managed session.
    func restoreToNormal(
        _ session: ProductionDebugSession,
        consent: ExplicitRestartConsent
    ) async throws -> NormalChatGPTSession {
        try await executeManagedRecovery(session, consent: consent)
    }

    /// Retries a failed restart transaction for which no debug session could
    /// be returned. Consent is consumed only when pending work actually exists.
    func recoverPendingToNormal(
        verifiedBundle: VerifiedChatGPTBundle,
        consent: ExplicitRestartConsent
    ) async throws -> NormalChatGPTSession? {
        guard let pending = pendingRecovery else {
            if restartTransactionInProgress {
                throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                    "生产重启事务仍在执行，当前没有可安全确认的恢复结果；"
                        + "本次未消费授权，也未误报恢复完成。"
                )
            }
            return nil
        }
        guard pending.originatingSessionID == nil else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "待恢复事务属于仍受管的 production session；"
                    + "必须通过该 session 的显式恢复入口处理。"
                    + "本次未消费授权，也未发送任何退出信号。"
            )
        }
        guard pending.bundle.stableIdentity == verifiedBundle.stableIdentity else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "待恢复事务与当前已验证 ChatGPT bundle 不一致；未发送任何退出信号。"
            )
        }
        guard recoveryInProgressID == nil else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "待恢复事务正在执行；本次未发送任何退出信号，也未消费新的授权。"
            )
        }
        try consume(consent)
        do {
            let normal = try await executePendingRecovery(pending)
            completePendingRecovery(pending)
            return normal
        } catch {
            throw RuntimeSecurityError.automaticRollbackFailed(
                primary: pending.primaryFailure,
                rollback: "待恢复重试失败，未能安全确认时不会发送任何退出信号；"
                    + "状态已保留，需使用新的明确授权再次恢复："
                    + error.localizedDescription
            )
        }
    }

    func isActive(_ session: ProductionDebugSession) -> Bool {
        activeSessions[session.id] == session
    }

    func hasPendingRecovery() -> Bool {
        pendingRecovery != nil
    }

    private func returnToNormal(
        _ session: ProductionDebugSession
    ) async throws -> NormalChatGPTSession {
        guard activeSessions[session.id] == session else {
            throw RuntimeSecurityError.unrecognizedSession
        }
        DiagnosticsLogger.shared.log("return-to-normal-begin", "session=\(session.id)")
        let bundle = try reverify(session.bundle)
        let profile = try ensureUserDataDirectory()
        guard profile.url == session.userDataDirectory.standardized,
              profile.identity == session.userDataIdentity
        else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "受管 session 的 user-data-dir 已变化"
            )
        }

        try await stopManagedDebugProcess(
            session.process,
            bundle: bundle,
            userDataDirectory: profile.url
        )
        do {
            let normalSession = try await ensureNormalInstance(bundle: bundle)
            activeSessions.removeValue(forKey: session.id)
            DiagnosticsLogger.shared.log("return-to-normal-ok", "session=\(session.id)")
            return normalSession
        } catch let failure as NormalInstanceRecoveryFailure {
            let pending = PendingRestartRecovery(
                id: UUID(),
                bundle: bundle,
                profile: profile,
                returnedPID: failure.returnedPID,
                primaryFailure: "受管 debug session 已停止，但 normal 实例未通过身份验收："
                    + failure.localizedDescription,
                originatingSessionID: session.id
            )
            pendingRecovery = pending
            DiagnosticsLogger.shared.log(
                "return-to-normal-pending",
                "session=\(session.id) reason=\(failure.localizedDescription)"
            )
            throw RuntimeSecurityError.automaticRollbackFailed(
                primary: "受管 debug session 已停止",
                rollback: failure.localizedDescription
            )
        }
    }

    private func executeManagedRecovery(
        _ session: ProductionDebugSession,
        consent: ExplicitRestartConsent?
    ) async throws -> NormalChatGPTSession {
        guard activeSessions[session.id] == session else {
            throw RuntimeSecurityError.unrecognizedSession
        }
        guard managedRecoveryInProgressSessionIDs.insert(session.id).inserted else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "受管 session 的恢复事务已在执行；未发送重复退出信号，"
                    + "也未消费新的授权。"
            )
        }
        defer { managedRecoveryInProgressSessionIDs.remove(session.id) }
        let associatedPending: PendingRestartRecovery?
        if let pending = pendingRecovery {
            guard pending.originatingSessionID == session.id else {
                throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                    "存在不属于当前受管 session 的待恢复事务；"
                        + "未消费授权，也未发送退出信号。"
                )
            }
            associatedPending = pending
        } else {
            associatedPending = nil
        }
        if let pending = associatedPending {
            guard consent != nil else {
                throw RuntimeSecurityError.automaticRollbackFailed(
                    primary: pending.primaryFailure,
                    rollback: "待恢复事务已进入 recoveryRequired；"
                        + "再次重试必须获得新的明确授权，当前未发送任何退出信号。"
                )
            }
            guard recoveryInProgressID == nil else {
                throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                    "同一待恢复事务正在执行；本次未发送重复退出信号，"
                        + "也未消费新的授权。"
                )
            }
        }
        if let consent {
            try consume(consent)
        }
        if let pending = associatedPending {
            do {
                let normal = try await executePendingRecovery(pending)
                completePendingRecovery(pending)
                return normal
            } catch {
                throw RuntimeSecurityError.automaticRollbackFailed(
                    primary: pending.primaryFailure,
                    rollback: "待恢复重试失败；未发送未经验证的退出信号，"
                        + "pending 与受管 session 状态均已保留，可使用新的授权再次重试："
                        + error.localizedDescription
                )
            }
        }
        // Once the user authorized recovery, caller cancellation must not be
        // able to strand ChatGPT after its managed debug process has exited.
        let task = Task.detached { [self] in
            try await returnToNormal(session)
        }
        return try await task.value
    }

    private func consume(_ consent: ExplicitRestartConsent) throws {
        guard consumedConsentIDs.insert(consent.id).inserted else {
            throw RuntimeSecurityError.explicitRestartConsentRequired
        }
    }

    private func reverify(
        _ expected: VerifiedChatGPTBundle
    ) throws -> VerifiedChatGPTBundle {
        let actual = try bundleVerifier.verify(appURL: expected.appURL)
        guard actual.stableIdentity == expected.stableIdentity else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "bundle 稳定身份在授权后发生变化"
            )
        }
        return actual
    }

    private func executePendingRecovery(
        _ pending: PendingRestartRecovery
    ) async throws -> NormalChatGPTSession {
        guard pendingRecovery?.id == pending.id else {
            throw RuntimeSecurityError.unrecognizedSession
        }
        guard recoveryInProgressID == nil else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "同一待恢复事务已在执行；未发送重复退出信号。"
            )
        }
        recoveryInProgressID = pending.id
        defer {
            if recoveryInProgressID == pending.id {
                recoveryInProgressID = nil
            }
        }
        let task = Task.detached { [self] in
            try await recoverFailedRestart(pending)
        }
        return try await task.value
    }

    private func recoverFailedRestart(
        _ pending: PendingRestartRecovery
    ) async throws -> NormalChatGPTSession {
        let bundle = try reverify(pending.bundle)
        try validateUserDataDirectory(pending.profile)
        guard let returnedPID = pending.returnedPID else {
            do {
                return try await ensureNormalInstance(bundle: bundle)
            } catch {
                throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                    "LaunchServices 未返回可关联到本次授权事务的 PID；"
                        + "因此未向任何候选进程发送退出信号，待恢复状态已保留："
                        + error.localizedDescription
                )
            }
        }
        return try await recoverReturnedLaunch(
            pid: returnedPID,
            bundle: bundle,
            profile: pending.profile
        )
    }

    private func recoverReturnedLaunch(
        pid: pid_t,
        bundle: VerifiedChatGPTBundle,
        profile: VerifiedUserDataDirectory
    ) async throws -> NormalChatGPTSession {
        let firstProcess: RuntimeProcessSnapshot
        do {
            firstProcess = try processInspector.snapshot(pid: pid)
        } catch RuntimeSecurityError.processUnavailable {
            // The returned PID no longer exists. `ensureNormalInstance` still
            // validates any current LaunchServices main before accepting it.
            return try await ensureNormalInstance(bundle: bundle)
        }

        let firstApplications = await applicationController.runningApplications(
            bundleIdentifier: bundle.bundleIdentifier
        )
        guard firstApplications.count == 1,
              let firstApplication = firstApplications.first,
              firstApplication.pid == pid
        else {
            throw unsafeReturnedPIDRecoveryError(
                pid: pid,
                detail: "LaunchServices 未唯一指向该 PID"
            )
        }
        do {
            try validateApplication(
                firstApplication,
                process: firstProcess,
                bundle: bundle
            )
        } catch {
            throw unsafeReturnedPIDRecoveryError(
                pid: pid,
                detail: error.localizedDescription
            )
        }

        // Close the LaunchServices/process inspection race immediately before
        // any termination request. Both samples must describe the same main
        // process identity and the refreshed application must remain unique.
        let secondProcess: RuntimeProcessSnapshot
        do {
            secondProcess = try processInspector.snapshot(pid: pid)
        } catch {
            throw unsafeReturnedPIDRecoveryError(
                pid: pid,
                detail: "二次进程采样失败：\(error.localizedDescription)"
            )
        }
        let secondApplications = await applicationController.runningApplications(
            bundleIdentifier: bundle.bundleIdentifier
        )
        guard secondApplications.count == 1,
              let secondApplication = secondApplications.first,
              secondApplication.pid == pid,
              sameProcessIdentity(firstProcess, secondProcess)
        else {
            throw unsafeReturnedPIDRecoveryError(
                pid: pid,
                detail: "二次身份采样发生变化"
            )
        }
        do {
            try validateApplication(
                secondApplication,
                process: secondProcess,
                bundle: bundle
            )
        } catch {
            throw unsafeReturnedPIDRecoveryError(
                pid: pid,
                detail: error.localizedDescription
            )
        }

        if (try? validateNormalProcess(secondProcess, bundle: bundle)) != nil {
            return NormalChatGPTSession(
                id: UUID(),
                bundle: bundle,
                process: secondProcess
            )
        }

        do {
            try validateDebugProcess(
                secondProcess,
                bundle: bundle,
                userDataDirectory: profile.url
            )
        } catch {
            throw unsafeReturnedPIDRecoveryError(
                pid: pid,
                detail: "进程既不是严格 normal 也不是本事务的严格 debug 实例"
            )
        }
        try await gracefullyTerminate(
            secondApplication,
            process: secondProcess
        )
        return try await ensureNormalInstance(bundle: bundle)
    }

    private func completePendingRecovery(_ pending: PendingRestartRecovery) {
        guard pendingRecovery?.id == pending.id else { return }
        pendingRecovery = nil
        if let sessionID = pending.originatingSessionID {
            activeSessions.removeValue(forKey: sessionID)
        }
    }

    private func unsafeReturnedPIDRecoveryError(
        pid: pid_t,
        detail: String
    ) -> RuntimeSecurityError {
        .runningApplicationIdentityMismatch(
            "LaunchServices 返回的 PID \(pid) 无法安全闭合身份（\(detail)）；"
                + "未发送任何退出信号，待恢复状态已保留。"
        )
    }

    private func sameProcessIdentity(
        _ lhs: RuntimeProcessSnapshot,
        _ rhs: RuntimeProcessSnapshot
    ) -> Bool {
        lhs.pid == rhs.pid
            && lhs.processGroupID == rhs.processGroupID
            && lhs.startTime == rhs.startTime
            && Self.canonicalExecutable(lhs.executableURL)
                == Self.canonicalExecutable(rhs.executableURL)
            && lhs.arguments == rhs.arguments
    }

    private func ensureUserDataDirectory() throws -> VerifiedUserDataDirectory {
        let directory = userDataDirectory.standardized
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                let parent = directory.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                try rejectSymbolicLinkComponents(in: parent)
                guard mkdir(directory.path, mode_t(S_IRWXU)) == 0 else {
                    throw RuntimeSecurityError.secureDirectoryCreationFailed(
                        "mkdir 0700 \(directory.path)：\(String(cString: strerror(errno)))"
                    )
                }
            } catch {
                if let runtimeError = error as? RuntimeSecurityError {
                    throw runtimeError
                }
                throw RuntimeSecurityError.secureDirectoryCreationFailed(
                    "无法创建真实 Codex profile：\(error.localizedDescription)"
                )
            }
        }

        try rejectSymbolicLinkComponents(in: directory)
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(directory.path)
        }
        return VerifiedUserDataDirectory(
            url: directory,
            identity: FileIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                owner: info.st_uid
            )
        )
    }

    private func validateUserDataDirectory(
        _ expected: VerifiedUserDataDirectory
    ) throws {
        let actual = try ensureUserDataDirectory()
        guard actual == expected else {
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(
                expected.url.path
            )
        }
    }

    private func rejectSymbolicLinkComponents(in url: URL) throws {
        let components = url.standardized.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                throw RuntimeSecurityError.secureDirectoryIdentityChanged(
                    current.path
                )
            }
            guard info.st_mode & S_IFMT != S_IFLNK else {
                throw RuntimeSecurityError.secureDirectoryIdentityChanged(
                    current.path
                )
            }
        }
    }

    private func existingMainInstanceIfPresent(
        bundle: VerifiedChatGPTBundle
    ) async throws -> ExistingMainInstance? {
        let applications = await applicationController.runningApplications(
            bundleIdentifier: bundle.bundleIdentifier
        )
        guard applications.count <= 1 else {
            throw RuntimeSecurityError.multipleRunningChatGPTInstances(
                applications.count
            )
        }
        guard let application = applications.first else { return nil }
        let process = try await validateStableApplication(
            application,
            bundle: bundle
        )
        try validateNormalProcess(process, bundle: bundle)
        return ExistingMainInstance(
            application: application,
            process: process
        )
    }

    private func stopManagedDebugProcess(
        _ expectedProcess: RuntimeProcessSnapshot,
        bundle: VerifiedChatGPTBundle,
        userDataDirectory: URL
    ) async throws {
        let applications = await applicationController.runningApplications(
            bundleIdentifier: bundle.bundleIdentifier
        )
        guard applications.count <= 1 else {
            throw RuntimeSecurityError.multipleRunningChatGPTInstances(
                applications.count
            )
        }
        guard let application = applications.first else {
            do {
                let process = try processInspector.snapshot(pid: expectedProcess.pid)
                guard process.startTime == expectedProcess.startTime else {
                    throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                        "受管 PID 已被其他进程复用"
                    )
                }
                try validateDebugProcess(
                    process,
                    bundle: bundle,
                    userDataDirectory: userDataDirectory
                )
                let managedReference = RunningChatGPTApplication(
                    pid: process.pid,
                    bundleIdentifier: bundle.bundleIdentifier,
                    executableURL: bundle.executableURL
                )
                try await gracefullyTerminate(
                    managedReference,
                    process: process
                )
                return
            } catch RuntimeSecurityError.processUnavailable {
                return
            }
        }
        guard application.pid == expectedProcess.pid else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "当前主实例 PID \(application.pid) 不是受管 PID \(expectedProcess.pid)"
            )
        }
        let process = try processInspector.snapshot(pid: application.pid)
        try validateApplication(
            application,
            process: process,
            bundle: bundle
        )
        guard process.startTime == expectedProcess.startTime else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "受管 PID 启动时间已变化"
            )
        }
        try validateDebugProcess(
            process,
            bundle: bundle,
            userDataDirectory: userDataDirectory
        )
        try await gracefullyTerminate(application, process: process)
    }

    private func gracefullyTerminate(
        _ application: RunningChatGPTApplication,
        process: RuntimeProcessSnapshot
    ) async throws {
        var accepted = false
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timing.gracefulTerminationTimeout)
        var nextRetryAt = clock.now
        while true {
            if !accepted || clock.now >= nextRetryAt {
                let requestAccepted = await applicationController.requestTermination(
                    of: application
                )
                if requestAccepted {
                    accepted = true
                    // The quit AppleEvent can be lost while the relaunched app is
                    // still finishing startup, so a single terminate request is not
                    // reliable. Re-send it until the deadline; the process identity
                    // is still revalidated on every poll below.
                    nextRetryAt = clock.now.advanced(by: timing.terminationRetryInterval)
                } else if !accepted {
                    do {
                        let current = try processInspector.snapshot(pid: process.pid)
                        guard current.startTime != process.startTime else {
                            throw RuntimeSecurityError.gracefulTerminationRejected(
                                process.pid
                            )
                        }
                    } catch RuntimeSecurityError.processUnavailable {
                        return
                    }
                    throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                        "退出请求期间 PID 被复用"
                    )
                }
            }

            do {
                let current = try processInspector.snapshot(pid: process.pid)
                guard current.startTime == process.startTime,
                      Self.canonicalExecutable(current.executableURL)
                        == Self.canonicalExecutable(process.executableURL)
                else {
                    throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                        "退出等待期间 PID 被复用"
                    )
                }
            } catch RuntimeSecurityError.processUnavailable {
                return
            }
            guard clock.now < deadline else {
                DiagnosticsLogger.shared.log(
                    "graceful-termination-timeout",
                    "pid=\(process.pid) timeout=\(timing.gracefulTerminationTimeout)"
                )
                throw RuntimeSecurityError.gracefulTerminationTimedOut(process.pid)
            }
            try await Task.sleep(for: timing.pollInterval)
        }
    }

    private func ensureNormalInstance(
        bundle: VerifiedChatGPTBundle
    ) async throws -> NormalChatGPTSession {
        var returnedPID: pid_t?
        do {
            // The normal app will resolve this same default profile internally. Do
            // not restart if the path became a symlink or writable by another user.
            _ = try ensureUserDataDirectory()
            let applications = await applicationController.runningApplications(
                bundleIdentifier: bundle.bundleIdentifier
            )
            guard applications.count <= 1 else {
                throw RuntimeSecurityError.multipleRunningChatGPTInstances(
                    applications.count
                )
            }
            if let existing = applications.first {
                let process = try await validateStableApplication(
                    existing,
                    bundle: bundle
                )
                try validateNormalProcess(process, bundle: bundle)
                return NormalChatGPTSession(
                    id: UUID(),
                    bundle: bundle,
                    process: process
                )
            }

            let pid = try await workspaceLauncher.launch(
                WorkspaceApplicationLaunchRequest(
                    appURL: bundle.appURL,
                    arguments: [],
                    environment: [:]
                )
            )
            returnedPID = pid
            let discoveredProcess = try await waitForProcess(pid: pid)
            let launchedApplications = await applicationController.runningApplications(
                bundleIdentifier: bundle.bundleIdentifier
            )
            guard launchedApplications.count == 1,
                  let launchedApplication = launchedApplications.first,
                  launchedApplication.pid == pid
            else {
                throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                    "恢复 normal 后 LaunchServices 未唯一指向返回 PID \(pid)"
                )
            }
            try validateApplication(
                launchedApplication,
                process: discoveredProcess,
                bundle: bundle
            )
            let process = try await validateStableApplication(
                launchedApplication,
                firstProcess: discoveredProcess,
                bundle: bundle
            )
            try validateNormalProcess(process, bundle: bundle)
            return NormalChatGPTSession(
                id: UUID(),
                bundle: bundle,
                process: process
            )
        } catch let failure as NormalInstanceRecoveryFailure {
            throw failure
        } catch {
            throw NormalInstanceRecoveryFailure(
                returnedPID: returnedPID,
                cause: error.localizedDescription
            )
        }
    }

    private func validateStableApplication(
        _ application: RunningChatGPTApplication,
        firstProcess: RuntimeProcessSnapshot? = nil,
        bundle: VerifiedChatGPTBundle
    ) async throws -> RuntimeProcessSnapshot {
        let first = try firstProcess ?? processInspector.snapshot(
            pid: application.pid
        )
        try validateApplication(
            application,
            process: first,
            bundle: bundle
        )
        let second = try processInspector.snapshot(pid: application.pid)
        let refreshed = await applicationController.runningApplications(
            bundleIdentifier: bundle.bundleIdentifier
        )
        guard refreshed.count == 1,
              let refreshedApplication = refreshed.first,
              refreshedApplication.pid == application.pid,
              sameProcessIdentity(first, second)
        else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "normal 实例在双重身份采样期间发生变化"
            )
        }
        try validateApplication(
            refreshedApplication,
            process: second,
            bundle: bundle
        )
        return second
    }

    private func waitForProcess(pid: pid_t) async throws -> RuntimeProcessSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timing.processDiscoveryTimeout)
        repeat {
            do {
                return try processInspector.snapshot(pid: pid)
            } catch RuntimeSecurityError.processUnavailable {
                if clock.now >= deadline { break }
                try await Task.sleep(for: timing.pollInterval)
            }
        } while clock.now < deadline
        throw RuntimeSecurityError.processUnavailable(pid)
    }

    private func validateApplication(
        _ application: RunningChatGPTApplication,
        process: RuntimeProcessSnapshot,
        bundle: VerifiedChatGPTBundle
    ) throws {
        guard application.pid > 1,
              application.pid != getpid(),
              application.bundleIdentifier == bundle.bundleIdentifier,
              let applicationExecutable = application.executableURL,
              Self.canonicalExecutable(applicationExecutable)
                == Self.canonicalExecutable(bundle.executableURL),
              process.pid == application.pid,
              Self.canonicalExecutable(process.executableURL)
                == Self.canonicalExecutable(bundle.executableURL)
        else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "PID、Bundle ID 或 executable 不匹配"
            )
        }
    }

    private func validateDebugProcess(
        _ process: RuntimeProcessSnapshot,
        bundle: VerifiedChatGPTBundle,
        userDataDirectory: URL
    ) throws {
        let expectedControlArguments = Self.debugArguments(
            userDataDirectory: userDataDirectory
        )
        let containsEachControlArgumentExactlyOnce = expectedControlArguments
            .allSatisfy { expected in
                process.arguments.lazy.filter { $0 == expected }.count == 1
            }
        let containsOnlyExpectedControlArguments = process.arguments.allSatisfy {
            argument in
            guard Self.isDebugControlArgument(argument) else { return true }
            return expectedControlArguments.contains(argument)
        }
        guard process.pid > 1,
              process.pid != getpid(),
              Self.canonicalExecutable(process.executableURL)
                == Self.canonicalExecutable(bundle.executableURL),
              containsEachControlArgumentExactlyOnce,
              containsOnlyExpectedControlArguments
        else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "调试实例 executable 或启动参数不匹配"
            )
        }
    }

    private func validateNormalProcess(
        _ process: RuntimeProcessSnapshot,
        bundle: VerifiedChatGPTBundle
    ) throws {
        let hasNonNormalArgument = process.arguments.contains { argument in
            argument == "--remote-debugging-pipe"
                || argument.hasPrefix("--remote-debugging-address")
                || argument.hasPrefix("--remote-debugging-port")
                || argument == "--user-data-dir"
                || argument.hasPrefix("--user-data-dir=")
        }
        guard process.pid > 1,
              process.pid != getpid(),
              Self.canonicalExecutable(process.executableURL)
                == Self.canonicalExecutable(bundle.executableURL),
              !hasNonNormalArgument
        else {
            throw RuntimeSecurityError.runningApplicationIdentityMismatch(
                "恢复后的实例仍包含 remote-debugging/user-data-dir 参数或身份不匹配"
            )
        }
    }

    private static func debugArguments(userDataDirectory: URL) -> [String] {
        [
            "--user-data-dir=\(userDataDirectory.path)",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
        ]
    }

    private static func isDebugControlArgument(_ argument: String) -> Bool {
        let controlNames = [
            "--user-data-dir",
            "--remote-debugging-address",
            "--remote-debugging-port",
            "--remote-debugging-pipe",
        ]
        return controlNames.contains { name in
            argument == name || argument.hasPrefix("\(name)=")
        }
    }

    private static func canonicalExecutable(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
