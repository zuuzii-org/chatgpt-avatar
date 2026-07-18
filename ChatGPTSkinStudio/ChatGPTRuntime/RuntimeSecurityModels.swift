import Darwin
import Foundation

enum RuntimeSecurityError: Error, LocalizedError, Sendable, Equatable {
    case appPathNotAllowed(String)
    case appPathIsSymbolicLink(String)
    case bundleMetadataUnavailable(String)
    case bundleIdentifierMismatch(expected: String, actual: String?)
    case teamIdentifierMismatch(expected: String, actual: String?)
    case codeSignatureValidationFailed(String)
    case secureDirectoryCreationFailed(String)
    case secureDirectoryIdentityChanged(String)
    case workspaceLaunchFailed(String)
    case processUnavailable(pid_t)
    case processIdentityMismatch(String)
    case activePortFileUnavailable(String)
    case invalidActivePortFile(String)
    case listenerVerificationFailed(String)
    case multipleRunningChatGPTInstances(Int)
    case runningApplicationIdentityMismatch(String)
    case gracefulTerminationRejected(pid_t)
    case gracefulTerminationTimedOut(pid_t)
    case activePortFileNotFresh(String)
    case automaticRollbackFailed(primary: String, rollback: String)
    case unrecognizedSession
    case unsafeProcessGroup(String)
    case processSignalFailed(String)
    case cleanupTimedOut
    case explicitRestartConsentRequired

    var errorDescription: String? {
        switch self {
        case let .appPathNotAllowed(path):
            "ChatGPT App 路径不在允许列表中：\(path)"
        case let .appPathIsSymbolicLink(path):
            "ChatGPT App 路径不能经过符号链接：\(path)"
        case let .bundleMetadataUnavailable(detail):
            "无法读取 ChatGPT App 元数据：\(detail)"
        case let .bundleIdentifierMismatch(expected, actual):
            "ChatGPT Bundle ID 不匹配，期望 \(expected)，实际 \(actual ?? "缺失")"
        case let .teamIdentifierMismatch(expected, actual):
            "ChatGPT Team ID 不匹配，期望 \(expected)，实际 \(actual ?? "缺失")"
        case let .codeSignatureValidationFailed(detail):
            "ChatGPT 代码签名验证失败：\(detail)"
        case let .secureDirectoryCreationFailed(detail):
            "无法创建隔离运行目录：\(detail)"
        case let .secureDirectoryIdentityChanged(path):
            "隔离运行目录身份已变化，拒绝继续：\(path)"
        case let .workspaceLaunchFailed(detail):
            "无法启动隔离 ChatGPT 实例：\(detail)"
        case let .processUnavailable(pid):
            "目标进程不存在：\(pid)"
        case let .processIdentityMismatch(detail):
            "隔离进程身份复核失败：\(detail)"
        case let .activePortFileUnavailable(path):
            "等待 DevToolsActivePort 超时：\(path)"
        case let .invalidActivePortFile(detail):
            "DevToolsActivePort 无效：\(detail)"
        case let .listenerVerificationFailed(detail):
            "CDP listener 校验失败：\(detail)"
        case let .multipleRunningChatGPTInstances(count):
            "发现 \(count) 个正在运行的 ChatGPT 主实例，已安全停止"
        case let .runningApplicationIdentityMismatch(detail):
            "正在运行的 ChatGPT 身份不匹配：\(detail)"
        case let .gracefulTerminationRejected(pid):
            "ChatGPT PID \(pid) 拒绝了优雅退出请求"
        case let .gracefulTerminationTimedOut(pid):
            "等待 ChatGPT PID \(pid) 优雅退出超时"
        case let .activePortFileNotFresh(path):
            "DevToolsActivePort 未由本次启动刷新：\(path)"
        case let .automaticRollbackFailed(primary, rollback):
            "调试重启失败（\(primary)），自动恢复原生实例也失败（\(rollback)）"
        case .unrecognizedSession:
            "隔离调试会话不是当前 launcher 创建的会话"
        case let .unsafeProcessGroup(detail):
            "拒绝向未通过身份复核的进程组发送信号：\(detail)"
        case let .processSignalFailed(detail):
            "发送进程信号失败：\(detail)"
        case .cleanupTimedOut:
            "隔离进程组未能在期限内退出"
        case .explicitRestartConsentRequired:
            "生产 ChatGPT 重启需要用户明确授权"
        }
    }
}

struct ChatGPTBundleMetadata: Sendable, Equatable {
    let bundleIdentifier: String
    let shortVersion: String
    let buildVersion: String
    let executableURL: URL
}

struct CodeSigningIdentity: Sendable, Equatable {
    let identifier: String
    let teamIdentifier: String
}

struct VerifiedChatGPTBundle: Sendable, Equatable {
    let appURL: URL
    let executableURL: URL
    let bundleIdentifier: String
    let teamIdentifier: String
    let shortVersion: String
    let buildVersion: String
}

struct ChatGPTBundleStableIdentity: Sendable, Equatable {
    let appURL: URL
    let executableURL: URL
    let bundleIdentifier: String
    let teamIdentifier: String

    init(_ bundle: VerifiedChatGPTBundle) {
        appURL = bundle.appURL.resolvingSymlinksInPath().standardizedFileURL
        executableURL = bundle.executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        bundleIdentifier = bundle.bundleIdentifier
        teamIdentifier = bundle.teamIdentifier
    }
}

extension VerifiedChatGPTBundle {
    var stableIdentity: ChatGPTBundleStableIdentity {
        ChatGPTBundleStableIdentity(self)
    }
}

struct FileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: uid_t
}

struct IsolatedRuntimeStorage: Sendable, Equatable {
    let rootURL: URL
    let userDataDirectory: URL
    let codexHomeDirectory: URL
    let rootIdentity: FileIdentity
    let userDataIdentity: FileIdentity
    let codexHomeIdentity: FileIdentity
}

struct ProcessStartTime: Sendable, Equatable, Comparable {
    let seconds: UInt64
    let microseconds: UInt64

    static func < (lhs: ProcessStartTime, rhs: ProcessStartTime) -> Bool {
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        return lhs.microseconds < rhs.microseconds
    }
}

struct RuntimeProcessSnapshot: Sendable, Equatable {
    let pid: pid_t
    let processGroupID: pid_t
    let startTime: ProcessStartTime
    let executableURL: URL
    let arguments: [String]
}

/// Stable process identity collected during a user-wide scan. Some unrelated
/// processes expose their executable identity but not KERN_PROCARGS2; callers
/// must fail closed if such a candidate falls inside a protected path.
struct RuntimeProcessCandidate: Sendable, Equatable {
    let pid: pid_t
    let processGroupID: pid_t
    let startTime: ProcessStartTime
    let executableURL: URL
    let arguments: [String]?

    init(
        pid: pid_t,
        processGroupID: pid_t,
        startTime: ProcessStartTime,
        executableURL: URL,
        arguments: [String]?
    ) {
        self.pid = pid
        self.processGroupID = processGroupID
        self.startTime = startTime
        self.executableURL = executableURL
        self.arguments = arguments
    }

    init(_ process: RuntimeProcessSnapshot) {
        pid = process.pid
        processGroupID = process.processGroupID
        startTime = process.startTime
        executableURL = process.executableURL
        arguments = process.arguments
    }

    func exactSnapshot() -> RuntimeProcessSnapshot? {
        guard let arguments else { return nil }
        return RuntimeProcessSnapshot(
            pid: pid,
            processGroupID: processGroupID,
            startTime: startTime,
            executableURL: executableURL,
            arguments: arguments
        )
    }
}

struct DevToolsActivePort: Sendable, Equatable {
    let port: UInt16
    let browserWebSocketPath: String
}

struct VerifiedDebugListener: Sendable, Equatable {
    let pid: pid_t
    let address: String
    let port: UInt16
}

struct IsolatedDebugSession: Sendable, Equatable, Identifiable {
    let id: UUID
    let bundle: VerifiedChatGPTBundle
    let process: RuntimeProcessSnapshot
    let storage: IsolatedRuntimeStorage
    let endpoint: DevToolsActivePort
    let listener: VerifiedDebugListener
}

struct ProductionDebugSession: Sendable, Equatable, Identifiable {
    let id: UUID
    let bundle: VerifiedChatGPTBundle
    let process: RuntimeProcessSnapshot
    let userDataDirectory: URL
    let userDataIdentity: FileIdentity
    let endpoint: DevToolsActivePort
    let listener: VerifiedDebugListener
}

protocol ProductionDebugSessionValidating: Sendable {
    func validate(_ session: ProductionDebugSession) async throws
}

struct NormalChatGPTSession: Sendable, Equatable, Identifiable {
    let id: UUID
    let bundle: VerifiedChatGPTBundle
    let process: RuntimeProcessSnapshot
}

/// A restart request can only be constructed after an explicit, affirmative UI action.
/// There is deliberately no production restart implementation in the runtime layer yet.
struct ExplicitRestartConsent: Sendable, Equatable {
    let id: UUID
    let grantedAt: Date
    let disclosureRevision: Int

    init?(
        userConfirmed: Bool,
        grantedAt: Date = Date(),
        disclosureRevision: Int = 1,
        id: UUID = UUID()
    ) {
        guard userConfirmed, disclosureRevision > 0 else { return nil }
        self.id = id
        self.grantedAt = grantedAt
        self.disclosureRevision = disclosureRevision
    }
}

struct ProductionRestartRequest: Sendable, Equatable {
    let bundle: VerifiedChatGPTBundle
    let consent: ExplicitRestartConsent

    fileprivate init(bundle: VerifiedChatGPTBundle, consent: ExplicitRestartConsent) {
        self.bundle = bundle
        self.consent = consent
    }
}

protocol ProductionChatGPTRestarting: Sendable {
    func restartForDebugging(_ request: ProductionRestartRequest) async throws
        -> ProductionDebugSession
    func rollbackToNormal(_ session: ProductionDebugSession) async throws
        -> NormalChatGPTSession
    func restoreToNormal(
        _ session: ProductionDebugSession,
        consent: ExplicitRestartConsent
    ) async throws -> NormalChatGPTSession
    func recoverPendingToNormal(
        verifiedBundle: VerifiedChatGPTBundle,
        consent: ExplicitRestartConsent
    ) async throws -> NormalChatGPTSession?
}

extension ProductionChatGPTRestarting {
    /// Restarters without an out-of-session recovery transaction have no
    /// pending work. Production overrides this to make a failed launch
    /// recoverable even when no `ProductionDebugSession` was created.
    func recoverPendingToNormal(
        verifiedBundle: VerifiedChatGPTBundle,
        consent: ExplicitRestartConsent
    ) async throws -> NormalChatGPTSession? {
        nil
    }
}

/// Pure authorization gate. It never terminates or launches a process; the UI
/// must first provide a consent value created by an affirmative user action.
struct ProductionRestartGate: Sendable {
    func makeRequest(
        bundle: VerifiedChatGPTBundle,
        consent: ExplicitRestartConsent?
    ) throws -> ProductionRestartRequest {
        guard let consent else {
            throw RuntimeSecurityError.explicitRestartConsentRequired
        }
        return ProductionRestartRequest(bundle: bundle, consent: consent)
    }
}
