import Foundation

enum ThemeSwitchError: LocalizedError, Sendable, Equatable {
    case previousThemeRestored(
        snapshot: SkinInjectionSnapshot,
        failedThemeID: String,
        cause: String
    )
    case recoveryRequired(
        previousThemeID: String,
        failedThemeID: String,
        cause: String,
        restorationFailure: String
    )

    var errorDescription: String? {
        switch self {
        case let .previousThemeRestored(_, failedThemeID, cause):
            "主题 \(failedThemeID) 切换失败，原主题已在同一 ChatGPT 会话中恢复：\(cause)"
        case let .recoveryRequired(_, failedThemeID, cause, restorationFailure):
            "主题 \(failedThemeID) 切换失败，原主题也无法恢复。切换错误：\(cause)；恢复错误：\(restorationFailure)"
        }
    }
}
