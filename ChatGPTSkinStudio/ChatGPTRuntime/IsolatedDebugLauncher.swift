import AppKit
import Darwin
import Foundation

struct WorkspaceApplicationLaunchRequest: Sendable, Equatable {
    let appURL: URL
    let arguments: [String]
    let environment: [String: String]
}

protocol WorkspaceApplicationLaunching: Sendable {
    @MainActor
    func launch(_ request: WorkspaceApplicationLaunchRequest) async throws -> pid_t
}

enum IsolatedDebugRecoveryKind: String, Sendable, Equatable {
    case validatedCleanup
    case unverifiedLaunch
}

struct IsolatedDebugRecoveryRecord: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: IsolatedDebugRecoveryKind
    let processIdentifier: pid_t?
    let storageRootURL: URL
    let primaryReason: String
}

enum IsolatedDebugLauncherError: Error, LocalizedError, Sendable, Equatable {
    case recoveryRequired(
        recoveryID: UUID,
        processIdentifier: pid_t?,
        primary: String,
        recoveryFailure: String
    )
    case launchQuarantined(
        recoveryID: UUID,
        processIdentifier: pid_t?,
        storageRootURL: URL,
        primary: String
    )
    case recoveryNotFound(UUID)
    case recoveryAlreadyInProgress(UUID)

    var errorDescription: String? {
        switch self {
        case let .recoveryRequired(recoveryID, processIdentifier, primary, recoveryFailure):
            "隔离调试启动失败，自动恢复也未完成。recovery ID：\(recoveryID.uuidString)，"
                + "PID：\(Self.describe(processIdentifier))。原始错误：\(primary)；"
                + "恢复错误：\(recoveryFailure)"
        case let .launchQuarantined(
            recoveryID,
            processIdentifier,
            storageRootURL,
            primary
        ):
            "隔离调试启动身份尚未验证，已隔离保留且不会自动 signal 或删除。"
                + "recovery ID：\(recoveryID.uuidString)，PID：\(Self.describe(processIdentifier))，"
                + "storage：\(storageRootURL.path)。原始错误：\(primary)"
        case let .recoveryNotFound(recoveryID):
            "未找到隔离调试 recovery：\(recoveryID.uuidString)"
        case let .recoveryAlreadyInProgress(recoveryID):
            "隔离调试 recovery 正在进行：\(recoveryID.uuidString)"
        }
    }

    private static func describe(_ processIdentifier: pid_t?) -> String {
        processIdentifier.map(String.init) ?? "unknown"
    }
}

struct NSWorkspaceApplicationLauncher: WorkspaceApplicationLaunching {
    @MainActor
    func launch(_ request: WorkspaceApplicationLaunchRequest) async throws -> pid_t {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // A windowless ChatGPT is an immediate Automatic Termination candidate:
        // the OS sends it a Quit AppleEvent within seconds-to-minutes, killing
        // the managed debug session (and any relaunched normal instance) out
        // from under the skin. Activation makes the new instance frontmost so
        // Electron creates its main window and stays alive.
        configuration.activates = true
        configuration.arguments = request.arguments
        configuration.environment = request.environment

        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: request.appURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(
                        throwing: RuntimeSecurityError.workspaceLaunchFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }
                guard let application, application.processIdentifier > 0 else {
                    continuation.resume(
                        throwing: RuntimeSecurityError.workspaceLaunchFailed(
                            "Launch Services 未返回有效 PID"
                        )
                    )
                    return
                }
                continuation.resume(returning: application.processIdentifier)
            }
        }
    }
}

actor IsolatedDebugLauncher {
    struct Timing: Sendable, Equatable {
        let processDiscoveryTimeout: Duration
        let activePortTimeout: Duration
        let terminationGracePeriod: Duration
        let killGracePeriod: Duration
        let pollInterval: Duration

        static let production = Timing(
            processDiscoveryTimeout: .seconds(5),
            activePortTimeout: .seconds(10),
            terminationGracePeriod: .seconds(3),
            killGracePeriod: .seconds(2),
            pollInterval: .milliseconds(50)
        )
    }

    private struct SessionRecord: Sendable {
        let id: UUID
        let bundle: VerifiedChatGPTBundle
        let process: RuntimeProcessSnapshot
        let storage: IsolatedRuntimeStorage
        let launchBaseline: LaunchBaseline
    }

    private struct BaselineProcessIdentity: Sendable, Equatable {
        let pid: pid_t
        let startTime: ProcessStartTime
        let executableURL: URL

        func matches(_ candidate: RuntimeProcessCandidate) -> Bool {
            pid == candidate.pid
                && startTime == candidate.startTime
                && executableURL == IsolatedDebugLauncher.canonical(candidate.executableURL)
        }
    }

    private struct BaselineApplicationIdentity: Sendable, Equatable {
        let pid: pid_t
        let executableURL: URL?

        func matches(_ application: RunningChatGPTApplication) -> Bool {
            guard pid == application.pid else { return false }
            switch (executableURL, application.executableURL) {
            case let (.some(expected), .some(actual)):
                return expected == IsolatedDebugLauncher.canonical(actual)
            case (nil, nil):
                return true
            default:
                return false
            }
        }
    }

    private struct LaunchBaseline: Sendable {
        let processes: [BaselineProcessIdentity]
        let applications: [BaselineApplicationIdentity]

        func contains(_ candidate: RuntimeProcessCandidate) -> Bool {
            processes.contains { $0.matches(candidate) }
        }

        func contains(_ application: RunningChatGPTApplication) -> Bool {
            applications.contains { $0.matches(application) }
        }
    }

    private struct QuarantinedObservation: Sendable {
        let relevantProcesses: [RuntimeProcessCandidate]
        let newApplications: [RunningChatGPTApplication]

        var isEmpty: Bool {
            relevantProcesses.isEmpty && newApplications.isEmpty
        }
    }

    private enum PendingRecovery: Sendable {
        case validated(record: SessionRecord, primaryReason: String)
        case quarantined(
            id: UUID,
            bundle: VerifiedChatGPTBundle,
            processIdentifier: pid_t?,
            storage: IsolatedRuntimeStorage,
            launchBaseline: LaunchBaseline,
            primaryReason: String
        )

        var auditRecord: IsolatedDebugRecoveryRecord {
            switch self {
            case let .validated(record, primaryReason):
                IsolatedDebugRecoveryRecord(
                    id: record.id,
                    kind: .validatedCleanup,
                    processIdentifier: record.process.pid,
                    storageRootURL: record.storage.rootURL,
                    primaryReason: primaryReason
                )
            case let .quarantined(
                id,
                _,
                processIdentifier,
                storage,
                _,
                primaryReason
            ):
                IsolatedDebugRecoveryRecord(
                    id: id,
                    kind: .unverifiedLaunch,
                    processIdentifier: processIdentifier,
                    storageRootURL: storage.rootURL,
                    primaryReason: primaryReason
                )
            }
        }
    }

    private let storageManager: any IsolatedRuntimeStorageManaging
    private let workspaceLauncher: any WorkspaceApplicationLaunching
    private let processInspector: any RuntimeProcessInspecting
    private let endpointDiscoverer: any DevToolsActivePortDiscovering
    private let listenerVerifier: DebugListenerVerifier
    private let applicationController: any RunningChatGPTApplicationControlling
    private let processGroupSignaler: any ProcessGroupSignaling
    private let exactProcessSignaler: any ExactProcessSignaling
    private let timing: Timing
    private var activeSessions: [UUID: IsolatedDebugSession] = [:]
    private var activeSessionBaselines: [UUID: LaunchBaseline] = [:]
    private var pendingRecoveries: [UUID: PendingRecovery] = [:]
    private var recoveryAttempts: Set<UUID> = []
    private var consumedConsentIDs: Set<UUID> = []

    init(
        storageManager: any IsolatedRuntimeStorageManaging = SecureIsolatedRuntimeStorageManager(),
        workspaceLauncher: any WorkspaceApplicationLaunching = NSWorkspaceApplicationLauncher(),
        processInspector: any RuntimeProcessInspecting = DarwinRuntimeProcessInspector(),
        endpointDiscoverer: any DevToolsActivePortDiscovering = StrictDevToolsActivePortDiscoverer(),
        listenerVerifier: DebugListenerVerifier = DebugListenerVerifier(),
        applicationController: any RunningChatGPTApplicationControlling =
            NSWorkspaceRunningChatGPTApplicationController(),
        processGroupSignaler: any ProcessGroupSignaling = DarwinProcessGroupSignaler(),
        exactProcessSignaler: any ExactProcessSignaling = DarwinExactProcessSignaler(),
        timing: Timing = .production
    ) {
        self.storageManager = storageManager
        self.workspaceLauncher = workspaceLauncher
        self.processInspector = processInspector
        self.endpointDiscoverer = endpointDiscoverer
        self.listenerVerifier = listenerVerifier
        self.applicationController = applicationController
        self.processGroupSignaler = processGroupSignaler
        self.exactProcessSignaler = exactProcessSignaler
        self.timing = timing
    }

    func launch(
        verifiedBundle bundle: VerifiedChatGPTBundle,
        consent: ExplicitRestartConsent
    ) async throws -> IsolatedDebugSession {
        // Requiring and consuming the consent value at this boundary prevents
        // background preflight code or retries from replaying one UI approval.
        guard consumedConsentIDs.insert(consent.id).inserted else {
            throw RuntimeSecurityError.explicitRestartConsentRequired
        }
        // Capture both the kernel process view and Launch Services view before
        // asking Launch Services to create an instance. If the async launch API
        // later throws without a PID, only identities absent from both baselines
        // may be attributed to this request.
        let launchBaseline = try await captureLaunchBaseline(for: bundle)
        let storage = try storageManager.createStorage()
        let request = WorkspaceApplicationLaunchRequest(
            appURL: bundle.appURL,
            arguments: Self.requiredArguments(for: storage),
            environment: ["CODEX_HOME": storage.codexHomeDirectory.path]
        )

        var launchedPID: pid_t?
        var validatedRecord: SessionRecord?
        do {
            let pid = try await workspaceLauncher.launch(request)
            launchedPID = pid
            let process = try await waitForProcess(pid: pid)
            guard process.pid == pid else {
                throw RuntimeSecurityError.processIdentityMismatch(
                    "process inspector 返回了非请求 PID：期望 \(pid)，实际 \(process.pid)"
                )
            }
            try verifyLaunchIdentity(process, bundle: bundle, storage: storage)

            let record = SessionRecord(
                id: UUID(),
                bundle: bundle,
                process: process,
                storage: storage,
                launchBaseline: launchBaseline
            )
            validatedRecord = record

            let endpoint = try await endpointDiscoverer.waitForEndpoint(
                in: storage.userDataDirectory,
                timeout: timing.activePortTimeout
            )
            let listener = try listenerVerifier.verify(
                port: endpoint.port,
                belongsTo: process.pid,
                processInspector: processInspector
            )
            let session = IsolatedDebugSession(
                id: record.id,
                bundle: bundle,
                process: process,
                storage: storage,
                endpoint: endpoint,
                listener: listener
            )
            activeSessions[session.id] = session
            activeSessionBaselines[session.id] = launchBaseline
            return session
        } catch {
            let primaryError = error
            let primaryReason = primaryError.localizedDescription
            if let validatedRecord {
                pendingRecoveries[validatedRecord.id] = .validated(
                    record: validatedRecord,
                    primaryReason: primaryReason
                )
                recoveryAttempts.insert(validatedRecord.id)
                do {
                    try await detachedTerminateAndRemove(validatedRecord)
                    recoveryAttempts.remove(validatedRecord.id)
                    pendingRecoveries.removeValue(forKey: validatedRecord.id)
                } catch let cleanupError {
                    recoveryAttempts.remove(validatedRecord.id)
                    throw IsolatedDebugLauncherError.recoveryRequired(
                        recoveryID: validatedRecord.id,
                        processIdentifier: validatedRecord.process.pid,
                        primary: primaryReason,
                        recoveryFailure: cleanupError.localizedDescription
                    )
                }
            } else {
                let recoveryID = UUID()
                pendingRecoveries[recoveryID] = .quarantined(
                    id: recoveryID,
                    bundle: bundle,
                    processIdentifier: launchedPID,
                    storage: storage,
                    launchBaseline: launchBaseline,
                    primaryReason: primaryReason
                )
                if let launchedPID {
                    // A Launch Services PID is only a hint until snapshot, executable,
                    // argv, PGID, and private-storage identity all match. Never signal
                    // this PID or delete its potentially live profile from this branch.
                    throw IsolatedDebugLauncherError.launchQuarantined(
                        recoveryID: recoveryID,
                        processIdentifier: launchedPID,
                        storageRootURL: storage.rootURL,
                        primary: primaryReason
                    )
                }

                // An asynchronous Launch Services failure is never proof that no
                // process started. The first failure therefore only quarantines:
                // it never signals a guessed process and never deletes storage.
                throw IsolatedDebugLauncherError.launchQuarantined(
                    recoveryID: recoveryID,
                    processIdentifier: nil,
                    storageRootURL: storage.rootURL,
                    primary: primaryReason
                )
            }
            throw primaryError
        }
    }

    func cleanup(_ session: IsolatedDebugSession) async throws {
        guard let saved = activeSessions[session.id],
              saved == session,
              let launchBaseline = activeSessionBaselines[session.id]
        else {
            throw RuntimeSecurityError.unrecognizedSession
        }
        guard recoveryAttempts.insert(session.id).inserted else {
            throw IsolatedDebugLauncherError.recoveryAlreadyInProgress(session.id)
        }
        defer { recoveryAttempts.remove(session.id) }
        let record = SessionRecord(
            id: saved.id,
            bundle: saved.bundle,
            process: saved.process,
            storage: saved.storage,
            launchBaseline: launchBaseline
        )
        // A caller can arrive here already cancelled (for example an E2E body
        // failure). Once the session identity is recognized, cleanup is an
        // authorized rollback and must not inherit that cancellation.
        try await detachedTerminateAndRemove(record)
        activeSessions.removeValue(forKey: saved.id)
        activeSessionBaselines.removeValue(forKey: saved.id)
    }

    func isActive(_ session: IsolatedDebugSession) -> Bool {
        activeSessions[session.id] == session
    }

    func recoveryRecords() -> [IsolatedDebugRecoveryRecord] {
        pendingRecoveries.values
            .map(\.auditRecord)
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func retryRecovery(id recoveryID: UUID) async throws {
        guard let pendingRecovery = pendingRecoveries[recoveryID] else {
            throw IsolatedDebugLauncherError.recoveryNotFound(recoveryID)
        }
        guard recoveryAttempts.insert(recoveryID).inserted else {
            throw IsolatedDebugLauncherError.recoveryAlreadyInProgress(recoveryID)
        }
        defer { recoveryAttempts.remove(recoveryID) }

        switch pendingRecovery {
        case let .validated(record, primaryReason):
            do {
                try await detachedTerminateAndRemove(record)
                pendingRecoveries.removeValue(forKey: recoveryID)
            } catch {
                throw IsolatedDebugLauncherError.recoveryRequired(
                    recoveryID: recoveryID,
                    processIdentifier: record.process.pid,
                    primary: primaryReason,
                    recoveryFailure: error.localizedDescription
                )
            }

        case let .quarantined(
            id,
            bundle,
            processIdentifier,
            storage,
            launchBaseline,
            primaryReason
        ):
            try await retryQuarantinedRecovery(
                id: id,
                bundle: bundle,
                processIdentifier: processIdentifier,
                storage: storage,
                launchBaseline: launchBaseline,
                primaryReason: primaryReason
            )
        }
    }

    private static func requiredArguments(for storage: IsolatedRuntimeStorage) -> [String] {
        [
            "--user-data-dir=\(storage.userDataDirectory.path)",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
        ]
    }

    private func captureLaunchBaseline(
        for bundle: VerifiedChatGPTBundle
    ) async throws -> LaunchBaseline {
        let appContents = Self.canonical(
            bundle.appURL.appendingPathComponent("Contents", isDirectory: true)
        )
        let candidates = try processInspector.allUserProcesses()
        let processes = candidates.compactMap { candidate -> BaselineProcessIdentity? in
            let executable = Self.canonical(candidate.executableURL)
            guard executable.isStrictDescendant(of: appContents) else { return nil }
            return BaselineProcessIdentity(
                pid: candidate.pid,
                startTime: candidate.startTime,
                executableURL: executable
            )
        }
        let applications = await applicationController.runningApplications(
            bundleIdentifier: bundle.bundleIdentifier
        ).map { application in
            BaselineApplicationIdentity(
                pid: application.pid,
                executableURL: application.executableURL.map(Self.canonical)
            )
        }
        return LaunchBaseline(processes: processes, applications: applications)
    }

    private func retryQuarantinedRecovery(
        id recoveryID: UUID,
        bundle: VerifiedChatGPTBundle,
        processIdentifier: pid_t?,
        storage: IsolatedRuntimeStorage,
        launchBaseline: LaunchBaseline,
        primaryReason: String
    ) async throws {
        guard let processIdentifier else {
            try await recoverUnknownOrExitedLaunch(
                recoveryID: recoveryID,
                bundle: bundle,
                processIdentifier: nil,
                storage: storage,
                launchBaseline: launchBaseline,
                primaryReason: primaryReason
            )
            return
        }
        let process: RuntimeProcessSnapshot
        do {
            process = try processInspector.snapshot(pid: processIdentifier)
        } catch RuntimeSecurityError.processUnavailable {
            try await recoverUnknownOrExitedLaunch(
                recoveryID: recoveryID,
                bundle: bundle,
                processIdentifier: processIdentifier,
                storage: storage,
                launchBaseline: launchBaseline,
                primaryReason: primaryReason
            )
            return
        } catch {
            throw IsolatedDebugLauncherError.recoveryRequired(
                recoveryID: recoveryID,
                processIdentifier: processIdentifier,
                primary: primaryReason,
                recoveryFailure: "尚未验证的 PID 无法重新 snapshot：\(error.localizedDescription)"
            )
        }

        do {
            guard process.pid == processIdentifier else {
                throw RuntimeSecurityError.processIdentityMismatch(
                    "recovery snapshot PID 不匹配：期望 \(processIdentifier)，实际 \(process.pid)"
                )
            }
            try verifyLaunchIdentity(process, bundle: bundle, storage: storage)
        } catch {
            throw IsolatedDebugLauncherError.recoveryRequired(
                recoveryID: recoveryID,
                processIdentifier: processIdentifier,
                primary: primaryReason,
                recoveryFailure: "尚未验证的 PID 仍未通过完整身份复核：\(error.localizedDescription)"
            )
        }

        let validatedRecord = SessionRecord(
            id: recoveryID,
            bundle: bundle,
            process: process,
            storage: storage,
            launchBaseline: launchBaseline
        )
        try await performValidatedRecovery(
            validatedRecord,
            primaryReason: primaryReason
        )
    }

    private func performValidatedRecovery(
        _ validatedRecord: SessionRecord,
        primaryReason: String
    ) async throws {
        pendingRecoveries[validatedRecord.id] = .validated(
            record: validatedRecord,
            primaryReason: primaryReason
        )
        do {
            try await detachedTerminateAndRemove(validatedRecord)
            pendingRecoveries.removeValue(forKey: validatedRecord.id)
        } catch {
            throw IsolatedDebugLauncherError.recoveryRequired(
                recoveryID: validatedRecord.id,
                processIdentifier: validatedRecord.process.pid,
                primary: primaryReason,
                recoveryFailure: error.localizedDescription
            )
        }
    }

    private func recoverUnknownOrExitedLaunch(
        recoveryID: UUID,
        bundle: VerifiedChatGPTBundle,
        processIdentifier: pid_t?,
        storage: IsolatedRuntimeStorage,
        launchBaseline: LaunchBaseline,
        primaryReason: String
    ) async throws {
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timing.processDiscoveryTimeout)
            var emptyObservationCount = 0

            while true {
                try verifyStorageIdentity(storage)
                let observation = try await quarantinedObservation(
                    processIdentifier: processIdentifier,
                    bundle: bundle,
                    storage: storage,
                    launchBaseline: launchBaseline
                )
                if !observation.isEmpty {
                    let validatedRecord = try validatedUnknownPIDRecord(
                        recoveryID: recoveryID,
                        expectedProcessIdentifier: processIdentifier,
                        observation: observation,
                        bundle: bundle,
                        storage: storage,
                        launchBaseline: launchBaseline
                    )
                    try await performValidatedRecovery(
                        validatedRecord,
                        primaryReason: primaryReason
                    )
                    return
                }

                emptyObservationCount += 1
                if emptyObservationCount >= 2, clock.now >= deadline {
                    break
                }
                if clock.now < deadline {
                    try await Task.sleep(for: timing.pollInterval)
                }
            }

            // Deletion has its own terminal observation after the stable window.
            // A process that appears here is deliberately left quarantined for a
            // later retry; this branch never begins signalling after deciding to
            // take the storage-only path.
            try verifyStorageIdentity(storage)
            let finalObservation = try await quarantinedObservation(
                processIdentifier: processIdentifier,
                bundle: bundle,
                storage: storage,
                launchBaseline: launchBaseline
            )
            guard finalObservation.isEmpty else {
                throw RuntimeSecurityError.processIdentityMismatch(
                    "终态扫描发现新的官方 app 或关联 helper："
                        + describe(finalObservation)
                )
            }
            try verifyStorageIdentity(storage)
            try storageManager.removeStorage(storage)
            pendingRecoveries.removeValue(forKey: recoveryID)
        } catch {
            if let launcherError = error as? IsolatedDebugLauncherError {
                throw launcherError
            }
            throw IsolatedDebugLauncherError.recoveryRequired(
                recoveryID: recoveryID,
                processIdentifier: processIdentifier,
                primary: primaryReason,
                recoveryFailure: "无法证明隔离 storage 已无人使用：\(error.localizedDescription)"
            )
        }
    }

    private func quarantinedObservation(
        processIdentifier: pid_t?,
        bundle: VerifiedChatGPTBundle,
        storage: IsolatedRuntimeStorage,
        launchBaseline: LaunchBaseline
    ) async throws -> QuarantinedObservation {
        let storageRoot = Self.canonical(storage.rootURL)
        let protectedPaths = [
            storage.rootURL.standardizedFileURL.path,
            storage.userDataDirectory.standardizedFileURL.path,
            storage.codexHomeDirectory.standardizedFileURL.path,
        ]
        let appContents = Self.canonical(
            bundle.appURL.appendingPathComponent("Contents", isDirectory: true)
        )

        let allProcesses = try processInspector.allUserProcesses()
        let relevantProcesses = allProcesses.filter { candidate in
            let executable = Self.canonical(candidate.executableURL)
            let executableIsInStorage = executable.isStrictDescendant(of: storageRoot)
            let isReturnedPIDOrGroup = processIdentifier.map {
                candidate.pid == $0 || candidate.processGroupID == $0
            } ?? false
            let argumentsReferenceStorage = candidate.arguments?.contains { argument in
                protectedPaths.contains { path in
                    argument == path
                        || argument.hasPrefix("\(path)/")
                        || argument == "--user-data-dir=\(path)"
                        || argument.hasPrefix("--user-data-dir=\(path)/")
                }
            } ?? false
            let belongsToVerifiedApp = executable.isStrictDescendant(of: appContents)
            let isNewVerifiedAppCandidate = belongsToVerifiedApp
                && !launchBaseline.contains(candidate)
            return executableIsInStorage
                || isReturnedPIDOrGroup
                || argumentsReferenceStorage
                || isNewVerifiedAppCandidate
        }.sorted { $0.pid < $1.pid }

        let applications = await applicationController.runningApplications(
            bundleIdentifier: bundle.bundleIdentifier
        )
        let newApplications = applications
            .filter { application in
                guard launchBaseline.contains(application),
                      let currentProcess = allProcesses.first(where: {
                          $0.pid == application.pid
                      }),
                      launchBaseline.contains(currentProcess)
                else {
                    // PID reuse is not accepted as a baseline match: the kernel
                    // start time must still be the one captured before launch.
                    return true
                }
                return false
            }
            .sorted { $0.pid < $1.pid }
        return QuarantinedObservation(
            relevantProcesses: relevantProcesses,
            newApplications: newApplications
        )
    }

    private func validatedUnknownPIDRecord(
        recoveryID: UUID,
        expectedProcessIdentifier: pid_t?,
        observation: QuarantinedObservation,
        bundle: VerifiedChatGPTBundle,
        storage: IsolatedRuntimeStorage,
        launchBaseline: LaunchBaseline
    ) throws -> SessionRecord {
        guard observation.newApplications.count == 1,
              let application = observation.newApplications.first,
              application.pid > 1,
              application.pid != getpid(),
              application.bundleIdentifier == bundle.bundleIdentifier,
              let applicationExecutable = application.executableURL,
              Self.canonical(applicationExecutable) == Self.canonical(bundle.executableURL)
        else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "新增 Launch Services app 不唯一或身份不完整：\(describe(observation))"
            )
        }
        if let expectedProcessIdentifier,
           application.pid != expectedProcessIdentifier {
            throw RuntimeSecurityError.processIdentityMismatch(
                "新增 Launch Services PID 与 launcher 返回值不匹配"
            )
        }

        let process = try processInspector.snapshot(pid: application.pid)
        guard process.pid == application.pid else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "新增 app snapshot PID 不匹配"
            )
        }
        try verifyLaunchIdentity(process, bundle: bundle, storage: storage)
        let processCandidate = RuntimeProcessCandidate(process)
        guard !launchBaseline.contains(processCandidate),
              observation.relevantProcesses.contains(where: {
                  Self.sameIdentity($0, processCandidate)
              })
        else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "新增 LS app 未在进程增量视图中闭合"
            )
        }

        let members = try processInspector.groupMembers(
            processGroupID: process.processGroupID
        )
        let provisionalRecord = SessionRecord(
            id: recoveryID,
            bundle: bundle,
            process: process,
            storage: storage,
            launchBaseline: launchBaseline
        )
        try validateGroupMembers(members, record: provisionalRecord)
        let memberCandidates = members.map(RuntimeProcessCandidate.init)
        let storageRoot = Self.canonical(storage.rootURL)
        let appContents = Self.canonical(
            bundle.appURL.appendingPathComponent("Contents", isDirectory: true)
        )

        for candidate in observation.relevantProcesses {
            let executable = Self.canonical(candidate.executableURL)
            if executable.isStrictDescendant(of: appContents) {
                guard candidate.processGroupID == process.processGroupID,
                      memberCandidates.contains(where: {
                          Self.sameIdentity($0, candidate)
                      })
                else {
                    throw RuntimeSecurityError.processIdentityMismatch(
                        "新增官方 app/helper 不在已验证独立 PGID 内：PID \(candidate.pid)"
                    )
                }
            } else if executable.isStrictDescendant(of: storageRoot) {
                guard candidate.arguments != nil,
                      candidate.pid > 1,
                      candidate.pid != getpid(),
                      candidate.startTime >= process.startTime
                else {
                    throw RuntimeSecurityError.processIdentityMismatch(
                        "隔离 storage helper 身份不完整：PID \(candidate.pid)"
                    )
                }
            } else {
                throw RuntimeSecurityError.processIdentityMismatch(
                    "关联进程 executable 不在允许根目录：PID \(candidate.pid)"
                )
            }
        }
        return provisionalRecord
    }

    private static func sameIdentity(
        _ lhs: RuntimeProcessCandidate,
        _ rhs: RuntimeProcessCandidate
    ) -> Bool {
        lhs.pid == rhs.pid
            && lhs.processGroupID == rhs.processGroupID
            && lhs.startTime == rhs.startTime
            && canonical(lhs.executableURL) == canonical(rhs.executableURL)
            && lhs.arguments == rhs.arguments
    }

    private func describe(_ observation: QuarantinedObservation) -> String {
        let processes = observation.relevantProcesses.map {
            "PID \($0.pid)/PGID \($0.processGroupID)"
        }.joined(separator: ", ")
        let applications = observation.newApplications.map {
            "LS PID \($0.pid)"
        }.joined(separator: ", ")
        return "processes=[\(processes)], applications=[\(applications)]"
    }

    private func detachedTerminateAndRemove(_ record: SessionRecord) async throws {
        // This recovery is deliberately detached from the cancelled launch/apply
        // task. Once a process has been positively identified, cancellation must
        // not interrupt the authorized rollback halfway through termination.
        try await Task.detached { [self] in
            try await terminateAndRemove(record)
        }.value
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

    private func verifyLaunchIdentity(
        _ process: RuntimeProcessSnapshot,
        bundle: VerifiedChatGPTBundle,
        storage: IsolatedRuntimeStorage
    ) throws {
        guard process.pid > 1 else {
            throw RuntimeSecurityError.processIdentityMismatch("launcher 返回了无效 PID")
        }
        guard process.processGroupID == process.pid,
              process.processGroupID > 1,
              process.processGroupID != getpgrp()
        else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "目标进程没有独立且安全的 PGID：PID \(process.pid)，PGID \(process.processGroupID)"
            )
        }
        let actualExecutable = process.executableURL.resolvingSymlinksInPath().standardizedFileURL
        let expectedExecutable = bundle.executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard actualExecutable == expectedExecutable else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "executable 不匹配：\(actualExecutable.path)"
            )
        }

        let required = Set(Self.requiredArguments(for: storage))
        let actual = Set(process.arguments)
        guard required.isSubset(of: actual) else {
            throw RuntimeSecurityError.processIdentityMismatch("目标进程缺少隔离调试参数")
        }
        try verifyStorageIdentity(storage)
    }

    private func terminateAndRemove(_ record: SessionRecord) async throws {
        try verifyStorageIdentity(record.storage)

        var members = try processInspector.groupMembers(
            processGroupID: record.process.processGroupID
        )
        if !members.isEmpty {
            let leader = try validatedLeader(in: members, record: record)
            let gracefulReference = RunningChatGPTApplication(
                pid: leader.pid,
                bundleIdentifier: record.bundle.bundleIdentifier,
                executableURL: leader.executableURL
            )
            let gracefulAccepted = await applicationController.requestTermination(
                of: gracefulReference
            )
            if gracefulAccepted {
                _ = try await waitUntilGroupIsEmpty(
                    record.process.processGroupID,
                    for: timing.terminationGracePeriod
                )
            }
        }

        // Some CODEX_HOME plugins join an unrelated browser's process group.
        // They are never group-signaled: only exact, revalidated PIDs whose
        // executable remains inside this session's private storage are eligible.
        try await terminateStorageDescendants(record)

        members = try processInspector.groupMembers(
            processGroupID: record.process.processGroupID
        )
        if !members.isEmpty {
            // Group fallback remains limited to signed app-bundle executables.
            // Storage helpers have already been handled by exact PID above.
            try validateGroupMembers(
                members,
                record: record
            )
            try processGroupSignaler.send(
                signal: SIGTERM,
                toProcessGroup: record.process.processGroupID
            )
            if !(try await waitUntilGroupIsEmpty(
                record.process.processGroupID,
                for: timing.terminationGracePeriod
            )) {
                members = try processInspector.groupMembers(
                    processGroupID: record.process.processGroupID
                )
                if !members.isEmpty {
                    // The leader commonly exits before Electron helpers. Revalidate every
                    // survivor before escalating; do not require the departed leader.
                    try validateGroupMembers(members, record: record)
                    try processGroupSignaler.send(
                        signal: SIGKILL,
                        toProcessGroup: record.process.processGroupID
                    )
                }
                guard try await waitUntilGroupIsEmpty(
                    record.process.processGroupID,
                    for: timing.killGracePeriod
                ) else {
                    throw RuntimeSecurityError.cleanupTimedOut
                }
            }
        }

        // Re-enumerate immediately before deletion to catch cross-PGID helpers
        // that appeared while the main app group was exiting.
        try await terminateStorageDescendants(record)
        guard try storageDescendants(for: record).isEmpty else {
            throw RuntimeSecurityError.cleanupTimedOut
        }
        let finalObservation = try await quarantinedObservation(
            processIdentifier: record.process.pid,
            bundle: record.bundle,
            storage: record.storage,
            launchBaseline: record.launchBaseline
        )
        guard finalObservation.isEmpty else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "清理终态仍存在本次启动新增的 app/helper："
                    + describe(finalObservation)
            )
        }
        try verifyStorageIdentity(record.storage)
        try storageManager.removeStorage(record.storage)
    }

    private func terminateStorageDescendants(_ record: SessionRecord) async throws {
        let initial = try storageDescendants(for: record)
        guard !initial.isEmpty else { return }

        // Preflight every target before mutating any process. Each signal path
        // performs this same exact identity check again immediately before kill(2).
        for process in initial {
            _ = try liveExactProcess(process, record: record)
        }
        for process in initial {
            try signalExactProcessIfStillLive(
                process,
                signal: SIGTERM,
                record: record
            )
        }

        var remaining = try await waitForExactProcesses(
            initial,
            toExitWithin: timing.terminationGracePeriod,
            record: record
        )
        for process in remaining {
            try signalExactProcessIfStillLive(
                process,
                signal: SIGKILL,
                record: record
            )
        }
        remaining = try await waitForExactProcesses(
            remaining,
            toExitWithin: timing.killGracePeriod,
            record: record
        )
        guard remaining.isEmpty else {
            throw RuntimeSecurityError.cleanupTimedOut
        }

        let final = try storageDescendants(for: record)
        guard final.isEmpty else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "精确清理期间出现了新的隔离存储进程"
            )
        }
    }

    private func storageDescendants(
        for record: SessionRecord
    ) throws -> [RuntimeProcessSnapshot] {
        try verifyStorageIdentity(record.storage)
        let storageRoot = Self.canonical(record.storage.rootURL)
        var descendants: [RuntimeProcessSnapshot] = []
        for candidate in try processInspector.allUserProcesses() {
            let executable = Self.canonical(candidate.executableURL)
            guard executable.isStrictDescendant(of: storageRoot) else { continue }
            guard candidate.pid > 1,
                  candidate.pid != getpid(),
                  candidate.startTime >= record.process.startTime
            else {
                throw RuntimeSecurityError.processIdentityMismatch(
                    "PID \(candidate.pid) 位于隔离存储中，但 PID 或启动时间不安全"
                )
            }
            guard let process = candidate.exactSnapshot() else {
                throw RuntimeSecurityError.processIdentityMismatch(
                    "无法读取隔离存储 PID \(candidate.pid) 的 argv"
                )
            }
            descendants.append(process)
        }
        return descendants.sorted { $0.pid < $1.pid }
    }

    private func signalExactProcessIfStillLive(
        _ expected: RuntimeProcessSnapshot,
        signal: Int32,
        record: SessionRecord
    ) throws {
        guard let current = try liveExactProcess(expected, record: record) else {
            return
        }
        try exactProcessSignaler.send(signal: signal, toProcessID: current.pid)
    }

    private func liveExactProcess(
        _ expected: RuntimeProcessSnapshot,
        record: SessionRecord
    ) throws -> RuntimeProcessSnapshot? {
        try verifyStorageIdentity(record.storage)
        let current: RuntimeProcessSnapshot
        do {
            current = try processInspector.snapshot(pid: expected.pid)
        } catch RuntimeSecurityError.processUnavailable {
            return nil
        }

        let storageRoot = Self.canonical(record.storage.rootURL)
        let expectedExecutable = Self.canonical(expected.executableURL)
        let currentExecutable = Self.canonical(current.executableURL)
        guard current.pid == expected.pid,
              current.pid > 1,
              current.pid != getpid(),
              current.startTime == expected.startTime,
              current.startTime >= record.process.startTime,
              currentExecutable == expectedExecutable,
              currentExecutable.isStrictDescendant(of: storageRoot),
              current.arguments == expected.arguments
        else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "PID \(expected.pid) 在精确信号前身份发生变化"
            )
        }
        return current
    }

    private func waitForExactProcesses(
        _ expected: [RuntimeProcessSnapshot],
        toExitWithin timeout: Duration,
        record: SessionRecord
    ) async throws -> [RuntimeProcessSnapshot] {
        guard !expected.isEmpty else { return [] }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            var remaining: [RuntimeProcessSnapshot] = []
            for process in expected {
                if let current = try liveExactProcess(process, record: record) {
                    remaining.append(current)
                }
            }
            if remaining.isEmpty { return [] }
            guard clock.now < deadline else { return remaining }
            try await Task.sleep(for: timing.pollInterval)
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func waitUntilGroupIsEmpty(
        _ processGroupID: pid_t,
        for timeout: Duration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if try processInspector.groupMembers(processGroupID: processGroupID).isEmpty {
                return true
            }
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: timing.pollInterval)
        }
    }

    private func validateGroupMembers(
        _ members: [RuntimeProcessSnapshot],
        record: SessionRecord
    ) throws {
        let expectedPGID = record.process.processGroupID
        let appContents = record.bundle.appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard !members.isEmpty else {
            throw RuntimeSecurityError.unsafeProcessGroup("进程组为空")
        }

        for member in members {
            guard member.pid > 1,
                  member.pid != getpid(),
                  member.processGroupID == expectedPGID,
                  member.startTime >= record.process.startTime
            else {
                throw RuntimeSecurityError.unsafeProcessGroup(
                    "PID \(member.pid) 的 PGID 或启动时间不安全"
                )
            }

            let executable = member.executableURL.resolvingSymlinksInPath().standardizedFileURL
            let belongsToVerifiedApp = executable.isStrictDescendant(of: appContents)
            guard belongsToVerifiedApp else {
                throw RuntimeSecurityError.unsafeProcessGroup(
                    "PID \(member.pid) 的 executable 不在允许根目录：\(executable.path)"
                )
            }
        }
    }

    private func validatedLeader(
        in members: [RuntimeProcessSnapshot],
        record: SessionRecord
    ) throws -> RuntimeProcessSnapshot {
        guard let leader = members.first(where: { $0.pid == record.process.pid }),
              leader.processGroupID == record.process.processGroupID,
              leader.startTime == record.process.startTime,
              leader.executableURL.resolvingSymlinksInPath().standardizedFileURL
                == record.process.executableURL.resolvingSymlinksInPath().standardizedFileURL,
              Set(Self.requiredArguments(for: record.storage))
                .isSubset(of: Set(leader.arguments))
        else {
            throw RuntimeSecurityError.unsafeProcessGroup("leader 身份已变化")
        }
        return leader
    }

    private func verifyStorageIdentity(_ storage: IsolatedRuntimeStorage) throws {
        try verifyDirectory(
            storage.rootURL,
            expected: storage.rootIdentity
        )
        try verifyDirectory(
            storage.userDataDirectory,
            expected: storage.userDataIdentity
        )
        try verifyDirectory(
            storage.codexHomeDirectory,
            expected: storage.codexHomeIdentity
        )
    }

    private func verifyDirectory(_ url: URL, expected: FileIdentity) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == expected.owner,
              info.st_uid == getuid(),
              UInt64(info.st_dev) == expected.device,
              UInt64(info.st_ino) == expected.inode,
              info.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
        else {
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(url.path)
        }
    }
}
