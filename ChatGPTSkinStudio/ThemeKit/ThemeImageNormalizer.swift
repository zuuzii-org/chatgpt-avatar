import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ThemeImageNormalizerReadEvent: Equatable, Sendable {
    case didInspectSource(URL)
    case didOpenSource(URL)
    case didReadSource(URL)
}

struct ThemeImageNormalizerFileSystemHooks: Sendable {
    let onEvent: @Sendable (ThemeImageNormalizerReadEvent) -> Void

    init(
        onEvent: @escaping @Sendable (ThemeImageNormalizerReadEvent) -> Void = { _ in }
    ) {
        self.onEvent = onEvent
    }
}

struct ThemeImageNormalizer: Sendable {
    let policy: ThemeImageNormalizationPolicy
    private let fileSystemHooks: ThemeImageNormalizerFileSystemHooks

    init(
        policy: ThemeImageNormalizationPolicy = .default,
        fileSystemHooks: ThemeImageNormalizerFileSystemHooks = .init()
    ) {
        self.policy = policy
        self.fileSystemHooks = fileSystemHooks
    }

    func prepare(sourceURL: URL) throws -> ThemeImportDraft {
        try Task.checkCancellation()
        let didStartSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceData = try readRegularFile(at: sourceURL)
        guard let imageSource = CGImageSourceCreateWithData(
            sourceData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ThemeImportError.invalidImage
        }

        guard CGImageSourceGetStatus(imageSource) == .statusComplete else {
            throw ThemeImportError.invalidImage
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount == 1 else {
            if frameCount > 1 {
                throw ThemeImportError.animatedOrMultiFrame(frameCount: frameCount)
            }
            throw ThemeImportError.invalidImage
        }
        guard CGImageSourceGetStatusAtIndex(imageSource, 0) == .statusComplete else {
            throw ThemeImportError.invalidImage
        }

        let sourceFormat = try detectSourceFormat(imageSource)
        try validateExtension(sourceURL.pathExtension, for: sourceFormat)

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any],
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw ThemeImportError.invalidImage
        }

        let rawWidth = widthNumber.intValue
        let rawHeight = heightNumber.intValue
        guard rawWidth > 0, rawHeight > 0 else {
            throw ThemeImportError.invalidImage
        }
        let (sourcePixelCount, sourcePixelOverflow) = rawWidth.multipliedReportingOverflow(
            by: rawHeight
        )
        guard !sourcePixelOverflow,
              sourcePixelCount <= policy.maximumSourcePixelCount
        else {
            throw ThemeImportError.sourcePixelLimitExceeded(
                width: rawWidth,
                height: rawHeight
            )
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5 ... 8).contains(orientation)
        let orientedWidth = swapsAxes ? rawHeight : rawWidth
        let orientedHeight = swapsAxes ? rawWidth : rawHeight
        var targetLongEdge = targetLongEdge(
            width: orientedWidth,
            height: orientedHeight
        )
        var jpegQuality = policy.initialJPEGQuality
        var lastEncodedByteCount = 0

        for _ in 0 ..< policy.maximumEncodingAttempts {
            try Task.checkCancellation()
            guard let image = makeOrientedThumbnail(
                from: imageSource,
                maximumLongEdge: targetLongEdge
            ) else {
                throw ThemeImportError.invalidImage
            }
            guard image.width > 0, image.height > 0 else {
                throw ThemeImportError.invalidImage
            }
            let (outputPixelCount, outputPixelOverflow) = image.width.multipliedReportingOverflow(
                by: image.height
            )
            guard !outputPixelOverflow,
                  outputPixelCount <= policy.maximumOutputPixelCount,
                  max(image.width, image.height) <= policy.maximumLongEdge
            else {
                throw ThemeImportError.normalizationFailed(
                    "系统解码结果超过导入输出尺寸限制。"
                )
            }

            let outputFormat: ThemeImageFormat = hasTransparency(image) ? .png : .jpeg
            let encoded = try encode(
                image,
                format: outputFormat,
                jpegQuality: jpegQuality
            )
            lastEncodedByteCount = encoded.count

            if encoded.count <= policy.maximumOutputBytes {
                var warnings: [ThemeImportWarning] = []
                if image.width < orientedWidth || image.height < orientedHeight {
                    warnings.append(
                        .downsampled(
                            originalWidth: orientedWidth,
                            originalHeight: orientedHeight,
                            outputWidth: image.width,
                            outputHeight: image.height
                        )
                    )
                }
                if image.width < policy.lowResolutionWidth
                    || image.height < policy.lowResolutionHeight
                {
                    warnings.append(
                        .lowResolution(width: image.width, height: image.height)
                    )
                }

                return ThemeImportDraft(
                    id: UUID(),
                    suggestedName: Self.suggestedThemeName(for: sourceURL),
                    sourceFileName: sourceURL.lastPathComponent,
                    imageData: encoded,
                    format: outputFormat,
                    originalPixelWidth: orientedWidth,
                    originalPixelHeight: orientedHeight,
                    pixelWidth: image.width,
                    pixelHeight: image.height,
                    warnings: warnings
                )
            }

            if outputFormat == .jpeg,
               jpegQuality - policy.jpegQualityStep >= policy.minimumJPEGQuality
            {
                jpegQuality -= policy.jpegQualityStep
                continue
            }

            let currentLongEdge = max(image.width, image.height)
            guard currentLongEdge > 1 else { break }
            let byteRatio = Double(policy.maximumOutputBytes) / Double(encoded.count)
            let estimatedScale = sqrt(max(0.01, byteRatio)) * 0.96
            let reductionScale = min(
                policy.dimensionReductionFactor,
                max(0.25, estimatedScale)
            )
            let nextLongEdge = max(1, Int((Double(currentLongEdge) * reductionScale).rounded(.down)))
            guard nextLongEdge < currentLongEdge else { break }
            targetLongEdge = nextLongEdge
            jpegQuality = policy.initialJPEGQuality
        }

        throw ThemeImportError.outputTooLarge(
            bytes: lastEncodedByteCount,
            maximumBytes: policy.maximumOutputBytes
        )
    }

    private func readRegularFile(at sourceURL: URL) throws -> Data {
        let lexicalURL = sourceURL.standardizedFileURL
        var lexicalMetadata = stat()
        let lstatResult = lexicalURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &lexicalMetadata)
        }
        let lstatError = lstatResult == 0 ? 0 : errno
        guard lstatResult == 0 else {
            if lstatError == ENOENT { throw ThemeImportError.sourceMissing }
            throw ThemeImportError.fileSystem(Self.posixErrorDescription(lstatError))
        }
        let inspectedSnapshot = SourceFileSnapshot(lexicalMetadata)
        if inspectedSnapshot.fileType == S_IFLNK {
            throw ThemeImportError.sourceIsSymbolicLink
        }
        guard inspectedSnapshot.fileType == S_IFREG else {
            throw ThemeImportError.sourceNotRegularFile
        }
        fileSystemHooks.onEvent(.didInspectSource(lexicalURL))

        let fileDescriptor: Int32 = lexicalURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        let openError = fileDescriptor >= 0 ? 0 : errno
        guard fileDescriptor >= 0 else {
            if openError == ELOOP { throw ThemeImportError.sourceIsSymbolicLink }
            if openError == ENOENT { throw ThemeImportError.sourceMissing }
            throw ThemeImportError.fileSystem(Self.posixErrorDescription(openError))
        }
        defer { Darwin.close(fileDescriptor) }

        var openedMetadata = stat()
        let fstatResult = Darwin.fstat(fileDescriptor, &openedMetadata)
        let fstatError = fstatResult == 0 ? 0 : errno
        guard fstatResult == 0 else {
            throw ThemeImportError.fileSystem(Self.posixErrorDescription(fstatError))
        }
        let openedSnapshot = SourceFileSnapshot(openedMetadata)
        guard openedSnapshot.fileType == S_IFREG else {
            throw ThemeImportError.sourceNotRegularFile
        }
        guard inspectedSnapshot == openedSnapshot else {
            throw ThemeImportError.normalizationFailed("源图片在检查与打开之间发生变化。")
        }
        fileSystemHooks.onEvent(.didOpenSource(lexicalURL))

        guard openedSnapshot.size > 0 else {
            throw ThemeImportError.sourceEmpty
        }
        guard openedSnapshot.size <= policy.maximumSourceBytes else {
            throw ThemeImportError.sourceTooLarge(
                bytes: Int(clamping: openedSnapshot.size),
                maximumBytes: policy.maximumSourceBytes
            )
        }
        guard let byteCount = Int(exactly: openedSnapshot.size) else {
            throw ThemeImportError.sourceTooLarge(
                bytes: Int.max,
                maximumBytes: policy.maximumSourceBytes
            )
        }

        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { buffer in
            guard byteCount == 0 || buffer.baseAddress != nil else {
                throw ThemeImportError.normalizationFailed("无法分配源图片缓冲区。")
            }
            var offset = 0
            while offset < byteCount {
                try Task.checkCancellation()
                let count = Darwin.read(
                    fileDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    byteCount - offset
                )
                if count < 0 {
                    let readError = errno
                    if readError == EINTR { continue }
                    throw ThemeImportError.fileSystem(
                        Self.posixErrorDescription(readError)
                    )
                }
                guard count > 0 else {
                    throw ThemeImportError.normalizationFailed("源图片在读取期间发生变化。")
                }
                offset += count
            }
        }

        var trailingByte: UInt8 = 0
        var trailingCount: Int
        repeat {
            trailingCount = Darwin.read(fileDescriptor, &trailingByte, 1)
        } while trailingCount < 0 && errno == EINTR
        guard trailingCount >= 0 else {
            let readError = errno
            throw ThemeImportError.fileSystem(Self.posixErrorDescription(readError))
        }
        guard trailingCount == 0 else {
            throw ThemeImportError.normalizationFailed("源图片在读取期间发生大小变化。")
        }
        fileSystemHooks.onEvent(.didReadSource(lexicalURL))

        var finalOpenedMetadata = stat()
        let finalFStatResult = Darwin.fstat(fileDescriptor, &finalOpenedMetadata)
        guard finalFStatResult == 0 else {
            let finalFStatError = errno
            throw ThemeImportError.fileSystem(Self.posixErrorDescription(finalFStatError))
        }
        var finalLexicalMetadata = stat()
        let finalLStatResult = lexicalURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &finalLexicalMetadata)
        }
        guard finalLStatResult == 0 else {
            throw ThemeImportError.normalizationFailed("源图片在读取期间发生变化。")
        }
        let finalOpenedSnapshot = SourceFileSnapshot(finalOpenedMetadata)
        let finalLexicalSnapshot = SourceFileSnapshot(finalLexicalMetadata)
        guard finalOpenedSnapshot == openedSnapshot,
              finalLexicalSnapshot == openedSnapshot
        else {
            throw ThemeImportError.normalizationFailed("源图片在读取期间发生变化。")
        }
        return data
    }

    private func detectSourceFormat(_ imageSource: CGImageSource) throws -> SourceFormat {
        guard let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier)
        else {
            throw ThemeImportError.unsupportedSourceFormat("unknown")
        }

        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .webP) { return .webp }
        if type.conforms(to: .heic) { return .heic }
        if let heif = UTType("public.heif"), type.conforms(to: heif) { return .heif }
        throw ThemeImportError.unsupportedSourceFormat(typeIdentifier)
    }

    private func validateExtension(_ extensionName: String, for format: SourceFormat) throws {
        let normalizedExtension = extensionName.lowercased()
        guard format.allowedExtensions.contains(normalizedExtension) else {
            throw ThemeImportError.disguisedSourceExtension(
                extensionName: normalizedExtension.isEmpty ? "(none)" : normalizedExtension,
                actualFormat: format.presentationName
            )
        }
    }

    private func targetLongEdge(width: Int, height: Int) -> Int {
        let longestEdge = max(width, height)
        let pixelCount = Double(width) * Double(height)
        let pixelScale = min(
            1,
            sqrt(Double(policy.maximumOutputPixelCount) / pixelCount)
        )
        let edgeScale = min(
            1,
            Double(policy.maximumLongEdge) / Double(longestEdge)
        )
        return max(1, Int((Double(longestEdge) * min(pixelScale, edgeScale)).rounded(.down)))
    }

    private func makeOrientedThumbnail(
        from source: CGImageSource,
        maximumLongEdge: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumLongEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func encode(
        _ image: CGImage,
        format: ThemeImageFormat,
        jpegQuality: Double
    ) throws -> Data {
        let typeIdentifier: String
        let properties: [CFString: Any]
        switch format {
        case .png:
            typeIdentifier = UTType.png.identifier
            properties = [:]
        case .jpeg:
            typeIdentifier = UTType.jpeg.identifier
            properties = [
                kCGImageDestinationLossyCompressionQuality: jpegQuality,
            ]
        case .webp:
            throw ThemeImportError.normalizationFailed("规格化输出不应使用 WebP。")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ThemeImportError.normalizationFailed("系统无法创建图片编码器。")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ThemeImportError.normalizationFailed("系统无法完成图片编码。")
        }
        return output as Data
    }

    private func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            break
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return true
        }

        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, pixelCount > 0 else { return true }
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow else { return true }
        var rgbaBytes = [UInt8](repeating: 0, count: byteCount)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rendered = rgbaBytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return false
            }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard rendered else { return true }
        return stride(from: 3, to: rgbaBytes.count, by: 4).contains {
            rgbaBytes[$0] < 255
        }
    }

    private static func suggestedThemeName(for sourceURL: URL) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let withoutControls = baseName.components(separatedBy: .controlCharacters).joined(separator: " ")
        let collapsed = withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Imported Theme" : trimmed
        return String(fallback.prefix(100))
    }

    private static func posixErrorDescription(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }
}

private struct SourceFileSnapshot: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let fileType: mode_t
    let size: off_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        owner = metadata.st_uid
        fileType = metadata.st_mode & S_IFMT
        size = metadata.st_size
        modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(metadata.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }
}

private enum SourceFormat {
    case png
    case jpeg
    case webp
    case heic
    case heif

    var allowedExtensions: Set<String> {
        switch self {
        case .png: ["png"]
        case .jpeg: ["jpg", "jpeg"]
        case .webp: ["webp"]
        case .heic: ["heic"]
        case .heif: ["heif", "hif"]
        }
    }

    var presentationName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .heic: "HEIC"
        case .heif: "HEIF"
        }
    }
}
