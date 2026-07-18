import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import ChatGPTSkinStudio

final class ThemeImportTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let didResolve = FileManager.default.temporaryDirectory.path.withCString { path in
            Darwin.realpath(path, &resolvedPath) != nil
        }
        guard didResolve else { throw TestFailure.fixtureCreationFailed }
        let resolvedBytes = resolvedPath
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        temporaryRoot = URL(
            fileURLWithPath: String(decoding: resolvedBytes, as: UTF8.self),
            isDirectory: true
        )
            .appendingPathComponent("ChatGPTSkinStudio-ThemeImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testNormalizerAppliesOrientationDownsamplesAndStripsMetadata() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("rotated.jpg")
        let sourceImage = try makeImage(width: 120, height: 80, hasAlpha: false)
        try encode(
            images: [sourceImage],
            typeIdentifier: UTType.jpeg.identifier,
            properties: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 31.2,
                    kCGImagePropertyGPSLatitudeRef: "N",
                ],
            ]
        ).write(to: sourceURL)

        let policy = ThemeImageNormalizationPolicy(
            maximumLongEdge: 60,
            maximumOutputPixelCount: 3_600,
            lowResolutionWidth: 1,
            lowResolutionHeight: 1
        )
        let draft = try ThemeImageNormalizer(policy: policy).prepare(sourceURL: sourceURL)

        XCTAssertEqual(draft.format, .jpeg)
        XCTAssertEqual(draft.originalPixelWidth, 80)
        XCTAssertEqual(draft.originalPixelHeight, 120)
        XCTAssertEqual(draft.pixelWidth, 40)
        XCTAssertEqual(draft.pixelHeight, 60)
        XCTAssertEqual(
            draft.warnings,
            [
                .downsampled(
                    originalWidth: 80,
                    originalHeight: 120,
                    outputWidth: 40,
                    outputHeight: 60
                ),
            ]
        )

        let outputSource = try XCTUnwrap(
            CGImageSourceCreateWithData(draft.imageData as CFData, nil)
        )
        let outputProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(outputProperties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(
            (outputProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
            1
        )
    }

    func testNormalizerNeverUpscalesAndPreservesTransparencyAsPNG() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("transparent.png")
        let sourceImage = try makeImage(width: 24, height: 16, hasAlpha: true)
        try encode(
            images: [sourceImage],
            typeIdentifier: UTType.png.identifier
        ).write(to: sourceURL)

        let policy = ThemeImageNormalizationPolicy(
            maximumLongEdge: 3_840,
            maximumOutputPixelCount: 12_000_000,
            lowResolutionWidth: 1,
            lowResolutionHeight: 1
        )
        let draft = try ThemeImageNormalizer(policy: policy).prepare(sourceURL: sourceURL)

        XCTAssertEqual(draft.format, .png)
        XCTAssertEqual(draft.pixelWidth, 24)
        XCTAssertEqual(draft.pixelHeight, 16)
        XCTAssertFalse(
            draft.warnings.contains {
                if case .downsampled = $0 { return true }
                return false
            }
        )
    }

    func testNormalizerUsesJPEGWhenPNGAlphaChannelIsFullyOpaque() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("opaque-alpha.png")
        let sourceImage = try makeImage(
            width: 32,
            height: 20,
            hasAlpha: true,
            fillAlpha: 1
        )
        try encode(
            images: [sourceImage],
            typeIdentifier: UTType.png.identifier
        ).write(to: sourceURL)

        let draft = try ThemeImageNormalizer(
            policy: ThemeImageNormalizationPolicy(
                lowResolutionWidth: 1,
                lowResolutionHeight: 1
            )
        ).prepare(sourceURL: sourceURL)

        XCTAssertEqual(draft.format, .jpeg)
    }

    func testNormalizerAcceptsHEICAndConvertsItToJPEG() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("phone.heic")
        let sourceImage = try makeImage(width: 40, height: 24, hasAlpha: false)
        try encode(
            images: [sourceImage],
            typeIdentifier: UTType.heic.identifier
        ).write(to: sourceURL)

        let draft = try ThemeImageNormalizer(
            policy: ThemeImageNormalizationPolicy(
                lowResolutionWidth: 1,
                lowResolutionHeight: 1
            )
        ).prepare(sourceURL: sourceURL)

        XCTAssertEqual(draft.format, .jpeg)
        XCTAssertTrue(draft.imageData.starts(with: [0xff, 0xd8, 0xff]))
    }

    func testNormalizerAcceptsWebPAndConvertsItToTrustedOutput() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("web-image.webp")
        let webPFixture = try XCTUnwrap(
            Data(
                base64Encoded: "UklGRiwAAABXRUJQVlA4ICAAAABwAQCdASoCAAIAAsBMJYwCdAF1AAD+9PQ2vDZDFeAAAA=="
            )
        )
        try webPFixture.write(to: sourceURL)

        let draft = try ThemeImageNormalizer(
            policy: ThemeImageNormalizationPolicy(
                lowResolutionWidth: 1,
                lowResolutionHeight: 1
            )
        ).prepare(sourceURL: sourceURL)

        XCTAssertEqual(draft.format, .jpeg)
        XCTAssertEqual(draft.pixelWidth, 2)
        XCTAssertEqual(draft.pixelHeight, 2)
        XCTAssertTrue(draft.imageData.starts(with: [0xff, 0xd8, 0xff]))
    }

    func testNormalizerRejectsSymlinkDisguisedFormatMultiframeAndCorruption() throws {
        let validPNG = temporaryRoot.appendingPathComponent("valid.png")
        try encode(
            images: [try makeImage(width: 16, height: 8, hasAlpha: true)],
            typeIdentifier: UTType.png.identifier
        ).write(to: validPNG)

        let symlink = temporaryRoot.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: validPNG)
        XCTAssertThrowsError(try ThemeImageNormalizer().prepare(sourceURL: symlink)) { error in
            XCTAssertEqual(error as? ThemeImportError, .sourceIsSymbolicLink)
        }

        let disguised = temporaryRoot.appendingPathComponent("disguised.jpg")
        try Data(contentsOf: validPNG).write(to: disguised)
        XCTAssertThrowsError(try ThemeImageNormalizer().prepare(sourceURL: disguised)) { error in
            XCTAssertEqual(
                error as? ThemeImportError,
                .disguisedSourceExtension(extensionName: "jpg", actualFormat: "PNG")
            )
        }

        let animatedGIF = temporaryRoot.appendingPathComponent("animated.gif")
        let gifFrame = try makeImage(width: 8, height: 8, hasAlpha: false)
        try encode(
            images: [gifFrame, gifFrame],
            typeIdentifier: UTType.gif.identifier
        ).write(to: animatedGIF)
        XCTAssertThrowsError(try ThemeImageNormalizer().prepare(sourceURL: animatedGIF)) { error in
            XCTAssertEqual(
                error as? ThemeImportError,
                .animatedOrMultiFrame(frameCount: 2)
            )
        }

        let corrupt = temporaryRoot.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        XCTAssertThrowsError(try ThemeImageNormalizer().prepare(sourceURL: corrupt)) { error in
            XCTAssertEqual(error as? ThemeImportError, .invalidImage)
        }
    }

    func testNormalizerRejectsSourceByteAndPixelBombs() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("large.png")
        try encode(
            images: [try makeImage(width: 100, height: 100, hasAlpha: true)],
            typeIdentifier: UTType.png.identifier
        ).write(to: sourceURL)

        XCTAssertThrowsError(
            try ThemeImageNormalizer(
                policy: ThemeImageNormalizationPolicy(maximumSourceBytes: 32)
            ).prepare(sourceURL: sourceURL)
        ) { error in
            guard case ThemeImportError.sourceTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try ThemeImageNormalizer(
                policy: ThemeImageNormalizationPolicy(maximumSourcePixelCount: 9_999)
            ).prepare(sourceURL: sourceURL)
        ) { error in
            XCTAssertEqual(
                error as? ThemeImportError,
                .sourcePixelLimitExceeded(width: 100, height: 100)
            )
        }
    }

    func testNormalizerIterativelyShrinksTransparentOutputToByteBudget() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("noise.png")
        let sourceImage = try makeNoisyTransparentImage(width: 256, height: 256)
        try encode(
            images: [sourceImage],
            typeIdentifier: UTType.png.identifier
        ).write(to: sourceURL)

        let policy = ThemeImageNormalizationPolicy(
            maximumLongEdge: 256,
            maximumOutputPixelCount: 65_536,
            maximumOutputBytes: 24 * 1024,
            lowResolutionWidth: 1,
            lowResolutionHeight: 1
        )
        let draft = try ThemeImageNormalizer(policy: policy).prepare(sourceURL: sourceURL)

        XCTAssertEqual(draft.format, .png)
        XCTAssertLessThanOrEqual(draft.imageData.count, 24 * 1024)
        XCTAssertLessThan(max(draft.pixelWidth, draft.pixelHeight), 256)
        XCTAssertTrue(
            draft.warnings.contains {
                if case .downsampled = $0 { return true }
                return false
            }
        )
    }

    func testNormalizerRejectsSourceReplacementBetweenInspectionAndOpen() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("inspection-race.jpg")
        let replacementURL = temporaryRoot.appendingPathComponent("inspection-attacker.tmp")
        let sourceData = try encode(
            images: [try makeImage(width: 32, height: 20, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        )
        try sourceData.write(to: sourceURL)
        try Data(repeating: 0x5a, count: sourceData.count).write(to: replacementURL)

        let normalizer = ThemeImageNormalizer(
            fileSystemHooks: ThemeImageNormalizerFileSystemHooks(onEvent: { event in
                guard case .didInspectSource = event else { return }
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.moveItem(at: replacementURL, to: sourceURL)
            })
        )

        XCTAssertThrowsError(try normalizer.prepare(sourceURL: sourceURL)) { error in
            guard case let ThemeImportError.normalizationFailed(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("检查与打开之间发生变化"))
        }
    }

    func testNormalizerRejectsSameInodeSameSizeMutationBetweenInspectionAndOpen() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("inspection-mutation.jpg")
        try encode(
            images: [try makeImage(width: 32, height: 20, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        ).write(to: sourceURL)

        let normalizer = ThemeImageNormalizer(
            fileSystemHooks: ThemeImageNormalizerFileSystemHooks(onEvent: { event in
                guard case .didInspectSource = event else { return }
                usleep(20_000)
                let descriptor = Darwin.open(
                    sourceURL.path,
                    O_WRONLY | O_CLOEXEC | O_NOFOLLOW
                )
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }
                var replacementByte: UInt8 = 0
                _ = Darwin.pwrite(descriptor, &replacementByte, 1, 0)
                _ = Darwin.fsync(descriptor)
            })
        )

        XCTAssertThrowsError(try normalizer.prepare(sourceURL: sourceURL)) { error in
            guard case let ThemeImportError.normalizationFailed(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("检查与打开之间发生变化"))
        }
    }

    func testNormalizerRejectsSourceReplacementAfterOpen() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("open-race.jpg")
        let replacementURL = temporaryRoot.appendingPathComponent("open-attacker.tmp")
        let sourceData = try encode(
            images: [try makeImage(width: 32, height: 20, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        )
        try sourceData.write(to: sourceURL)
        try Data(repeating: 0x6b, count: sourceData.count).write(to: replacementURL)

        let normalizer = ThemeImageNormalizer(
            fileSystemHooks: ThemeImageNormalizerFileSystemHooks(onEvent: { event in
                guard case .didOpenSource = event else { return }
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.moveItem(at: replacementURL, to: sourceURL)
            })
        )

        XCTAssertThrowsError(try normalizer.prepare(sourceURL: sourceURL)) { error in
            guard case let ThemeImportError.normalizationFailed(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("读取期间发生变化"))
        }
    }

    func testNormalizerRejectsSameInodeSameSizeMutationAfterRead() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("same-inode-race.jpg")
        try encode(
            images: [try makeImage(width: 32, height: 20, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        ).write(to: sourceURL)

        let normalizer = ThemeImageNormalizer(
            fileSystemHooks: ThemeImageNormalizerFileSystemHooks(onEvent: { event in
                guard case .didReadSource = event else { return }
                usleep(20_000)
                let descriptor = Darwin.open(
                    sourceURL.path,
                    O_WRONLY | O_CLOEXEC | O_NOFOLLOW
                )
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }
                var replacementByte: UInt8 = 0
                _ = Darwin.pwrite(descriptor, &replacementByte, 1, 0)
                _ = Darwin.fsync(descriptor)
            })
        )

        XCTAssertThrowsError(try normalizer.prepare(sourceURL: sourceURL)) { error in
            guard case let ThemeImportError.normalizationFailed(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("读取期间发生变化"))
        }
    }

    func testServiceCommitsTrustedThemeWithSecurePermissionsAndReloads() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("My Photo.jpg")
        try encode(
            images: [try makeImage(width: 80, height: 50, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        ).write(to: sourceURL)

        let repository = try makeRepository()
        let service = ThemeImportService(repository: repository)
        let draft = try await service.prepare(sourceURL: sourceURL)
        let result = try await service.commit(
            draft: draft,
            displayName: "  My   Imported Theme  ",
            focalPoint: ThemeNormalizedPoint(x: 0.25, y: 0.75)
        )

        XCTAssertTrue(result.theme.manifest.id.hasPrefix("user-"))
        XCTAssertEqual(result.theme.manifest.name, "My Imported Theme")
        XCTAssertEqual(result.theme.source, .user)
        XCTAssertEqual(result.theme.manifest.hero.focalPoint, .init(x: 0.25, y: 0.75))
        XCTAssertEqual(result.theme.heroAsset.format, .jpeg)
        XCTAssertEqual(try repository.loadUserThemes().map(\.manifest.id), [result.theme.manifest.id])

        let directoryMode = try permissions(at: result.theme.directoryURL)
        let themesRootMode = try permissions(at: repository.userThemesRoot)
        let imageMode = try permissions(at: result.theme.heroAsset.fileURL)
        let manifestMode = try permissions(
            at: result.theme.directoryURL.appendingPathComponent("theme.json")
        )
        XCTAssertEqual(themesRootMode, 0o700)
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(imageMode, 0o600)
        XCTAssertEqual(manifestMode, 0o600)
        XCTAssertEqual(try ownerIdentifier(at: repository.userThemesRoot), getuid())
        XCTAssertEqual(try ownerIdentifier(at: result.theme.directoryURL), getuid())

        let entries = try FileManager.default.contentsOfDirectory(
            at: repository.userThemesRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(entries.contains { $0.lastPathComponent.hasPrefix(".import-") })
    }

    func testServiceCleansStagingWhenInitialValidationFails() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("source.jpg")
        try encode(
            images: [try makeImage(width: 32, height: 20, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        ).write(to: sourceURL)

        let repository = try makeRepository()
        let service = ThemeImportService(repository: repository)
        let validDraft = try await service.prepare(sourceURL: sourceURL)
        let forgedDraft = ThemeImportDraft(
            id: validDraft.id,
            suggestedName: validDraft.suggestedName,
            sourceFileName: validDraft.sourceFileName,
            imageData: validDraft.imageData,
            format: .png,
            originalPixelWidth: validDraft.originalPixelWidth,
            originalPixelHeight: validDraft.originalPixelHeight,
            pixelWidth: validDraft.pixelWidth,
            pixelHeight: validDraft.pixelHeight,
            warnings: validDraft.warnings
        )

        await XCTAssertThrowsErrorAsync(
            try await service.commit(draft: forgedDraft)
        ) { error in
            guard case ThemeImportError.validationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: repository.userThemesRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(entries.isEmpty)
    }

    func testServiceRejectsSymlinkedUserThemeRootWithoutWritingThroughIt() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("source.jpg")
        try encode(
            images: [try makeImage(width: 32, height: 20, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        ).write(to: sourceURL)

        let bundledRoot = temporaryRoot.appendingPathComponent("Bundled", isDirectory: true)
        let redirectedRoot = temporaryRoot.appendingPathComponent("Redirected", isDirectory: true)
        let symlinkedUserRoot = temporaryRoot.appendingPathComponent("User", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundledRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: redirectedRoot,
            withIntermediateDirectories: true
        )
        let repository = ThemeRepository(
            bundledThemesRoot: bundledRoot,
            userThemesRoot: symlinkedUserRoot
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkedUserRoot,
            withDestinationURL: redirectedRoot
        )

        let service = ThemeImportService(repository: repository)
        let draft = try await service.prepare(sourceURL: sourceURL)

        await XCTAssertThrowsErrorAsync(
            try await service.commit(draft: draft)
        ) { error in
            XCTAssertEqual(
                error as? ThemeImportError,
                .unsafeThemeRoot(symlinkedUserRoot.path)
            )
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: redirectedRoot,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testServiceRejectsSymlinkInUserThemeRootAncestor() async throws {
        let bundledRoot = temporaryRoot.appendingPathComponent("Bundled", isDirectory: true)
        let redirectedAncestor = temporaryRoot.appendingPathComponent(
            "RedirectedAncestor",
            isDirectory: true
        )
        let symlinkedAncestor = temporaryRoot.appendingPathComponent(
            "LinkedAncestor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundledRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: redirectedAncestor,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkedAncestor,
            withDestinationURL: redirectedAncestor
        )

        let userRoot = symlinkedAncestor.appendingPathComponent("User", isDirectory: true)
        let repository = ThemeRepository(
            bundledThemesRoot: bundledRoot,
            userThemesRoot: userRoot
        )
        let service = ThemeImportService(repository: repository)
        let draft = try await makeJPEGDraft(for: service)

        await XCTAssertThrowsErrorAsync(
            try await service.commit(draft: draft)
        ) { error in
            XCTAssertEqual(error as? ThemeImportError, .unsafeThemeRoot(userRoot.path))
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: redirectedAncestor,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testServiceRejectsGroupOrWorldWritableOwnedThemeRoot() async throws {
        let repository = try makeRepository()
        try FileManager.default.createDirectory(
            at: repository.userThemesRoot,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(
            chmod(repository.userThemesRoot.path, mode_t(0o777)),
            0
        )

        let service = ThemeImportService(repository: repository)
        let draft = try await makeJPEGDraft(for: service)
        await XCTAssertThrowsErrorAsync(
            try await service.commit(draft: draft)
        ) { error in
            XCTAssertEqual(
                error as? ThemeImportError,
                .unsafeThemeRoot(repository.userThemesRoot.path)
            )
        }
    }

    func testServiceUsesDurableCommitOrderAndHardenedRenameFlags() async throws {
        let repository = try makeRepository()
        let recorder = LockedFileSystemEventRecorder()
        let configuration = ThemeImportFileSystemConfiguration(
            onEvent: recorder.record
        )
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let draft = try await makeJPEGDraft(for: service)

        _ = try await service.commit(draft: draft)

        let hardenedFlags = ThemeImportFileSystemConfiguration.renameFlags(
            supportsResolveBeneath: true
        )
        XCTAssertEqual(hardenedFlags & UInt32(RENAME_EXCL), UInt32(RENAME_EXCL))
        XCTAssertEqual(
            hardenedFlags & UInt32(RENAME_NOFOLLOW_ANY),
            UInt32(RENAME_NOFOLLOW_ANY)
        )
        XCTAssertEqual(
            hardenedFlags & UInt32(RENAME_RESOLVE_BENEATH),
            UInt32(RENAME_RESOLVE_BENEATH)
        )
        XCTAssertEqual(
            ThemeImportFileSystemConfiguration.renameFlags(
                supportsResolveBeneath: false
            ),
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        )
        let actualFlags = ThemeImportFileSystemConfiguration.renameFlagsForCurrentOS
        let synchronizedParents = recorder.events.compactMap { event -> String? in
            guard case let .parentDirectorySynchronized(component) = event else {
                return nil
            }
            return component
        }
        XCTAssertTrue(synchronizedParents.contains("User"))
        XCTAssertTrue(synchronizedParents.contains { $0.hasPrefix(".import-") })
        XCTAssertEqual(
            recorder.events.filter(\.isCommitDurabilityEvent),
            [
                .fileSynchronized(name: "hero.jpg", usedFullSync: true),
                .fileSynchronized(name: "theme.json", usedFullSync: true),
                .workspaceSynchronized,
                .willRename(flags: actualFlags),
                .didRename,
                .rootSynchronized,
            ]
        )
    }

    func testServiceFallsBackToFSyncWhenFullSyncIsUnsupported() async throws {
        let repository = try makeRepository()
        let recorder = LockedFileSystemEventRecorder()
        let configuration = ThemeImportFileSystemConfiguration(
            fullSync: { _ in
                errno = EINVAL
                return -1
            },
            sync: { Darwin.fsync($0) },
            onEvent: recorder.record
        )
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let draft = try await makeJPEGDraft(for: service)

        _ = try await service.commit(draft: draft)

        XCTAssertTrue(
            recorder.events.contains(
                .fileSynchronized(name: "hero.jpg", usedFullSync: false)
            )
        )
        XCTAssertTrue(
            recorder.events.contains(
                .fileSynchronized(name: "theme.json", usedFullSync: false)
            )
        )
    }

    func testServiceCancellationAtRenameBoundaryCleansOnlyOwnedStaging() async throws {
        let repository = try makeRepository()
        let configuration = ThemeImportFileSystemConfiguration(onEvent: { event in
            guard case .willRename = event else { return }
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        })
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let draft = try await makeJPEGDraft(for: service)
        let commitTask = Task<ThemeImportResult, Error> {
            try await service.commit(draft: draft)
        }

        await XCTAssertThrowsErrorAsync(try await commitTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: repository.userThemesRoot,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testCancellationAfterRootSynchronizationPerformsObservableDurableRollback() async throws {
        let repository = try makeRepository()
        let recorder = LockedFileSystemEventRecorder()
        let configuration = ThemeImportFileSystemConfiguration(onEvent: { event in
            recorder.record(event)
            guard case .rootSynchronized = event else { return }
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        })
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let draft = try await makeJPEGDraft(for: service)
        let commitTask = Task<ThemeImportResult, Error> {
            try await service.commit(draft: draft)
        }

        await XCTAssertThrowsErrorAsync(try await commitTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: repository.userThemesRoot,
                includingPropertiesForKeys: nil
            ).isEmpty
        )

        let events = recorder.events
        XCTAssertTrue(events.contains { event in
            if case .rollbackStarted = event { return true }
            return false
        })
        XCTAssertTrue(
            events.contains(
                .rollbackOperationSucceeded(.unlinkFile(name: "hero.jpg"))
            )
        )
        XCTAssertTrue(
            events.contains(
                .rollbackOperationSucceeded(.unlinkFile(name: "theme.json"))
            )
        )
        let workspaceSyncIndex = try XCTUnwrap(
            events.firstIndex(
                of: .rollbackOperationSucceeded(.synchronizeWorkspace)
            )
        )
        let removeIndex = try XCTUnwrap(
            events.firstIndex { event in
                guard case .rollbackOperationSucceeded(.removeDirectory) = event else {
                    return false
                }
                return true
            }
        )
        let rootSyncIndex = try XCTUnwrap(
            events.firstIndex(of: .rollbackOperationSucceeded(.synchronizeRoot))
        )
        let completedIndex = try XCTUnwrap(
            events.firstIndex(of: .rollbackCompleted(failureCount: 0))
        )
        XCTAssertLessThan(workspaceSyncIndex, removeIndex)
        XCTAssertLessThan(removeIndex, rootSyncIndex)
        XCTAssertLessThan(rootSyncIndex, completedIndex)
    }

    func testRollbackUnlinkFailureReportsPrimaryAndRollbackAndRetainsOwnedFinal() async throws {
        let repository = try makeRepository()
        let recorder = LockedFileSystemEventRecorder()
        let configuration = ThemeImportFileSystemConfiguration(
            rollbackInjectedError: { operation in
                guard operation == .unlinkFile(name: "hero.jpg") else { return nil }
                return EIO
            },
            onEvent: { event in
                recorder.record(event)
                guard case .rootSynchronized = event else { return }
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let draft = try await makeJPEGDraft(for: service)
        let commitTask = Task<ThemeImportResult, Error> {
            try await service.commit(draft: draft)
        }

        await XCTAssertThrowsErrorAsync(try await commitTask.value) { error in
            guard case let ThemeImportError.rollbackFailed(primary, failures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(primary, "CancellationError")
            XCTAssertTrue(
                failures.contains {
                    $0.contains("unlink file hero.jpg") && $0.contains("errno \(EIO)")
                }
            )
        }
        XCTAssertTrue(
            recorder.events.contains(
                .rollbackOperationFailed(
                    operation: .unlinkFile(name: "hero.jpg"),
                    errorCode: EIO
                )
            )
        )
        let finalDirectory = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: repository.userThemesRoot,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("user-") }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: finalDirectory.appendingPathComponent("hero.jpg").path
            )
        )
    }

    func testRollbackSynchronizationFailuresReportPrimaryAndBothDurabilityFailures() async throws {
        let repository = try makeRepository()
        let recorder = LockedFileSystemEventRecorder()
        let configuration = ThemeImportFileSystemConfiguration(
            rollbackInjectedError: { operation in
                switch operation {
                case .synchronizeWorkspace, .synchronizeRoot:
                    EIO
                default:
                    nil
                }
            },
            onEvent: { event in
                recorder.record(event)
                guard case .rootSynchronized = event else { return }
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let draft = try await makeJPEGDraft(for: service)
        let commitTask = Task<ThemeImportResult, Error> {
            try await service.commit(draft: draft)
        }

        await XCTAssertThrowsErrorAsync(try await commitTask.value) { error in
            guard case let ThemeImportError.rollbackFailed(primary, failures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(primary, "CancellationError")
            XCTAssertTrue(failures.contains { $0.contains("sync workspace") })
            XCTAssertTrue(failures.contains { $0.contains("sync root") })
            XCTAssertTrue(failures.allSatisfy { $0.contains("errno \(EIO)") })
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: repository.userThemesRoot,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
        XCTAssertTrue(
            recorder.events.contains(
                .rollbackOperationFailed(
                    operation: .synchronizeWorkspace,
                    errorCode: EIO
                )
            )
        )
        XCTAssertTrue(
            recorder.events.contains(
                .rollbackOperationFailed(operation: .synchronizeRoot, errorCode: EIO)
            )
        )
    }

    func testCleanupDoesNotDeleteAReplacedFileWithDifferentIdentity() async throws {
        let repository = try makeRepository()
        let replacement = Data("replacement owned by another writer".utf8)
        let configuration = ThemeImportFileSystemConfiguration(onEvent: { event in
            guard case let .willCleanup(directoryURL) = event else { return }
            let original = directoryURL.appendingPathComponent("hero.png")
            let attacker = directoryURL.appendingPathComponent("attacker.tmp")
            try? replacement.write(to: attacker)
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.moveItem(at: attacker, to: original)
        })
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let validDraft = try await makeJPEGDraft(for: service)
        let forgedDraft = ThemeImportDraft(
            id: validDraft.id,
            suggestedName: validDraft.suggestedName,
            sourceFileName: validDraft.sourceFileName,
            imageData: validDraft.imageData,
            format: .png,
            originalPixelWidth: validDraft.originalPixelWidth,
            originalPixelHeight: validDraft.originalPixelHeight,
            pixelWidth: validDraft.pixelWidth,
            pixelHeight: validDraft.pixelHeight,
            warnings: validDraft.warnings
        )

        await XCTAssertThrowsErrorAsync(
            try await service.commit(draft: forgedDraft)
        ) { error in
            guard case let ThemeImportError.rollbackFailed(primary, failures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(primary.contains("安全校验"))
            XCTAssertTrue(failures.contains { $0.contains("unlink file hero.png") })
        }

        let stagingDirectories = try FileManager.default.contentsOfDirectory(
            at: repository.userThemesRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".import-") }
        let stagingDirectory = try XCTUnwrap(stagingDirectories.first)
        XCTAssertEqual(stagingDirectories.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: stagingDirectory.appendingPathComponent("hero.png")),
            replacement
        )
    }

    func testRenameBoundaryRejectsAReplacedCreatedFileIdentity() async throws {
        let repository = try makeRepository()
        let replacement = Data("replacement before rename".utf8)
        let configuration = ThemeImportFileSystemConfiguration(onEvent: { event in
            guard case .willRename = event,
                  let stagingDirectory = try? FileManager.default
                      .contentsOfDirectory(
                          at: repository.userThemesRoot,
                          includingPropertiesForKeys: nil
                      )
                      .first(where: { $0.lastPathComponent.hasPrefix(".import-") })
            else {
                return
            }
            let original = stagingDirectory.appendingPathComponent("hero.jpg")
            let attacker = stagingDirectory.appendingPathComponent("attacker.tmp")
            try? replacement.write(to: attacker)
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.moveItem(at: attacker, to: original)
        })
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let draft = try await makeJPEGDraft(for: service)

        await XCTAssertThrowsErrorAsync(
            try await service.commit(draft: draft)
        ) { error in
            guard case let ThemeImportError.rollbackFailed(primary, failures) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(primary.contains("hero.jpg"))
            XCTAssertTrue(failures.contains { $0.contains("unlink file hero.jpg") })
        }

        let stagingDirectory = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: repository.userThemesRoot,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(".import-") }
        )
        XCTAssertEqual(
            try Data(contentsOf: stagingDirectory.appendingPathComponent("hero.jpg")),
            replacement
        )
    }

    func testWorkspaceOpenFailureLeavesUnverifiedEntryUntouched() async throws {
        let repository = try makeRepository()
        let redirectedDirectory = temporaryRoot.appendingPathComponent(
            "RedirectedWorkspace",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: redirectedDirectory,
            withIntermediateDirectories: false
        )
        let configuration = ThemeImportFileSystemConfiguration(onEvent: { event in
            guard case let .parentDirectorySynchronized(component) = event,
                  component.hasPrefix(".import-")
            else {
                return
            }
            let stagingURL = repository.userThemesRoot.appendingPathComponent(
                component,
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.createSymbolicLink(
                at: stagingURL,
                withDestinationURL: redirectedDirectory
            )
        })
        let service = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let draft = try await makeJPEGDraft(for: service)

        await XCTAssertThrowsErrorAsync(
            try await service.commit(draft: draft)
        ) { error in
            guard case ThemeImportError.fileSystem = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: repository.userThemesRoot,
            includingPropertiesForKeys: nil
        )
        let untouchedEntry = try XCTUnwrap(
            entries.first { $0.lastPathComponent.hasPrefix(".import-") }
        )
        var metadata = stat()
        XCTAssertEqual(lstat(untouchedEntry.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: redirectedDirectory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testServiceThemeRootLockTimesOutWithoutCreatingAWorkspace() async throws {
        let repository = try makeRepository()
        let firstService = ThemeImportService(repository: repository)
        let firstDraft = try await makeJPEGDraft(for: firstService)
        _ = try await firstService.commit(draft: firstDraft)

        let lockDescriptor = open(
            repository.userThemesRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(lockDescriptor, 0)
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        XCTAssertEqual(flock(lockDescriptor, LOCK_EX | LOCK_NB), 0)

        let configuration = ThemeImportFileSystemConfiguration(
            lockTimeout: .milliseconds(100),
            lockRetryInterval: .milliseconds(5)
        )
        let secondService = ThemeImportService(
            repository: repository,
            fileSystem: configuration
        )
        let secondDraft = try await makeJPEGDraft(for: secondService)
        let start = ContinuousClock.now

        await XCTAssertThrowsErrorAsync(
            try await secondService.commit(draft: secondDraft)
        ) { error in
            guard case let ThemeImportError.fileSystem(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("正在被另一个导入事务占用"))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let entries = try FileManager.default.contentsOfDirectory(
            at: repository.userThemesRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(entries.filter { $0.lastPathComponent.hasPrefix("user-") }.count, 1)
        XCTAssertFalse(entries.contains { $0.lastPathComponent.hasPrefix(".import-") })
    }

    func testServiceHonorsPreexistingCancellationWithoutCreatingThemeRoot() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("source.jpg")
        try encode(
            images: [try makeImage(width: 32, height: 20, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        ).write(to: sourceURL)

        let repository = try makeRepository()
        let service = ThemeImportService(repository: repository)
        let draft = try await service.prepare(sourceURL: sourceURL)
        let commitTask = Task<ThemeImportResult, Error> {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await service.commit(draft: draft)
        }

        await XCTAssertThrowsErrorAsync(try await commitTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repository.userThemesRoot.path)
        )
    }

    private func makeRepository() throws -> ThemeRepository {
        let bundledRoot = temporaryRoot.appendingPathComponent("Bundled", isDirectory: true)
        let userRoot = temporaryRoot.appendingPathComponent("User", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundledRoot,
            withIntermediateDirectories: true
        )
        return ThemeRepository(
            bundledThemesRoot: bundledRoot,
            userThemesRoot: userRoot
        )
    }

    private func makeJPEGDraft(
        for service: ThemeImportService
    ) async throws -> ThemeImportDraft {
        let sourceURL = temporaryRoot.appendingPathComponent("source-\(UUID().uuidString).jpg")
        try encode(
            images: [try makeImage(width: 32, height: 20, hasAlpha: false)],
            typeIdentifier: UTType.jpeg.identifier
        ).write(to: sourceURL)
        return try await service.prepare(sourceURL: sourceURL)
    }

    private func makeImage(
        width: Int,
        height: Int,
        hasAlpha: Bool,
        fillAlpha: CGFloat? = nil
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else {
            throw TestFailure.fixtureCreationFailed
        }
        context.setFillColor(
            red: 0.12,
            green: 0.42,
            blue: 0.74,
            alpha: fillAlpha ?? (hasAlpha ? 0.5 : 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestFailure.fixtureCreationFailed
        }
        return image
    }

    private func encode(
        images: [CGImage],
        typeIdentifier: String,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            typeIdentifier as CFString,
            images.count,
            nil
        ) else {
            throw TestFailure.fixtureCreationFailed
        }
        for image in images {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw TestFailure.fixtureCreationFailed
        }
        return output as Data
    }

    private func makeNoisyTransparentImage(width: Int, height: Int) throws -> CGImage {
        var seed: UInt32 = 0x1234_5678
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let buffer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for pixel in 0 ..< (width * height) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let alpha: UInt8 = 192
                buffer[pixel * 4] = UInt8((seed >> 16) & 0x7f)
                buffer[pixel * 4 + 1] = UInt8((seed >> 8) & 0x7f)
                buffer[pixel * 4 + 2] = UInt8(seed & 0x7f)
                buffer[pixel * 4 + 3] = alpha
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            throw TestFailure.fixtureCreationFailed
        }
        return image
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return number.intValue & 0o777
    }

    private func ownerIdentifier(at url: URL) throws -> uid_t {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try XCTUnwrap(attributes[.ownerAccountID] as? NSNumber)
        return uid_t(number.uint32Value)
    }
}

private extension ThemeImportFileSystemEvent {
    var isCommitDurabilityEvent: Bool {
        switch self {
        case .fileSynchronized,
             .workspaceSynchronized,
             .willRename,
             .didRename,
             .rootSynchronized:
            true
        case .parentDirectorySynchronized,
             .willCleanup,
             .rollbackStarted,
             .rollbackOperationSucceeded,
             .rollbackOperationFailed,
             .rollbackCompleted:
            false
        }
    }
}

private final class LockedFileSystemEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [ThemeImportFileSystemEvent] = []

    var events: [ThemeImportFileSystemEvent] {
        lock.withLock { storedEvents }
    }

    func record(_ event: ThemeImportFileSystemEvent) {
        lock.withLock {
            storedEvents.append(event)
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            errorHandler(error)
        }
    }
}

private enum TestFailure: Error {
    case fixtureCreationFailed
}
