import Foundation

struct ThemeRepository: Sendable {
    static let applicationSupportDirectoryName = "ChatGPTSkinStudio"

    let bundledThemesRoot: URL
    let userThemesRoot: URL
    let validator: ThemeValidator

    init(
        bundledThemesRoot: URL,
        userThemesRoot: URL,
        validator: ThemeValidator = ThemeValidator()
    ) {
        self.bundledThemesRoot = bundledThemesRoot.standardizedFileURL
        self.userThemesRoot = userThemesRoot.standardizedFileURL
        self.validator = validator
    }

    static func live(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> ThemeRepository {
        guard let resourceRoot = bundle.resourceURL else {
            throw ThemeValidationError.fileSystem("应用缺少资源目录")
        }
        let bundledRoot = bundle.url(forResource: "Themes", withExtension: nil)
            ?? resourceRoot.appendingPathComponent("Themes", isDirectory: true)

        let applicationSupportRoot: URL
        do {
            applicationSupportRoot = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw ThemeValidationError.fileSystem(error.localizedDescription)
        }
        let userRoot = applicationSupportRoot
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)

        return ThemeRepository(
            bundledThemesRoot: bundledRoot,
            userThemesRoot: userRoot
        )
    }

    func loadBundledThemes() throws -> [LoadedTheme] {
        try loadThemes(
            from: bundledThemesRoot,
            source: .bundled,
            missingRootIsEmpty: false
        )
    }

    func loadUserThemes() throws -> [LoadedTheme] {
        try loadThemes(
            from: userThemesRoot,
            source: .user,
            missingRootIsEmpty: true
        )
    }

    func loadAllThemes() throws -> [LoadedTheme] {
        let themes = try loadBundledThemes() + loadUserThemes()
        var seenIDs: Set<String> = []
        for theme in themes {
            guard seenIDs.insert(theme.manifest.id).inserted else {
                throw ThemeValidationError.duplicateThemeID(theme.manifest.id)
            }
        }
        return themes.sorted { $0.manifest.id < $1.manifest.id }
    }

    private func loadThemes(
        from root: URL,
        source: ThemeSource,
        missingRootIsEmpty: Bool
    ) throws -> [LoadedTheme] {
        let lexicalRoot = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: lexicalRoot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            if missingRootIsEmpty { return [] }
            throw ThemeValidationError.themeDirectoryMissing(lexicalRoot.path)
        }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: lexicalRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ThemeValidationError.fileSystem(error.localizedDescription)
        }

        var themes: [LoadedTheme] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                throw ThemeValidationError.fileSystem(error.localizedDescription)
            }
            guard values.isDirectory == true else { continue }

            let resolvedEntry = entry.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isDescendant(resolvedEntry, of: resolvedRoot) else {
                throw ThemeValidationError.assetEscapesTheme(entry.lastPathComponent)
            }
            themes.append(
                try validator.validateAndLoad(themeDirectory: entry, source: source)
            )
        }

        var seenIDs: Set<String> = []
        for theme in themes {
            guard seenIDs.insert(theme.manifest.id).inserted else {
                throw ThemeValidationError.duplicateThemeID(theme.manifest.id)
            }
        }
        return themes.sorted { $0.manifest.id < $1.manifest.id }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }
}
