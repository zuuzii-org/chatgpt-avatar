import AppKit
import Combine
import Foundation

struct StudioDiagnostic: Identifiable, Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case info
        case warning
        case error
    }

    let id = UUID()
    let level: Level
    let message: String
}

enum AppModelActivationGate {
    static func canCommitActive(
        currentState: SkinSessionState,
        themeID: String,
        coordinatorIsActive: Bool
    ) -> Bool {
        guard coordinatorIsActive,
              case .injecting(let injectingThemeID) = currentState
        else {
            return false
        }
        return injectingThemeID == themeID
    }

    static func canCommitSwitch(
        currentState: SkinSessionState,
        themeID: String,
        coordinatorIsActive: Bool
    ) -> Bool {
        coordinatorIsActive && isMatchingSwitch(
            currentState: currentState,
            themeID: themeID
        )
    }

    static func isMatchingSwitch(
        currentState: SkinSessionState,
        themeID: String
    ) -> Bool {
        guard case .switchingTheme(let switchingThemeID) = currentState else {
            return false
        }
        return switchingThemeID == themeID
    }

    static func canCommitSwitchRecovery(
        currentState: SkinSessionState,
        themeID: String
    ) -> Bool {
        isMatchingSwitch(currentState: currentState, themeID: themeID)
    }
}

enum ThemeImportUIPhase: Equatable, Sendable {
    case idle
    case preparing(fileName: String)
    case editing
    case committing
    case succeeded(themeID: String)
    case failed(message: String)

    var isBusy: Bool {
        switch self {
        case .preparing, .committing:
            true
        default:
            false
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum RestartAction: Sendable, Equatable {
        case apply
        case restore
    }

    @Published private(set) var themes: [LoadedTheme] = []
    @Published var selectedThemeID: String?
    @Published private(set) var state: SkinSessionState = .idle
    @Published private(set) var verifiedBundle: VerifiedChatGPTBundle?
    @Published private(set) var diagnostics: [StudioDiagnostic] = []
    @Published var errorMessage: String?
    @Published var isShowingRestartConsent = false
    @Published private(set) var pendingRestartAction: RestartAction?
    @Published var isShowingThemeImagePicker = false
    @Published private(set) var isShowingThemeImport = false
    @Published private(set) var themeImportPhase: ThemeImportUIPhase = .idle
    @Published private(set) var themeImportDraft: ThemeImportDraft?
    @Published var themeImportDisplayName = ""
    @Published var themeImportFocalX = 0.5
    @Published var themeImportFocalY = 0.5

    private let bundleVerifier = ChatGPTBundleVerifier()
    private let coordinator = SkinSessionCoordinator()
    private var themeRepository: ThemeRepository?
    private var themeImportService: ThemeImportService?
    private var themeImportTask: Task<Void, Never>?
    private var themeImportOperationID = UUID()
    private var hasStarted = false
    private var stateBeforeRestartConsent: SkinSessionState = .idle

    var selectedTheme: LoadedTheme? {
        themes.first { $0.manifest.id == selectedThemeID }
    }

    var activeTheme: LoadedTheme? {
        guard let activeThemeID else { return nil }
        return themes.first { $0.manifest.id == activeThemeID }
    }

    var canApply: Bool {
        guard let selectedThemeID,
              verifiedBundle != nil,
              !state.isBusy,
              !isShowingRestartConsent
        else {
            return false
        }
        if let activeThemeID {
            return activeThemeID != selectedThemeID
        }
        return !isActive
    }

    var canCommitThemeImport: Bool {
        guard themeImportDraft != nil else { return false }
        switch themeImportPhase {
        case .editing, .failed:
            break
        default:
            return false
        }
        return !themeImportDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isActive: Bool {
        switch state {
        case .active, .recoveryRequired:
            true
        default:
            false
        }
    }

    var activeThemeID: String? {
        guard case .active(let themeID, _) = state else { return nil }
        return themeID
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        state = .preflighting
        diagnostics.removeAll()
        do {
            let repository = try ThemeRepository.live()
            themeRepository = repository
            themes = try repository.loadAllThemes()
            selectedThemeID = selectedThemeID ?? themes.first?.manifest.id
            diagnostics.append(.init(level: .info, message: "已验证 \(themes.count) 个本地纯数据主题包。"))

            let verified = try bundleVerifier.verify(
                appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
            )
            verifiedBundle = verified
            diagnostics.append(.init(level: .info, message: "ChatGPT \(verified.shortVersion) / build \(verified.buildVersion)"))
            diagnostics.append(.init(level: .info, message: "Bundle ID 与 OpenAI Team ID 验证通过。"))
            diagnostics.append(.init(level: .warning, message: "版本仅用于诊断；应用时由运行时结构探测决定兼容性。"))
            state = .idle
        } catch {
            state = .degraded(message: error.localizedDescription)
            errorMessage = error.localizedDescription
            diagnostics.append(.init(level: .error, message: "身份预检失败：\(error.localizedDescription)"))
        }
    }

    func prepareThemeImport(from sourceURL: URL) {
        themeImportTask?.cancel()
        let operationID = UUID()
        themeImportOperationID = operationID
        themeImportDraft = nil
        themeImportDisplayName = ""
        themeImportFocalX = 0.5
        themeImportFocalY = 0.5
        themeImportPhase = .preparing(fileName: sourceURL.lastPathComponent)
        isShowingThemeImport = true

        themeImportTask = Task { [weak self] in
            guard let self else { return }
            let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let service = try resolveThemeImportService()
                let draft = try await service.prepare(sourceURL: sourceURL)
                try Task.checkCancellation()
                guard themeImportOperationID == operationID else { return }
                themeImportTask = nil
                themeImportDraft = draft
                themeImportDisplayName = draft.suggestedName
                themeImportPhase = .editing
            } catch is CancellationError {
                guard themeImportOperationID == operationID else { return }
                themeImportTask = nil
                dismissThemeImport()
            } catch {
                guard themeImportOperationID == operationID else { return }
                themeImportTask = nil
                themeImportPhase = .failed(message: error.localizedDescription)
            }
        }
    }

    func commitThemeImport() async {
        guard canCommitThemeImport, let draft = themeImportDraft else { return }
        let operationID = UUID()
        themeImportOperationID = operationID
        themeImportPhase = .committing

        do {
            let service = try resolveThemeImportService()
            let result = try await service.commit(
                draft: draft,
                displayName: themeImportDisplayName,
                focalPoint: ThemeNormalizedPoint(
                    x: themeImportFocalX,
                    y: themeImportFocalY
                )
            )
            guard themeImportOperationID == operationID else { return }

            do {
                try reloadThemes(selecting: result.theme.manifest.id)
            } catch {
                // The committed package has already passed final validation. Keep it
                // visible even if an unrelated catalog entry prevents a full reload.
                themes.removeAll { $0.manifest.id == result.theme.manifest.id }
                themes.append(result.theme)
                themes.sort { $0.manifest.id < $1.manifest.id }
                selectedThemeID = result.theme.manifest.id
                diagnostics.append(
                    .init(
                        level: .warning,
                        message: "主题已导入，但目录刷新遇到其他无效主题：\(error.localizedDescription)"
                    )
                )
            }

            themeImportPhase = .succeeded(themeID: result.theme.manifest.id)
            diagnostics.append(
                .init(
                    level: .info,
                    message: "已安全导入图片主题：\(result.theme.manifest.name)。导入过程未重启 ChatGPT。"
                )
            )
        } catch {
            guard themeImportOperationID == operationID else { return }
            themeImportPhase = .failed(message: error.localizedDescription)
        }
    }

    func dismissThemeImport() {
        guard themeImportPhase != .committing else { return }
        themeImportTask?.cancel()
        themeImportTask = nil
        themeImportOperationID = UUID()
        isShowingThemeImport = false
        themeImportPhase = .idle
        themeImportDraft = nil
        themeImportDisplayName = ""
        themeImportFocalX = 0.5
        themeImportFocalY = 0.5
    }

    func chooseAnotherThemeImage() {
        guard !themeImportPhase.isBusy else { return }
        isShowingThemeImagePicker = true
    }

    func reportThemeImagePickerFailure(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else {
            return
        }
        errorMessage = "无法选择图片：\(error.localizedDescription)"
    }

    private func resolveThemeImportService() throws -> ThemeImportService {
        if let themeImportService { return themeImportService }
        let service = try ThemeImportService.live()
        themeImportService = service
        return service
    }

    private func reloadThemes(selecting themeID: String) throws {
        let repository: ThemeRepository
        if let themeRepository {
            repository = themeRepository
        } else {
            let resolved = try ThemeRepository.live()
            themeRepository = resolved
            repository = resolved
        }
        themes = try repository.loadAllThemes()
        selectedThemeID = themes.contains { $0.manifest.id == themeID } ? themeID : themes.first?.manifest.id
    }

    func requestApply() {
        guard canApply else { return }
        DiagnosticsLogger.shared.log(
            "ui-request-apply",
            "theme=\(selectedTheme?.manifest.id ?? "none") hasActive=\(activeThemeID != nil)"
        )
        if activeThemeID != nil {
            Task { await switchToSelectedTheme() }
            return
        }
        stateBeforeRestartConsent = state
        pendingRestartAction = .apply
        state = .awaitingRestartConsent
        isShowingRestartConsent = true
    }

    func requestRestore() {
        guard isActive, !state.isBusy else { return }
        stateBeforeRestartConsent = state
        pendingRestartAction = .restore
        state = .awaitingRestartConsent
        isShowingRestartConsent = true
    }

    func cancelRestart() {
        isShowingRestartConsent = false
        pendingRestartAction = nil
        state = stateBeforeRestartConsent
    }

    func confirmRestart() async {
        guard let action = pendingRestartAction,
              let consent = ExplicitRestartConsent(userConfirmed: true)
        else { return }
        isShowingRestartConsent = false
        pendingRestartAction = nil

        switch action {
        case .apply:
            await apply(consent: consent)
        case .restore:
            await restore(consent: consent)
        }
    }

    private func apply(consent: ExplicitRestartConsent) async {
        guard let theme = selectedTheme, let bundle = verifiedBundle else { return }

        do {
            state = .launchingDebugSession
            let snapshot = try await coordinator.apply(
                theme: theme,
                verifiedBundle: bundle,
                consent: consent,
                progress: { [weak self] update in
                    await self?.handleCoordinatorProgress(update)
                }
            )
            let coordinatorIsActive = await coordinator.isActive(
                generation: snapshot.generation
            )
            guard AppModelActivationGate.canCommitActive(
                currentState: state,
                themeID: theme.manifest.id,
                coordinatorIsActive: coordinatorIsActive
            ) else {
                return
            }
            errorMessage = nil
            state = .active(themeID: theme.manifest.id, appBuild: snapshot.appBuild)
            let verificationSummary = snapshot.effectiveMode == .full
                ? "结构探测、主题图片解码与可见性验证通过"
                : "结构探测与样式可见性验证通过；Hero 将在进入 Home / Full 时解码"
            diagnostics.append(
                .init(
                    level: .info,
                    message: "\(verificationSummary)，皮肤已应用：\(theme.manifest.name)"
                )
            )
        } catch let error as SkinError {
            switch error {
            case let .incompatibleApp(message):
                state = .incompatible(message: message)
                errorMessage = "当前 ChatGPT 结构不兼容：\(message)"
                diagnostics.append(.init(level: .error, message: "结构探测不兼容，未保留任何增强：\(message)"))
            default:
                state = .degraded(message: error.localizedDescription)
                errorMessage = error.localizedDescription
                diagnostics.append(.init(level: .error, message: "应用失败并已回退：\(error.localizedDescription)"))
            }
        } catch let error as RuntimeSecurityError {
            errorMessage = error.localizedDescription
            if case .automaticRollbackFailed = error {
                state = .recoveryRequired(message: error.localizedDescription)
                diagnostics.append(
                    .init(level: .error, message: "自动恢复失败，需要手动重试：\(error.localizedDescription)")
                )
            } else {
                state = .degraded(message: error.localizedDescription)
                diagnostics.append(
                    .init(level: .error, message: "应用失败并已回退：\(error.localizedDescription)")
                )
            }
        } catch {
            state = .degraded(message: error.localizedDescription)
            errorMessage = error.localizedDescription
            diagnostics.append(
                .init(level: .error, message: "应用失败并已回退：\(error.localizedDescription)")
            )
        }
    }

    private func switchToSelectedTheme() async {
        guard let theme = selectedTheme,
              let bundle = verifiedBundle,
              case .active(let previousThemeID, _) = state,
              previousThemeID != theme.manifest.id
        else {
            return
        }

        state = .switchingTheme(themeID: theme.manifest.id)
        do {
            let snapshot = try await coordinator.switchTheme(
                to: theme,
                verifiedBundle: bundle
            )
            let coordinatorIsActive = await coordinator.isActive(
                generation: snapshot.generation
            )
            guard AppModelActivationGate.canCommitSwitch(
                currentState: state,
                themeID: theme.manifest.id,
                coordinatorIsActive: coordinatorIsActive
            ) else {
                return
            }
            errorMessage = nil
            state = .active(themeID: theme.manifest.id, appBuild: snapshot.appBuild)
            diagnostics.append(
                .init(
                    level: .info,
                    message: "已在同一 ChatGPT 进程中切换主题：\(theme.manifest.name)；未重启 ChatGPT。"
                )
            )
        } catch let error as ThemeSwitchError {
            switch error {
            case .previousThemeRestored(let restoredSnapshot, _, _):
                guard restoredSnapshot.themeID == previousThemeID else {
                    return
                }
                let coordinatorIsActive = await coordinator.isActive(
                    generation: restoredSnapshot.generation
                )
                guard AppModelActivationGate.canCommitSwitch(
                    currentState: state,
                    themeID: theme.manifest.id,
                    coordinatorIsActive: coordinatorIsActive
                ) else {
                    return
                }
                state = .active(
                    themeID: restoredSnapshot.themeID,
                    appBuild: restoredSnapshot.appBuild
                )
                errorMessage = error.localizedDescription
                diagnostics.append(
                    .init(
                        level: .warning,
                        message: "主题切换失败，原主题已在同一进程中恢复：\(error.localizedDescription)"
                    )
                )
            case .recoveryRequired:
                guard AppModelActivationGate.canCommitSwitchRecovery(
                    currentState: state,
                    themeID: theme.manifest.id
                ) else {
                    return
                }
                state = .recoveryRequired(message: error.localizedDescription)
                errorMessage = error.localizedDescription
                diagnostics.append(
                    .init(
                        level: .error,
                        message: "主题切换与原主题恢复均失败，需要恢复 ChatGPT：\(error.localizedDescription)"
                    )
                )
            }
        } catch let error as RuntimeSecurityError {
            guard AppModelActivationGate.canCommitSwitchRecovery(
                currentState: state,
                themeID: theme.manifest.id
            ) else {
                return
            }
            state = .recoveryRequired(message: error.localizedDescription)
            errorMessage = error.localizedDescription
            diagnostics.append(
                .init(
                    level: .error,
                    message: "受管 ChatGPT session 身份复验失败，需要恢复：\(error.localizedDescription)"
                )
            )
        } catch {
            // Non-security preflight checks run before the active generation is
            // replaced. Those failures may preserve the
            // previous theme only while its captured generation remains active.
            guard let preservedSnapshot = await coordinator.snapshot(),
                  preservedSnapshot.themeID == previousThemeID
            else {
                return
            }
            let coordinatorIsActive = await coordinator.isActive(
                generation: preservedSnapshot.generation
            )
            guard AppModelActivationGate.canCommitSwitch(
                currentState: state,
                themeID: theme.manifest.id,
                coordinatorIsActive: coordinatorIsActive
            ) else {
                return
            }
            state = .active(
                themeID: previousThemeID,
                appBuild: preservedSnapshot.appBuild
            )
            errorMessage = error.localizedDescription
            diagnostics.append(
                .init(
                    level: .warning,
                    message: "主题未切换，原主题保持启用：\(error.localizedDescription)"
                )
            )
        }
    }

    private func restore(consent: ExplicitRestartConsent) async {
        guard let bundle = verifiedBundle else { return }
        do {
            state = .cleaningUp
            try await coordinator.restore(
                verifiedBundle: bundle,
                consent: consent
            )
            state = .idle
            diagnostics.append(.init(level: .info, message: "增强节点、样式与调试 listener 已清理，ChatGPT 已恢复正常启动。"))
        } catch {
            state = .recoveryRequired(message: error.localizedDescription)
            errorMessage = error.localizedDescription
            diagnostics.append(
                .init(level: .error, message: "恢复失败，可再次重试：\(error.localizedDescription)")
            )
        }
    }

    private func handleCoordinatorProgress(_ update: SkinSessionState) {
        switch update {
        case .cleaningUp, .incompatible, .degraded, .recoveryRequired:
            isShowingRestartConsent = false
            pendingRestartAction = nil
        default:
            break
        }
        state = update
        switch update {
        case .incompatible(let message):
            errorMessage = "当前 ChatGPT 结构不兼容：\(message)"
            diagnostics.append(
                .init(level: .error, message: "运行期结构失配：\(message)")
            )
        case .degraded(let message):
            errorMessage = message
            diagnostics.append(
                .init(level: .warning, message: "运行期已安全降级：\(message)")
            )
        case .recoveryRequired(let message):
            errorMessage = message
            diagnostics.append(
                .init(level: .error, message: "自动恢复未完成：\(message)")
            )
        default:
            break
        }
    }

    func revealThemeDirectory() {
        guard let theme = selectedTheme else { return }
        NSWorkspace.shared.activateFileViewerSelecting([theme.directoryURL])
    }
}
