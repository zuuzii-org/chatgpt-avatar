import Darwin
import Foundation
import XCTest

@testable import ChatGPTSkinStudio

final class IsolatedDebugRecoveryTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSkinStudio-IsolatedRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testValidatedLaunchFailureRetainsFailedCleanupAndRetryClearsIt() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_001,
            executableURL: fixture.bundle.executableURL,
            mode: .valid,
            groupAlive: false
        )
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 1
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected launch failure")
        } catch let IsolatedDebugLauncherError.recoveryRequired(
            id,
            processIdentifier,
            primary,
            recoveryFailure
        ) {
            recoveryID = id
            XCTAssertEqual(processIdentifier, harness.processIdentifier)
            XCTAssertTrue(primary.contains("injected endpoint failure"))
            XCTAssertTrue(recoveryFailure.contains("injected storage removal failure"))
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        let retained = await launcher.recoveryRecords()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.id, recoveryID)
        XCTAssertEqual(retained.first?.kind, .validatedCleanup)
        let storageRoot = try XCTUnwrap(retained.first?.storageRootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))

        try await launcher.retryRecovery(id: recoveryID)

        let remainingRecoveries = await launcher.recoveryRecords()
        XCTAssertTrue(remainingRecoveries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertEqual(storageManager.removalCancellationStates(), [false, false])
    }

    func testCancelledLaunchCannotCancelDetachedValidatedCleanup() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_002,
            executableURL: fixture.bundle.executableURL,
            mode: .valid,
            groupAlive: false
        )
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: true
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            XCTFail("Expected endpoint failure")
        } catch RuntimeSecurityError.activePortFileUnavailable {
            // The primary error remains observable after detached cleanup succeeds.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(storageManager.removalCancellationStates(), [false])
        let remainingRecoveries = await launcher.recoveryRecords()
        XCTAssertTrue(remainingRecoveries.isEmpty)
        let storage = try XCTUnwrap(storageManager.lastCreatedStorage())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.rootURL.path))
    }

    func testUnverifiedLaunchNeverSignalsUntilRetryRevalidatesFullIdentity() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_003,
            executableURL: fixture.bundle.executableURL,
            mode: .wrongIdentity,
            groupAlive: true
        )
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected quarantine")
        } catch let IsolatedDebugLauncherError.launchQuarantined(
            id,
            processIdentifier,
            storageRootURL,
            primary
        ) {
            recoveryID = id
            XCTAssertEqual(processIdentifier, harness.processIdentifier)
            XCTAssertTrue(primary.contains("独立且安全的 PGID"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: storageRootURL.path))
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        do {
            try await launcher.retryRecovery(id: recoveryID)
            XCTFail("Expected identity rejection")
        } catch let IsolatedDebugLauncherError.recoveryRequired(
            id,
            _,
            _,
            recoveryFailure
        ) {
            XCTAssertEqual(id, recoveryID)
            XCTAssertTrue(recoveryFailure.contains("完整身份复核"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.groupSignals().isEmpty)
        XCTAssertTrue(storageManager.removalCancellationStates().isEmpty)

        harness.setMode(.valid)
        try await launcher.retryRecovery(id: recoveryID)

        XCTAssertEqual(harness.groupSignals(), [SIGTERM])
        let remainingRecoveries = await launcher.recoveryRecords()
        XCTAssertTrue(remainingRecoveries.isEmpty)
        XCTAssertEqual(storageManager.removalCancellationStates(), [false])
    }

    func testMissingUnverifiedPIDKeepsStorageWhileAnyScopedProcessRemains() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_004,
            executableURL: fixture.bundle.executableURL,
            mode: .unavailable,
            groupAlive: false
        )
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        let storageRoot: URL
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected quarantine")
        } catch let IsolatedDebugLauncherError.launchQuarantined(
            id,
            _,
            root,
            _
        ) {
            recoveryID = id
            storageRoot = root
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        harness.setCandidates([
            RuntimeProcessCandidate(
                pid: 45_005,
                processGroupID: harness.processIdentifier,
                startTime: .init(seconds: 101, microseconds: 1),
                executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: nil
            ),
        ])
        do {
            try await launcher.retryRecovery(id: recoveryID)
            XCTFail("Expected scoped-process quarantine")
        } catch let IsolatedDebugLauncherError.recoveryRequired(
            id,
            _,
            _,
            recoveryFailure
        ) {
            XCTAssertEqual(id, recoveryID)
            XCTAssertTrue(recoveryFailure.contains("Launch Services app"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertTrue(storageManager.removalCancellationStates().isEmpty)
        XCTAssertTrue(harness.groupSignals().isEmpty)

        harness.setCandidates([])
        try await launcher.retryRecovery(id: recoveryID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertEqual(storageManager.removalCancellationStates(), [false])
        let remainingRecoveries = await launcher.recoveryRecords()
        XCTAssertTrue(remainingRecoveries.isEmpty)
    }

    func testWorkspaceLaunchFailureRetainsUnknownPIDRecoveryWhenRemovalFails() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_006,
            executableURL: fixture.bundle.executableURL,
            mode: .unavailable,
            groupAlive: false
        )
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 1
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false,
            workspaceLaunchThrows: true
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected unknown-PID recovery")
        } catch let IsolatedDebugLauncherError.launchQuarantined(
            id,
            processIdentifier,
            storageRootURL,
            primary
        ) {
            recoveryID = id
            XCTAssertNil(processIdentifier)
            XCTAssertTrue(primary.contains("injected workspace launch failure"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: storageRootURL.path))
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        let retained = await launcher.recoveryRecords()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.id, recoveryID)
        XCTAssertEqual(retained.first?.kind, .unverifiedLaunch)
        XCTAssertNil(retained.first?.processIdentifier)
        let storageRoot = try XCTUnwrap(retained.first?.storageRootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertTrue(harness.groupSignals().isEmpty)
        XCTAssertTrue(storageManager.removalCancellationStates().isEmpty)

        do {
            try await launcher.retryRecovery(id: recoveryID)
            XCTFail("Expected injected storage removal failure")
        } catch let IsolatedDebugLauncherError.recoveryRequired(
            id,
            processIdentifier,
            _,
            recoveryFailure
        ) {
            XCTAssertEqual(id, recoveryID)
            XCTAssertNil(processIdentifier)
            XCTAssertTrue(recoveryFailure.contains("injected storage removal failure"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))

        try await launcher.retryRecovery(id: recoveryID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertTrue(harness.groupSignals().isEmpty)
        let remainingRecoveries = await launcher.recoveryRecords()
        XCTAssertTrue(remainingRecoveries.isEmpty)
    }

    func testWorkspaceLaunchFailureDoesNotDeleteUnknownPIDStorageWithAppBlocker() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_007,
            executableURL: fixture.bundle.executableURL,
            mode: .unavailable,
            groupAlive: false
        )
        harness.setUnknownPIDAppBlocker(true)
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false,
            workspaceLaunchThrows: true
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        let storageRoot: URL
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected unknown-PID storage quarantine")
        } catch let IsolatedDebugLauncherError.launchQuarantined(
            id,
            processIdentifier,
            root,
            _
        ) {
            recoveryID = id
            XCTAssertNil(processIdentifier)
            storageRoot = root
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertTrue(storageManager.removalCancellationStates().isEmpty)
        XCTAssertTrue(harness.groupSignals().isEmpty)

        do {
            try await launcher.retryRecovery(id: recoveryID)
            XCTFail("Expected ambiguous app quarantine")
        } catch let IsolatedDebugLauncherError.recoveryRequired(
            id,
            processIdentifier,
            _,
            recoveryFailure
        ) {
            XCTAssertEqual(id, recoveryID)
            XCTAssertNil(processIdentifier)
            XCTAssertTrue(recoveryFailure.contains("Launch Services app"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertTrue(storageManager.removalCancellationStates().isEmpty)
        XCTAssertTrue(harness.groupSignals().isEmpty)

        harness.setUnknownPIDAppBlocker(false)
        try await launcher.retryRecovery(id: recoveryID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertTrue(harness.groupSignals().isEmpty)
        let remainingRecoveries = await launcher.recoveryRecords()
        XCTAssertTrue(remainingRecoveries.isEmpty)
    }

    func testUnknownPIDRetryPromotesOnlyFullyClosedNewLaunchIdentity() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_008,
            executableURL: fixture.bundle.executableURL,
            mode: .valid,
            groupAlive: true
        )
        harness.setPostLaunchScenarios([.validMain])
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false,
            workspaceLaunchThrows: true
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        let storageRoot: URL
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected unknown-PID quarantine")
        } catch let IsolatedDebugLauncherError.launchQuarantined(
            id,
            processIdentifier,
            root,
            _
        ) {
            recoveryID = id
            storageRoot = root
            XCTAssertNil(processIdentifier)
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        try await launcher.retryRecovery(id: recoveryID)

        XCTAssertEqual(harness.groupSignals(), [SIGTERM])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
        XCTAssertEqual(storageManager.removalCancellationStates(), [false])
        let remainingRecoveries = await launcher.recoveryRecords()
        XCTAssertTrue(remainingRecoveries.isEmpty)
    }

    func testDelayedUnknownPIDProcessPreventsStableStorageDeletion() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_009,
            executableURL: fixture.bundle.executableURL,
            mode: .wrongIdentity,
            groupAlive: true
        )
        harness.setPostLaunchScenarios([.none, .ambiguousMain])
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false,
            workspaceLaunchThrows: true,
            processDiscoveryTimeout: .milliseconds(3)
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        let storageRoot: URL
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected unknown-PID quarantine")
        } catch let IsolatedDebugLauncherError.launchQuarantined(id, _, root, _) {
            recoveryID = id
            storageRoot = root
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        do {
            try await launcher.retryRecovery(id: recoveryID)
            XCTFail("Expected delayed ambiguous process to remain quarantined")
        } catch let IsolatedDebugLauncherError.recoveryRequired(
            id,
            processIdentifier,
            _,
            recoveryFailure
        ) {
            XCTAssertEqual(id, recoveryID)
            XCTAssertNil(processIdentifier)
            XCTAssertTrue(recoveryFailure.contains("独立且安全的 PGID"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertGreaterThanOrEqual(harness.candidateScanCount(), 3)
        XCTAssertTrue(harness.groupSignals().isEmpty)
        XCTAssertTrue(storageManager.removalCancellationStates().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    func testAmbiguousNewPIDIsNeverSignaledOrDeleted() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_010,
            executableURL: fixture.bundle.executableURL,
            mode: .wrongIdentity,
            groupAlive: true
        )
        harness.setPostLaunchScenarios([.ambiguousMain])
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false,
            workspaceLaunchThrows: true
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        let storageRoot: URL
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected unknown-PID quarantine")
        } catch let IsolatedDebugLauncherError.launchQuarantined(id, _, root, _) {
            recoveryID = id
            storageRoot = root
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        do {
            try await launcher.retryRecovery(id: recoveryID)
            XCTFail("Expected ambiguous identity rejection")
        } catch IsolatedDebugLauncherError.recoveryRequired {
            // Expected: no mutation is authorized by an incomplete identity.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.groupSignals().isEmpty)
        XCTAssertTrue(storageManager.removalCancellationStates().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    func testLaunchServicesBaselineCannotHideSamePIDWithNewStartTime() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_011,
            executableURL: fixture.bundle.executableURL,
            mode: .wrongIdentity,
            groupAlive: true
        )
        harness.setPrelaunchState(
            candidates: [
                RuntimeProcessCandidate(
                    pid: harness.processIdentifier,
                    processGroupID: harness.processIdentifier,
                    startTime: .init(seconds: 50, microseconds: 1),
                    executableURL: fixture.bundle.executableURL,
                    arguments: []
                ),
            ],
            applications: [
                RunningChatGPTApplication(
                    pid: harness.processIdentifier,
                    bundleIdentifier: fixture.bundle.bundleIdentifier,
                    executableURL: fixture.bundle.executableURL
                ),
            ]
        )
        harness.setPostLaunchScenarios([.ambiguousMain])
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false,
            workspaceLaunchThrows: true
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))

        let recoveryID: UUID
        let storageRoot: URL
        do {
            _ = try await launcher.launch(
                verifiedBundle: fixture.bundle,
                consent: consent
            )
            return XCTFail("Expected unknown-PID quarantine")
        } catch let IsolatedDebugLauncherError.launchQuarantined(id, _, root, _) {
            recoveryID = id
            storageRoot = root
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        do {
            try await launcher.retryRecovery(id: recoveryID)
            XCTFail("Expected PID-reuse identity rejection")
        } catch IsolatedDebugLauncherError.recoveryRequired {
            // The new kernel start time must defeat the LS pid/executable baseline.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.groupSignals().isEmpty)
        XCTAssertTrue(storageManager.removalCancellationStates().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    func testCancelledCallerCannotInterruptRecognizedSessionCleanup() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_012,
            executableURL: fixture.bundle.executableURL,
            mode: .valid,
            groupAlive: true
        )
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false,
            endpointSucceeds: true
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let session = try await launcher.launch(
            verifiedBundle: fixture.bundle,
            consent: consent
        )

        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        try await launcher.cleanup(session)

        XCTAssertEqual(harness.groupSignals(), [SIGTERM])
        XCTAssertEqual(storageManager.removalCancellationStates(), [false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
        let isActive = await launcher.isActive(session)
        XCTAssertFalse(isActive)
    }

    func testConcurrentCleanupIsRejectedWithoutDuplicateSignalOrDeletion() async throws {
        let fixture = try makeFixture()
        let harness = IsolatedRecoveryHarness(
            processIdentifier: 45_013,
            executableURL: fixture.bundle.executableURL,
            mode: .valid,
            groupAlive: true
        )
        harness.setAcceptsGracefulTermination(true)
        let storageManager = AuditedIsolatedStorageManager(
            temporaryRoot: temporaryRoot,
            injectedRemovalFailures: 0
        )
        let launcher = makeLauncher(
            harness: harness,
            storageManager: storageManager,
            cancelBeforeEndpointFailure: false,
            endpointSucceeds: true,
            terminationGracePeriod: .milliseconds(30)
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let session = try await launcher.launch(
            verifiedBundle: fixture.bundle,
            consent: consent
        )

        let firstCleanup = Task {
            try await launcher.cleanup(session)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while harness.gracefulRequestCount() == 0, clock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(harness.gracefulRequestCount(), 1)

        do {
            try await launcher.cleanup(session)
            XCTFail("Expected concurrent cleanup rejection")
        } catch let IsolatedDebugLauncherError.recoveryAlreadyInProgress(id) {
            XCTAssertEqual(id, session.id)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        try await firstCleanup.value

        XCTAssertEqual(harness.groupSignals(), [SIGTERM])
        XCTAssertEqual(storageManager.removalCancellationStates(), [false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    private func makeFixture() throws -> IsolatedRecoveryFixture {
        let appURL = temporaryRoot.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/ChatGPT")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture executable".utf8).write(to: executableURL)
        return IsolatedRecoveryFixture(
            bundle: VerifiedChatGPTBundle(
                appURL: appURL,
                executableURL: executableURL,
                bundleIdentifier: "com.openai.codex",
                teamIdentifier: "2DC432GLL2",
                shortVersion: "99.0",
                buildVersion: "isolated-recovery-tests"
            )
        )
    }

    private func makeLauncher(
        harness: IsolatedRecoveryHarness,
        storageManager: AuditedIsolatedStorageManager,
        cancelBeforeEndpointFailure: Bool,
        workspaceLaunchThrows: Bool = false,
        endpointSucceeds: Bool = false,
        processDiscoveryTimeout: Duration = .zero,
        terminationGracePeriod: Duration = .zero
    ) -> IsolatedDebugLauncher {
        let endpointDiscoverer: any DevToolsActivePortDiscovering = endpointSucceeds
            ? SuccessfulIsolatedEndpointDiscoverer()
            : FailingIsolatedEndpointDiscoverer(
                cancelCurrentTask: cancelBeforeEndpointFailure
            )
        let commandExecutor: any CommandExecuting = endpointSucceeds
            ? SuccessfulIsolatedCommandExecutor(
                processIdentifier: harness.processIdentifier
            )
            : UnreachableIsolatedCommandExecutor()
        return IsolatedDebugLauncher(
            storageManager: storageManager,
            workspaceLauncher: IsolatedRecoveryWorkspaceLauncher(
                harness: harness,
                shouldThrow: workspaceLaunchThrows
            ),
            processInspector: IsolatedRecoveryProcessInspector(harness: harness),
            endpointDiscoverer: endpointDiscoverer,
            listenerVerifier: DebugListenerVerifier(
                commandExecutor: commandExecutor
            ),
            applicationController: IsolatedRecoveryApplicationController(harness: harness),
            processGroupSignaler: IsolatedRecoveryGroupSignaler(harness: harness),
            exactProcessSignaler: IsolatedRecoveryExactSignaler(harness: harness),
            timing: .init(
                processDiscoveryTimeout: processDiscoveryTimeout,
                activePortTimeout: .zero,
                terminationGracePeriod: terminationGracePeriod,
                killGracePeriod: .zero,
                pollInterval: .milliseconds(1)
            )
        )
    }

}

private struct IsolatedRecoveryFixture {
    let bundle: VerifiedChatGPTBundle
}

private final class AuditedIsolatedStorageManager:
    IsolatedRuntimeStorageManaging,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let base: SecureIsolatedRuntimeStorageManager
    private var remainingRemovalFailures: Int
    private var removalWasCancelled: [Bool] = []
    private var createdStorage: IsolatedRuntimeStorage?

    init(temporaryRoot: URL, injectedRemovalFailures: Int) {
        base = SecureIsolatedRuntimeStorageManager(temporaryRoot: temporaryRoot)
        remainingRemovalFailures = injectedRemovalFailures
    }

    func createStorage() throws -> IsolatedRuntimeStorage {
        let storage = try base.createStorage()
        lock.lock()
        createdStorage = storage
        lock.unlock()
        return storage
    }

    func removeStorage(_ storage: IsolatedRuntimeStorage) throws {
        lock.lock()
        removalWasCancelled.append(Task.isCancelled)
        if remainingRemovalFailures > 0 {
            remainingRemovalFailures -= 1
            lock.unlock()
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(
                "injected storage removal failure"
            )
        }
        lock.unlock()
        try base.removeStorage(storage)
    }

    func removalCancellationStates() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return removalWasCancelled
    }

    func lastCreatedStorage() -> IsolatedRuntimeStorage? {
        lock.lock()
        defer { lock.unlock() }
        return createdStorage
    }
}

private final class IsolatedRecoveryHarness: @unchecked Sendable {
    enum SnapshotMode {
        case valid
        case wrongIdentity
        case unavailable
    }

    enum GeneratedScenario {
        case none
        case validMain
        case ambiguousMain
    }

    let processIdentifier: pid_t
    private let executableURL: URL
    private let lock = NSLock()
    private var request: WorkspaceApplicationLaunchRequest?
    private var mode: SnapshotMode
    private var isGroupAlive: Bool
    private var candidates: [RuntimeProcessCandidate] = []
    private var hasUnknownPIDAppBlocker = false
    private var prelaunchCandidates: [RuntimeProcessCandidate] = []
    private var prelaunchApplications: [RunningChatGPTApplication] = []
    private var postLaunchScenarios: [GeneratedScenario] = []
    private var postLaunchScanIndex = 0
    private var allCandidateScanCount = 0
    private var currentScenario: GeneratedScenario = .none
    private var launchProcessTerminated = false
    private var acceptsGracefulTermination = false
    private var gracefulTerminationRequestCount = 0
    private var sentGroupSignals: [Int32] = []
    private var sentExactSignals: [Int32] = []

    init(
        processIdentifier: pid_t,
        executableURL: URL,
        mode: SnapshotMode,
        groupAlive: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.executableURL = executableURL
        self.mode = mode
        isGroupAlive = groupAlive
    }

    func capture(_ request: WorkspaceApplicationLaunchRequest) {
        lock.lock()
        self.request = request
        launchProcessTerminated = false
        lock.unlock()
    }

    func snapshot(requestedPID: pid_t) throws -> RuntimeProcessSnapshot {
        lock.lock()
        let request = self.request
        let mode = self.mode
        lock.unlock()
        guard let request else {
            throw RuntimeSecurityError.processUnavailable(requestedPID)
        }
        switch mode {
        case .unavailable:
            throw RuntimeSecurityError.processUnavailable(requestedPID)
        case .valid:
            return RuntimeProcessSnapshot(
                pid: processIdentifier,
                processGroupID: processIdentifier,
                startTime: .init(seconds: 100, microseconds: 1),
                executableURL: executableURL,
                arguments: request.arguments
            )
        case .wrongIdentity:
            return RuntimeProcessSnapshot(
                pid: processIdentifier,
                processGroupID: processIdentifier + 99,
                startTime: .init(seconds: 100, microseconds: 1),
                executableURL: executableURL,
                arguments: request.arguments
            )
        }
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        lock.lock()
        let alive = isGroupAlive
        lock.unlock()
        guard alive, processGroupID == processIdentifier else { return [] }
        return [try validSnapshot()]
    }

    func allCandidates() -> [RuntimeProcessCandidate] {
        lock.lock()
        allCandidateScanCount += 1
        let candidates = self.candidates
        let request = self.request
        let hasUnknownPIDAppBlocker = self.hasUnknownPIDAppBlocker
        let prelaunchCandidates = self.prelaunchCandidates
        let launchProcessTerminated = self.launchProcessTerminated
        var scenario = currentScenario
        if request != nil, !postLaunchScenarios.isEmpty {
            let index = min(postLaunchScanIndex, postLaunchScenarios.count - 1)
            scenario = postLaunchScenarios[index]
            currentScenario = scenario
            postLaunchScanIndex += 1
        }
        lock.unlock()
        guard let request else { return prelaunchCandidates + candidates }
        guard !launchProcessTerminated else { return candidates }

        var generated: [RuntimeProcessCandidate] = []
        if hasUnknownPIDAppBlocker {
            generated.append(
                RuntimeProcessCandidate(
                    pid: processIdentifier + 500,
                    processGroupID: processIdentifier + 500,
                    startTime: .init(seconds: 100, microseconds: 1),
                    executableURL: executableURL,
                    arguments: request.arguments
                )
            )
        }
        switch scenario {
        case .none:
            break
        case .validMain:
            generated.append(
                RuntimeProcessCandidate(
                    pid: processIdentifier,
                    processGroupID: processIdentifier,
                    startTime: .init(seconds: 100, microseconds: 1),
                    executableURL: executableURL,
                    arguments: request.arguments
                )
            )
        case .ambiguousMain:
            generated.append(
                RuntimeProcessCandidate(
                    pid: processIdentifier,
                    processGroupID: processIdentifier + 99,
                    startTime: .init(seconds: 100, microseconds: 1),
                    executableURL: executableURL,
                    arguments: request.arguments
                )
            )
        }
        return candidates + generated
    }

    func runningApplications(bundleIdentifier: String) -> [RunningChatGPTApplication] {
        lock.lock()
        let request = self.request
        let prelaunchApplications = self.prelaunchApplications
        let scenario = currentScenario
        let launchProcessTerminated = self.launchProcessTerminated
        lock.unlock()
        guard request != nil else { return prelaunchApplications }
        guard !launchProcessTerminated else { return [] }
        switch scenario {
        case .none:
            return []
        case .validMain, .ambiguousMain:
            return [
                RunningChatGPTApplication(
                    pid: processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    executableURL: executableURL
                ),
            ]
        }
    }

    func setMode(_ mode: SnapshotMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    func setCandidates(_ candidates: [RuntimeProcessCandidate]) {
        lock.lock()
        self.candidates = candidates
        lock.unlock()
    }

    func setUnknownPIDAppBlocker(_ enabled: Bool) {
        lock.lock()
        hasUnknownPIDAppBlocker = enabled
        lock.unlock()
    }

    func setPostLaunchScenarios(_ scenarios: [GeneratedScenario]) {
        lock.lock()
        postLaunchScenarios = scenarios
        postLaunchScanIndex = 0
        currentScenario = .none
        lock.unlock()
    }

    func setPrelaunchState(
        candidates: [RuntimeProcessCandidate],
        applications: [RunningChatGPTApplication]
    ) {
        lock.lock()
        prelaunchCandidates = candidates
        prelaunchApplications = applications
        lock.unlock()
    }

    func candidateScanCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return allCandidateScanCount
    }

    func setAcceptsGracefulTermination(_ accepted: Bool) {
        lock.lock()
        acceptsGracefulTermination = accepted
        lock.unlock()
    }

    func requestGracefulTermination() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        gracefulTerminationRequestCount += 1
        return acceptsGracefulTermination
    }

    func gracefulRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return gracefulTerminationRequestCount
    }

    func sendGroup(signal: Int32, processGroupID: pid_t) throws {
        guard processGroupID == processIdentifier else {
            throw RuntimeSecurityError.unsafeProcessGroup("unexpected test PGID")
        }
        lock.lock()
        sentGroupSignals.append(signal)
        if signal == SIGTERM || signal == SIGKILL {
            isGroupAlive = false
            launchProcessTerminated = true
        }
        lock.unlock()
    }

    func sendExact(signal: Int32) {
        lock.lock()
        sentExactSignals.append(signal)
        lock.unlock()
    }

    func groupSignals() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return sentGroupSignals
    }

    private func validSnapshot() throws -> RuntimeProcessSnapshot {
        lock.lock()
        let request = self.request
        lock.unlock()
        guard let request else {
            throw RuntimeSecurityError.processUnavailable(processIdentifier)
        }
        return RuntimeProcessSnapshot(
            pid: processIdentifier,
            processGroupID: processIdentifier,
            startTime: .init(seconds: 100, microseconds: 1),
            executableURL: executableURL,
            arguments: request.arguments
        )
    }
}

private struct IsolatedRecoveryWorkspaceLauncher: WorkspaceApplicationLaunching {
    let harness: IsolatedRecoveryHarness
    let shouldThrow: Bool

    @MainActor
    func launch(_ request: WorkspaceApplicationLaunchRequest) async throws -> pid_t {
        harness.capture(request)
        if shouldThrow {
            throw RuntimeSecurityError.workspaceLaunchFailed(
                "injected workspace launch failure"
            )
        }
        return harness.processIdentifier
    }
}

private struct IsolatedRecoveryProcessInspector: RuntimeProcessInspecting {
    let harness: IsolatedRecoveryHarness

    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot {
        try harness.snapshot(requestedPID: pid)
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        try harness.groupMembers(processGroupID: processGroupID)
    }

    func allUserProcesses() throws -> [RuntimeProcessCandidate] {
        harness.allCandidates()
    }
}

private struct FailingIsolatedEndpointDiscoverer: DevToolsActivePortDiscovering {
    let cancelCurrentTask: Bool

    func waitForEndpoint(
        in userDataDirectory: URL,
        timeout: Duration
    ) async throws -> DevToolsActivePort {
        if cancelCurrentTask {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        throw RuntimeSecurityError.activePortFileUnavailable(
            "injected endpoint failure: \(userDataDirectory.path)"
        )
    }
}

private struct SuccessfulIsolatedEndpointDiscoverer: DevToolsActivePortDiscovering {
    func waitForEndpoint(
        in userDataDirectory: URL,
        timeout: Duration
    ) async throws -> DevToolsActivePort {
        DevToolsActivePort(
            port: 9_222,
            browserWebSocketPath: "/devtools/browser/isolated-recovery-test"
        )
    }
}

private struct UnreachableIsolatedCommandExecutor: CommandExecuting {
    func run(executableURL: URL, arguments: [String]) throws -> CommandExecutionResult {
        throw RuntimeSecurityError.listenerVerificationFailed(
            "listener verifier must not run in recovery tests"
        )
    }
}

private struct SuccessfulIsolatedCommandExecutor: CommandExecuting {
    let processIdentifier: pid_t

    func run(executableURL: URL, arguments: [String]) throws -> CommandExecutionResult {
        CommandExecutionResult(
            terminationStatus: 0,
            standardOutput: Data(
                "p\(processIdentifier)\nn127.0.0.1:9222\nTST=LISTEN\n".utf8
            ),
            standardError: Data()
        )
    }
}

private struct IsolatedRecoveryApplicationController:
    RunningChatGPTApplicationControlling
{
    let harness: IsolatedRecoveryHarness

    @MainActor
    func runningApplications(bundleIdentifier: String) -> [RunningChatGPTApplication] {
        harness.runningApplications(bundleIdentifier: bundleIdentifier)
    }

    @MainActor
    func requestTermination(of application: RunningChatGPTApplication) -> Bool {
        harness.requestGracefulTermination()
    }
}

private struct IsolatedRecoveryGroupSignaler: ProcessGroupSignaling {
    let harness: IsolatedRecoveryHarness

    func send(signal: Int32, toProcessGroup processGroupID: pid_t) throws {
        try harness.sendGroup(signal: signal, processGroupID: processGroupID)
    }
}

private struct IsolatedRecoveryExactSignaler: ExactProcessSignaling {
    let harness: IsolatedRecoveryHarness

    func send(signal: Int32, toProcessID processID: pid_t) throws {
        harness.sendExact(signal: signal)
    }
}
