import Foundation

enum SkinError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case incompatibleApp(String)
    case permissionRequired(String)
    case discoveryFailed(String)
    case connectionFailed(String)
    case protocolFailure(String)
    case injectionFailed(String)
    case cleanupFailed(String)
    case timedOut(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .incompatibleApp(let message): message
        case .permissionRequired(let message): message
        case .discoveryFailed(let message): message
        case .connectionFailed(let message): message
        case .protocolFailure(let message): message
        case .injectionFailed(let message): message
        case .cleanupFailed(let message): message
        case .timedOut(let message): message
        case .cancelled: "操作已取消。"
        }
    }
}
