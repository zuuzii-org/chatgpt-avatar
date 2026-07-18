import Darwin
import Foundation

struct CommandExecutionResult: Sendable, Equatable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol CommandExecuting: Sendable {
    func run(executableURL: URL, arguments: [String]) throws -> CommandExecutionResult
}

struct FoundationCommandExecutor: CommandExecuting {
    func run(executableURL: URL, arguments: [String]) throws -> CommandExecutionResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw RuntimeSecurityError.listenerVerificationFailed(
                "无法执行 \(executableURL.path)：\(error.localizedDescription)"
            )
        }

        // lsof output for a single port is bounded and small. Reading before
        // waitUntilExit also prevents either pipe from retaining unread EOF data.
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandExecutionResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outputData,
            standardError: errorData
        )
    }
}

struct DebugListenerVerifier: Sendable {
    private struct ListenerRecord: Equatable {
        let pid: pid_t
        var names: [String]
        var states: [String]
    }

    private let commandExecutor: any CommandExecuting
    private let lsofURL: URL

    init(
        commandExecutor: any CommandExecuting = FoundationCommandExecutor(),
        lsofURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof", isDirectory: false)
    ) {
        self.commandExecutor = commandExecutor
        self.lsofURL = lsofURL
    }

    func verify(
        port: UInt16,
        belongsTo expectedPID: pid_t,
        processInspector: (any RuntimeProcessInspecting)? = nil
    ) throws -> VerifiedDebugListener {
        guard expectedPID > 0, port >= 1024 else {
            throw RuntimeSecurityError.listenerVerificationFailed("PID 或端口无效")
        }
        let result = try commandExecutor.run(
            executableURL: lsofURL,
            arguments: [
                "-nP",
                "-iTCP:\(port)",
                "-sTCP:LISTEN",
                "-FpnT",
            ]
        )
        guard result.terminationStatus == 0 else {
            let detail = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RuntimeSecurityError.listenerVerificationFailed(
                detail.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "lsof 未找到目标 listener"
            )
        }

        let records = try Self.parse(result.standardOutput)
        guard !records.isEmpty else {
            throw RuntimeSecurityError.listenerVerificationFailed("lsof 输出中没有 listener")
        }
        let uniquePIDs = Set(records.map(\.pid))
        if uniquePIDs != [expectedPID] {
            try validateInheritedSocketHolders(
                uniquePIDs,
                expectedPID: expectedPID,
                processInspector: processInspector
            )
        }

        let expectedName = "127.0.0.1:\(port)"
        let names = records.flatMap(\.names)
        let states = records.flatMap(\.states)
        guard !names.isEmpty, names.allSatisfy({ $0 == expectedName }) else {
            throw RuntimeSecurityError.listenerVerificationFailed(
                "listener 必须只绑定 \(expectedName)，实际 \(names)"
            )
        }
        guard states.count == names.count,
              !states.isEmpty,
              states.allSatisfy({ $0 == "ST=LISTEN" })
        else {
            throw RuntimeSecurityError.listenerVerificationFailed(
                "listener TCP 状态无效：\(states)"
            )
        }
        return VerifiedDebugListener(pid: expectedPID, address: "127.0.0.1", port: port)
    }

    /// Electron/Chromium spawns child services (for example the Computer Use
    /// service) after the DevTools listen socket exists. Those children inherit
    /// the socket FD across posix_spawn, so lsof reports every FD holder for
    /// the same listener. Sharing a listen socket requires FD inheritance, so a
    /// legitimate extra holder is always a same-process-group descendant of the
    /// debug instance leader. Anything else means an unrelated process holds
    /// the port and verification must fail closed.
    private func validateInheritedSocketHolders(
        _ holderPIDs: Set<pid_t>,
        expectedPID: pid_t,
        processInspector: (any RuntimeProcessInspecting)?
    ) throws {
        guard holderPIDs.contains(expectedPID) else {
            throw RuntimeSecurityError.listenerVerificationFailed(
                "端口 owner 不唯一或不属于 PID \(expectedPID)：\(holderPIDs.sorted())"
            )
        }
        guard let processInspector else {
            throw RuntimeSecurityError.listenerVerificationFailed(
                "端口被多个进程持有但无法复核进程身份：\(holderPIDs.sorted())"
            )
        }
        let expected = try processInspector.snapshot(pid: expectedPID)
        guard expected.pid == expectedPID,
              expected.processGroupID > 1,
              expected.processGroupID != getpgrp()
        else {
            throw RuntimeSecurityError.listenerVerificationFailed(
                "端口 owner PID \(expectedPID) 的进程组身份不安全"
            )
        }
        for holderPID in holderPIDs where holderPID != expectedPID {
            let holder = try processInspector.snapshot(pid: holderPID)
            guard holder.pid == holderPID,
                  holder.pid > 1,
                  holder.pid != getpid(),
                  holder.processGroupID == expected.processGroupID,
                  holder.startTime >= expected.startTime
            else {
                throw RuntimeSecurityError.listenerVerificationFailed(
                    "端口 owner PID \(holderPID) 不是 PID \(expectedPID) 的同进程组后代"
                )
            }
        }
    }

    private static func parse(_ data: Data) throws -> [ListenerRecord] {
        guard !data.isEmpty, data.count <= 64 * 1024,
              let output = String(data: data, encoding: .utf8)
        else {
            throw RuntimeSecurityError.listenerVerificationFailed("lsof 输出为空、过大或不是 UTF-8")
        }

        var records: [ListenerRecord] = []
        var current: ListenerRecord?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                if let current { records.append(current) }
                guard !value.isEmpty,
                      value.allSatisfy(\.isNumber),
                      let pid = pid_t(value),
                      pid > 0
                else {
                    throw RuntimeSecurityError.listenerVerificationFailed("lsof PID 字段无效")
                }
                current = ListenerRecord(pid: pid, names: [], states: [])
            case "n":
                guard var record = current else {
                    throw RuntimeSecurityError.listenerVerificationFailed("lsof name 缺少 PID 记录")
                }
                record.names.append(value)
                current = record
            case "T":
                guard var record = current else {
                    throw RuntimeSecurityError.listenerVerificationFailed("lsof state 缺少 PID 记录")
                }
                if value.hasPrefix("ST=") {
                    record.states.append(value)
                }
                current = record
            default:
                continue
            }
        }
        if let current { records.append(current) }
        return records
    }
}

struct ProductionDebugSessionValidator: ProductionDebugSessionValidating, Sendable {
    private let processInspector: any RuntimeProcessInspecting
    private let listenerVerifier: DebugListenerVerifier

    init(
        processInspector: any RuntimeProcessInspecting = DarwinRuntimeProcessInspector(),
        listenerVerifier: DebugListenerVerifier = DebugListenerVerifier()
    ) {
        self.processInspector = processInspector
        self.listenerVerifier = listenerVerifier
    }

    func validate(_ session: ProductionDebugSession) async throws {
        let expected = session.process
        let initialProcess = try processInspector.snapshot(pid: expected.pid)
        try Self.validateProcessIdentity(initialProcess, expected: expected)

        try validateUserDataDirectoryIdentity(session)

        guard session.listener.pid == expected.pid,
              session.listener.address == "127.0.0.1",
              session.listener.port == session.endpoint.port
        else {
            throw RuntimeSecurityError.listenerVerificationFailed(
                "受管 session 保存的 listener 身份无效"
            )
        }
        let actualListener = try listenerVerifier.verify(
            port: session.endpoint.port,
            belongsTo: expected.pid,
            processInspector: processInspector
        )
        guard actualListener == session.listener else {
            throw RuntimeSecurityError.listenerVerificationFailed(
                "受管 session 的 loopback listener 身份已变化"
            )
        }

        // lsof is a separate system snapshot. Re-sample both immutable process
        // identity and profile identity so a PID/profile replacement during
        // listener verification cannot pass as the captured managed session.
        let finalProcess = try processInspector.snapshot(pid: expected.pid)
        try Self.validateProcessIdentity(finalProcess, expected: expected)
        try validateUserDataDirectoryIdentity(session)
    }

    private static func validateProcessIdentity(
        _ actual: RuntimeProcessSnapshot,
        expected: RuntimeProcessSnapshot
    ) throws {
        guard actual.pid == expected.pid,
              actual.processGroupID == expected.processGroupID,
              actual.startTime == expected.startTime
        else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "PID \(expected.pid) 的 PID/PGID/startTime 身份已变化"
            )
        }
        guard Self.canonicalExecutable(actual.executableURL)
                == Self.canonicalExecutable(expected.executableURL)
        else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "PID \(expected.pid) 的 executable 已变化"
            )
        }
        guard actual.arguments == expected.arguments else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "PID \(expected.pid) 的 immutable arguments 已变化"
            )
        }
    }

    private func validateUserDataDirectoryIdentity(
        _ session: ProductionDebugSession
    ) throws {
        var info = stat()
        guard lstat(session.userDataDirectory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(
                session.userDataDirectory.path
            )
        }
        let actualIdentity = FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            owner: info.st_uid
        )
        guard actualIdentity == session.userDataIdentity else {
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(
                session.userDataDirectory.path
            )
        }
    }

    private static func canonicalExecutable(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
