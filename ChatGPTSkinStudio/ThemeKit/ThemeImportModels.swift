import Foundation

struct ThemeImageNormalizationPolicy: Equatable, Sendable {
    static let `default` = ThemeImageNormalizationPolicy()

    let maximumSourceBytes: Int
    let maximumSourcePixelCount: Int
    let maximumLongEdge: Int
    let maximumOutputPixelCount: Int
    let maximumOutputBytes: Int
    let maximumEncodingAttempts: Int
    let initialJPEGQuality: Double
    let minimumJPEGQuality: Double
    let jpegQualityStep: Double
    let dimensionReductionFactor: Double
    let lowResolutionWidth: Int
    let lowResolutionHeight: Int

    init(
        maximumSourceBytes: Int = 128 * 1024 * 1024,
        maximumSourcePixelCount: Int = 64_000_000,
        maximumLongEdge: Int = 3_840,
        maximumOutputPixelCount: Int = 12_000_000,
        maximumOutputBytes: Int = 12 * 1024 * 1024,
        maximumEncodingAttempts: Int = 24,
        initialJPEGQuality: Double = 0.9,
        minimumJPEGQuality: Double = 0.7,
        jpegQualityStep: Double = 0.1,
        dimensionReductionFactor: Double = 0.82,
        lowResolutionWidth: Int = 1_600,
        lowResolutionHeight: Int = 900
    ) {
        precondition(maximumSourceBytes > 0)
        precondition(maximumSourcePixelCount > 0)
        precondition(maximumLongEdge > 0)
        precondition(maximumOutputPixelCount > 0)
        precondition(maximumOutputBytes > 0)
        precondition(maximumEncodingAttempts > 0)
        precondition((0 ... 1).contains(initialJPEGQuality))
        precondition((0 ... initialJPEGQuality).contains(minimumJPEGQuality))
        precondition(jpegQualityStep > 0)
        precondition((0 ..< 1).contains(dimensionReductionFactor))
        precondition(lowResolutionWidth > 0)
        precondition(lowResolutionHeight > 0)

        self.maximumSourceBytes = maximumSourceBytes
        self.maximumSourcePixelCount = maximumSourcePixelCount
        self.maximumLongEdge = maximumLongEdge
        self.maximumOutputPixelCount = maximumOutputPixelCount
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumEncodingAttempts = maximumEncodingAttempts
        self.initialJPEGQuality = initialJPEGQuality
        self.minimumJPEGQuality = minimumJPEGQuality
        self.jpegQualityStep = jpegQualityStep
        self.dimensionReductionFactor = dimensionReductionFactor
        self.lowResolutionWidth = lowResolutionWidth
        self.lowResolutionHeight = lowResolutionHeight
    }
}

enum ThemeImportWarning: Equatable, Sendable {
    case downsampled(
        originalWidth: Int,
        originalHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    )
    case lowResolution(width: Int, height: Int)
}

struct ThemeImportDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let suggestedName: String
    let sourceFileName: String
    let imageData: Data
    let format: ThemeImageFormat
    let originalPixelWidth: Int
    let originalPixelHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let warnings: [ThemeImportWarning]
}

struct ThemeImportResult: Equatable, Sendable {
    let theme: LoadedTheme
    let warnings: [ThemeImportWarning]
}

enum ThemeImportError: Error, Equatable, LocalizedError, Sendable {
    case sourceMissing
    case sourceIsSymbolicLink
    case sourceNotRegularFile
    case sourceEmpty
    case sourceTooLarge(bytes: Int, maximumBytes: Int)
    case sourcePixelLimitExceeded(width: Int, height: Int)
    case unsupportedSourceFormat(String)
    case disguisedSourceExtension(extensionName: String, actualFormat: String)
    case animatedOrMultiFrame(frameCount: Int)
    case invalidImage
    case normalizationFailed(String)
    case outputTooLarge(bytes: Int, maximumBytes: Int)
    case invalidThemeName
    case invalidFocalPoint
    case unsafeThemeRoot(String)
    case unableToAllocateThemeID
    case fileSystem(String)
    case rollbackFailed(primary: String, rollbackFailures: [String])
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "所选图片不存在。"
        case .sourceIsSymbolicLink:
            "不允许从符号链接导入主题图片。"
        case .sourceNotRegularFile:
            "所选项目不是普通图片文件。"
        case .sourceEmpty:
            "所选图片是空文件。"
        case let .sourceTooLarge(bytes, maximumBytes):
            "源图片文件过大：\(bytes) bytes，最大允许 \(maximumBytes) bytes。"
        case let .sourcePixelLimitExceeded(width, height):
            "源图片像素尺寸过大：\(width)×\(height)。"
        case let .unsupportedSourceFormat(format):
            "不支持该图片格式：\(format)。"
        case let .disguisedSourceExtension(extensionName, actualFormat):
            "图片扩展名 .\(extensionName) 与真实格式 \(actualFormat) 不匹配。"
        case let .animatedOrMultiFrame(frameCount):
            "主题图片必须是单帧静态图片；当前文件包含 \(frameCount) 帧。"
        case .invalidImage:
            "所选文件不是可完整解码的图片。"
        case let .normalizationFailed(message):
            "图片规格化失败：\(message)"
        case let .outputTooLarge(bytes, maximumBytes):
            "规格化图片仍然过大：\(bytes) bytes，最大允许 \(maximumBytes) bytes。"
        case .invalidThemeName:
            "主题名称必须包含 1 到 100 个可见字符。"
        case .invalidFocalPoint:
            "图片焦点必须位于 0...1 的画布范围内。"
        case let .unsafeThemeRoot(path):
            "用户主题目录不安全：\(path)"
        case .unableToAllocateThemeID:
            "无法分配唯一的用户主题 ID。"
        case let .fileSystem(message):
            "主题文件系统操作失败：\(message)"
        case let .rollbackFailed(primary, rollbackFailures):
            "主题导入失败，且 durable rollback 未完整完成。原始错误：\(primary)；回滚错误：\(rollbackFailures.joined(separator: "；"))"
        case let .validationFailed(message):
            "生成的主题未通过安全校验：\(message)"
        }
    }
}
