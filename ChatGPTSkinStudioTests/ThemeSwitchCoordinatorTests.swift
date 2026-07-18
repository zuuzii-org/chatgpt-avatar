import Foundation
import XCTest

@testable import ChatGPTSkinStudio

final class ThemeSwitchCoordinatorTests: XCTestCase {
    func testCancelledApplyBeforeRestartHasNoProcessSideEffects() async throws {
        let fixture = try makeFixture(failingInstallAttempts: [])
        let applyTask = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await fixture.coordinator.apply(
                theme: fixture.themeA,
                verifiedBundle: fixture.bundle,
                consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
                progress: { state in await fixture.states.append(state) }
            )
        }

        do {
            _ = try await applyTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Cancellation is rejected before restartForDebugging.
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let validationCount = await fixture.validator.validationCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let managedPID = await fixture.coordinator.managedProcessIdentifier()

        XCTAssertTrue(installedThemeIDs.isEmpty)
        XCTAssertEqual(validationCount, 0)
        XCTAssertEqual(restartCount, 0)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertNil(managedPID)
    }

    func testCancellationAfterApplyInstallValidatesThenRollsBack() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            cancellingSuccessfulInstallAttempts: [1]
        )

        do {
            _ = try await fixture.coordinator.apply(
                theme: fixture.themeA,
                verifiedBundle: fixture.bundle,
                consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
                progress: { state in await fixture.states.append(state) }
            )
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // The returned install is validated, cleaned and rolled back.
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let installWasCancelled = await fixture.injector.wasCancelled(attempt: 1)
        let restoreAttempts = await fixture.injector.restoreAttemptCount()
        let validationCount = await fixture.validator.validationCount()
        let preValidationWasCancelled = await fixture.validator.wasCancelled(validation: 1)
        let postValidationWasCancelled = await fixture.validator.wasCancelled(validation: 2)
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let rollbackWasCancelled = await fixture.restarter.rollbackWasCancelled(attempt: 1)
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let managedPID = await fixture.coordinator.managedProcessIdentifier()
        let injectorSnapshot = await fixture.injector.snapshot()
        let becameActive = await fixture.coordinator.isActive(
            generation: "switch-generation-1"
        )

        XCTAssertEqual(installedThemeIDs, [fixture.themeA.manifest.id])
        XCTAssertEqual(installWasCancelled, true)
        XCTAssertEqual(restoreAttempts, 1)
        XCTAssertEqual(validationCount, 2)
        XCTAssertEqual(preValidationWasCancelled, false)
        XCTAssertEqual(postValidationWasCancelled, false)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(rollbackWasCancelled, false)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertNil(managedPID)
        XCTAssertNil(injectorSnapshot)
        XCTAssertFalse(becameActive)
    }

    func testSwitchesThemeInSameManagedProcessWithoutRestart() async throws {
        let fixture = try makeFixture(failingInstallAttempts: [])
        let initial = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )
        let processBeforeSwitch = await fixture.coordinator.managedProcessIdentifier()

        let switched = try await fixture.coordinator.switchTheme(
            to: fixture.themeB,
            verifiedBundle: fixture.bundle
        )
        let processAfterSwitch = await fixture.coordinator.managedProcessIdentifier()
        let switchedIsActive = await fixture.coordinator.isActive(
            generation: switched.generation
        )
        let initialIsActive = await fixture.coordinator.isActive(
            generation: initial.generation
        )
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let validationCount = await fixture.validator.validationCount()
        let recordedStates = await fixture.states.values()

        XCTAssertEqual(processBeforeSwitch, fixture.debugSession.process.pid)
        XCTAssertEqual(processAfterSwitch, fixture.debugSession.process.pid)
        XCTAssertEqual(switched.themeID, fixture.themeB.manifest.id)
        XCTAssertNotEqual(switched.generation, initial.generation)
        XCTAssertTrue(switchedIsActive)
        XCTAssertFalse(initialIsActive)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertEqual(validationCount, 4)
        XCTAssertEqual(
            installedThemeIDs,
            [fixture.themeA.manifest.id, fixture.themeB.manifest.id]
        )
        XCTAssertTrue(
            recordedStates.contains(
                .switchingTheme(themeID: fixture.themeB.manifest.id)
            )
        )

        var initialMonitorTerminated = false
        for _ in 0 ..< 100 {
            if await fixture.injector.streamTerminated(
                generation: initial.generation
            ) {
                initialMonitorTerminated = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(initialMonitorTerminated)

        await fixture.injector.emit(
            SkinRuntimeInvalidation(
                generation: initial.generation,
                kind: .incompatible,
                message: "stale generation"
            )
        )
        let rollbackCountAfterStaleSignal = await fixture.restarter.rollbackCount()
        let activeAfterStaleSignal = await fixture.coordinator.isActive(
            generation: switched.generation
        )
        XCTAssertEqual(rollbackCountAfterStaleSignal, 0)
        XCTAssertTrue(activeAfterStaleSignal)
    }

    func testCancelledSwitchPreflightPreservesActiveGenerationWithoutMutation() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            cancellingValidations: [3]
        )
        let initial = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        let switchTask = Task {
            try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
        }
        do {
            _ = try await switchTask.value
            XCTFail("Expected cancellation after preflight validation")
        } catch is CancellationError {
            // The cancellation gate runs before phase/monitor/renderer mutation.
        }

        let snapshot = await fixture.injector.snapshot()
        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let restoreAttempts = await fixture.injector.restoreAttemptCount()
        let validationCount = await fixture.validator.validationCount()
        let cancelledValidation = await fixture.validator.wasCancelled(
            validation: 3
        )
        let initialStillActive = await fixture.coordinator.isActive(
            generation: initial.generation
        )
        for _ in 0 ..< 20 { await Task.yield() }
        let initialMonitorTerminated = await fixture.injector.streamTerminated(
            generation: initial.generation
        )
        let recordedStates = await fixture.states.values()

        XCTAssertEqual(snapshot, initial)
        XCTAssertEqual(installedThemeIDs, [fixture.themeA.manifest.id])
        XCTAssertEqual(restoreAttempts, 0)
        XCTAssertEqual(validationCount, 3)
        XCTAssertEqual(cancelledValidation, true)
        XCTAssertTrue(initialStillActive)
        XCTAssertFalse(initialMonitorTerminated)
        XCTAssertFalse(
            recordedStates.contains(
                .switchingTheme(themeID: fixture.themeB.manifest.id)
            )
        )
    }

    func testPendingRecoveryFailureDoesNotFallThroughToNoOpRestore() async throws {
        let pendingFailure = RuntimeSecurityError.runningApplicationIdentityMismatch(
            "planned pending identity ambiguity; no signal"
        )
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            pendingRecoveryFailure: pendingFailure
        )

        do {
            try await fixture.coordinator.restore(
                verifiedBundle: fixture.bundle,
                consent: try XCTUnwrap(
                    ExplicitRestartConsent(userConfirmed: true)
                )
            )
            XCTFail("Expected pending recovery failure")
        } catch let error as RuntimeSecurityError {
            XCTAssertEqual(error, pendingFailure)
        }

        let pendingAttempts = await fixture.restarter.pendingRecoveryAttemptCount()
        let injectorRestoreAttempts = await fixture.injector.restoreAttemptCount()
        let managedPID = await fixture.coordinator.managedProcessIdentifier()
        XCTAssertEqual(pendingAttempts, 1)
        XCTAssertEqual(injectorRestoreAttempts, 0)
        XCTAssertNil(managedPID)
    }

    func testFailedSwitchRestoresPreviousThemeWithoutRestart() async throws {
        let fixture = try makeFixture(failingInstallAttempts: [2])
        _ = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        var errorSnapshot: SkinInjectionSnapshot?
        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected the planned switch failure")
        } catch let error as ThemeSwitchError {
            guard case let .previousThemeRestored(snapshot, failedThemeID, _) = error else {
                return XCTFail("Expected previousThemeRestored, got \(error)")
            }
            errorSnapshot = snapshot
            XCTAssertEqual(snapshot.themeID, fixture.themeA.manifest.id)
            XCTAssertEqual(failedThemeID, fixture.themeB.manifest.id)
        }

        let optionalRestoredSnapshot = await fixture.injector.snapshot()
        let restoredSnapshot = try XCTUnwrap(optionalRestoredSnapshot)
        let restoredIsActive = await fixture.coordinator.isActive(
            generation: restoredSnapshot.generation
        )
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let finalState = await fixture.states.values().last
        XCTAssertEqual(errorSnapshot, restoredSnapshot)
        XCTAssertEqual(restoredSnapshot.themeID, fixture.themeA.manifest.id)
        XCTAssertTrue(restoredIsActive)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertEqual(
            installedThemeIDs,
            [
                fixture.themeA.manifest.id,
                fixture.themeB.manifest.id,
                fixture.themeA.manifest.id,
            ]
        )
        XCTAssertEqual(
            finalState,
            .switchingTheme(themeID: fixture.themeB.manifest.id)
        )
    }

    func testFailedSwitchAndFailedRestorationRequiresRecoveryWithoutSilentRestart() async throws {
        let fixture = try makeFixture(failingInstallAttempts: [2, 3])
        _ = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected recoveryRequired")
        } catch let error as ThemeSwitchError {
            guard case .recoveryRequired = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
        }

        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let managedProcessIdentifier = await fixture.coordinator.managedProcessIdentifier()
        let finalState = await fixture.states.values().last
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertEqual(managedProcessIdentifier, fixture.debugSession.process.pid)
        guard case .recoveryRequired = finalState else {
            return XCTFail("Expected final recoveryRequired state")
        }
    }

    func testRejectsSwitchingToAlreadyActiveThemeWithoutReinstalling() async throws {
        let fixture = try makeFixture(failingInstallAttempts: [])
        let initial = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeA,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected the same-theme switch to be rejected")
        } catch let error as SkinError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let validationCount = await fixture.validator.validationCount()
        let initialIsActive = await fixture.coordinator.isActive(
            generation: initial.generation
        )
        XCTAssertEqual(installedThemeIDs, [fixture.themeA.manifest.id])
        XCTAssertEqual(validationCount, 2)
        XCTAssertTrue(initialIsActive)
    }

    func testProcessDriftRejectsSwitchBeforeInjection() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            validationFailures: [
                3: .processIdentityMismatch("planned process drift"),
            ]
        )
        let initial = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected process drift rejection")
        } catch RuntimeSecurityError.processIdentityMismatch {
            // Expected before any renderer mutation.
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let validationCount = await fixture.validator.validationCount()
        let initialIsActive = await fixture.coordinator.isActive(
            generation: initial.generation
        )
        let recordedStates = await fixture.states.values()
        XCTAssertEqual(installedThemeIDs, [fixture.themeA.manifest.id])
        XCTAssertEqual(validationCount, 3)
        XCTAssertTrue(initialIsActive)
        XCTAssertFalse(
            recordedStates.contains(
                .switchingTheme(themeID: fixture.themeB.manifest.id)
            )
        )
    }

    func testListenerDriftRejectsSwitchBeforeInjection() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            validationFailures: [
                3: .listenerVerificationFailed("planned listener drift"),
            ]
        )
        let initial = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected listener drift rejection")
        } catch RuntimeSecurityError.listenerVerificationFailed {
            // Expected before any renderer mutation.
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let validationCount = await fixture.validator.validationCount()
        let initialIsActive = await fixture.coordinator.isActive(
            generation: initial.generation
        )
        let recordedStates = await fixture.states.values()
        XCTAssertEqual(installedThemeIDs, [fixture.themeA.manifest.id])
        XCTAssertEqual(validationCount, 3)
        XCTAssertTrue(initialIsActive)
        XCTAssertFalse(
            recordedStates.contains(
                .switchingTheme(themeID: fixture.themeB.manifest.id)
            )
        )
    }

    func testApplyPreInstallDriftBlocksInjectorInstallAndRollsBack() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            validationFailures: [
                1: .listenerVerificationFailed("planned apply pre-install drift"),
            ]
        )

        do {
            _ = try await fixture.coordinator.apply(
                theme: fixture.themeA,
                verifiedBundle: fixture.bundle,
                consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
                progress: { state in await fixture.states.append(state) }
            )
            XCTFail("Expected pre-install drift rejection")
        } catch RuntimeSecurityError.listenerVerificationFailed {
            // No renderer install may start after the progress suspension drifted.
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let restoreAttempts = await fixture.injector.restoreAttemptCount()
        let validationCount = await fixture.validator.validationCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let managedPID = await fixture.coordinator.managedProcessIdentifier()

        XCTAssertTrue(installedThemeIDs.isEmpty)
        XCTAssertEqual(restoreAttempts, 1)
        XCTAssertEqual(validationCount, 1)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertNil(managedPID)
    }

    func testApplyPostInstallDriftRollsBackBeforeActiveWriteback() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            validationFailures: [
                2: .processIdentityMismatch("planned apply post-install drift"),
            ]
        )

        do {
            _ = try await fixture.coordinator.apply(
                theme: fixture.themeA,
                verifiedBundle: fixture.bundle,
                consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
                progress: { state in await fixture.states.append(state) }
            )
            XCTFail("Expected post-install drift rejection")
        } catch RuntimeSecurityError.processIdentityMismatch {
            // The existing apply rollback gate owns recovery.
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let restoreAttempts = await fixture.injector.restoreAttemptCount()
        let validationCount = await fixture.validator.validationCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let managedPID = await fixture.coordinator.managedProcessIdentifier()
        let injectorSnapshot = await fixture.injector.snapshot()
        let becameActive = await fixture.coordinator.isActive(
            generation: "switch-generation-1"
        )

        XCTAssertEqual(installedThemeIDs, [fixture.themeA.manifest.id])
        XCTAssertEqual(restoreAttempts, 1)
        XCTAssertEqual(validationCount, 2)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertNil(managedPID)
        XCTAssertNil(injectorSnapshot)
        XCTAssertFalse(becameActive)
    }

    func testNewThemePostInstallDriftCleansWithoutCompensationOrSilentRestart() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            validationFailures: [
                4: .listenerVerificationFailed("planned B post-install drift"),
            ]
        )
        let initial = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected recoveryRequired")
        } catch let error as ThemeSwitchError {
            guard case .recoveryRequired = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let restoreAttempts = await fixture.injector.restoreAttemptCount()
        let validationCount = await fixture.validator.validationCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let injectorSnapshot = await fixture.injector.snapshot()
        let initialIsActive = await fixture.coordinator.isActive(
            generation: initial.generation
        )
        let newThemeIsActive = await fixture.coordinator.isActive(
            generation: "switch-generation-2"
        )

        XCTAssertEqual(
            installedThemeIDs,
            [fixture.themeA.manifest.id, fixture.themeB.manifest.id]
        )
        XCTAssertEqual(restoreAttempts, 2)
        XCTAssertEqual(validationCount, 4)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertNil(injectorSnapshot)
        XCTAssertFalse(initialIsActive)
        XCTAssertFalse(newThemeIsActive)
        guard case .recoveryRequired = await fixture.states.values().last else {
            return XCTFail("Expected recoveryRequired progress")
        }
    }

    func testNewThemePostInstallDriftCleanupFailureStillBlocksCompensation() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            failingRestoreAttempts: [2],
            validationFailures: [
                4: .listenerVerificationFailed("planned B post-install drift"),
            ]
        )
        _ = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected recoveryRequired")
        } catch let error as ThemeSwitchError {
            guard case .recoveryRequired = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let restoreAttempts = await fixture.injector.restoreAttemptCount()
        let validationCount = await fixture.validator.validationCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let injectorSnapshot = await fixture.injector.snapshot()
        let newThemeIsActive = await fixture.coordinator.isActive(
            generation: "switch-generation-2"
        )

        XCTAssertEqual(
            installedThemeIDs,
            [fixture.themeA.manifest.id, fixture.themeB.manifest.id]
        )
        XCTAssertEqual(restoreAttempts, 2)
        XCTAssertEqual(validationCount, 4)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertEqual(injectorSnapshot?.themeID, fixture.themeB.manifest.id)
        XCTAssertFalse(newThemeIsActive)
        guard case .recoveryRequired = await fixture.states.values().last else {
            return XCTFail("Expected recoveryRequired progress")
        }
    }

    func testCompensationPostInstallDriftCleansWithoutActiveWritebackOrRestart() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [2],
            validationFailures: [
                5: .processIdentityMismatch("planned compensation post-install drift"),
            ]
        )
        let initial = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected recoveryRequired")
        } catch let error as ThemeSwitchError {
            guard case .recoveryRequired = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
        }

        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let restoreAttempts = await fixture.injector.restoreAttemptCount()
        let validationCount = await fixture.validator.validationCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCount = await fixture.restarter.normalRestoreCount()
        let injectorSnapshot = await fixture.injector.snapshot()
        let initialIsActive = await fixture.coordinator.isActive(
            generation: initial.generation
        )
        let compensationIsActive = await fixture.coordinator.isActive(
            generation: "switch-generation-3"
        )

        XCTAssertEqual(
            installedThemeIDs,
            [
                fixture.themeA.manifest.id,
                fixture.themeB.manifest.id,
                fixture.themeA.manifest.id,
            ]
        )
        XCTAssertEqual(restoreAttempts, 3)
        XCTAssertEqual(validationCount, 5)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCount, 0)
        XCTAssertNil(injectorSnapshot)
        XCTAssertFalse(initialIsActive)
        XCTAssertFalse(compensationIsActive)
        guard case .recoveryRequired = await fixture.states.values().last else {
            return XCTFail("Expected recoveryRequired progress")
        }
    }

    func testOldThemeCleanupFailureBlocksNewInstallAndAllowsExplicitRestore() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            failingRestoreAttempts: [1]
        )
        _ = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected recoveryRequired")
        } catch let error as ThemeSwitchError {
            guard case .recoveryRequired = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
        }

        let installedBeforeRestore = await fixture.injector.installedThemeIDs()
        let cleanupAttemptsBeforeRestore = await fixture.injector.restoreAttemptCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCountBefore = await fixture.restarter.normalRestoreCount()
        XCTAssertEqual(installedBeforeRestore, [fixture.themeA.manifest.id])
        XCTAssertEqual(cleanupAttemptsBeforeRestore, 1)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCountBefore, 0)
        guard case .recoveryRequired = await fixture.states.values().last else {
            return XCTFail("Expected recoveryRequired progress")
        }

        try await fixture.coordinator.restore(
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )
        let cleanupAttemptsAfterRestore = await fixture.injector.restoreAttemptCount()
        let normalRestoreCountAfter = await fixture.restarter.normalRestoreCount()
        let managedPID = await fixture.coordinator.managedProcessIdentifier()
        XCTAssertEqual(cleanupAttemptsAfterRestore, 2)
        XCTAssertEqual(normalRestoreCountAfter, 1)
        XCTAssertNil(managedPID)
    }

    func testNewThemeCleanupFailureBlocksAutomaticReinstallAndAllowsExplicitRestore() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            cleanupFailedInstallAttempts: [2]
        )
        _ = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected recoveryRequired")
        } catch let error as ThemeSwitchError {
            guard case .recoveryRequired = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
        }

        let installedBeforeRestore = await fixture.injector.installedThemeIDs()
        let cleanupAttemptsBeforeRestore = await fixture.injector.restoreAttemptCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCountBefore = await fixture.restarter.normalRestoreCount()
        XCTAssertEqual(
            installedBeforeRestore,
            [fixture.themeA.manifest.id, fixture.themeB.manifest.id]
        )
        XCTAssertEqual(cleanupAttemptsBeforeRestore, 1)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCountBefore, 0)
        guard case .recoveryRequired = await fixture.states.values().last else {
            return XCTFail("Expected recoveryRequired progress")
        }

        try await fixture.coordinator.restore(
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )
        let cleanupAttemptsAfterRestore = await fixture.injector.restoreAttemptCount()
        let normalRestoreCountAfter = await fixture.restarter.normalRestoreCount()
        XCTAssertEqual(cleanupAttemptsAfterRestore, 2)
        XCTAssertEqual(normalRestoreCountAfter, 1)
    }

    func testCompensationCleanupFailureBlocksThirdInstallAndAllowsExplicitRestore() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [2],
            failingRestoreAttempts: [2]
        )
        _ = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            XCTFail("Expected recoveryRequired")
        } catch let error as ThemeSwitchError {
            guard case .recoveryRequired = error else {
                return XCTFail("Expected recoveryRequired, got \(error)")
            }
        }

        let installedBeforeRestore = await fixture.injector.installedThemeIDs()
        let cleanupAttemptsBeforeRestore = await fixture.injector.restoreAttemptCount()
        let restartCount = await fixture.restarter.restartCount()
        let rollbackCount = await fixture.restarter.rollbackCount()
        let normalRestoreCountBefore = await fixture.restarter.normalRestoreCount()
        XCTAssertEqual(
            installedBeforeRestore,
            [fixture.themeA.manifest.id, fixture.themeB.manifest.id]
        )
        XCTAssertEqual(cleanupAttemptsBeforeRestore, 2)
        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(normalRestoreCountBefore, 0)

        try await fixture.coordinator.restore(
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )
        let cleanupAttemptsAfterRestore = await fixture.injector.restoreAttemptCount()
        let normalRestoreCountAfter = await fixture.restarter.normalRestoreCount()
        XCTAssertEqual(cleanupAttemptsAfterRestore, 3)
        XCTAssertEqual(normalRestoreCountAfter, 1)
    }

    func testCancellationStillRestoresPreviousThemeInIndependentTask() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [],
            cancellingInstallAttempts: [2]
        )
        _ = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        let switchTask = Task {
            try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
        }
        let result = await switchTask.result
        let restoredSnapshot: SkinInjectionSnapshot
        switch result {
        case .success:
            return XCTFail("Expected the cancelled switch to restore and report failure")
        case .failure(let error):
            guard let switchError = error as? ThemeSwitchError,
                  case let .previousThemeRestored(snapshot, failedThemeID, _) = switchError
            else {
                return XCTFail("Expected previousThemeRestored, got \(error)")
            }
            restoredSnapshot = snapshot
            XCTAssertEqual(failedThemeID, fixture.themeB.manifest.id)
        }

        let restoredIsActive = await fixture.coordinator.isActive(
            generation: restoredSnapshot.generation
        )
        let installedThemeIDs = await fixture.injector.installedThemeIDs()
        let secondInstallWasCancelled = await fixture.injector.wasCancelled(attempt: 2)
        let restorationInstallWasCancelled = await fixture.injector.wasCancelled(attempt: 3)
        let restorationPreValidationWasCancelled = await fixture.validator.wasCancelled(
            validation: 4
        )
        let restorationPostValidationWasCancelled = await fixture.validator.wasCancelled(
            validation: 5
        )
        let cleanupAttemptCount = await fixture.injector.restoreAttemptCount()
        XCTAssertEqual(restoredSnapshot.themeID, fixture.themeA.manifest.id)
        XCTAssertTrue(restoredIsActive)
        XCTAssertEqual(
            installedThemeIDs,
            [
                fixture.themeA.manifest.id,
                fixture.themeB.manifest.id,
                fixture.themeA.manifest.id,
            ]
        )
        XCTAssertEqual(secondInstallWasCancelled, true)
        XCTAssertEqual(restorationInstallWasCancelled, false)
        XCTAssertEqual(restorationPreValidationWasCancelled, false)
        XCTAssertEqual(restorationPostValidationWasCancelled, false)
        XCTAssertEqual(cleanupAttemptCount, 2)
    }

    func testRestoredGenerationInvalidationWinsRaceOverActiveWriteback() async throws {
        let fixture = try makeFixture(
            failingInstallAttempts: [2],
            invalidationsOnSuccessfulAttempts: [3: .incompatible]
        )
        _ = try await fixture.coordinator.apply(
            theme: fixture.themeA,
            verifiedBundle: fixture.bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true)),
            progress: { state in await fixture.states.append(state) }
        )

        let restoredSnapshot: SkinInjectionSnapshot
        do {
            _ = try await fixture.coordinator.switchTheme(
                to: fixture.themeB,
                verifiedBundle: fixture.bundle
            )
            return XCTFail("Expected previousThemeRestored")
        } catch let error as ThemeSwitchError {
            guard case let .previousThemeRestored(snapshot, _, _) = error else {
                return XCTFail("Expected previousThemeRestored, got \(error)")
            }
            restoredSnapshot = snapshot
        }

        for _ in 0 ..< 100 {
            if case .incompatible = await fixture.states.values().last {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        let optionalFinalState = await fixture.states.values().last
        let finalState = try XCTUnwrap(optionalFinalState)
        guard case .incompatible = finalState else {
            return XCTFail("Expected invalidation terminal state, got \(finalState)")
        }
        let rollbackCount = await fixture.restarter.rollbackCount()
        let restoredIsActive = await fixture.coordinator.isActive(
            generation: restoredSnapshot.generation
        )
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertFalse(restoredIsActive)
        XCTAssertFalse(
            AppModelActivationGate.canCommitSwitch(
                currentState: finalState,
                themeID: fixture.themeB.manifest.id,
                coordinatorIsActive: false
            )
        )
    }

    private func makeFixture(
        failingInstallAttempts: Set<Int>,
        cancellingInstallAttempts: Set<Int> = [],
        cancellingSuccessfulInstallAttempts: Set<Int> = [],
        cleanupFailedInstallAttempts: Set<Int> = [],
        failingRestoreAttempts: Set<Int> = [],
        invalidationsOnSuccessfulAttempts: [Int: SkinRuntimeInvalidationKind] = [:],
        validationFailures: [Int: RuntimeSecurityError] = [:],
        cancellingValidations: Set<Int> = [],
        pendingRecoveryFailure: RuntimeSecurityError? = nil
    ) throws -> ThemeSwitchFixture {
        let themeDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ChatGPTSkinStudio/Resources/Themes/original-night-city")
        let baseTheme = try ThemeValidator().validateAndLoad(
            themeDirectory: themeDirectory,
            source: .bundled
        )
        let themeA = renamedTheme(baseTheme, id: "switch-theme-a", name: "Theme A")
        let themeB = renamedTheme(baseTheme, id: "switch-theme-b", name: "Theme B")

        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/ChatGPT")
        let bundle = VerifiedChatGPTBundle(
            appURL: appURL,
            executableURL: executableURL,
            bundleIdentifier: "com.openai.codex",
            teamIdentifier: "2DC432GLL2",
            shortVersion: "99.0",
            buildVersion: "switch-test-build"
        )
        let process = RuntimeProcessSnapshot(
            pid: 43_210,
            processGroupID: 43_210,
            startTime: .init(seconds: 4_321, microseconds: 10),
            executableURL: executableURL,
            arguments: []
        )
        let debugSession = ProductionDebugSession(
            id: UUID(),
            bundle: bundle,
            process: process,
            userDataDirectory: URL(fileURLWithPath: "/tmp/chatgpt-theme-switch-test"),
            userDataIdentity: .init(device: 1, inode: 2, owner: 0),
            endpoint: .init(
                port: 53_811,
                browserWebSocketPath: "/devtools/browser/theme-switch-test"
            ),
            listener: .init(pid: process.pid, address: "127.0.0.1", port: 53_811)
        )
        let injector = ThemeSwitchFakeInjector(
            failingInstallAttempts: failingInstallAttempts,
            cancellingInstallAttempts: cancellingInstallAttempts,
            cancellingSuccessfulInstallAttempts: cancellingSuccessfulInstallAttempts,
            cleanupFailedInstallAttempts: cleanupFailedInstallAttempts,
            failingRestoreAttempts: failingRestoreAttempts,
            invalidationsOnSuccessfulAttempts: invalidationsOnSuccessfulAttempts
        )
        let restarter = ThemeSwitchFakeRestarter(
            debugSession: debugSession,
            pendingRecoveryFailure: pendingRecoveryFailure
        )
        let validator = ThemeSwitchFakeSessionValidator(
            failures: validationFailures,
            cancellingValidations: cancellingValidations
        )
        let states = ThemeSwitchStateRecorder()
        return ThemeSwitchFixture(
            bundle: bundle,
            debugSession: debugSession,
            themeA: themeA,
            themeB: themeB,
            injector: injector,
            restarter: restarter,
            validator: validator,
            states: states,
            coordinator: SkinSessionCoordinator(
                restarter: restarter,
                injector: injector,
                sessionValidator: validator
            )
        )
    }

    private func renamedTheme(
        _ theme: LoadedTheme,
        id: String,
        name: String
    ) -> LoadedTheme {
        let source = theme.manifest
        let manifest = ThemeManifestV3(
            schemaVersion: source.schemaVersion,
            id: id,
            name: name,
            nativeTheme: source.nativeTheme,
            hero: source.hero,
            sidebar: source.sidebar,
            composer: source.composer,
            compatibility: source.compatibility,
            assets: source.assets,
            features: source.features
        )
        return LoadedTheme(
            manifest: manifest,
            directoryURL: theme.directoryURL,
            source: theme.source,
            assets: theme.assets
        )
    }
}

private struct ThemeSwitchFixture {
    let bundle: VerifiedChatGPTBundle
    let debugSession: ProductionDebugSession
    let themeA: LoadedTheme
    let themeB: LoadedTheme
    let injector: ThemeSwitchFakeInjector
    let restarter: ThemeSwitchFakeRestarter
    let validator: ThemeSwitchFakeSessionValidator
    let states: ThemeSwitchStateRecorder
    let coordinator: SkinSessionCoordinator
}

private actor ThemeSwitchStateRecorder {
    private var states: [SkinSessionState] = []

    func append(_ state: SkinSessionState) {
        states.append(state)
    }

    func values() -> [SkinSessionState] {
        states
    }
}

private actor ThemeSwitchFakeInjector: SkinInjecting {
    private let failingInstallAttempts: Set<Int>
    private let cancellingInstallAttempts: Set<Int>
    private let cancellingSuccessfulInstallAttempts: Set<Int>
    private let cleanupFailedInstallAttempts: Set<Int>
    private let failingRestoreAttempts: Set<Int>
    private let invalidationsOnSuccessfulAttempts: [Int: SkinRuntimeInvalidationKind]
    private var installAttempts = 0
    private var restoreAttempts = 0
    private var installedThemes: [String] = []
    private var cancellationStates: [Int: Bool] = [:]
    private var currentSnapshot: SkinInjectionSnapshot?
    private var continuations: [String: AsyncStream<SkinRuntimeInvalidation>.Continuation] = [:]
    private var terminatedGenerations: Set<String> = []

    init(
        failingInstallAttempts: Set<Int>,
        cancellingInstallAttempts: Set<Int>,
        cancellingSuccessfulInstallAttempts: Set<Int>,
        cleanupFailedInstallAttempts: Set<Int>,
        failingRestoreAttempts: Set<Int>,
        invalidationsOnSuccessfulAttempts: [Int: SkinRuntimeInvalidationKind]
    ) {
        self.failingInstallAttempts = failingInstallAttempts
        self.cancellingInstallAttempts = cancellingInstallAttempts
        self.cancellingSuccessfulInstallAttempts = cancellingSuccessfulInstallAttempts
        self.cleanupFailedInstallAttempts = cleanupFailedInstallAttempts
        self.failingRestoreAttempts = failingRestoreAttempts
        self.invalidationsOnSuccessfulAttempts = invalidationsOnSuccessfulAttempts
    }

    func install(
        port: Int,
        theme: LoadedTheme,
        verifiedBundle: VerifiedChatGPTBundle,
        registry: StructuralAdapterRegistry
    ) throws -> SkinInjectionHandle {
        installAttempts += 1
        installedThemes.append(theme.manifest.id)
        if cancellingInstallAttempts.contains(installAttempts) {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            cancellationStates[installAttempts] = Task.isCancelled
            throw CancellationError()
        }
        if cancellingSuccessfulInstallAttempts.contains(installAttempts) {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        cancellationStates[installAttempts] = Task.isCancelled
        if cleanupFailedInstallAttempts.contains(installAttempts) {
            throw SkinError.cleanupFailed(
                "planned install cleanup failure \(installAttempts)"
            )
        }
        if failingInstallAttempts.contains(installAttempts) {
            throw SkinError.injectionFailed("planned install failure \(installAttempts)")
        }

        let generation = "switch-generation-\(installAttempts)"
        let pair = AsyncStream<SkinRuntimeInvalidation>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.recordTermination(generation: generation)
            }
        }
        continuations[generation] = pair.continuation
        let snapshot = SkinInjectionSnapshot(
            generation: generation,
            themeID: theme.manifest.id,
            appBuild: verifiedBundle.buildVersion,
            targetID: "renderer-1",
            routeID: "home",
            effectiveMode: .full
        )
        currentSnapshot = snapshot
        if let kind = invalidationsOnSuccessfulAttempts[installAttempts] {
            pair.continuation.yield(
                SkinRuntimeInvalidation(
                    generation: generation,
                    kind: kind,
                    message: "planned restored-generation invalidation"
                )
            )
        }
        return SkinInjectionHandle(snapshot: snapshot, invalidations: pair.stream)
    }

    func restore() throws {
        restoreAttempts += 1
        if failingRestoreAttempts.contains(restoreAttempts) {
            throw SkinError.cleanupFailed(
                "planned restore failure \(restoreAttempts)"
            )
        }
        if let generation = currentSnapshot?.generation {
            continuations[generation]?.finish()
        }
        currentSnapshot = nil
    }

    func snapshot() -> SkinInjectionSnapshot? {
        currentSnapshot
    }

    func installedThemeIDs() -> [String] {
        installedThemes
    }

    func restoreAttemptCount() -> Int {
        restoreAttempts
    }

    func wasCancelled(attempt: Int) -> Bool? {
        cancellationStates[attempt]
    }

    func streamTerminated(generation: String) -> Bool {
        terminatedGenerations.contains(generation)
    }

    func emit(_ invalidation: SkinRuntimeInvalidation) {
        continuations[invalidation.generation]?.yield(invalidation)
    }

    private func recordTermination(generation: String) {
        terminatedGenerations.insert(generation)
    }
}

private actor ThemeSwitchFakeSessionValidator: ProductionDebugSessionValidating {
    private let failures: [Int: RuntimeSecurityError]
    private let cancellingValidations: Set<Int>
    private var validations = 0
    private var cancellationStates: [Int: Bool] = [:]

    init(
        failures: [Int: RuntimeSecurityError],
        cancellingValidations: Set<Int>
    ) {
        self.failures = failures
        self.cancellingValidations = cancellingValidations
    }

    func validate(_ session: ProductionDebugSession) throws {
        validations += 1
        if cancellingValidations.contains(validations) {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        cancellationStates[validations] = Task.isCancelled
        if let failure = failures[validations] {
            throw failure
        }
    }

    func validationCount() -> Int {
        validations
    }

    func wasCancelled(validation: Int) -> Bool? {
        cancellationStates[validation]
    }
}

private actor ThemeSwitchFakeRestarter: ProductionChatGPTRestarting {
    private let debugSession: ProductionDebugSession
    private let pendingRecoveryFailure: RuntimeSecurityError?
    private var restarts = 0
    private var rollbacks = 0
    private var rollbackCancellationStates: [Int: Bool] = [:]
    private var normalRestores = 0
    private var pendingRecoveryAttempts = 0

    init(
        debugSession: ProductionDebugSession,
        pendingRecoveryFailure: RuntimeSecurityError?
    ) {
        self.debugSession = debugSession
        self.pendingRecoveryFailure = pendingRecoveryFailure
    }

    func restartForDebugging(
        _ request: ProductionRestartRequest
    ) -> ProductionDebugSession {
        restarts += 1
        return debugSession
    }

    func rollbackToNormal(
        _ session: ProductionDebugSession
    ) -> NormalChatGPTSession {
        rollbacks += 1
        rollbackCancellationStates[rollbacks] = Task.isCancelled
        return normalSession()
    }

    func restoreToNormal(
        _ session: ProductionDebugSession,
        consent: ExplicitRestartConsent
    ) -> NormalChatGPTSession {
        normalRestores += 1
        return normalSession()
    }

    func recoverPendingToNormal(
        verifiedBundle: VerifiedChatGPTBundle,
        consent: ExplicitRestartConsent
    ) throws -> NormalChatGPTSession? {
        guard let pendingRecoveryFailure else { return nil }
        pendingRecoveryAttempts += 1
        throw pendingRecoveryFailure
    }

    func restartCount() -> Int { restarts }
    func rollbackCount() -> Int { rollbacks }
    func rollbackWasCancelled(attempt: Int) -> Bool? {
        rollbackCancellationStates[attempt]
    }
    func normalRestoreCount() -> Int { normalRestores }
    func pendingRecoveryAttemptCount() -> Int { pendingRecoveryAttempts }

    private func normalSession() -> NormalChatGPTSession {
        NormalChatGPTSession(
            id: UUID(),
            bundle: debugSession.bundle,
            process: debugSession.process
        )
    }
}
