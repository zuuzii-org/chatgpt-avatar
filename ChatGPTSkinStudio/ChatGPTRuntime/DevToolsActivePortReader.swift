import Darwin
import Foundation

protocol DevToolsActivePortDiscovering: Sendable {
    func waitForEndpoint(
        in userDataDirectory: URL,
        timeout: Duration
    ) async throws -> DevToolsActivePort
}

struct DevToolsActivePortFileFingerprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let contents: Data
}

protocol FreshDevToolsActivePortDiscovering: Sendable {
    func captureBaseline(in userDataDirectory: URL) throws
        -> DevToolsActivePortFileFingerprint?
    func waitForFreshEndpoint(
        in userDataDirectory: URL,
        differentFrom baseline: DevToolsActivePortFileFingerprint?,
        timeout: Duration
    ) async throws -> DevToolsActivePort
}

struct StrictDevToolsActivePortDiscoverer:
    DevToolsActivePortDiscovering,
    FreshDevToolsActivePortDiscovering
{
    private static let maximumFileBytes = 512

    private struct SecureFileRead {
        let data: Data
        let fingerprint: DevToolsActivePortFileFingerprint
    }

    func waitForEndpoint(
        in userDataDirectory: URL,
        timeout: Duration = .seconds(10)
    ) async throws -> DevToolsActivePort {
        let activePortURL = userDataDirectory.appendingPathComponent(
            "DevToolsActivePort",
            isDirectory: false
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastInvalidError: Error?

        while clock.now < deadline {
            do {
                let file = try readSecureFile(at: activePortURL)
                return try Self.parse(file.data)
            } catch let error as RuntimeSecurityError {
                switch error {
                case .activePortFileUnavailable:
                    break
                default:
                    lastInvalidError = error
                }
            } catch {
                lastInvalidError = error
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        if let lastInvalidError { throw lastInvalidError }
        throw RuntimeSecurityError.activePortFileUnavailable(activePortURL.path)
    }

    func captureBaseline(
        in userDataDirectory: URL
    ) throws -> DevToolsActivePortFileFingerprint? {
        let activePortURL = userDataDirectory.appendingPathComponent(
            "DevToolsActivePort",
            isDirectory: false
        )
        do {
            return try readSecureFile(at: activePortURL).fingerprint
        } catch RuntimeSecurityError.activePortFileUnavailable {
            return nil
        }
    }

    func waitForFreshEndpoint(
        in userDataDirectory: URL,
        differentFrom baseline: DevToolsActivePortFileFingerprint?,
        timeout: Duration = .seconds(10)
    ) async throws -> DevToolsActivePort {
        let activePortURL = userDataDirectory.appendingPathComponent(
            "DevToolsActivePort",
            isDirectory: false
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?

        while clock.now < deadline {
            do {
                let file = try readSecureFile(at: activePortURL)
                guard Self.isFresh(file.fingerprint, comparedWith: baseline) else {
                    lastError = RuntimeSecurityError.activePortFileNotFresh(
                        activePortURL.path
                    )
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
                return try Self.parse(file.data)
            } catch let error as RuntimeSecurityError {
                lastError = error
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        if let lastError { throw lastError }
        throw RuntimeSecurityError.activePortFileNotFresh(activePortURL.path)
    }

    static func isFresh(
        _ current: DevToolsActivePortFileFingerprint,
        comparedWith baseline: DevToolsActivePortFileFingerprint?
    ) -> Bool {
        guard let baseline else { return true }
        guard current.device == baseline.device,
              current.contents != baseline.contents
        else {
            return false
        }

        let modificationAdvanced: Bool
        if current.modificationSeconds != baseline.modificationSeconds {
            modificationAdvanced = current.modificationSeconds
                > baseline.modificationSeconds
        } else {
            modificationAdvanced = current.modificationNanoseconds
                > baseline.modificationNanoseconds
        }
        guard modificationAdvanced else { return false }

        // Chromium may rewrite the same inode or atomically replace the file.
        // Both are accepted only after a strict mtime and content advance; a
        // device change is always rejected as a profile-path identity change.
        if current.inode == baseline.inode {
            return true
        }
        return current.inode != 0 && baseline.inode != 0
    }

    static func parse(_ data: Data) throws -> DevToolsActivePort {
        guard !data.isEmpty, data.count <= maximumFileBytes else {
            throw RuntimeSecurityError.invalidActivePortFile("文件大小越界")
        }
        guard data.allSatisfy({ $0 == 0x0A || (0x20 ... 0x7E).contains($0) }) else {
            throw RuntimeSecurityError.invalidActivePortFile("只能包含可打印 ASCII 和 LF")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeSecurityError.invalidActivePortFile("不是 UTF-8")
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 2 else {
            throw RuntimeSecurityError.invalidActivePortFile("必须恰好包含两行")
        }

        let portText = lines[0]
        guard !portText.isEmpty,
              portText.allSatisfy(\.isNumber),
              portText.first != "0",
              let portValue = UInt16(portText),
              portValue >= 1024
        else {
            throw RuntimeSecurityError.invalidActivePortFile("端口必须是 1024...65535 的十进制整数")
        }

        let prefix = "/devtools/browser/"
        let path = lines[1]
        guard path.hasPrefix(prefix),
              path.count == prefix.count + 36,
              !path.contains(".."),
              !path.contains("\\")
        else {
            throw RuntimeSecurityError.invalidActivePortFile("browser WebSocket path 格式错误")
        }
        let identifier = String(path.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: identifier),
              uuid.uuidString.caseInsensitiveCompare(identifier) == .orderedSame
        else {
            throw RuntimeSecurityError.invalidActivePortFile("browser WebSocket 标识不是规范 UUID")
        }

        return DevToolsActivePort(port: portValue, browserWebSocketPath: path)
    }

    private func readSecureFile(at url: URL) throws -> SecureFileRead {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw RuntimeSecurityError.activePortFileUnavailable(url.path)
            }
            throw RuntimeSecurityError.invalidActivePortFile("open 失败：\(posixMessage())")
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw RuntimeSecurityError.invalidActivePortFile("fstat 失败：\(posixMessage())")
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              info.st_size > 0,
              info.st_size <= Self.maximumFileBytes
        else {
            throw RuntimeSecurityError.invalidActivePortFile("文件身份、owner、link 或大小无效")
        }

        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return read(descriptor, baseAddress.advanced(by: offset), remaining)
            }
            guard count > 0 else {
                throw RuntimeSecurityError.invalidActivePortFile(
                    count == 0 ? "文件被截断" : "read 失败：\(posixMessage())"
                )
            }
            offset += count
        }

        var extraByte: UInt8 = 0
        guard read(descriptor, &extraByte, 1) == 0 else {
            throw RuntimeSecurityError.invalidActivePortFile("文件读取期间发生增长")
        }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_dev == info.st_dev,
              finalInfo.st_ino == info.st_ino,
              finalInfo.st_size == info.st_size,
              finalInfo.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              finalInfo.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec
        else {
            throw RuntimeSecurityError.invalidActivePortFile("文件读取期间身份或内容发生变化")
        }
        let data = Data(bytes)
        return SecureFileRead(
            data: data,
            fingerprint: DevToolsActivePortFileFingerprint(
                device: UInt64(finalInfo.st_dev),
                inode: UInt64(finalInfo.st_ino),
                size: Int64(finalInfo.st_size),
                modificationSeconds: Int64(finalInfo.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(finalInfo.st_mtimespec.tv_nsec),
                contents: data
            )
        )
    }
}

private func posixMessage() -> String {
    String(cString: strerror(errno))
}
