import CryptoKit
import Darwin
import Foundation

enum ThemeImportRollbackOperation: Equatable, Sendable {
    case verifyRoot
    case verifyWorkspace
    case unlinkFile(name: String)
    case synchronizeWorkspace
    case verifyDirectory(name: String)
    case removeDirectory(name: String)
    case synchronizeRoot
}

enum ThemeImportFileSystemEvent: Equatable, Sendable {
    case parentDirectorySynchronized(createdComponent: String)
    case fileSynchronized(name: String, usedFullSync: Bool)
    case workspaceSynchronized
    case willRename(flags: UInt32)
    case didRename
    case rootSynchronized
    case willCleanup(directoryURL: URL)
    case rollbackStarted(directoryURL: URL)
    case rollbackOperationSucceeded(ThemeImportRollbackOperation)
    case rollbackOperationFailed(operation: ThemeImportRollbackOperation, errorCode: Int32)
    case rollbackCompleted(failureCount: Int)
}

struct ThemeImportFileSystemConfiguration: Sendable {
    static let hardenedRenameFlags = UInt32(
        RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
    )

    static func renameFlags(supportsResolveBeneath: Bool) -> UInt32 {
        let compatibleFlags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        return supportsResolveBeneath ? hardenedRenameFlags : compatibleFlags
    }

    static var renameFlagsForCurrentOS: UInt32 {
        if #available(macOS 26.0, *) {
            renameFlags(supportsResolveBeneath: true)
        } else {
            renameFlags(supportsResolveBeneath: false)
        }
    }

    let lockTimeout: Duration
    let lockRetryInterval: Duration
    let fullSync: @Sendable (Int32) -> Int32
    let sync: @Sendable (Int32) -> Int32
    let rollbackInjectedError: @Sendable (ThemeImportRollbackOperation) -> Int32?
    let onEvent: @Sendable (ThemeImportFileSystemEvent) -> Void

    init(
        lockTimeout: Duration = .seconds(2),
        lockRetryInterval: Duration = .milliseconds(25),
        fullSync: @escaping @Sendable (Int32) -> Int32 = {
            Darwin.fcntl($0, F_FULLFSYNC)
        },
        sync: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) },
        rollbackInjectedError: @escaping @Sendable (
            ThemeImportRollbackOperation
        ) -> Int32? = { _ in nil },
        onEvent: @escaping @Sendable (ThemeImportFileSystemEvent) -> Void = { _ in }
    ) {
        self.lockTimeout = lockTimeout
        self.lockRetryInterval = lockRetryInterval
        self.fullSync = fullSync
        self.sync = sync
        self.rollbackInjectedError = rollbackInjectedError
        self.onEvent = onEvent
    }
}

actor ThemeImportService {
    private let repository: ThemeRepository
    private let normalizer: ThemeImageNormalizer
    private let compatibility: ThemeCompatibility
    private let fileSystem: ThemeImportFileSystemConfiguration

    init(
        repository: ThemeRepository,
        normalizer: ThemeImageNormalizer = ThemeImageNormalizer(),
        compatibility: ThemeCompatibility = ThemeCompatibility(
            adapterProtocol: "chatgpt-macos-renderer",
            minimumAPIVersion: 1,
            maximumAPIVersion: 1
        ),
        fileSystem: ThemeImportFileSystemConfiguration = ThemeImportFileSystemConfiguration()
    ) {
        self.repository = repository
        self.normalizer = normalizer
        self.compatibility = compatibility
        self.fileSystem = fileSystem
    }

    static func live(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> ThemeImportService {
        ThemeImportService(
            repository: try ThemeRepository.live(bundle: bundle, fileManager: fileManager)
        )
    }

    func prepare(sourceURL: URL) async throws -> ThemeImportDraft {
        try Task.checkCancellation()
        let draft = try normalizer.prepare(sourceURL: sourceURL)
        try Task.checkCancellation()
        return draft
    }

    func commit(
        draft: ThemeImportDraft,
        displayName: String? = nil,
        focalPoint: ThemeNormalizedPoint = ThemeNormalizedPoint(x: 0.5, y: 0.5)
    ) async throws -> ThemeImportResult {
        try Task.checkCancellation()
        let name = try normalizedThemeName(displayName ?? draft.suggestedName)
        guard focalPoint.x.isFinite,
              focalPoint.y.isFinite,
              (0 ... 1).contains(focalPoint.x),
              (0 ... 1).contains(focalPoint.y)
        else {
            throw ThemeImportError.invalidFocalPoint
        }
        try validateDraft(draft)

        let imageFileName: String
        switch draft.format {
        case .png:
            imageFileName = "hero.png"
        case .jpeg:
            imageFileName = "hero.jpg"
        case .webp:
            throw ThemeImportError.normalizationFailed(
                "导入规格化结果不允许使用 WebP 输出。"
            )
        }

        let themesRoot = try openUserThemesRoot()
        do {
            try await acquireExclusiveLock(on: themesRoot.fileDescriptor)
        } catch {
            Darwin.close(themesRoot.fileDescriptor)
            throw error
        }
        defer {
            Self.releaseExclusiveLock(on: themesRoot.fileDescriptor)
            Darwin.close(themesRoot.fileDescriptor)
        }

        let workspace = try createImportWorkspace(in: themesRoot)
        var rollbackDirectoryName: String? = workspace.locations.stagingName
        var createdFiles: [String: ImportedFileIdentity] = [:]
        defer {
            Darwin.close(workspace.fileDescriptor)
        }

        do {
            let sha256 = Self.sha256Hex(draft.imageData)
            let manifest = makeManifest(
                id: workspace.locations.themeID,
                name: name,
                focalPoint: focalPoint,
                imageFileName: imageFileName,
                imageFormat: draft.format,
                imageSHA256: sha256,
                pixelWidth: draft.pixelWidth,
                pixelHeight: draft.pixelHeight
            )

            do {
                _ = try writeFile(
                    draft.imageData,
                    named: imageFileName,
                    in: workspace.fileDescriptor,
                    tracking: &createdFiles
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let manifestData = try encoder.encode(manifest)
                _ = try writeFile(
                    manifestData,
                    named: "theme.json",
                    in: workspace.fileDescriptor,
                    tracking: &createdFiles
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ThemeImportError {
                throw error
            } catch {
                throw ThemeImportError.fileSystem(error.localizedDescription)
            }

            try synchronizeDirectory(workspace.fileDescriptor)
            fileSystem.onEvent(.workspaceSynchronized)
            try Task.checkCancellation()
            try assertCreatedFilesAreOwned(
                createdFiles,
                in: workspace.fileDescriptor
            )
            try assertWorkspaceIsOwned(
                workspace,
                named: workspace.locations.stagingName,
                at: workspace.locations.stagingURL,
                in: themesRoot
            )
            do {
                let stagedTheme = try repository.validator.validateAndLoad(
                    themeDirectory: workspace.locations.stagingURL,
                    source: .user
                )
                guard stagedTheme.manifest == manifest else {
                    throw ThemeImportError.validationFailed(
                        "staging 主题内容与本次导入清单不一致。"
                    )
                }
            } catch let error as ThemeImportError {
                throw error
            } catch {
                throw ThemeImportError.validationFailed(error.localizedDescription)
            }
            try assertWorkspaceIsOwned(
                workspace,
                named: workspace.locations.stagingName,
                at: workspace.locations.stagingURL,
                in: themesRoot
            )
            try assertCreatedFilesAreOwned(
                createdFiles,
                in: workspace.fileDescriptor
            )

            let renameFlags = ThemeImportFileSystemConfiguration.renameFlagsForCurrentOS
            fileSystem.onEvent(.willRename(flags: renameFlags))
            try Task.checkCancellation()
            try assertWorkspaceIsOwned(
                workspace,
                named: workspace.locations.stagingName,
                at: workspace.locations.stagingURL,
                in: themesRoot
            )
            try assertCreatedFilesAreOwned(
                createdFiles,
                in: workspace.fileDescriptor
            )
            let renameResult = workspace.locations.stagingName.withCString { stagingName in
                workspace.locations.finalName.withCString { finalName in
                    Darwin.renameatx_np(
                        themesRoot.fileDescriptor,
                        stagingName,
                        themesRoot.fileDescriptor,
                        finalName,
                        renameFlags
                    )
                }
            }
            guard renameResult == 0 else {
                let renameError = errno
                throw ThemeImportError.fileSystem(Self.posixErrorDescription(renameError))
            }
            rollbackDirectoryName = workspace.locations.finalName
            fileSystem.onEvent(.didRename)
            try synchronizeDirectory(themesRoot.fileDescriptor)
            fileSystem.onEvent(.rootSynchronized)
            try assertWorkspaceIsOwned(
                workspace,
                named: workspace.locations.finalName,
                at: workspace.locations.finalURL,
                in: themesRoot
            )
            try assertCreatedFilesAreOwned(
                createdFiles,
                in: workspace.fileDescriptor
            )

            try Task.checkCancellation()
            let loadedTheme: LoadedTheme
            do {
                loadedTheme = try repository.validator.validateAndLoad(
                    themeDirectory: workspace.locations.finalURL,
                    source: .user
                )
            } catch {
                throw ThemeImportError.validationFailed(error.localizedDescription)
            }
            guard loadedTheme.manifest == manifest else {
                throw ThemeImportError.validationFailed(
                    "最终主题内容与本次导入清单不一致。"
                )
            }
            try assertWorkspaceIsOwned(
                workspace,
                named: workspace.locations.finalName,
                at: workspace.locations.finalURL,
                in: themesRoot
            )
            try assertCreatedFilesAreOwned(
                createdFiles,
                in: workspace.fileDescriptor
            )
            try Task.checkCancellation()

            rollbackDirectoryName = nil
            return ThemeImportResult(theme: loadedTheme, warnings: draft.warnings)
        } catch {
            guard let directoryName = rollbackDirectoryName else {
                throw error
            }
            let rollbackURL = themesRoot.url.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            fileSystem.onEvent(.willCleanup(directoryURL: rollbackURL))
            fileSystem.onEvent(.rollbackStarted(directoryURL: rollbackURL))
            let failures = durableRollbackOwnedImport(
                root: themesRoot,
                directoryFileDescriptor: workspace.fileDescriptor,
                directoryName: directoryName,
                identity: workspace.identity,
                createdFiles: createdFiles
            )
            fileSystem.onEvent(.rollbackCompleted(failureCount: failures.count))
            guard failures.isEmpty else {
                throw ThemeImportError.rollbackFailed(
                    primary: Self.primaryErrorDescription(error),
                    rollbackFailures: failures.map(\.description)
                )
            }
            throw error
        }
    }

    private func validateDraft(_ draft: ThemeImportDraft) throws {
        guard !draft.imageData.isEmpty,
              draft.imageData.count <= normalizer.policy.maximumOutputBytes,
              draft.pixelWidth > 0,
              draft.pixelHeight > 0
        else {
            throw ThemeImportError.normalizationFailed("导入草稿中的图片数据无效。")
        }
        let (pixelCount, overflow) = draft.pixelWidth.multipliedReportingOverflow(
            by: draft.pixelHeight
        )
        guard !overflow,
              pixelCount <= normalizer.policy.maximumOutputPixelCount,
              max(draft.pixelWidth, draft.pixelHeight) <= normalizer.policy.maximumLongEdge
        else {
            throw ThemeImportError.normalizationFailed("导入草稿超过输出尺寸限制。")
        }
        guard draft.format == .png || draft.format == .jpeg else {
            throw ThemeImportError.normalizationFailed("导入草稿的输出格式无效。")
        }
    }

    private func openUserThemesRoot() throws -> SecureThemeRoot {
        // ThemeRepository already establishes the lexical path once. Re-standardizing
        // after creation can rewrite /private/var to the /var symlink alias and would
        // defeat the component-wise O_NOFOLLOW walk on a later import.
        let root = repository.userThemesRoot
        let pathComponents = root.pathComponents
        guard root.isFileURL,
              pathComponents.first == "/",
              pathComponents.count > 1
        else {
            throw ThemeImportError.unsafeThemeRoot(root.path)
        }

        var currentDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else {
            throw ThemeImportError.fileSystem(Self.posixErrorDescription())
        }

        var reachedTrustedAncestor = false
        do {
            for component in pathComponents.dropFirst() {
                guard !component.isEmpty,
                      component != ".",
                      component != "..",
                      !component.contains("/")
                else {
                    throw ThemeImportError.unsafeThemeRoot(root.path)
                }

                var childDescriptor = component.withCString { name in
                    Darwin.openat(
                        currentDescriptor,
                        name,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                if childDescriptor < 0 {
                    let openError = errno
                    guard openError == ENOENT, reachedTrustedAncestor else {
                        if openError == ELOOP || openError == ENOTDIR || openError == ENOENT {
                            throw ThemeImportError.unsafeThemeRoot(root.path)
                        }
                        throw ThemeImportError.fileSystem(
                            Self.posixErrorDescription(openError)
                        )
                    }

                    let createResult = component.withCString { name in
                        Darwin.mkdirat(currentDescriptor, name, mode_t(0o700))
                    }
                    if createResult != 0, errno != EEXIST {
                        let createError = errno
                        throw ThemeImportError.fileSystem(
                            Self.posixErrorDescription(createError)
                        )
                    }
                    if createResult == 0 {
                        try synchronizeDirectory(currentDescriptor)
                        fileSystem.onEvent(
                            .parentDirectorySynchronized(createdComponent: component)
                        )
                    }

                    childDescriptor = component.withCString { name in
                        Darwin.openat(
                            currentDescriptor,
                            name,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                    guard childDescriptor >= 0 else {
                        let retryError = errno
                        if retryError == ELOOP || retryError == ENOTDIR {
                            throw ThemeImportError.unsafeThemeRoot(root.path)
                        }
                        throw ThemeImportError.fileSystem(
                            Self.posixErrorDescription(retryError)
                        )
                    }
                }

                var childMetadata = stat()
                guard Darwin.fstat(childDescriptor, &childMetadata) == 0,
                      (childMetadata.st_mode & S_IFMT) == S_IFDIR
                else {
                    Darwin.close(childDescriptor)
                    throw ThemeImportError.unsafeThemeRoot(root.path)
                }

                let isSecureCurrentUserDirectory = Self.isSecureCurrentUserDirectory(
                    childMetadata
                )
                guard !reachedTrustedAncestor || isSecureCurrentUserDirectory else {
                    Darwin.close(childDescriptor)
                    throw ThemeImportError.unsafeThemeRoot(root.path)
                }
                if isSecureCurrentUserDirectory {
                    reachedTrustedAncestor = true
                }

                Darwin.close(currentDescriptor)
                currentDescriptor = childDescriptor
            }

            var rootMetadata = stat()
            guard reachedTrustedAncestor,
                  Darwin.fstat(currentDescriptor, &rootMetadata) == 0,
                  Self.isSecureCurrentUserDirectory(rootMetadata)
            else {
                throw ThemeImportError.unsafeThemeRoot(root.path)
            }
            let identity = DirectoryIdentity(rootMetadata)
            guard (try? Self.directoryIdentity(at: root)) == identity else {
                throw ThemeImportError.unsafeThemeRoot(root.path)
            }
            return SecureThemeRoot(
                url: root,
                fileDescriptor: currentDescriptor,
                identity: identity
            )
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private func acquireExclusiveLock(on fileDescriptor: Int32) async throws {
        let clock = ContinuousClock()
        let configuredTimeout = min(fileSystem.lockTimeout, .seconds(2))
        let timeout = max(configuredTimeout, .zero)
        let retryInterval = max(
            min(fileSystem.lockRetryInterval, .milliseconds(50)),
            .milliseconds(1)
        )
        let deadline = clock.now.advanced(by: timeout)

        while true {
            try Task.checkCancellation()
            if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                return
            }

            let lockError = errno
            if lockError == EINTR {
                continue
            }
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                throw ThemeImportError.fileSystem(
                    Self.posixErrorDescription(lockError)
                )
            }
            guard clock.now < deadline else {
                throw ThemeImportError.fileSystem(
                    "用户主题目录正在被另一个导入事务占用，请稍后重试。"
                )
            }

            let remaining = clock.now.duration(to: deadline)
            try await Task.sleep(for: min(retryInterval, remaining))
        }
    }

    private static func releaseExclusiveLock(on fileDescriptor: Int32) {
        while flock(fileDescriptor, LOCK_UN) != 0, errno == EINTR {}
    }

    private func createImportWorkspace(in root: SecureThemeRoot) throws -> ImportWorkspace {
        for _ in 0 ..< 16 {
            let identifier = UUID().uuidString.lowercased()
            let themeID = "user-\(identifier)"
            let stagingName = ".import-\(identifier)"
            let finalName = themeID
            let locations = ImportLocations(
                themeID: themeID,
                stagingName: stagingName,
                finalName: finalName,
                stagingURL: root.url.appendingPathComponent(stagingName, isDirectory: true),
                finalURL: root.url.appendingPathComponent(finalName, isDirectory: true)
            )

            let createResult = stagingName.withCString { name in
                Darwin.mkdirat(root.fileDescriptor, name, mode_t(0o700))
            }
            if createResult != 0 {
                if errno == EEXIST { continue }
                throw ThemeImportError.fileSystem(Self.posixErrorDescription())
            }

            do {
                try synchronizeDirectory(root.fileDescriptor)
                fileSystem.onEvent(
                    .parentDirectorySynchronized(createdComponent: stagingName)
                )
            } catch {
                // mkdirat succeeded, but without an opened descriptor there is no
                // safe identity-bound rollback. Leave the hidden empty directory.
                throw error
            }

            let directoryFileDescriptor = stagingName.withCString { name in
                Darwin.openat(
                    root.fileDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard directoryFileDescriptor >= 0 else {
                let openError = errno
                throw ThemeImportError.fileSystem(
                    Self.posixErrorDescription(openError)
                )
            }

            do {
                var stagingMetadata = stat()
                guard Darwin.fstat(directoryFileDescriptor, &stagingMetadata) == 0,
                      Self.isSecureCurrentUserDirectory(stagingMetadata)
                else {
                    throw ThemeImportError.fileSystem("无法验证导入 staging 目录。")
                }
                let workspace = ImportWorkspace(
                    locations: locations,
                    fileDescriptor: directoryFileDescriptor,
                    identity: DirectoryIdentity(stagingMetadata)
                )
                try assertWorkspaceIsOwned(
                    workspace,
                    named: stagingName,
                    at: locations.stagingURL,
                    in: root
                )
                return workspace
            } catch {
                var stagingMetadata = stat()
                var rollbackFailures: [ThemeImportRollbackFailure]
                fileSystem.onEvent(.willCleanup(directoryURL: locations.stagingURL))
                fileSystem.onEvent(.rollbackStarted(directoryURL: locations.stagingURL))
                if Darwin.fstat(directoryFileDescriptor, &stagingMetadata) == 0 {
                    rollbackFailures = durableRollbackOwnedImport(
                        root: root,
                        directoryFileDescriptor: directoryFileDescriptor,
                        directoryName: stagingName,
                        identity: DirectoryIdentity(stagingMetadata),
                        createdFiles: [:]
                    )
                } else {
                    let verificationError = errno
                    let operation = ThemeImportRollbackOperation.verifyWorkspace
                    rollbackFailures = [
                        makeRollbackFailure(
                            operation: operation,
                            code: verificationError,
                            context: "无法读取 staging 目录文件描述符"
                        ),
                    ]
                }
                fileSystem.onEvent(
                    .rollbackCompleted(failureCount: rollbackFailures.count)
                )
                Darwin.close(directoryFileDescriptor)
                guard rollbackFailures.isEmpty else {
                    throw ThemeImportError.rollbackFailed(
                        primary: Self.primaryErrorDescription(error),
                        rollbackFailures: rollbackFailures.map(\.description)
                    )
                }
                throw error
            }
        }
        throw ThemeImportError.unableToAllocateThemeID
    }

    private func assertWorkspaceIsOwned(
        _ workspace: ImportWorkspace,
        named directoryName: String,
        at directoryURL: URL,
        in root: SecureThemeRoot
    ) throws {
        var rootMetadata = stat()
        guard Darwin.fstat(root.fileDescriptor, &rootMetadata) == 0,
              Self.isSecureCurrentUserDirectory(rootMetadata),
              DirectoryIdentity(rootMetadata) == root.identity,
              try Self.directoryIdentity(at: root.url) == root.identity
        else {
            throw ThemeImportError.unsafeThemeRoot(root.url.path)
        }

        var descriptorMetadata = stat()
        guard Darwin.fstat(workspace.fileDescriptor, &descriptorMetadata) == 0,
              Self.isSecureCurrentUserDirectory(descriptorMetadata),
              DirectoryIdentity(descriptorMetadata) == workspace.identity
        else {
            throw ThemeImportError.fileSystem("导入目录的文件描述符归属已发生变化。")
        }

        var relativeMetadata = stat()
        let relativeResult = directoryName.withCString { name in
            Darwin.fstatat(
                root.fileDescriptor,
                name,
                &relativeMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard relativeResult == 0,
              Self.isSecureCurrentUserDirectory(relativeMetadata),
              DirectoryIdentity(relativeMetadata) == workspace.identity,
              try Self.directoryIdentity(at: directoryURL) == workspace.identity
        else {
            throw ThemeImportError.fileSystem("导入目录的路径归属已发生变化。")
        }
    }

    private func writeFile(
        _ data: Data,
        named fileName: String,
        in directoryFileDescriptor: Int32,
        tracking createdFiles: inout [String: ImportedFileIdentity]
    ) throws -> ImportedFileIdentity {
        let fileDescriptor = fileName.withCString { name in
            Darwin.openat(
                directoryFileDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else {
            throw ThemeImportError.fileSystem(Self.posixErrorDescription())
        }
        defer { Darwin.close(fileDescriptor) }

        var createdMetadata = stat()
        guard Darwin.fstat(fileDescriptor, &createdMetadata) == 0,
              (createdMetadata.st_mode & S_IFMT) == S_IFREG,
              createdMetadata.st_uid == getuid()
        else {
            throw ThemeImportError.fileSystem("无法验证新建导入文件的归属。")
        }
        let identity = ImportedFileIdentity(createdMetadata)
        createdFiles[fileName] = identity

        try data.withUnsafeBytes { buffer in
            guard data.isEmpty || buffer.baseAddress != nil else {
                throw ThemeImportError.fileSystem("无法读取待写入的导入数据。")
            }
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let written = Darwin.write(
                    fileDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
                if written < 0, errno == EINTR { continue }
                if written < 0 {
                    throw ThemeImportError.fileSystem(Self.posixErrorDescription())
                }
                guard written > 0 else {
                    throw ThemeImportError.fileSystem("导入文件写入提前结束。")
                }
                offset += written
            }
        }

        guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            throw ThemeImportError.fileSystem(Self.posixErrorDescription())
        }
        var finalMetadata = stat()
        guard Darwin.fstat(fileDescriptor, &finalMetadata) == 0,
              (finalMetadata.st_mode & S_IFMT) == S_IFREG,
              ImportedFileIdentity(finalMetadata) == identity,
              (finalMetadata.st_mode & mode_t(0o077)) == 0
        else {
            throw ThemeImportError.fileSystem("导入文件的归属或权限已发生变化。")
        }

        let usedFullSync = try synchronizeFile(fileDescriptor)
        fileSystem.onEvent(
            .fileSynchronized(name: fileName, usedFullSync: usedFullSync)
        )
        return identity
    }

    private func assertCreatedFilesAreOwned(
        _ createdFiles: [String: ImportedFileIdentity],
        in directoryFileDescriptor: Int32
    ) throws {
        for (fileName, identity) in createdFiles {
            var metadata = stat()
            let result = fileName.withCString { name in
                Darwin.fstatat(
                    directoryFileDescriptor,
                    name,
                    &metadata,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard result == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  identity.owner == getuid(),
                  ImportedFileIdentity(metadata) == identity,
                  (metadata.st_mode & mode_t(0o077)) == 0
            else {
                throw ThemeImportError.fileSystem(
                    "导入文件的路径归属已发生变化：\(fileName)"
                )
            }
        }
    }

    private func synchronizeFile(_ fileDescriptor: Int32) throws -> Bool {
        while true {
            if fileSystem.fullSync(fileDescriptor) != -1 {
                return true
            }
            let fullSyncError = errno
            if fullSyncError == EINTR {
                continue
            }
            guard Self.isUnsupportedFullSyncError(fullSyncError) else {
                throw ThemeImportError.fileSystem(
                    Self.posixErrorDescription(fullSyncError)
                )
            }
            try synchronizeDirectory(fileDescriptor)
            return false
        }
    }

    private func synchronizeDirectory(_ fileDescriptor: Int32) throws {
        while true {
            if fileSystem.sync(fileDescriptor) == 0 {
                return
            }
            let syncError = errno
            if syncError == EINTR {
                continue
            }
            throw ThemeImportError.fileSystem(Self.posixErrorDescription(syncError))
        }
    }

    private func durableRollbackOwnedImport(
        root: SecureThemeRoot,
        directoryFileDescriptor: Int32,
        directoryName: String,
        identity: DirectoryIdentity,
        createdFiles: [String: ImportedFileIdentity]
    ) -> [ThemeImportRollbackFailure] {
        var failures: [ThemeImportRollbackFailure] = []

        var rootMetadata = stat()
        let rootStatResult = Darwin.fstat(root.fileDescriptor, &rootMetadata)
        if rootStatResult != 0 {
            failures.append(
                makeRollbackFailure(
                    operation: .verifyRoot,
                    code: errno,
                    context: "无法读取用户主题根目录文件描述符"
                )
            )
            return failures
        }
        guard Self.isSecureCurrentUserDirectory(rootMetadata),
              DirectoryIdentity(rootMetadata) == root.identity
        else {
            failures.append(
                makeRollbackFailure(
                    operation: .verifyRoot,
                    code: ESTALE,
                    context: "用户主题根目录归属无法证明，已停止 rollback"
                )
            )
            return failures
        }
        recordRollbackSuccess(.verifyRoot)

        var descriptorMetadata = stat()
        let descriptorStatResult = Darwin.fstat(directoryFileDescriptor, &descriptorMetadata)
        if descriptorStatResult != 0 {
            failures.append(
                makeRollbackFailure(
                    operation: .verifyWorkspace,
                    code: errno,
                    context: "无法读取导入目录文件描述符"
                )
            )
            return failures
        }
        guard Self.isSecureCurrentUserDirectory(descriptorMetadata),
              identity.owner == getuid(),
              DirectoryIdentity(descriptorMetadata) == identity
        else {
            failures.append(
                makeRollbackFailure(
                    operation: .verifyWorkspace,
                    code: ESTALE,
                    context: "导入目录归属无法证明，已停止 rollback"
                )
            )
            return failures
        }
        recordRollbackSuccess(.verifyWorkspace)

        var didDeleteFile = false
        for fileName in createdFiles.keys.sorted() {
            guard let fileIdentity = createdFiles[fileName] else { continue }
            let operation = ThemeImportRollbackOperation.unlinkFile(name: fileName)
            var relativeMetadata = stat()
            let relativeResult = fileName.withCString { name in
                Darwin.fstatat(
                    directoryFileDescriptor,
                    name,
                    &relativeMetadata,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            if relativeResult != 0 {
                failures.append(
                    makeRollbackFailure(
                        operation: operation,
                        code: errno,
                        context: "无法验证待删除文件"
                    )
                )
                continue
            }
            guard (relativeMetadata.st_mode & S_IFMT) == S_IFREG,
                  fileIdentity.owner == getuid(),
                  ImportedFileIdentity(relativeMetadata) == fileIdentity
            else {
                failures.append(
                    makeRollbackFailure(
                        operation: operation,
                        code: ESTALE,
                        context: "文件归属无法证明，已保留该路径"
                    )
                )
                continue
            }

            // Darwin does not provide unlink-by-inode. An advisory flock cannot stop a
            // malicious same-UID writer that ignores it, so a residual fstatat -> unlinkat
            // TOCTOU window remains. Any identity mismatch we can prove is deliberately
            // leaked instead of deleted; never relax this identity gate to improve cleanup.
            if let unlinkError = performRollbackOperation(operation, syscall: {
                fileName.withCString { name in
                    Darwin.unlinkat(directoryFileDescriptor, name, 0)
                }
            }) {
                failures.append(
                    makeRollbackFailure(
                        operation: operation,
                        code: unlinkError,
                        context: "unlinkat 失败"
                    )
                )
            } else {
                didDeleteFile = true
                recordRollbackSuccess(operation)
            }
        }

        if didDeleteFile {
            let operation = ThemeImportRollbackOperation.synchronizeWorkspace
            if let syncError = performRollbackOperation(operation, syscall: {
                fileSystem.sync(directoryFileDescriptor)
            }) {
                failures.append(
                    makeRollbackFailure(
                        operation: operation,
                        code: syncError,
                        context: "删除文件后 fsync workspace 失败"
                    )
                )
            } else {
                recordRollbackSuccess(operation)
            }
        }

        let verificationOperation = ThemeImportRollbackOperation.verifyDirectory(
            name: directoryName
        )
        var relativeMetadata = stat()
        let relativeResult = directoryName.withCString { name in
            Darwin.fstatat(
                root.fileDescriptor,
                name,
                &relativeMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if relativeResult != 0 {
            failures.append(
                makeRollbackFailure(
                    operation: verificationOperation,
                    code: errno,
                    context: "无法验证待删除导入目录"
                )
            )
            return failures
        }
        guard Self.isSecureCurrentUserDirectory(relativeMetadata),
              DirectoryIdentity(relativeMetadata) == identity
        else {
            failures.append(
                makeRollbackFailure(
                    operation: verificationOperation,
                    code: ESTALE,
                    context: "导入目录路径归属无法证明，已保留该路径"
                )
            )
            return failures
        }
        recordRollbackSuccess(verificationOperation)

        // The same Darwin limitation leaves an unavoidable fstatat -> rmdir gap here too.
        // If identity cannot be proven immediately before deletion, leak the directory.
        let removeOperation = ThemeImportRollbackOperation.removeDirectory(name: directoryName)
        if let removeError = performRollbackOperation(removeOperation, syscall: {
            directoryName.withCString { name in
                Darwin.unlinkat(root.fileDescriptor, name, AT_REMOVEDIR)
            }
        }) {
            failures.append(
                makeRollbackFailure(
                    operation: removeOperation,
                    code: removeError,
                    context: "rmdir 失败"
                )
            )
            return failures
        }
        recordRollbackSuccess(removeOperation)

        let rootSyncOperation = ThemeImportRollbackOperation.synchronizeRoot
        if let syncError = performRollbackOperation(rootSyncOperation, syscall: {
            fileSystem.sync(root.fileDescriptor)
        }) {
            failures.append(
                makeRollbackFailure(
                    operation: rootSyncOperation,
                    code: syncError,
                    context: "删除目录后 fsync root 失败"
                )
            )
        } else {
            recordRollbackSuccess(rootSyncOperation)
        }
        return failures
    }

    private func performRollbackOperation(
        _ operation: ThemeImportRollbackOperation,
        syscall: () -> Int32
    ) -> Int32? {
        if let injectedError = fileSystem.rollbackInjectedError(operation) {
            return injectedError
        }
        while true {
            if syscall() == 0 {
                return nil
            }
            let operationError = errno
            if operationError == EINTR {
                continue
            }
            return operationError
        }
    }

    private func makeRollbackFailure(
        operation: ThemeImportRollbackOperation,
        code: Int32,
        context: String
    ) -> ThemeImportRollbackFailure {
        fileSystem.onEvent(
            .rollbackOperationFailed(operation: operation, errorCode: code)
        )
        return ThemeImportRollbackFailure(
            description: "\(Self.rollbackOperationDescription(operation))：\(context)："
                + "\(Self.posixErrorDescription(code)) (errno \(code))"
        )
    }

    private func recordRollbackSuccess(_ operation: ThemeImportRollbackOperation) {
        fileSystem.onEvent(.rollbackOperationSucceeded(operation))
    }

    private static func directoryIdentity(at url: URL) throws -> DirectoryIdentity {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        guard result == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else {
            throw ThemeImportError.fileSystem("目录归属验证失败：\(url.path)")
        }
        return DirectoryIdentity(metadata)
    }

    private static func isSecureCurrentUserDirectory(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFDIR
            && metadata.st_uid == getuid()
            && (metadata.st_mode & mode_t(0o022)) == 0
    }

    private static func isUnsupportedFullSyncError(_ code: Int32) -> Bool {
        code == EINVAL
            || code == ENOTSUP
            || code == ENOTTY
    }

    private func normalizedThemeName(_ proposedName: String) throws -> String {
        let withoutControls = proposedName
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
        let collapsed = withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let normalized = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 100 else {
            throw ThemeImportError.invalidThemeName
        }
        return normalized
    }

    private func makeManifest(
        id: String,
        name: String,
        focalPoint: ThemeNormalizedPoint,
        imageFileName: String,
        imageFormat: ThemeImageFormat,
        imageSHA256: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> ThemeManifestV3 {
        ThemeManifestV3(
            schemaVersion: ThemeManifestV3.currentSchemaVersion,
            id: id,
            name: name,
            nativeTheme: ThemeNativePalette(
                accent: "#43D8F5",
                secondary: "#8A7CF5",
                surface: "#091426",
                ink: "#EAF6FF",
                muted: "#9DB2C7",
                success: "#56D6AD",
                warning: "#E8C66A",
                danger: "#F1788D"
            ),
            hero: ThemeHeroConfiguration(
                asset: "hero",
                focalPoint: focalPoint,
                safeArea: ThemeNormalizedRect(x: 0, y: 0, width: 1, height: 1),
                adaptiveScrim: ThemeAdaptiveScrim(
                    color: "#061020",
                    opacity: 0.44
                )
            ),
            sidebar: ThemeGlassConfiguration(opacity: 0.78, blurRadius: 28),
            composer: ThemeGlassConfiguration(opacity: 0.82, blurRadius: 24),
            compatibility: compatibility,
            assets: [
                "hero": ThemeAssetDescriptor(
                    path: imageFileName,
                    sha256: imageSHA256,
                    format: imageFormat,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                ),
            ],
            features: ThemeFeatures(
                homeEnhancer: true,
                motion: false,
                routeAware: true
            )
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func primaryErrorDescription(_ error: Error) -> String {
        if error is CancellationError {
            return "CancellationError"
        }
        if let importError = error as? ThemeImportError {
            return importError.errorDescription ?? String(describing: importError)
        }
        return "\(String(describing: type(of: error)))：\(error.localizedDescription)"
    }

    private static func rollbackOperationDescription(
        _ operation: ThemeImportRollbackOperation
    ) -> String {
        switch operation {
        case .verifyRoot:
            "verify root"
        case .verifyWorkspace:
            "verify workspace"
        case let .unlinkFile(name):
            "unlink file \(name)"
        case .synchronizeWorkspace:
            "sync workspace"
        case let .verifyDirectory(name):
            "verify directory \(name)"
        case let .removeDirectory(name):
            "remove directory \(name)"
        case .synchronizeRoot:
            "sync root"
        }
    }

    private static func posixErrorDescription(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }
}

private struct ImportLocations {
    let themeID: String
    let stagingName: String
    let finalName: String
    let stagingURL: URL
    let finalURL: URL
}

private struct SecureThemeRoot {
    let url: URL
    let fileDescriptor: Int32
    let identity: DirectoryIdentity
}

private struct ImportWorkspace {
    let locations: ImportLocations
    let fileDescriptor: Int32
    let identity: DirectoryIdentity
}

private struct DirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        owner = metadata.st_uid
    }
}

private struct ImportedFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        owner = metadata.st_uid
    }
}

private struct ThemeImportRollbackFailure {
    let description: String
}
