import Foundation

struct ThemeManifestV3: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let id: String
    let name: String
    let nativeTheme: ThemeNativePalette
    let hero: ThemeHeroConfiguration
    let sidebar: ThemeGlassConfiguration
    let composer: ThemeGlassConfiguration
    let compatibility: ThemeCompatibility
    let assets: [String: ThemeAssetDescriptor]
    let features: ThemeFeatures
    // schema v3.1 扩展：全部可选，缺省时皮肤行为与旧主题完全一致。
    let brand: ThemeBrandConfiguration?
    let icons: ThemeIconConfiguration?
    let texts: ThemeTextConfiguration?

    init(
        schemaVersion: Int,
        id: String,
        name: String,
        nativeTheme: ThemeNativePalette,
        hero: ThemeHeroConfiguration,
        sidebar: ThemeGlassConfiguration,
        composer: ThemeGlassConfiguration,
        compatibility: ThemeCompatibility,
        assets: [String: ThemeAssetDescriptor],
        features: ThemeFeatures,
        brand: ThemeBrandConfiguration? = nil,
        icons: ThemeIconConfiguration? = nil,
        texts: ThemeTextConfiguration? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.nativeTheme = nativeTheme
        self.hero = hero
        self.sidebar = sidebar
        self.composer = composer
        self.compatibility = compatibility
        self.assets = assets
        self.features = features
        self.brand = brand
        self.icons = icons
        self.texts = texts
    }
}

/// 品牌印记配置：印记 SVG 通过 owned overlay 节点渲染，绝不改动原生 DOM。
struct ThemeBrandConfiguration: Codable, Equatable, Sendable {
    let mark: ThemeBrandMark?
    let wordmarkSuffix: String?
    let wordmarkSlotPadding: Double?

    init(
        mark: ThemeBrandMark? = nil,
        wordmarkSuffix: String? = nil,
        wordmarkSlotPadding: Double? = nil
    ) {
        self.mark = mark
        self.wordmarkSuffix = wordmarkSuffix
        self.wordmarkSlotPadding = wordmarkSlotPadding
    }
}

struct ThemeBrandMark: Codable, Equatable, Sendable {
    let anchorText: String
    let size: Double
    let svgViewBox: String
    let svgBody: String
    let glow: Bool?

    init(
        anchorText: String,
        size: Double,
        svgViewBox: String,
        svgBody: String,
        glow: Bool? = nil
    ) {
        self.anchorText = anchorText
        self.size = size
        self.svgViewBox = svgViewBox
        self.svgBody = svgBody
        self.glow = glow
    }
}

struct ThemeIconConfiguration: Codable, Equatable, Sendable {
    let tint: String?
    let nav: [ThemeIconOverride]?
    let suggestions: [ThemeIconOverride]?

    init(
        tint: String? = nil,
        nav: [ThemeIconOverride]? = nil,
        suggestions: [ThemeIconOverride]? = nil
    ) {
        self.tint = tint
        self.nav = nav
        self.suggestions = suggestions
    }
}

struct ThemeIconOverride: Codable, Equatable, Sendable {
    let match: String
    let path: String

    init(match: String, path: String) {
        self.match = match
        self.path = path
    }
}

struct ThemeTextConfiguration: Codable, Equatable, Sendable {
    let composerPlaceholder: String?

    init(composerPlaceholder: String? = nil) {
        self.composerPlaceholder = composerPlaceholder
    }
}

struct ThemeNativePalette: Codable, Equatable, Sendable {
    let accent: String
    let secondary: String?
    let surface: String
    let ink: String
    let muted: String?
    let success: String?
    let warning: String?
    let danger: String?
}

struct ThemeHeroConfiguration: Codable, Equatable, Sendable {
    let asset: String
    let focalPoint: ThemeNormalizedPoint
    let safeArea: ThemeNormalizedRect
    let adaptiveScrim: ThemeAdaptiveScrim
}

struct ThemeNormalizedPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct ThemeNormalizedRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ThemeAdaptiveScrim: Codable, Equatable, Sendable {
    let color: String
    let opacity: Double
}

struct ThemeGlassConfiguration: Codable, Equatable, Sendable {
    let opacity: Double
    let blurRadius: Double
}

struct ThemeCompatibility: Codable, Equatable, Sendable {
    let adapterProtocol: String
    let minimumAPIVersion: Int
    let maximumAPIVersion: Int

    func supports(_ contract: ChatGPTAdapterProtocolContract) -> Bool {
        guard minimumAPIVersion > 0, maximumAPIVersion >= minimumAPIVersion else {
            return false
        }
        return adapterProtocol == contract.identifier
            && (minimumAPIVersion...maximumAPIVersion).contains(contract.apiVersion)
    }
}

struct ThemeFeatures: Codable, Equatable, Sendable {
    let homeEnhancer: Bool
    let motion: Bool
    let routeAware: Bool
}

enum ThemeImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case webp

    var allowedExtensions: Set<String> {
        switch self {
        case .png:
            ["png"]
        case .jpeg:
            ["jpg", "jpeg"]
        case .webp:
            ["webp"]
        }
    }
}

struct ThemeAssetDescriptor: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let format: ThemeImageFormat
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ThemeSource: String, Codable, Equatable, Sendable {
    case bundled
    case user
}

struct LoadedThemeAsset: Equatable, Sendable {
    let name: String
    let fileURL: URL
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let sha256: String
    let format: ThemeImageFormat
}

struct LoadedTheme: Equatable, Sendable {
    let manifest: ThemeManifestV3
    let directoryURL: URL
    let source: ThemeSource
    let assets: [String: LoadedThemeAsset]

    var heroAsset: LoadedThemeAsset {
        // Validation guarantees this reference before LoadedTheme is created.
        assets[manifest.hero.asset]!
    }
}
