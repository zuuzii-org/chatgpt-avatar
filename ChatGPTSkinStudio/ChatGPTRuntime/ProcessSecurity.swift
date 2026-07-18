import Darwin
import Foundation

protocol RuntimeProcessInspecting: Sendable {
    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot
    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot]
    /// Returns stable identity candidates for every current real/effective-user process.
    func allUserProcesses() throws -> [RuntimeProcessCandidate]
}

protocol ProcessGroupSignaling: Sendable {
    func send(signal: Int32, toProcessGroup processGroupID: pid_t) throws
}

protocol ExactProcessSignaling: Sendable {
    func send(signal: Int32, toProcessID processID: pid_t) throws
}

struct DarwinRuntimeProcessInspector: RuntimeProcessInspecting {
    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot {
        guard pid > 0 else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }

        let info = try bsdInfo(pid: pid)
        guard info.pbi_uid == getuid(), info.pbi_ruid == getuid() else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "PID \(pid) 不属于当前用户"
            )
        }
        let executableURL = try executableURL(pid: pid)
        let arguments = try processArguments(pid: pid)
        let finalInfo = try bsdInfo(pid: pid)
        guard info.pbi_pgid == finalInfo.pbi_pgid,
              info.pbi_start_tvsec == finalInfo.pbi_start_tvsec,
              info.pbi_start_tvusec == finalInfo.pbi_start_tvusec,
              info.pbi_uid == finalInfo.pbi_uid,
              info.pbi_ruid == finalInfo.pbi_ruid
        else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "PID \(pid) 在采样期间发生身份变化"
            )
        }
        return RuntimeProcessSnapshot(
            pid: pid,
            processGroupID: pid_t(info.pbi_pgid),
            startTime: ProcessStartTime(
                seconds: info.pbi_start_tvsec,
                microseconds: info.pbi_start_tvusec
            ),
            executableURL: executableURL,
            arguments: arguments
        )
    }

    private func bsdInfo(pid: pid_t) throws -> proc_bsdinfo {
        var info = proc_bsdinfo()
        let copied = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard copied == MemoryLayout<proc_bsdinfo>.size else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }
        return info
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        guard processGroupID > 1 else {
            throw RuntimeSecurityError.unsafeProcessGroup("PGID 必须大于 1")
        }

        var members: [RuntimeProcessSnapshot] = []
        for pid in try allProcessIDs() {
            guard getpgid(pid) == processGroupID else { continue }
            do {
                let process = try snapshot(pid: pid)
                if process.processGroupID == processGroupID {
                    members.append(process)
                }
            } catch RuntimeSecurityError.processUnavailable {
                // A process may disappear between enumeration and inspection.
                continue
            }
        }
        return members.sorted { $0.pid < $1.pid }
    }

    func allUserProcesses() throws -> [RuntimeProcessCandidate] {
        var processes: [RuntimeProcessCandidate] = []
        for pid in try allProcessIDs() {
            let initialInfo: proc_bsdinfo
            do {
                initialInfo = try bsdInfo(pid: pid)
            } catch RuntimeSecurityError.processUnavailable {
                continue
            }
            guard initialInfo.pbi_uid == getuid(), initialInfo.pbi_ruid == getuid() else {
                continue
            }
            if let process = try enumerationCandidate(
                pid: pid,
                initialInfo: initialInfo
            ) {
                processes.append(process)
            }
        }
        return processes.sorted { $0.pid < $1.pid }
    }

    private func enumerationCandidate(
        pid: pid_t,
        initialInfo: proc_bsdinfo
    ) throws -> RuntimeProcessCandidate? {
        // proc_pidpath is required to decide whether this process belongs to a
        // protected storage root. argv may be unavailable for unrelated user
        // processes, so preserve that fact and let the scoped caller decide.
        let argumentSnapshot = try? processArgumentSnapshot(pid: pid)
        // proc_pidpath can fail for a still-running executable that was replaced
        // by an App update. KERN_PROCARGS2 also carries the kernel-recorded exec
        // path; it is sufficient for broad storage routing, while every signal
        // still requires a fresh strict snapshot through proc_pidpath.
        let executable = (try? executableURL(pid: pid)) ?? argumentSnapshot?.executableURL
        let arguments = argumentSnapshot?.arguments
        let finalInfo: proc_bsdinfo
        do {
            finalInfo = try bsdInfo(pid: pid)
        } catch RuntimeSecurityError.processUnavailable {
            return nil
        }
        guard initialInfo.pbi_pgid == finalInfo.pbi_pgid,
              initialInfo.pbi_start_tvsec == finalInfo.pbi_start_tvsec,
              initialInfo.pbi_start_tvusec == finalInfo.pbi_start_tvusec,
              initialInfo.pbi_uid == finalInfo.pbi_uid,
              initialInfo.pbi_ruid == finalInfo.pbi_ruid
        else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "PID \(pid) 在全用户枚举期间发生身份变化"
            )
        }
        guard let executable else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "无法读取稳定存活 PID \(pid) 的 executable"
            )
        }
        return RuntimeProcessCandidate(
            pid: pid,
            processGroupID: pid_t(initialInfo.pbi_pgid),
            startTime: ProcessStartTime(
                seconds: initialInfo.pbi_start_tvsec,
                microseconds: initialInfo.pbi_start_tvusec
            ),
            executableURL: executable,
            arguments: arguments
        )
    }

    private func allProcessIDs() throws -> [pid_t] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount >= 0 else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "proc_listallpids 失败：\(Self.posixMessage())"
            )
        }

        // Process creation can race the size query. Reserve extra space and retry
        // once if the returned buffer was completely filled.
        var capacity = max(Int(estimatedCount) + 64, 128)
        for _ in 0 ..< 2 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = pids.count * MemoryLayout<pid_t>.stride
            let result = pids.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(byteCount))
            }
            guard result >= 0 else {
                throw RuntimeSecurityError.processIdentityMismatch(
                    "proc_listallpids 失败：\(Self.posixMessage())"
                )
            }
            if Int(result) >= capacity {
                capacity *= 2
                continue
            }
            return pids.prefix(Int(result)).filter { $0 > 0 }
        }

        throw RuntimeSecurityError.processIdentityMismatch("进程列表持续增长，无法获得稳定快照")
    }

    private func executableURL(pid: pid_t) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let copied = proc_pidpath(pid, &path, UInt32(path.count))
        guard copied > 0 else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }
        let pathBytes = path.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:))
        return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self), isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private struct ProcessArgumentSnapshot {
        let executableURL: URL
        let arguments: [String]
    }

    private func processArguments(pid: pid_t) throws -> [String] {
        try processArgumentSnapshot(pid: pid).arguments
    }

    private func processArgumentSnapshot(pid: pid_t) throws -> ProcessArgumentSnapshot {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var byteCount = 0
        guard sysctl(&query, u_int(query.count), nil, &byteCount, nil, 0) == 0,
              byteCount >= MemoryLayout<Int32>.size
        else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }

        var bytes = [UInt8](repeating: 0, count: byteCount)
        let readResult = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&query, u_int(query.count), buffer.baseAddress, &byteCount, nil, 0)
        }
        guard readResult == 0, byteCount >= MemoryLayout<Int32>.size else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }
        bytes.removeSubrange(byteCount ..< bytes.count)

        let argumentCount: Int32 = bytes.withUnsafeBytes { buffer in
            buffer.loadUnaligned(as: Int32.self)
        }
        guard argumentCount > 0, argumentCount <= 16_384 else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "PID \(pid) 的 argc 无效：\(argumentCount)"
            )
        }

        var cursor = MemoryLayout<Int32>.size
        guard cursor < bytes.count,
              let executableTerminator = bytes[cursor...].firstIndex(of: 0),
              executableTerminator > cursor,
              let executablePath = String(
                  bytes: bytes[cursor ..< executableTerminator],
                  encoding: .utf8
              ),
              executablePath.hasPrefix("/")
        else {
            throw RuntimeSecurityError.processIdentityMismatch("PID \(pid) 的 executable argv 损坏")
        }
        let argumentExecutableURL = URL(fileURLWithPath: executablePath, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        cursor = executableTerminator + 1
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0 ..< Int(argumentCount) {
            guard cursor < bytes.count,
                  let terminator = bytes[cursor...].firstIndex(of: 0),
                  terminator > cursor,
                  let argument = String(bytes: bytes[cursor ..< terminator], encoding: .utf8)
            else {
                throw RuntimeSecurityError.processIdentityMismatch("PID \(pid) 的 argv 损坏")
            }
            arguments.append(argument)
            cursor = terminator + 1
        }
        return ProcessArgumentSnapshot(
            executableURL: argumentExecutableURL,
            arguments: arguments
        )
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}

struct DarwinProcessGroupSignaler: ProcessGroupSignaling {
    func send(signal: Int32, toProcessGroup processGroupID: pid_t) throws {
        guard processGroupID > 1, processGroupID != getpgrp() else {
            throw RuntimeSecurityError.unsafeProcessGroup(
                "拒绝向 PGID \(processGroupID) 发送信号"
            )
        }
        guard kill(-processGroupID, signal) == 0 || errno == ESRCH else {
            throw RuntimeSecurityError.processSignalFailed(
                "kill(-\(processGroupID), \(signal))：\(String(cString: strerror(errno)))"
            )
        }
    }
}

struct DarwinExactProcessSignaler: ExactProcessSignaling {
    func send(signal: Int32, toProcessID processID: pid_t) throws {
        guard processID > 1, processID != getpid() else {
            throw RuntimeSecurityError.processIdentityMismatch(
                "拒绝向 PID \(processID) 发送信号"
            )
        }
        guard kill(processID, signal) == 0 || errno == ESRCH else {
            throw RuntimeSecurityError.processSignalFailed(
                "kill(\(processID), \(signal))：\(String(cString: strerror(errno)))"
            )
        }
    }
}
