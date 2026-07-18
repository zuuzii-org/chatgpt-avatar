import XCTest

@testable import ChatGPTSkinStudio

final class AppModelTests: XCTestCase {
    func testActivationGateCommitsOnlyMatchingInFlightTheme() {
        XCTAssertTrue(
            AppModelActivationGate.canCommitActive(
                currentState: .injecting(themeID: "original-night-city"),
                themeID: "original-night-city",
                coordinatorIsActive: true
            )
        )
        XCTAssertFalse(
            AppModelActivationGate.canCommitActive(
                currentState: .injecting(themeID: "another-theme"),
                themeID: "original-night-city",
                coordinatorIsActive: true
            )
        )
        XCTAssertFalse(
            AppModelActivationGate.canCommitActive(
                currentState: .injecting(themeID: "original-night-city"),
                themeID: "original-night-city",
                coordinatorIsActive: false
            )
        )
    }

    func testActivationGatePreservesRuntimeInvalidationTerminalStates() {
        let terminalStates: [SkinSessionState] = [
            .cleaningUp,
            .degraded(message: "renderer unavailable"),
            .incompatible(message: "adapter mismatch"),
            .recoveryRequired(message: "rollback failed"),
        ]

        for state in terminalStates {
            XCTAssertFalse(
                AppModelActivationGate.canCommitActive(
                    currentState: state,
                    themeID: "original-night-city",
                    coordinatorIsActive: true
                ),
                "运行期终态不得被迟到的 active 提交覆盖：\(state)"
            )
        }
    }

    func testThemeSwitchActivationGateRequiresMatchingBusyStateAndActiveCoordinator() {
        XCTAssertTrue(
            AppModelActivationGate.canCommitSwitch(
                currentState: .switchingTheme(themeID: "theme-b"),
                themeID: "theme-b",
                coordinatorIsActive: true
            )
        )
        XCTAssertFalse(
            AppModelActivationGate.canCommitSwitch(
                currentState: .switchingTheme(themeID: "theme-a"),
                themeID: "theme-b",
                coordinatorIsActive: true
            )
        )
        XCTAssertFalse(
            AppModelActivationGate.canCommitSwitch(
                currentState: .active(themeID: "theme-b", appBuild: "1"),
                themeID: "theme-b",
                coordinatorIsActive: true
            )
        )
        XCTAssertFalse(
            AppModelActivationGate.canCommitSwitch(
                currentState: .switchingTheme(themeID: "theme-b"),
                themeID: "theme-b",
                coordinatorIsActive: false
            )
        )
        XCTAssertTrue(
            AppModelActivationGate.canCommitSwitchRecovery(
                currentState: .switchingTheme(themeID: "theme-b"),
                themeID: "theme-b"
            )
        )
        XCTAssertFalse(
            AppModelActivationGate.canCommitSwitchRecovery(
                currentState: .switchingTheme(themeID: "theme-a"),
                themeID: "theme-b"
            )
        )
    }

    func testThemeSwitchActivationGatePreservesRuntimeTerminalStates() {
        let terminalStates: [SkinSessionState] = [
            .cleaningUp,
            .degraded(message: "renderer unavailable"),
            .incompatible(message: "adapter mismatch"),
            .recoveryRequired(message: "rollback failed"),
        ]

        for state in terminalStates {
            XCTAssertFalse(
                AppModelActivationGate.canCommitSwitch(
                    currentState: state,
                    themeID: "theme-b",
                    coordinatorIsActive: true
                ),
                "运行期终态不得被主题恢复的迟到 active 写回覆盖：\(state)"
            )
            XCTAssertFalse(
                AppModelActivationGate.canCommitSwitchRecovery(
                    currentState: state,
                    themeID: "theme-b"
                )
            )
        }
    }
}
