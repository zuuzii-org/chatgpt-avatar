import Foundation

enum SkinSessionState: Sendable, Equatable {
    case idle
    case preflighting
    case awaitingRestartConsent
    case launchingDebugSession
    case discoveringRenderer
    case injecting(themeID: String)
    case switchingTheme(themeID: String)
    case active(themeID: String, appBuild: String)
    case incompatible(message: String)
    case degraded(message: String)
    case recoveryRequired(message: String)
    case cleaningUp

    var title: String {
        switch self {
        case .idle: "待兼容性检测"
        case .preflighting: "正在检查环境"
        case .awaitingRestartConsent: "等待重启确认"
        case .launchingDebugSession: "正在启动安全会话"
        case .discoveringRenderer: "正在连接 ChatGPT"
        case .injecting: "正在应用皮肤"
        case .switchingTheme: "正在无重启切换"
        case .active: "皮肤已启用"
        case .incompatible: "当前结构不兼容"
        case .degraded: "已安全降级"
        case .recoveryRequired: "需要恢复 ChatGPT"
        case .cleaningUp: "正在恢复原生界面"
        }
    }

    var isBusy: Bool {
        switch self {
        case .preflighting, .launchingDebugSession, .discoveringRenderer, .injecting,
             .switchingTheme, .cleaningUp:
            true
        default:
            false
        }
    }
}
