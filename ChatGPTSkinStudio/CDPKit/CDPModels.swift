import Foundation

struct CDPTarget: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let type: String
    let title: String
    let url: String
    let webSocketDebuggerUrl: String?
}

struct CDPCommand: Codable, Sendable {
    let id: Int
    let method: String
    let params: [String: JSONValue]
}

struct CDPErrorPayload: Codable, Sendable, Equatable {
    let code: Int
    let message: String
    let data: JSONValue?
}

struct CDPEnvelope: Codable, Sendable, Equatable {
    let id: Int?
    let result: [String: JSONValue]?
    let error: CDPErrorPayload?
    let method: String?
    let params: [String: JSONValue]?
}

enum CDPClientError: LocalizedError, Sendable, Equatable {
    case invalidPort(Int)
    case invalidEndpoint(String)
    case redirectRejected
    case unexpectedStatus(Int)
    case responseTooLarge(Int)
    case malformedResponse(String)
    case noRenderer
    case ambiguousRenderer(Int)
    case socketClosed
    case commandFailed(code: Int, message: String)
    case timeout(method: String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "非法 CDP 端口：\(port)"
        case .invalidEndpoint(let endpoint): "非法 CDP endpoint：\(endpoint)"
        case .redirectRejected: "CDP discovery 不允许重定向。"
        case .unexpectedStatus(let status): "CDP discovery 返回 HTTP \(status)。"
        case .responseTooLarge(let bytes): "CDP discovery 响应过大：\(bytes) bytes。"
        case .malformedResponse(let message): "CDP discovery 响应无效：\(message)"
        case .noRenderer: "没有找到可用的 ChatGPT renderer。"
        case .ambiguousRenderer(let count): "找到 \(count) 个候选 renderer，已安全停止。"
        case .socketClosed: "CDP WebSocket 已关闭。"
        case .commandFailed(let code, let message): "CDP 命令失败（\(code)）：\(message)"
        case .timeout(let method): "CDP 命令超时：\(method)"
        }
    }
}
