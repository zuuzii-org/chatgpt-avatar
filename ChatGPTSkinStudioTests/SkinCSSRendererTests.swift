import CryptoKit
import Foundation
import XCTest
@testable import ChatGPTSkinStudio

final class SkinCSSRendererTests: XCTestCase {
    func testBundledHeroBypassesChromiumCSSValueLimit() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeDirectory = repositoryRoot
            .appendingPathComponent("ChatGPTSkinStudio/Resources/Themes/original-night-city")
        let theme = try ThemeValidator().validateAndLoad(
            themeDirectory: themeDirectory,
            source: .bundled
        )

        let rendered = try SkinCSSRenderer().render(theme: theme)

        XCTAssertGreaterThan(rendered.hero.dataURL.count, 2 * 1024 * 1024)
        XCTAssertLessThan(rendered.css.utf8.count, 128 * 1024)
        // schema v3.1：CSS 只允许出现图标替换用的 SVG mask data URL；
        // hero 位图字节仍必须走 typed hero payload，绝不进入 CSS。
        XCTAssertFalse(rendered.css.contains("data:image/png"))
        XCTAssertFalse(rendered.css.contains("data:image/jpeg"))
        XCTAssertFalse(rendered.css.contains("data:image/webp"))
        XCTAssertFalse(rendered.css.contains(rendered.hero.dataURL))
        XCTAssertEqual(rendered.hero.pixelWidth, 1920)
        XCTAssertEqual(rendered.hero.pixelHeight, 1200)

        let encoded = try XCTUnwrap(rendered.hero.dataURL.split(separator: ",", maxSplits: 1).last)
        let decoded = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        XCTAssertEqual(decoded.count, theme.heroAsset.byteCount)
        XCTAssertEqual(
            SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined(),
            theme.heroAsset.sha256
        )
    }

    func testRendererUsesLocalDataURLAndAccessibilityContracts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let heroBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let theme = try makeTheme(directory: directory, heroBytes: heroBytes)

        let rendered = try SkinCSSRenderer().render(theme: theme)
        let css = rendered.css
        XCTAssertTrue(rendered.hero.dataURL.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(rendered.hero.pixelWidth, 1)
        XCTAssertEqual(rendered.hero.pixelHeight, 1)
        XCTAssertEqual(rendered.hero.focalPointX, 0.72)
        XCTAssertEqual(rendered.hero.focalPointY, 0.35)
        XCTAssertFalse(css.contains("data:image/"))
        XCTAssertFalse(css.contains("--zuuzii-hero-image"))
        XCTAssertTrue(css.contains("--zuuzii-hero-position: 72% 35%"))
        XCTAssertTrue(css.contains(#"[data-zuuzii-skin-role="hero"]"#))
        XCTAssertTrue(css.contains(#"[data-zuuzii-skin-role="ambient"]"#))
        XCTAssertTrue(css.contains(#"[data-zuuzii-skin-role="theme-label"]"#))
        XCTAssertTrue(css.contains(":focus-visible"))
        XCTAssertTrue(css.contains("prefers-reduced-motion"))
        XCTAssertTrue(css.contains("scroll-behavior: auto !important"))
        XCTAssertTrue(css.contains("transition: none !important"))
        XCTAssertTrue(css.contains("data-home-ambient-suggestions"))
        XCTAssertTrue(css.contains(#"[data-skin-mode="token-only"]"#))
        XCTAssertFalse(css.contains(":root:has(body > [data-zuuzii-skin-overlay]) body {"))
        XCTAssertFalse(css.contains("http://"))
        XCTAssertFalse(css.contains("https://"))
    }

    func testRendererRejectsAssetChangedAfterValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let theme = try makeTheme(directory: directory, heroBytes: originalBytes)
        try Data([0x89, 0x50, 0x4e, 0x00]).write(to: theme.heroAsset.fileURL)

        XCTAssertThrowsError(try SkinCSSRenderer().render(theme: theme)) { error in
            guard case SkinError.invalidConfiguration(let message) = error else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
            XCTAssertTrue(message.contains("内容变化"))
        }
    }

    func testRendererRejectsSymlinkSwapAfterValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let heroBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let theme = try makeTheme(directory: directory, heroBytes: heroBytes)
        let replacementURL = directory.appendingPathComponent("replacement.png")
        try heroBytes.write(to: replacementURL)
        try FileManager.default.removeItem(at: theme.heroAsset.fileURL)
        try FileManager.default.createSymbolicLink(
            at: theme.heroAsset.fileURL,
            withDestinationURL: replacementURL
        )

        XCTAssertThrowsError(try SkinCSSRenderer().render(theme: theme)) { error in
            guard case SkinError.invalidConfiguration(let message) = error else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
            XCTAssertTrue(message.contains("不可安全读取"))
        }
    }

    func testRendererHonorsThemeMotionFlag() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let theme = try makeTheme(
            directory: directory,
            heroBytes: Data([0x89, 0x50, 0x4e, 0x47]),
            motion: false
        )
        let css = try SkinCSSRenderer().render(theme: theme).css

        XCTAssertTrue(css.contains("transition: opacity 0ms"))
        XCTAssertTrue(css.contains("transform: translateY(0)"))
        XCTAssertFalse(css.contains("translateY(-2px)"))
    }

    // MARK: - schema v3.1 扩展 CSS

    func testRendererEmitsThemingExtensionCSS() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let theme = try makeTheme(
            directory: directory,
            heroBytes: Data([0x89, 0x50, 0x4e, 0x47]),
            brand: ThemeBrandConfiguration(
                mark: ThemeBrandMark(
                    anchorText: "Codex",
                    size: 20,
                    svgViewBox: "0 0 48 48",
                    svgBody: "<circle cx=\"24\" cy=\"24\" r=\"20\"/>",
                    glow: true
                ),
                wordmarkSuffix: "NIGHT CITY",
                wordmarkSlotPadding: 34
            ),
            icons: ThemeIconConfiguration(
                tint: "#43D8F5",
                nav: [ThemeIconOverride(match: "新建任务", path: "M12 3l1.8 4.6z")],
                suggestions: [ThemeIconOverride(match: "探索", path: "M8 6l-5 6z")]
            ),
            texts: ThemeTextConfiguration(composerPlaceholder: "夜色已就绪")
        )

        let css = try SkinCSSRenderer().render(theme: theme).css

        // 字标槽位
        XCTAssertTrue(css.contains(#"[data-zuuzii-anchor="wordmark"]"#))
        XCTAssertTrue(css.contains("padding-left: 34px !important"))
        // owned 印记/后缀节点样式（几何由 bootstrap 实测写入）
        XCTAssertTrue(css.contains(#"[data-zuuzii-skin-role="brand-mark"]"#))
        XCTAssertTrue(css.contains(#"[data-zuuzii-skin-role="brand-suffix"]"#))
        XCTAssertTrue(css.contains(#"[data-zuuzii-skin-role="brand-mark"][data-glow="true"]"#))
        // nav 图标替换：隐藏原生 svg + mask ::before + 实测变量回退值
        XCTAssertTrue(css.contains(#"[data-zuuzii-anchor="nav-0"] svg"#))
        XCTAssertTrue(css.contains("visibility: hidden !important"))
        XCTAssertTrue(css.contains(#"[data-zuuzii-anchor="nav-0"]::before"#))
        XCTAssertTrue(css.contains("var(--zuuzii-icon-x-0, 0px)"))
        XCTAssertTrue(css.contains("background: #43D8F5"))
        XCTAssertTrue(css.contains("data:image/svg+xml;base64,"))
        // 建议卡：38px 圆形底框 + mask 图标
        XCTAssertTrue(css.contains(#"[data-zuuzii-anchor="sug-0"]::before"#))
        XCTAssertTrue(css.contains("border-radius: 50%"))
        XCTAssertTrue(css.contains(#"[data-zuuzii-anchor="sug-0"]::after"#))
        XCTAssertTrue(css.contains("var(--zuuzii-sug-icon-x-0, 24px)"))
        // composer 文案
        XCTAssertTrue(css.contains(#"[data-codex-composer-root] p.placeholder::after"#))
        XCTAssertTrue(css.contains("content: \"夜色已就绪\" !important"))
        // 只允许 SVG mask data URL，禁止任何远程 URL
        XCTAssertFalse(css.contains("http://"))
        XCTAssertFalse(css.contains("https://"))
    }

    func testRendererOmitsExtensionCSSWithoutExtensions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let theme = try makeTheme(directory: directory, heroBytes: Data([0x89, 0x50, 0x4e, 0x47]))
        let css = try SkinCSSRenderer().render(theme: theme).css

        XCTAssertFalse(css.contains("data-zuuzii-anchor"))
        XCTAssertFalse(css.contains("brand-mark"))
        XCTAssertFalse(css.contains("brand-suffix"))
        XCTAssertFalse(css.contains("data:image/"))
    }

    func testBundledThemeRendersThemingExtensionCSS() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeDirectory = repositoryRoot
            .appendingPathComponent("ChatGPTSkinStudio/Resources/Themes/original-night-city")
        let theme = try ThemeValidator().validateAndLoad(
            themeDirectory: themeDirectory,
            source: .bundled
        )

        let css = try SkinCSSRenderer().render(theme: theme).css

        // theme.json 冻结值驱动的扩展 CSS
        XCTAssertTrue(css.contains("padding-left: 34px !important"))
        for index in 0 ..< 6 {
            XCTAssertTrue(
                css.contains(#"[data-zuuzii-anchor="nav-\#(index)"]::before"#),
                "缺少 nav-\(index) 的 ::before 规则"
            )
        }
        for index in 0 ..< 4 {
            XCTAssertTrue(
                css.contains(#"[data-zuuzii-anchor="sug-\#(index)"]::after"#),
                "缺少 sug-\(index) 的 ::after 规则"
            )
        }
        XCTAssertTrue(css.contains("background: #43D8F5"))
        XCTAssertTrue(
            css.contains("content: \"夜色已就绪，写下今晚的第一个任务…\" !important")
        )
        XCTAssertFalse(css.contains("http://"))
        XCTAssertFalse(css.contains("https://"))
    }

    private func makeTheme(
        directory: URL,
        heroBytes: Data,
        motion: Bool = true,
        brand: ThemeBrandConfiguration? = nil,
        icons: ThemeIconConfiguration? = nil,
        texts: ThemeTextConfiguration? = nil
    ) throws -> LoadedTheme {
        let heroURL = directory.appendingPathComponent("hero.png")
        try heroBytes.write(to: heroURL)
        let heroSHA256 = SHA256.hash(data: heroBytes)
            .map { String(format: "%02x", $0) }
            .joined()

        return LoadedTheme(
            manifest: ThemeManifestV3(
                schemaVersion: 3,
                id: "test-theme",
                name: "Test Theme",
                nativeTheme: ThemeNativePalette(
                    accent: "#65D8E8",
                    secondary: "#9A7CFF",
                    surface: "#0E1623",
                    ink: "#F4F7FB",
                    muted: "#9CADC3",
                    success: nil,
                    warning: nil,
                    danger: nil
                ),
                hero: ThemeHeroConfiguration(
                    asset: "hero",
                    focalPoint: .init(x: 0.72, y: 0.35),
                    safeArea: .init(x: 0, y: 0, width: 0.55, height: 1),
                    adaptiveScrim: .init(color: "#070B12", opacity: 0.7)
                ),
                sidebar: .init(opacity: 0.78, blurRadius: 24),
                composer: .init(opacity: 0.84, blurRadius: 20),
                compatibility: .init(
                    adapterProtocol: "chatgpt-macos-renderer",
                    minimumAPIVersion: 1,
                    maximumAPIVersion: 1
                ),
                assets: [
                    "hero": .init(path: "hero.png", sha256: heroSHA256, format: .png, pixelWidth: 1, pixelHeight: 1),
                ],
                features: .init(homeEnhancer: true, motion: motion, routeAware: true),
                brand: brand,
                icons: icons,
                texts: texts
            ),
            directoryURL: directory,
            source: .bundled,
            assets: [
                "hero": .init(name: "hero", fileURL: heroURL, byteCount: heroBytes.count, pixelWidth: 1, pixelHeight: 1, sha256: heroSHA256, format: .png),
            ]
        )
    }
}
