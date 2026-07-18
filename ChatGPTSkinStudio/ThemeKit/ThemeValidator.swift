import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ThemeValidator: Sendable {
    static let maximumAssetBytes = 15 * 1024 * 1024
    static let maximumPixelCount = 40_000_000
    static let maximumManifestBytes = 1024 * 1024

    private static let prohibitedFileExtensions: Set<String> = [
        "js", "mjs", "cjs", "css", "html", "htm", "svg",
    ]

    init() {}

    func validateAndLoad(
        themeDirectory: URL,
        source: ThemeSource
    ) throws -> LoadedTheme {
        let lexicalRoot = themeDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lexicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ThemeValidationError.themeDirectoryMissing(lexicalRoot.path)
        }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        try rejectExecutableAssets(in: resolvedRoot)

        let manifestURL = lexicalRoot.appendingPathComponent("theme.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ThemeValidationError.manifestMissing(manifestURL.path)
        }
        let resolvedManifestURL = manifestURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isDescendant(resolvedManifestURL, of: resolvedRoot) else {
            throw ThemeValidationError.assetEscapesTheme("theme.json")
        }

        let manifestSize: Int
        do {
            manifestSize = try resolvedManifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw ThemeValidationError.fileSystem(error.localizedDescription)
        }
        guard manifestSize <= Self.maximumManifestBytes else {
            throw ThemeValidationError.manifestTooLarge(manifestSize)
        }

        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: resolvedManifestURL, options: [.mappedIfSafe])
        } catch {
            throw ThemeValidationError.fileSystem(error.localizedDescription)
        }

        try StrictThemeSchema.validate(manifestData)

        let manifest: ThemeManifestV3
        do {
            manifest = try JSONDecoder().decode(ThemeManifestV3.self, from: manifestData)
        } catch let error as ThemeValidationError {
            throw error
        } catch {
            throw ThemeValidationError.malformedManifest(error.localizedDescription)
        }

        try validateManifest(manifest)

        var loadedAssets: [String: LoadedThemeAsset] = [:]
        for assetName in manifest.assets.keys.sorted() {
            guard let descriptor = manifest.assets[assetName] else { continue }
            loadedAssets[assetName] = try validateAsset(
                named: assetName,
                descriptor: descriptor,
                lexicalRoot: lexicalRoot,
                resolvedRoot: resolvedRoot
            )
        }

        guard loadedAssets[manifest.hero.asset] != nil else {
            throw ThemeValidationError.missingHeroAsset(manifest.hero.asset)
        }

        return LoadedTheme(
            manifest: manifest,
            directoryURL: resolvedRoot,
            source: source,
            assets: loadedAssets
        )
    }

    private func validateManifest(_ manifest: ThemeManifestV3) throws {
        guard manifest.schemaVersion == ThemeManifestV3.currentSchemaVersion else {
            throw ThemeValidationError.unsupportedSchema(manifest.schemaVersion)
        }

        guard manifest.id.count <= 64,
              Self.matches(manifest.id, pattern: "^[a-z0-9]+(?:-[a-z0-9]+)*$")
        else {
            throw ThemeValidationError.invalidID(manifest.id)
        }

        let trimmedName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName == manifest.name,
              !trimmedName.isEmpty,
              trimmedName.count <= 100
        else {
            throw ThemeValidationError.invalidName
        }

        let colors: [(String, String?)] = [
            ("nativeTheme.accent", manifest.nativeTheme.accent),
            ("nativeTheme.secondary", manifest.nativeTheme.secondary),
            ("nativeTheme.surface", manifest.nativeTheme.surface),
            ("nativeTheme.ink", manifest.nativeTheme.ink),
            ("nativeTheme.muted", manifest.nativeTheme.muted),
            ("nativeTheme.success", manifest.nativeTheme.success),
            ("nativeTheme.warning", manifest.nativeTheme.warning),
            ("nativeTheme.danger", manifest.nativeTheme.danger),
            ("hero.adaptiveScrim.color", manifest.hero.adaptiveScrim.color),
        ]
        for (field, value) in colors {
            guard let value else { continue }
            guard Self.matches(value, pattern: "^#[0-9A-Fa-f]{6}$") else {
                throw ThemeValidationError.invalidColor(field: field, value: value)
            }
        }

        guard Self.matches(manifest.hero.asset, pattern: "^[a-z][a-z0-9-]*$") else {
            throw ThemeValidationError.invalidAssetName(manifest.hero.asset)
        }
        guard manifest.assets[manifest.hero.asset] != nil else {
            throw ThemeValidationError.missingHeroAsset(manifest.hero.asset)
        }

        try Self.validateNormalized(manifest.hero.focalPoint.x, field: "hero.focalPoint.x")
        try Self.validateNormalized(manifest.hero.focalPoint.y, field: "hero.focalPoint.y")
        try Self.validateNormalized(manifest.hero.safeArea.x, field: "hero.safeArea.x")
        try Self.validateNormalized(manifest.hero.safeArea.y, field: "hero.safeArea.y")
        try Self.validateNormalized(manifest.hero.safeArea.width, field: "hero.safeArea.width")
        try Self.validateNormalized(manifest.hero.safeArea.height, field: "hero.safeArea.height")
        try Self.validateNormalized(manifest.hero.adaptiveScrim.opacity, field: "hero.adaptiveScrim.opacity")

        let safeArea = manifest.hero.safeArea
        guard safeArea.width > 0,
              safeArea.height > 0,
              safeArea.x + safeArea.width <= 1.000_000_1,
              safeArea.y + safeArea.height <= 1.000_000_1
        else {
            throw ThemeValidationError.invalidSafeArea
        }

        try validateGlass(manifest.sidebar, field: "sidebar")
        try validateGlass(manifest.composer, field: "composer")

        try validateThemingExtensions(manifest)

        guard Self.matches(
            manifest.compatibility.adapterProtocol,
            pattern: "^[a-z0-9]+(?:[._-][a-z0-9]+)*$"
        ), manifest.compatibility.minimumAPIVersion > 0,
            manifest.compatibility.maximumAPIVersion
                >= manifest.compatibility.minimumAPIVersion
        else {
            throw ThemeValidationError.invalidCompatibility
        }

        guard !manifest.assets.isEmpty else {
            throw ThemeValidationError.missingHeroAsset(manifest.hero.asset)
        }
        for (name, descriptor) in manifest.assets {
            guard Self.matches(name, pattern: "^[a-z][a-z0-9-]*$") else {
                throw ThemeValidationError.invalidAssetName(name)
            }
            guard descriptor.pixelWidth > 0, descriptor.pixelHeight > 0 else {
                throw ThemeValidationError.invalidImage(descriptor.path)
            }
            let (declaredPixels, overflow) = descriptor.pixelWidth.multipliedReportingOverflow(
                by: descriptor.pixelHeight
            )
            guard !overflow, declaredPixels <= Self.maximumPixelCount else {
                throw ThemeValidationError.pixelLimitExceeded(
                    path: descriptor.path,
                    width: descriptor.pixelWidth,
                    height: descriptor.pixelHeight
                )
            }
            guard Self.matches(descriptor.sha256, pattern: "^[0-9A-Fa-f]{64}$") else {
                throw ThemeValidationError.invalidSHA256(path: descriptor.path)
            }
        }
    }

    private func validateGlass(_ glass: ThemeGlassConfiguration, field: String) throws {
        guard glass.opacity.isFinite,
              (0 ... 1).contains(glass.opacity),
              glass.blurRadius.isFinite,
              (0 ... 64).contains(glass.blurRadius)
        else {
            throw ThemeValidationError.invalidGlassConfiguration(field)
        }
    }

    // MARK: - schema v3.1 扩展校验（品牌印记 / 图标替换 / 文案）

    /// 校验可选扩展块；全部字段缺省时旧主题行为一字不变。
    private func validateThemingExtensions(_ manifest: ThemeManifestV3) throws {
        if let brand = manifest.brand {
            try Self.validateBrand(brand)
        }
        if let icons = manifest.icons {
            try Self.validateIcons(icons)
        }
        if let placeholder = manifest.texts?.composerPlaceholder {
            guard placeholder.count <= 32 else {
                throw ThemeValidationError.extensionTextTooLong(
                    field: "texts.composerPlaceholder",
                    length: placeholder.count
                )
            }
            // 文案会进入 CSS content 字符串；CSS 通道禁止反斜杠转义，
            // 且 <style> textContent 不允许出现闭合标签，因此拒绝这些字符。
            guard !placeholder.contains(where: Self.isCSSContentUnsafe) else {
                throw ThemeValidationError.extensionTextUnsafe(
                    field: "texts.composerPlaceholder"
                )
            }
        }
    }

    private static func validateBrand(_ brand: ThemeBrandConfiguration) throws {
        if let suffix = brand.wordmarkSuffix {
            guard suffix.count <= 32 else {
                throw ThemeValidationError.extensionTextTooLong(
                    field: "brand.wordmarkSuffix",
                    length: suffix.count
                )
            }
        }
        if let padding = brand.wordmarkSlotPadding {
            guard padding.isFinite, (0 ... 64).contains(padding) else {
                throw ThemeValidationError.invalidWordmarkSlotPadding(padding)
            }
        }
        guard let mark = brand.mark else { return }

        guard (1 ... 32).contains(mark.anchorText.count) else {
            throw ThemeValidationError.invalidAnchorText(mark.anchorText)
        }
        guard mark.size.isFinite, (12 ... 48).contains(mark.size) else {
            throw ThemeValidationError.invalidBrandMarkSize(mark.size)
        }
        try validateSVGViewBox(mark.svgViewBox)

        let bodyBytes = mark.svgBody.utf8.count
        guard bodyBytes <= 4 * 1024 else {
            throw ThemeValidationError.svgBodyTooLarge(bytes: bodyBytes)
        }
        if let detail = unsafeSVGDetail(mark.svgBody) {
            throw ThemeValidationError.svgBodyUnsafe(detail: detail)
        }
    }

    private static func validateIcons(_ icons: ThemeIconConfiguration) throws {
        if let tint = icons.tint {
            guard matches(tint, pattern: "^#[0-9A-Fa-f]{6}$") else {
                throw ThemeValidationError.invalidColor(field: "icons.tint", value: tint)
            }
        }
        try validateIconOverrides(icons.nav, field: "icons.nav")
        try validateIconOverrides(icons.suggestions, field: "icons.suggestions")
    }

    private static func validateIconOverrides(
        _ overrides: [ThemeIconOverride]?,
        field: String
    ) throws {
        guard let overrides else { return }
        guard overrides.count <= 16 else {
            throw ThemeValidationError.tooManyIconOverrides(
                field: field,
                count: overrides.count
            )
        }
        for override in overrides {
            guard (1 ... 32).contains(override.match.count) else {
                throw ThemeValidationError.invalidIconMatch(override.match)
            }
            let pathBytes = override.path.utf8.count
            guard pathBytes <= 2 * 1024 else {
                throw ThemeValidationError.iconPathTooLarge(
                    match: override.match,
                    bytes: pathBytes
                )
            }
            if let detail = unsafeSVGDetail(override.path) {
                throw ThemeValidationError.iconPathUnsafe(
                    match: override.match,
                    detail: detail
                )
            }
            guard override.path.first == "M" || override.path.first == "m" else {
                throw ThemeValidationError.iconPathMustStartWithCommand(
                    match: override.match
                )
            }
        }
    }

    private static func validateSVGViewBox(_ value: String) throws {
        guard matches(
            value,
            pattern: "^-?\\d+(?:\\.\\d+)?\\s+-?\\d+(?:\\.\\d+)?\\s+\\d+(?:\\.\\d+)?\\s+\\d+(?:\\.\\d+)?$"
        ) else {
            throw ThemeValidationError.invalidSVGViewBox(value)
        }
        let components = value.split(whereSeparator: \.isWhitespace)
        guard components.count == 4,
              let width = Double(components[2]),
              let height = Double(components[3]),
              width > 0,
              height > 0
        else {
            throw ThemeValidationError.invalidSVGViewBox(value)
        }
    }

    /// 扫描 SVG 片段中的禁用内容，返回命中的规则名；未命中返回 nil。
    private static func unsafeSVGDetail(_ value: String) -> String? {
        if value.range(of: "<script", options: .caseInsensitive) != nil {
            return "<script"
        }
        if value.range(
            of: #"on[A-Za-z]+\s*="#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return "事件属性 on*="
        }
        if value.range(of: "http", options: .caseInsensitive) != nil {
            return "http"
        }
        if value.range(
            of: #"url\s*\("#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return "url("
        }
        if value.range(of: "javascript:", options: .caseInsensitive) != nil {
            return "javascript:"
        }
        return nil
    }

    private static func isCSSContentUnsafe(_ character: Character) -> Bool {
        character == "\""
            || character == "'"
            || character == "\\"
            || character == "<"
            || character == ">"
            || character.isNewline
            || character.unicodeScalars.allSatisfy({
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private func validateAsset(
        named name: String,
        descriptor: ThemeAssetDescriptor,
        lexicalRoot: URL,
        resolvedRoot: URL
    ) throws -> LoadedThemeAsset {
        try validateRelativePath(descriptor.path)

        let extensionName = URL(fileURLWithPath: descriptor.path).pathExtension.lowercased()
        guard descriptor.format.allowedExtensions.contains(extensionName) else {
            throw ThemeValidationError.unsupportedAssetExtension(descriptor.path)
        }

        let lexicalURL = lexicalRoot
            .appendingPathComponent(descriptor.path, isDirectory: false)
            .standardizedFileURL
        guard Self.isDescendant(lexicalURL, of: lexicalRoot) else {
            throw ThemeValidationError.assetEscapesTheme(descriptor.path)
        }
        guard FileManager.default.fileExists(atPath: lexicalURL.path) else {
            throw ThemeValidationError.assetMissing(descriptor.path)
        }

        let resolvedURL = lexicalURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isDescendant(resolvedURL, of: resolvedRoot) else {
            throw ThemeValidationError.assetEscapesTheme(descriptor.path)
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ThemeValidationError.fileSystem(error.localizedDescription)
        }
        guard resourceValues.isRegularFile == true else {
            throw ThemeValidationError.assetNotRegularFile(descriptor.path)
        }
        let statedByteCount = resourceValues.fileSize ?? 0
        guard statedByteCount <= Self.maximumAssetBytes else {
            throw ThemeValidationError.assetTooLarge(path: descriptor.path, bytes: statedByteCount)
        }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: resolvedURL, options: [.mappedIfSafe])
        } catch {
            throw ThemeValidationError.fileSystem(error.localizedDescription)
        }
        guard bytes.count <= Self.maximumAssetBytes else {
            throw ThemeValidationError.assetTooLarge(path: descriptor.path, bytes: bytes.count)
        }

        let actualSHA256 = Self.sha256Hex(bytes)
        guard actualSHA256.caseInsensitiveCompare(descriptor.sha256) == .orderedSame else {
            throw ThemeValidationError.sha256Mismatch(path: descriptor.path)
        }

        guard let imageSource = CGImageSourceCreateWithData(
            bytes as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(imageSource) > 0
        else {
            throw ThemeValidationError.invalidImage(descriptor.path)
        }

        guard let actualFormat = Self.imageFormat(for: imageSource) else {
            throw ThemeValidationError.unsupportedImageFormat(descriptor.path)
        }
        guard actualFormat == descriptor.format else {
            throw ThemeValidationError.imageFormatMismatch(
                path: descriptor.path,
                declared: descriptor.format,
                actual: actualFormat
            )
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any],
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw ThemeValidationError.invalidImage(descriptor.path)
        }
        let width = widthNumber.intValue
        let height = heightNumber.intValue
        guard width > 0, height > 0 else {
            throw ThemeValidationError.invalidImage(descriptor.path)
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= Self.maximumPixelCount else {
            throw ThemeValidationError.pixelLimitExceeded(
                path: descriptor.path,
                width: width,
                height: height
            )
        }
        guard width == descriptor.pixelWidth, height == descriptor.pixelHeight else {
            throw ThemeValidationError.imageDimensionsMismatch(
                path: descriptor.path,
                expectedWidth: descriptor.pixelWidth,
                expectedHeight: descriptor.pixelHeight,
                actualWidth: width,
                actualHeight: height
            )
        }

        guard CGImageSourceCreateImageAtIndex(
            imageSource,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) != nil else {
            throw ThemeValidationError.invalidImage(descriptor.path)
        }

        return LoadedThemeAsset(
            name: name,
            fileURL: resolvedURL,
            byteCount: bytes.count,
            pixelWidth: width,
            pixelHeight: height,
            sha256: actualSHA256,
            format: actualFormat
        )
    }

    private func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              URL(string: path)?.scheme == nil
        else {
            throw ThemeValidationError.invalidRelativePath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ThemeValidationError.invalidRelativePath(path)
        }

        let extensionName = URL(fileURLWithPath: path).pathExtension.lowercased()
        let allowedExtensions = Set(ThemeImageFormat.allCases.flatMap(\.allowedExtensions))
        guard allowedExtensions.contains(extensionName) else {
            throw ThemeValidationError.unsupportedAssetExtension(path)
        }
    }

    private func rejectExecutableAssets(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ThemeValidationError.fileSystem("无法枚举主题目录：\(root.path)")
        }

        for case let fileURL as URL in enumerator {
            if Self.prohibitedFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                throw ThemeValidationError.prohibitedExecutableAsset(fileURL.path)
            }
        }
    }

    private static func validateNormalized(_ value: Double, field: String) throws {
        guard value.isFinite, (0 ... 1).contains(value) else {
            throw ThemeValidationError.invalidNormalizedValue(field)
        }
    }

    private static func imageFormat(for source: CGImageSource) -> ThemeImageFormat? {
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier)
        else {
            return nil
        }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .webP) { return .webp }
        return nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private enum StrictThemeSchema {
    private static let rootKeys: Set<String> = [
        "schemaVersion", "id", "name", "nativeTheme", "hero", "sidebar", "composer",
        "compatibility", "assets", "features", "brand", "icons", "texts",
    ]
    private static let paletteKeys: Set<String> = [
        "accent", "secondary", "surface", "ink", "muted", "success", "warning", "danger",
    ]
    private static let heroKeys: Set<String> = [
        "asset", "focalPoint", "safeArea", "adaptiveScrim",
    ]
    private static let pointKeys: Set<String> = ["x", "y"]
    private static let rectKeys: Set<String> = ["x", "y", "width", "height"]
    private static let scrimKeys: Set<String> = ["color", "opacity"]
    private static let glassKeys: Set<String> = ["opacity", "blurRadius"]
    private static let compatibilityKeys: Set<String> = [
        "adapterProtocol", "minimumAPIVersion", "maximumAPIVersion",
    ]
    private static let assetKeys: Set<String> = [
        "path", "sha256", "format", "pixelWidth", "pixelHeight",
    ]
    private static let featureKeys: Set<String> = ["homeEnhancer", "motion", "routeAware"]
    // schema v3.1 扩展块的允许键
    private static let brandKeys: Set<String> = [
        "mark", "wordmarkSuffix", "wordmarkSlotPadding",
    ]
    private static let brandMarkKeys: Set<String> = [
        "anchorText", "size", "svgViewBox", "svgBody", "glow",
    ]
    private static let iconsKeys: Set<String> = ["tint", "nav", "suggestions"]
    private static let iconOverrideKeys: Set<String> = ["match", "path"]
    private static let textsKeys: Set<String> = ["composerPlaceholder"]

    static func validate(_ data: Data) throws {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ThemeValidationError.malformedManifest(error.localizedDescription)
        }
        guard let root = raw as? [String: Any] else {
            throw ThemeValidationError.malformedManifest("根节点必须是对象")
        }
        guard let schemaVersion = root["schemaVersion"] as? Int else {
            throw ThemeValidationError.malformedManifest("schemaVersion 必须是整数")
        }
        guard schemaVersion == ThemeManifestV3.currentSchemaVersion else {
            throw ThemeValidationError.unsupportedSchema(schemaVersion)
        }

        try rejectRemoteValues(in: root)
        try validateKeys(root, allowed: rootKeys, path: "$" )
        try validateObject(root["nativeTheme"], allowed: paletteKeys, path: "$.nativeTheme")
        try validateObject(root["hero"], allowed: heroKeys, path: "$.hero")
        if let hero = root["hero"] as? [String: Any] {
            try validateObject(hero["focalPoint"], allowed: pointKeys, path: "$.hero.focalPoint")
            try validateObject(hero["safeArea"], allowed: rectKeys, path: "$.hero.safeArea")
            try validateObject(hero["adaptiveScrim"], allowed: scrimKeys, path: "$.hero.adaptiveScrim")
        }
        try validateObject(root["sidebar"], allowed: glassKeys, path: "$.sidebar")
        try validateObject(root["composer"], allowed: glassKeys, path: "$.composer")
        try validateObject(
            root["compatibility"],
            allowed: compatibilityKeys,
            path: "$.compatibility"
        )
        try validateObject(root["features"], allowed: featureKeys, path: "$.features")

        // schema v3.1：可选扩展块的键白名单校验
        if let brand = root["brand"] as? [String: Any] {
            try validateKeys(brand, allowed: brandKeys, path: "$.brand")
            try validateObject(brand["mark"], allowed: brandMarkKeys, path: "$.brand.mark")
        }
        if let icons = root["icons"] as? [String: Any] {
            try validateKeys(icons, allowed: iconsKeys, path: "$.icons")
            for listKey in ["nav", "suggestions"] {
                guard let entries = icons[listKey] as? [Any] else { continue }
                for (index, entry) in entries.enumerated() {
                    try validateObject(
                        entry,
                        allowed: iconOverrideKeys,
                        path: "$.icons.\(listKey)[\(index)]"
                    )
                }
            }
        }
        try validateObject(root["texts"], allowed: textsKeys, path: "$.texts")

        if let assets = root["assets"] as? [String: Any] {
            for (name, descriptor) in assets {
                try validateObject(
                    descriptor,
                    allowed: assetKeys,
                    path: "$.assets.\(name)"
                )
            }
        }
    }

    private static func validateObject(
        _ value: Any?,
        allowed: Set<String>,
        path: String
    ) throws {
        guard let object = value as? [String: Any] else { return }
        try validateKeys(object, allowed: allowed, path: path)
    }

    private static func validateKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        path: String
    ) throws {
        if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ThemeValidationError.unknownKey(path: path, key: key)
        }
    }

    private static func rejectRemoteValues(in value: Any) throws {
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let forbiddenPrefixes = [
                "http://", "https://", "ws://", "wss://", "ftp://", "//", "data:",
                "javascript:", "file:", "blob:",
            ]
            if forbiddenPrefixes.contains(where: normalized.hasPrefix) {
                throw ThemeValidationError.forbiddenRemoteValue(string)
            }
            return
        }
        if let array = value as? [Any] {
            for child in array {
                try rejectRemoteValues(in: child)
            }
            return
        }
        if let object = value as? [String: Any] {
            for child in object.values {
                try rejectRemoteValues(in: child)
            }
        }
    }
}
