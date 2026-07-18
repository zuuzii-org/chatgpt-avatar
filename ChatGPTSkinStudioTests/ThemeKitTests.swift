import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ChatGPTSkinStudio

final class ThemeKitTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSkinStudio-ThemeKitTests-\(UUID().uuidString)")
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

    func testBundledOriginalNightCityManifestAndHeroValidate() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeDirectory = repositoryRoot
            .appendingPathComponent("ChatGPTSkinStudio/Resources/Themes/original-night-city")

        let loaded = try ThemeValidator().validateAndLoad(
            themeDirectory: themeDirectory,
            source: .bundled
        )

        XCTAssertEqual(loaded.manifest.schemaVersion, 3)
        XCTAssertEqual(loaded.manifest.id, "original-night-city")
        XCTAssertEqual(loaded.manifest.compatibility.adapterProtocol, "chatgpt-macos-renderer")
        XCTAssertEqual(loaded.manifest.compatibility.minimumAPIVersion, 1)
        XCTAssertEqual(loaded.manifest.compatibility.maximumAPIVersion, 1)
        XCTAssertEqual(loaded.source, .bundled)
        XCTAssertEqual(loaded.heroAsset.pixelWidth, 1920)
        XCTAssertEqual(loaded.heroAsset.pixelHeight, 1200)
        XCTAssertEqual(
            loaded.heroAsset.sha256,
            "d74db725cbd88cf5dcb49f6f162a049349b16130a72affc5f66c7275e0435473"
        )
    }

    func testRepositoryLoadsBundledAndApplicationSupportThemes() throws {
        let bundledRoot = temporaryRoot.appendingPathComponent("Bundled")
        let userRoot = temporaryRoot.appendingPathComponent("Application Support/Themes")
        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        _ = try makeTheme(in: bundledRoot, id: "bundled-theme", name: "Bundled")
        _ = try makeTheme(in: userRoot, id: "user-theme", name: "User")

        let repository = ThemeRepository(
            bundledThemesRoot: bundledRoot,
            userThemesRoot: userRoot
        )
        let themes = try repository.loadAllThemes()

        XCTAssertEqual(themes.map(\.manifest.id), ["bundled-theme", "user-theme"])
        XCTAssertEqual(themes.map(\.source), [.bundled, .user])
    }

    func testMissingUserThemeRootIsAnEmptyCatalog() throws {
        let bundledRoot = temporaryRoot.appendingPathComponent("Bundled")
        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        _ = try makeTheme(in: bundledRoot, id: "bundled-theme", name: "Bundled")

        let repository = ThemeRepository(
            bundledThemesRoot: bundledRoot,
            userThemesRoot: temporaryRoot.appendingPathComponent("Missing")
        )

        XCTAssertEqual(try repository.loadUserThemes(), [])
        XCTAssertEqual(try repository.loadAllThemes().map(\.manifest.id), ["bundled-theme"])
    }

    func testRepositoryRejectsDuplicateIDsAcrossBundledAndUserRoots() throws {
        let bundledRoot = temporaryRoot.appendingPathComponent("Bundled")
        let userRoot = temporaryRoot.appendingPathComponent("User")
        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        _ = try makeTheme(in: bundledRoot, id: "same-id", name: "Bundled")
        _ = try makeTheme(in: userRoot, id: "same-id", name: "User")

        let repository = ThemeRepository(
            bundledThemesRoot: bundledRoot,
            userThemesRoot: userRoot
        )
        XCTAssertThrowsError(try repository.loadAllThemes()) { error in
            XCTAssertEqual(error as? ThemeValidationError, .duplicateThemeID("same-id"))
        }
    }

    func testRejectsInvalidThemeIDAndColor() throws {
        let theme = try makeTheme(in: temporaryRoot, id: "valid-id", name: "Valid")
        var manifest = try readManifest(at: theme)
        manifest["id"] = "../../unsafe"
        try writeManifest(manifest, to: theme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .invalidID("../../unsafe"))
        }

        manifest["id"] = "valid-id"
        var palette = try XCTUnwrap(manifest["nativeTheme"] as? [String: Any])
        palette["accent"] = "rgb(0, 0, 0)"
        manifest["nativeTheme"] = palette
        try writeManifest(manifest, to: theme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .invalidColor(field: "nativeTheme.accent", value: "rgb(0, 0, 0)")
            )
        }
    }

    func testCompatibilityUsesAdapterProtocolAPIRangeInsteadOfAppBuild() throws {
        let theme = try makeTheme(in: temporaryRoot, id: "protocol-theme", name: "Protocol")
        var manifest = try readManifest(at: theme)
        var compatibility = try XCTUnwrap(manifest["compatibility"] as? [String: Any])

        XCTAssertNil(compatibility["minimumBuild"])
        XCTAssertNil(compatibility["maximumBuild"])
        compatibility["minimumAPIVersion"] = 1
        compatibility["maximumAPIVersion"] = 2
        manifest["compatibility"] = compatibility
        try writeManifest(manifest, to: theme)

        let loaded = try ThemeValidator().validateAndLoad(
            themeDirectory: theme,
            source: .user
        )
        XCTAssertTrue(loaded.manifest.compatibility.supports(ChatGPTStructuralAdapterV1().manifest.protocolContract))

        compatibility["minimumAPIVersion"] = 0
        manifest["compatibility"] = compatibility
        try writeManifest(manifest, to: theme)
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .invalidCompatibility)
        }
    }

    func testLegacyBuildBoundThemeSchemaIsRejectedExplicitly() throws {
        let theme = try makeTheme(in: temporaryRoot, id: "legacy-theme", name: "Legacy")
        var manifest = try readManifest(at: theme)
        manifest["schemaVersion"] = 2
        manifest["compatibility"] = [
            "adapterID": "chatgpt-app-26.707.72221-5307",
            "minimumBuild": 5307,
            "maximumBuild": 5307,
        ]
        try writeManifest(manifest, to: theme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .unsupportedSchema(2))
        }
    }

    func testRejectsPathTraversalAndSymlinkEscape() throws {
        let traversalTheme = try makeTheme(
            in: temporaryRoot,
            id: "path-traversal",
            name: "Traversal"
        )
        var traversalManifest = try readManifest(at: traversalTheme)
        var traversalAssets = try XCTUnwrap(traversalManifest["assets"] as? [String: Any])
        var traversalHero = try XCTUnwrap(traversalAssets["hero"] as? [String: Any])
        traversalHero["path"] = "../outside.png"
        traversalAssets["hero"] = traversalHero
        traversalManifest["assets"] = traversalAssets
        try writeManifest(traversalManifest, to: traversalTheme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: traversalTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .invalidRelativePath("../outside.png")
            )
        }

        let symlinkTheme = temporaryRoot.appendingPathComponent("symlink-theme")
        try FileManager.default.createDirectory(at: symlinkTheme, withIntermediateDirectories: true)
        let outsideURL = temporaryRoot.appendingPathComponent("outside.png")
        let outsideBytes = try makePNG(width: 8, height: 4)
        try outsideBytes.write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: symlinkTheme.appendingPathComponent("hero.png"),
            withDestinationURL: outsideURL
        )
        try writeManifest(
            validManifest(
                id: "symlink-theme",
                name: "Symlink",
                imagePath: "hero.png",
                imageSHA256: sha256Hex(outsideBytes),
                format: .png,
                width: 8,
                height: 4
            ),
            to: symlinkTheme
        )

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: symlinkTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .assetEscapesTheme("hero.png"))
        }
    }

    func testRejectsUnsupportedExtensionAndFakeImage() throws {
        let unsupported = try makeTheme(
            in: temporaryRoot,
            id: "unsupported-extension",
            name: "Unsupported"
        )
        let original = unsupported.appendingPathComponent("hero.png")
        let renamed = unsupported.appendingPathComponent("hero.gif")
        try FileManager.default.moveItem(at: original, to: renamed)
        var unsupportedManifest = try readManifest(at: unsupported)
        var unsupportedAssets = try XCTUnwrap(unsupportedManifest["assets"] as? [String: Any])
        var unsupportedHero = try XCTUnwrap(unsupportedAssets["hero"] as? [String: Any])
        unsupportedHero["path"] = "hero.gif"
        unsupportedAssets["hero"] = unsupportedHero
        unsupportedManifest["assets"] = unsupportedAssets
        try writeManifest(unsupportedManifest, to: unsupported)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: unsupported, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .unsupportedAssetExtension("hero.gif")
            )
        }

        let fakeTheme = temporaryRoot.appendingPathComponent("fake-image")
        try FileManager.default.createDirectory(at: fakeTheme, withIntermediateDirectories: true)
        let fakeBytes = Data("not a png".utf8)
        try fakeBytes.write(to: fakeTheme.appendingPathComponent("hero.png"))
        try writeManifest(
            validManifest(
                id: "fake-image",
                name: "Fake",
                imagePath: "hero.png",
                imageSHA256: sha256Hex(fakeBytes),
                format: .png,
                width: 8,
                height: 4
            ),
            to: fakeTheme
        )

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: fakeTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .invalidImage("hero.png"))
        }
    }

    func testRejectsAssetLargerThan15MiB() throws {
        let theme = temporaryRoot.appendingPathComponent("oversize-theme")
        try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
        let imageURL = theme.appendingPathComponent("hero.png")
        FileManager.default.createFile(atPath: imageURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(atOffset: UInt64(ThemeValidator.maximumAssetBytes + 1))
        try handle.close()
        try writeManifest(
            validManifest(
                id: "oversize-theme",
                name: "Oversize",
                imagePath: "hero.png",
                imageSHA256: String(repeating: "0", count: 64),
                format: .png,
                width: 8,
                height: 4
            ),
            to: theme
        )

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            guard case let ThemeValidationError.assetTooLarge(path, bytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, "hero.png")
            XCTAssertGreaterThan(bytes, ThemeValidator.maximumAssetBytes)
        }
    }

    func testRejectsDeclaredImageOver40MP() throws {
        let theme = try makeTheme(in: temporaryRoot, id: "huge-pixels", name: "Huge")
        var manifest = try readManifest(at: theme)
        var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
        var hero = try XCTUnwrap(assets["hero"] as? [String: Any])
        hero["pixelWidth"] = 10_000
        hero["pixelHeight"] = 4_001
        assets["hero"] = hero
        manifest["assets"] = assets
        try writeManifest(manifest, to: theme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .pixelLimitExceeded(path: "hero.png", width: 10_000, height: 4_001)
            )
        }
    }

    func testRejectsSHAFormatAndContentMismatch() throws {
        let theme = try makeTheme(in: temporaryRoot, id: "hash-theme", name: "Hash")
        var manifest = try readManifest(at: theme)
        var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
        var hero = try XCTUnwrap(assets["hero"] as? [String: Any])
        hero["sha256"] = "abc"
        assets["hero"] = hero
        manifest["assets"] = assets
        try writeManifest(manifest, to: theme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .invalidSHA256(path: "hero.png"))
        }

        hero["sha256"] = String(repeating: "0", count: 64)
        assets["hero"] = hero
        manifest["assets"] = assets
        try writeManifest(manifest, to: theme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .sha256Mismatch(path: "hero.png"))
        }
    }

    func testRejectsActualImageFormatAndDimensionMismatch() throws {
        let theme = try makeTheme(
            in: temporaryRoot,
            id: "format-theme",
            name: "Format",
            imageFileName: "hero.jpg",
            declaredFormat: .jpeg
        )
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .imageFormatMismatch(path: "hero.jpg", declared: .jpeg, actual: .png)
            )
        }

        let dimensionTheme = try makeTheme(
            in: temporaryRoot,
            id: "dimension-theme",
            name: "Dimension"
        )
        var manifest = try readManifest(at: dimensionTheme)
        var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
        var hero = try XCTUnwrap(assets["hero"] as? [String: Any])
        hero["pixelWidth"] = 9
        assets["hero"] = hero
        manifest["assets"] = assets
        try writeManifest(manifest, to: dimensionTheme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: dimensionTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .imageDimensionsMismatch(
                    path: "hero.png",
                    expectedWidth: 9,
                    expectedHeight: 4,
                    actualWidth: 8,
                    actualHeight: 4
                )
            )
        }
    }

    func testStrictSchemaRejectsCSSJavaScriptAndRemoteURLs() throws {
        let unknownFieldTheme = try makeTheme(
            in: temporaryRoot,
            id: "unknown-field",
            name: "Unknown"
        )
        var unknownManifest = try readManifest(at: unknownFieldTheme)
        unknownManifest["css"] = "body { display: none }"
        try writeManifest(unknownManifest, to: unknownFieldTheme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: unknownFieldTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .unknownKey(path: "$", key: "css")
            )
        }

        let remoteTheme = try makeTheme(in: temporaryRoot, id: "remote", name: "Remote")
        var remoteManifest = try readManifest(at: remoteTheme)
        var remoteAssets = try XCTUnwrap(remoteManifest["assets"] as? [String: Any])
        var remoteHero = try XCTUnwrap(remoteAssets["hero"] as? [String: Any])
        remoteHero["path"] = "https://example.com/hero.png"
        remoteAssets["hero"] = remoteHero
        remoteManifest["assets"] = remoteAssets
        try writeManifest(remoteManifest, to: remoteTheme)

        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: remoteTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .forbiddenRemoteValue("https://example.com/hero.png")
            )
        }

        let scriptTheme = try makeTheme(in: temporaryRoot, id: "script", name: "Script")
        try Data("alert(1)".utf8).write(to: scriptTheme.appendingPathComponent("payload.js"))
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: scriptTheme, source: .user)
        ) { error in
            guard case ThemeValidationError.prohibitedExecutableAsset = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - schema v3.1 扩展校验

    func testValidThemingExtensionsValidate() throws {
        let theme = try makeTheme(in: temporaryRoot, id: "ext-valid", name: "Ext Valid")
        var manifest = try readManifest(at: theme)
        manifest["brand"] = validBrandBlock()
        manifest["icons"] = [
            "tint": "#43D8F5",
            "nav": [["match": "新建任务", "path": "M12 3l1.8 4.6L18 9z"]],
            "suggestions": [["match": "探索", "path": "M8 6l-5 6 5 6z"]],
        ]
        manifest["texts"] = ["composerPlaceholder": "夜色已就绪"]
        try writeManifest(manifest, to: theme)

        let loaded = try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)

        XCTAssertEqual(loaded.manifest.brand?.mark?.anchorText, "Codex")
        XCTAssertEqual(loaded.manifest.brand?.mark?.size, 20)
        XCTAssertEqual(loaded.manifest.brand?.mark?.svgViewBox, "0 0 48 48")
        XCTAssertEqual(loaded.manifest.brand?.mark?.glow, true)
        XCTAssertEqual(loaded.manifest.brand?.wordmarkSuffix, "NIGHT CITY")
        XCTAssertEqual(loaded.manifest.brand?.wordmarkSlotPadding, 34)
        XCTAssertEqual(loaded.manifest.icons?.tint, "#43D8F5")
        XCTAssertEqual(loaded.manifest.icons?.nav?.count, 1)
        XCTAssertEqual(loaded.manifest.icons?.suggestions?.first?.match, "探索")
        XCTAssertEqual(loaded.manifest.texts?.composerPlaceholder, "夜色已就绪")
    }

    func testLegacyThemeWithoutExtensionsStillValidates() throws {
        let theme = try makeTheme(in: temporaryRoot, id: "legacy", name: "Legacy")

        let loaded = try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)

        XCTAssertNil(loaded.manifest.brand)
        XCTAssertNil(loaded.manifest.icons)
        XCTAssertNil(loaded.manifest.texts)
    }

    func testBundledNightCityThemingExtensionsValidate() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeDirectory = repositoryRoot
            .appendingPathComponent("ChatGPTSkinStudio/Resources/Themes/original-night-city")

        let loaded = try ThemeValidator().validateAndLoad(
            themeDirectory: themeDirectory,
            source: .bundled
        )

        // 冻结规格值：品牌印记 + 6 条 nav 图标 + 4 条建议卡图标 + composer 文案
        XCTAssertEqual(loaded.manifest.brand?.mark?.anchorText, "Codex")
        XCTAssertEqual(loaded.manifest.brand?.mark?.size, 20)
        XCTAssertEqual(loaded.manifest.brand?.mark?.svgViewBox, "0 0 48 48")
        XCTAssertEqual(loaded.manifest.brand?.mark?.glow, true)
        XCTAssertEqual(loaded.manifest.brand?.wordmarkSuffix, "NIGHT CITY")
        XCTAssertEqual(loaded.manifest.brand?.wordmarkSlotPadding, 34)
        XCTAssertEqual(loaded.manifest.icons?.tint, "#43D8F5")
        XCTAssertEqual(
            loaded.manifest.icons?.nav?.map(\.match),
            ["新建任务", "拉取请求", "站点", "已安排", "插件", "项目"]
        )
        XCTAssertEqual(
            loaded.manifest.icons?.suggestions?.map(\.match),
            ["探索", "构建", "审查", "修复"]
        )
        XCTAssertEqual(
            loaded.manifest.texts?.composerPlaceholder,
            "夜色已就绪，写下今晚的第一个任务…"
        )
        // hero 资源未动，sha256 保持不变
        XCTAssertEqual(
            loaded.heroAsset.sha256,
            "d74db725cbd88cf5dcb49f6f162a049349b16130a72affc5f66c7275e0435473"
        )
    }

    func testRejectsUnsafeSVGBodyContent() throws {
        let scriptTheme = try extensionTheme(id: "svg-script") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["svgBody"] = "<script>alert(1)</script>"
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: scriptTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .svgBodyUnsafe(detail: "<script"))
        }

        let eventTheme = try extensionTheme(id: "svg-event") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["svgBody"] = "<rect onload=\"alert(1)\" width=\"4\" height=\"4\"/>"
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: eventTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .svgBodyUnsafe(detail: "事件属性 on*=")
            )
        }

        let urlTheme = try extensionTheme(id: "svg-url") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["svgBody"] = "<rect fill=\"url(#gradient)\" width=\"4\" height=\"4\"/>"
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: urlTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .svgBodyUnsafe(detail: "url("))
        }

        let httpTheme = try extensionTheme(id: "svg-http") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["svgBody"] = "<image href=\"https://evil.invalid/x.png\"/>"
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: httpTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .svgBodyUnsafe(detail: "http"))
        }

        let javascriptTheme = try extensionTheme(id: "svg-javascript") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["svgBody"] = "<a href=\"javascript:alert(1)\"><rect width=\"4\" height=\"4\"/></a>"
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: javascriptTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .svgBodyUnsafe(detail: "javascript:")
            )
        }
    }

    func testRejectsOversizedSVGBodyAndInvalidViewBox() throws {
        let oversizedTheme = try extensionTheme(id: "svg-oversized") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["svgBody"] = String(repeating: "a", count: 4 * 1024 + 1)
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: oversizedTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .svgBodyTooLarge(bytes: 4 * 1024 + 1)
            )
        }

        let viewBoxTheme = try extensionTheme(id: "svg-viewbox") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["svgViewBox"] = "0 0 48"
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: viewBoxTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .invalidSVGViewBox("0 0 48"))
        }
    }

    func testRejectsInvalidIconOverrides() throws {
        let badPathStartTheme = try extensionTheme(id: "icon-start") { manifest in
            manifest["icons"] = [
                "nav": [["match": "新建任务", "path": "L12 3l1.8 4.6z"]],
            ]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: badPathStartTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .iconPathMustStartWithCommand(match: "新建任务")
            )
        }

        let oversizedPathTheme = try extensionTheme(id: "icon-oversized") { manifest in
            manifest["icons"] = [
                "nav": [["match": "新建任务", "path": "M" + String(repeating: "1", count: 2048)]],
            ]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: oversizedPathTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .iconPathTooLarge(match: "新建任务", bytes: 2049)
            )
        }

        let unsafePathTheme = try extensionTheme(id: "icon-unsafe") { manifest in
            manifest["icons"] = [
                "nav": [["match": "新建任务", "path": "M12 3 url(https://evil.invalid) z"]],
            ]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: unsafePathTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .iconPathUnsafe(match: "新建任务", detail: "http")
            )
        }

        let emptyMatchTheme = try extensionTheme(id: "icon-empty-match") { manifest in
            manifest["icons"] = ["nav": [["match": "", "path": "M12 3z"]]]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: emptyMatchTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .invalidIconMatch(""))
        }

        let longMatchTheme = try extensionTheme(id: "icon-long-match") { manifest in
            manifest["icons"] = [
                "nav": [["match": String(repeating: "长", count: 33), "path": "M12 3z"]],
            ]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: longMatchTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .invalidIconMatch(String(repeating: "长", count: 33))
            )
        }

        let tooManyTheme = try extensionTheme(id: "icon-too-many") { manifest in
            manifest["icons"] = [
                "nav": (0 ..< 17).map { ["match": "条目\($0)", "path": "M12 3z"] },
            ]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: tooManyTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .tooManyIconOverrides(field: "icons.nav", count: 17)
            )
        }

        let badTintTheme = try extensionTheme(id: "icon-bad-tint") { manifest in
            manifest["icons"] = [
                "tint": "#43D8F5FF",
                "nav": [["match": "新建任务", "path": "M12 3z"]],
            ]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: badTintTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .invalidColor(field: "icons.tint", value: "#43D8F5FF")
            )
        }
    }

    func testRejectsInvalidBrandFieldsAndExtensionTexts() throws {
        let anchorTheme = try extensionTheme(id: "brand-anchor") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["anchorText"] = String(repeating: "字", count: 33)
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: anchorTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .invalidAnchorText(String(repeating: "字", count: 33))
            )
        }

        let sizeTheme = try extensionTheme(id: "brand-size") { manifest in
            var brand = validBrandBlock()
            var mark = brand["mark"] as! [String: Any]
            mark["size"] = 49
            brand["mark"] = mark
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: sizeTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .invalidBrandMarkSize(49))
        }

        let paddingTheme = try extensionTheme(id: "brand-padding") { manifest in
            var brand = validBrandBlock()
            brand["wordmarkSlotPadding"] = 65
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: paddingTheme, source: .user)
        ) { error in
            XCTAssertEqual(error as? ThemeValidationError, .invalidWordmarkSlotPadding(65))
        }

        let suffixTheme = try extensionTheme(id: "brand-suffix") { manifest in
            var brand = validBrandBlock()
            brand["wordmarkSuffix"] = String(repeating: "夜", count: 33)
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: suffixTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .extensionTextTooLong(field: "brand.wordmarkSuffix", length: 33)
            )
        }

        let placeholderTheme = try extensionTheme(id: "text-long") { manifest in
            manifest["texts"] = [
                "composerPlaceholder": String(repeating: "夜", count: 33),
            ]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: placeholderTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .extensionTextTooLong(field: "texts.composerPlaceholder", length: 33)
            )
        }

        // 文案进入 CSS content 字符串，引号会破坏样式表通道，必须拒绝
        let quoteTheme = try extensionTheme(id: "text-quote") { manifest in
            manifest["texts"] = ["composerPlaceholder": "夜色\"已就绪"]
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: quoteTheme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .extensionTextUnsafe(field: "texts.composerPlaceholder")
            )
        }
    }

    func testStrictSchemaRejectsUnknownExtensionKeys() throws {
        let theme = try extensionTheme(id: "ext-unknown-key") { manifest in
            var brand = validBrandBlock()
            brand["evil"] = true
            manifest["brand"] = brand
        }
        XCTAssertThrowsError(
            try ThemeValidator().validateAndLoad(themeDirectory: theme, source: .user)
        ) { error in
            XCTAssertEqual(
                error as? ThemeValidationError,
                .unknownKey(path: "$.brand", key: "evil")
            )
        }
    }

    /// 构造带合法 brand 块的扩展主题，再由各用例按需改写。
    private func extensionTheme(
        id: String,
        mutate: (inout [String: Any]) -> Void
    ) throws -> URL {
        let theme = try makeTheme(in: temporaryRoot, id: id, name: id)
        var manifest = try readManifest(at: theme)
        mutate(&manifest)
        try writeManifest(manifest, to: theme)
        return theme
    }

    private func validBrandBlock() -> [String: Any] {
        [
            "mark": [
                "anchorText": "Codex",
                "size": 20,
                "svgViewBox": "0 0 48 48",
                "svgBody": "<circle cx=\"24\" cy=\"24\" r=\"20\" fill=\"#0A1A2F\"/>",
                "glow": true,
            ],
            "wordmarkSuffix": "NIGHT CITY",
            "wordmarkSlotPadding": 34,
        ]
    }

    @discardableResult
    private func makeTheme(
        in themesRoot: URL,
        id: String,
        name: String,
        imageFileName: String = "hero.png",
        declaredFormat: ThemeImageFormat = .png
    ) throws -> URL {
        let themeDirectory = themesRoot.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: themeDirectory,
            withIntermediateDirectories: true
        )
        let imageBytes = try makePNG(width: 8, height: 4)
        try imageBytes.write(to: themeDirectory.appendingPathComponent(imageFileName))
        try writeManifest(
            validManifest(
                id: id,
                name: name,
                imagePath: imageFileName,
                imageSHA256: sha256Hex(imageBytes),
                format: declaredFormat,
                width: 8,
                height: 4
            ),
            to: themeDirectory
        )
        return themeDirectory
    }

    private func validManifest(
        id: String,
        name: String,
        imagePath: String,
        imageSHA256: String,
        format: ThemeImageFormat,
        width: Int,
        height: Int
    ) -> [String: Any] {
        [
            "schemaVersion": 3,
            "id": id,
            "name": name,
            "nativeTheme": [
                "accent": "#43D8F5",
                "secondary": "#8A7CF5",
                "surface": "#091426",
                "ink": "#EAF6FF",
                "muted": "#9DB2C7",
                "success": "#56D6AD",
                "warning": "#E8C66A",
                "danger": "#F1788D",
            ],
            "hero": [
                "asset": "hero",
                "focalPoint": ["x": 0.75, "y": 0.35],
                "safeArea": ["x": 0.02, "y": 0.08, "width": 0.52, "height": 0.8],
                "adaptiveScrim": ["color": "#061020", "opacity": 0.36],
            ],
            "sidebar": ["opacity": 0.78, "blurRadius": 28],
            "composer": ["opacity": 0.82, "blurRadius": 24],
            "compatibility": [
                "adapterProtocol": "chatgpt-macos-renderer",
                "minimumAPIVersion": 1,
                "maximumAPIVersion": 1,
            ],
            "assets": [
                "hero": [
                    "path": imagePath,
                    "sha256": imageSHA256,
                    "format": format.rawValue,
                    "pixelWidth": width,
                    "pixelHeight": height,
                ],
            ],
            "features": [
                "homeEnhancer": true,
                "motion": false,
                "routeAware": true,
            ],
        ]
    }

    private func readManifest(at themeDirectory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: themeDirectory.appendingPathComponent("theme.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeManifest(_ manifest: [String: Any], to themeDirectory: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: themeDirectory.appendingPathComponent("theme.json"),
            options: .atomic
        )
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.fixtureCreationFailed
        }
        context.setFillColor(red: 0.1, green: 0.4, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestError.fixtureCreationFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestError.fixtureCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestError.fixtureCreationFailed
        }
        return output as Data
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum TestError: Error {
    case fixtureCreationFailed
}
