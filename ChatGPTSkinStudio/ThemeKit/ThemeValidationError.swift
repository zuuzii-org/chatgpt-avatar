import Foundation

enum ThemeValidationError: Error, Equatable, LocalizedError, Sendable {
    case themeDirectoryMissing(String)
    case manifestMissing(String)
    case manifestTooLarge(Int)
    case malformedManifest(String)
    case unknownKey(path: String, key: String)
    case forbiddenRemoteValue(String)
    case unsupportedSchema(Int)
    case invalidID(String)
    case invalidName
    case invalidColor(field: String, value: String)
    case invalidAssetName(String)
    case missingHeroAsset(String)
    case invalidNormalizedValue(String)
    case invalidSafeArea
    case invalidGlassConfiguration(String)
    case invalidCompatibility
    case invalidRelativePath(String)
    case unsupportedAssetExtension(String)
    case assetEscapesTheme(String)
    case assetMissing(String)
    case assetNotRegularFile(String)
    case assetTooLarge(path: String, bytes: Int)
    case invalidSHA256(path: String)
    case sha256Mismatch(path: String)
    case invalidImage(String)
    case unsupportedImageFormat(String)
    case imageFormatMismatch(path: String, declared: ThemeImageFormat, actual: ThemeImageFormat)
    case pixelLimitExceeded(path: String, width: Int, height: Int)
    case imageDimensionsMismatch(path: String, expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case prohibitedExecutableAsset(String)
    case duplicateThemeID(String)
    case fileSystem(String)
    // schema v3.1 扩展校验错误
    case invalidSVGViewBox(String)
    case svgBodyTooLarge(bytes: Int)
    case svgBodyUnsafe(detail: String)
    case iconPathTooLarge(match: String, bytes: Int)
    case iconPathUnsafe(match: String, detail: String)
    case iconPathMustStartWithCommand(match: String)
    case tooManyIconOverrides(field: String, count: Int)
    case invalidIconMatch(String)
    case extensionTextTooLong(field: String, length: Int)
    case extensionTextUnsafe(field: String)
    case invalidAnchorText(String)
    case invalidBrandMarkSize(Double)
    case invalidWordmarkSlotPadding(Double)

    var errorDescription: String? {
        switch self {
        case let .themeDirectoryMissing(path):
            "主题目录不存在：\(path)"
        case let .manifestMissing(path):
            "主题缺少 theme.json：\(path)"
        case let .manifestTooLarge(bytes):
            "theme.json 过大：\(bytes) bytes"
        case let .malformedManifest(message):
            "theme.json 无法解析：\(message)"
        case let .unknownKey(path, key):
            "主题包含不支持的字段：\(path).\(key)"
        case let .forbiddenRemoteValue(value):
            "主题不允许远程或可执行 URL：\(value)"
        case let .unsupportedSchema(version):
            "不支持 Theme Schema v\(version)"
        case let .invalidID(id):
            "主题 ID 非法：\(id)"
        case .invalidName:
            "主题名称必须为 1 到 100 个字符且不能带首尾空白"
        case let .invalidColor(field, value):
            "主题颜色非法：\(field)=\(value)"
        case let .invalidAssetName(name):
            "资源名称非法：\(name)"
        case let .missingHeroAsset(name):
            "Hero 引用了不存在的资源：\(name)"
        case let .invalidNormalizedValue(field):
            "归一化坐标必须位于 0...1：\(field)"
        case .invalidSafeArea:
            "Hero safeArea 必须完整位于画布内"
        case let .invalidGlassConfiguration(field):
            "玻璃参数非法：\(field)"
        case .invalidCompatibility:
            "主题兼容范围非法"
        case let .invalidRelativePath(path):
            "主题资源必须使用安全相对路径：\(path)"
        case let .unsupportedAssetExtension(path):
            "主题资源扩展名不受支持：\(path)"
        case let .assetEscapesTheme(path):
            "主题资源越过主题目录：\(path)"
        case let .assetMissing(path):
            "主题资源不存在：\(path)"
        case let .assetNotRegularFile(path):
            "主题资源不是普通文件：\(path)"
        case let .assetTooLarge(path, bytes):
            "主题资源超过 15 MiB：\(path)（\(bytes) bytes）"
        case let .invalidSHA256(path):
            "主题资源 SHA-256 格式非法：\(path)"
        case let .sha256Mismatch(path):
            "主题资源 SHA-256 不匹配：\(path)"
        case let .invalidImage(path):
            "主题资源不是可解码图片：\(path)"
        case let .unsupportedImageFormat(path):
            "主题资源真实图片格式不受支持：\(path)"
        case let .imageFormatMismatch(path, declared, actual):
            "主题资源格式不匹配：\(path)，声明 \(declared.rawValue)，实际 \(actual.rawValue)"
        case let .pixelLimitExceeded(path, width, height):
            "主题资源超过 40 MP：\(path)（\(width)×\(height)）"
        case let .imageDimensionsMismatch(path, expectedWidth, expectedHeight, actualWidth, actualHeight):
            "主题资源尺寸不匹配：\(path)，声明 \(expectedWidth)×\(expectedHeight)，实际 \(actualWidth)×\(actualHeight)"
        case let .prohibitedExecutableAsset(path):
            "主题目录不允许 JavaScript、CSS 或 HTML：\(path)"
        case let .duplicateThemeID(id):
            "主题 ID 重复：\(id)"
        case let .fileSystem(message):
            "主题文件系统错误：\(message)"
        case let .invalidSVGViewBox(value):
            "品牌印记 SVG viewBox 格式非法：\(value)"
        case let .svgBodyTooLarge(bytes):
            "品牌印记 SVG 内容超过 4KB：\(bytes) bytes"
        case let .svgBodyUnsafe(detail):
            "品牌印记 SVG 包含禁用内容：\(detail)"
        case let .iconPathTooLarge(match, bytes):
            "图标路径超过 2KB：\(match)（\(bytes) bytes）"
        case let .iconPathUnsafe(match, detail):
            "图标路径包含禁用内容：\(match)（\(detail)）"
        case let .iconPathMustStartWithCommand(match):
            "图标路径必须以 M/m 命令开头：\(match)"
        case let .tooManyIconOverrides(field, count):
            "图标替换条目超过 16 条：\(field)（\(count) 条）"
        case let .invalidIconMatch(value):
            "图标匹配文本必须为 1 到 32 个字符：\(value)"
        case let .extensionTextTooLong(field, length):
            "扩展文案不能超过 32 个字符：\(field)（\(length) 字符）"
        case let .extensionTextUnsafe(field):
            "扩展文案不允许包含引号、反斜杠或控制字符：\(field)"
        case let .invalidAnchorText(value):
            "品牌印记锚点文本必须为 1 到 32 个字符：\(value)"
        case let .invalidBrandMarkSize(size):
            "品牌印记尺寸必须位于 12...48：\(size)"
        case let .invalidWordmarkSlotPadding(value):
            "字标槽位 padding 必须位于 0...64：\(value)"
        }
    }
}
