import Darwin
import Foundation

protocol IsolatedRuntimeStorageManaging: Sendable {
    func createStorage() throws -> IsolatedRuntimeStorage
    func removeStorage(_ storage: IsolatedRuntimeStorage) throws
}

struct SecureIsolatedRuntimeStorageManager: IsolatedRuntimeStorageManaging {
    private let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot.standardizedFileURL
    }

    func createStorage() throws -> IsolatedRuntimeStorage {
        let templateURL = temporaryRoot.appendingPathComponent(
            "com.zuuzii.chatgpt-skin-studio.debug.XXXXXX",
            isDirectory: true
        )
        var template = Array(templateURL.path.utf8CString)
        let rootPath: String = try template.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress, mkdtemp(baseAddress) != nil else {
                throw RuntimeSecurityError.secureDirectoryCreationFailed(posixFailure())
            }
            return String(cString: baseAddress)
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        do {
            try enforcePrivateDirectory(rootURL)
            let userDataDirectory = rootURL.appendingPathComponent("user-data", isDirectory: true)
            let codexHomeDirectory = rootURL.appendingPathComponent("codex-home", isDirectory: true)
            try createPrivateDirectory(userDataDirectory)
            try createPrivateDirectory(codexHomeDirectory)

            return IsolatedRuntimeStorage(
                rootURL: rootURL,
                userDataDirectory: userDataDirectory,
                codexHomeDirectory: codexHomeDirectory,
                rootIdentity: try identity(ofPrivateDirectory: rootURL),
                userDataIdentity: try identity(ofPrivateDirectory: userDataDirectory),
                codexHomeIdentity: try identity(ofPrivateDirectory: codexHomeDirectory)
            )
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    func removeStorage(_ storage: IsolatedRuntimeStorage) throws {
        let root = storage.rootURL.standardizedFileURL
        guard root.deletingLastPathComponent().standardizedFileURL == temporaryRoot,
              root.lastPathComponent.hasPrefix(
                "com.zuuzii.chatgpt-skin-studio.debug."
              ),
              storage.userDataDirectory.standardizedFileURL
                == root.appendingPathComponent("user-data", isDirectory: true),
              storage.codexHomeDirectory.standardizedFileURL
                == root.appendingPathComponent("codex-home", isDirectory: true)
        else {
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(storage.rootURL.path)
        }
        try verifyIdentity(storage.rootIdentity, at: storage.rootURL)
        try verifyIdentity(storage.userDataIdentity, at: storage.userDataDirectory)
        try verifyIdentity(storage.codexHomeIdentity, at: storage.codexHomeDirectory)
        try FileManager.default.removeItem(at: storage.rootURL)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        guard mkdir(url.path, mode_t(S_IRWXU)) == 0 else {
            throw RuntimeSecurityError.secureDirectoryCreationFailed(
                "mkdir \(url.path)：\(posixFailure())"
            )
        }
        try enforcePrivateDirectory(url)
    }

    private func enforcePrivateDirectory(_ url: URL) throws {
        guard chmod(url.path, mode_t(S_IRWXU)) == 0 else {
            throw RuntimeSecurityError.secureDirectoryCreationFailed(
                "chmod 0700 \(url.path)：\(posixFailure())"
            )
        }
        _ = try identity(ofPrivateDirectory: url)
    }

    private func identity(ofPrivateDirectory url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw RuntimeSecurityError.secureDirectoryCreationFailed(
                "lstat \(url.path)：\(posixFailure())"
            )
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw RuntimeSecurityError.secureDirectoryCreationFailed("不是目录：\(url.path)")
        }
        guard info.st_uid == getuid() else {
            throw RuntimeSecurityError.secureDirectoryCreationFailed("目录 owner 不匹配：\(url.path)")
        }
        guard info.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0,
              info.st_mode & mode_t(S_IRWXU) == mode_t(S_IRWXU)
        else {
            throw RuntimeSecurityError.secureDirectoryCreationFailed("目录权限不是 0700：\(url.path)")
        }
        return FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            owner: info.st_uid
        )
    }

    private func verifyIdentity(_ expected: FileIdentity, at url: URL) throws {
        let actual: FileIdentity
        do {
            actual = try identity(ofPrivateDirectory: url)
        } catch {
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(url.path)
        }
        guard actual == expected else {
            throw RuntimeSecurityError.secureDirectoryIdentityChanged(url.path)
        }
    }
}

private func posixFailure() -> String {
    String(cString: strerror(errno))
}
