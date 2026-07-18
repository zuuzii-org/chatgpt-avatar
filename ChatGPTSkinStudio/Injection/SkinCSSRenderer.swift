import CryptoKit
import Darwin
import Foundation

struct SkinHeroRenderAsset: Codable, Equatable, Sendable {
    let dataURL: String
    let focalPointX: Double
    let focalPointY: Double
    let pixelWidth: Int
    let pixelHeight: Int
}

struct RenderedSkin: Equatable, Sendable {
    let css: String
    let hero: SkinHeroRenderAsset
}

struct SkinCSSRenderer: Sendable {
    func render(theme: LoadedTheme) throws -> RenderedSkin {
        let manifest = theme.manifest
        let palette = manifest.nativeTheme
        let heroBytes = try readValidatedAsset(theme.heroAsset)
        let mimeType: String
        switch theme.heroAsset.format {
        case .png: mimeType = "image/png"
        case .jpeg: mimeType = "image/jpeg"
        case .webp: mimeType = "image/webp"
        }

        let heroDataURL = "data:\(mimeType);base64,\(heroBytes.base64EncodedString())"
        let surface = try rgba(palette.surface, opacity: manifest.sidebar.opacity)
        let composer = try rgba(palette.surface, opacity: manifest.composer.opacity)
        let elevated = try rgba(palette.surface, opacity: min(0.96, manifest.sidebar.opacity + 0.08))
        let border = try rgba(palette.accent, opacity: 0.28)
        let hoverBorder = try rgba(palette.accent, opacity: 0.62)
        let scrim = try rgba(
            manifest.hero.adaptiveScrim.color,
            opacity: manifest.hero.adaptiveScrim.opacity
        )
        let secondary = palette.secondary ?? palette.accent
        let muted = palette.muted ?? "#9CADC3"
        let success = palette.success ?? "#55D6A8"
        let warning = palette.warning ?? "#F4B860"
        let danger = palette.danger ?? "#FF6B78"
        let focalX = percentage(manifest.hero.focalPoint.x)
        let focalY = percentage(manifest.hero.focalPoint.y)
        let overlayMotionDuration = manifest.features.motion ? "220ms" : "0ms"
        let controlMotionDuration = manifest.features.motion ? "180ms" : "0ms"
        let hoverTranslation = manifest.features.motion ? "-2px" : "0"
        let labelTranslation = manifest.features.motion ? "-4px" : "0"

        let css = """
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) {
          color-scheme: dark;
        }

        :root:has(body > [data-zuuzii-skin-overlay]) {
          --zuuzii-accent: \(palette.accent);
          --zuuzii-secondary: \(secondary);
          --zuuzii-surface: \(palette.surface);
          --zuuzii-surface-glass: \(surface);
          --zuuzii-surface-elevated: \(elevated);
          --zuuzii-composer-glass: \(composer);
          --zuuzii-ink: \(palette.ink);
          --zuuzii-muted: \(muted);
          --zuuzii-success: \(success);
          --zuuzii-warning: \(warning);
          --zuuzii-danger: \(danger);
          --zuuzii-border: \(border);
          --zuuzii-border-hover: \(hoverBorder);
          --zuuzii-scrim: \(scrim);
          --zuuzii-sidebar-blur: \(format(manifest.sidebar.blurRadius))px;
          --zuuzii-composer-blur: \(format(manifest.composer.blurRadius))px;
          --zuuzii-hero-position: \(focalX) \(focalY);
        }

        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) body {
          background: \(palette.surface) !important;
          color: var(--zuuzii-ink);
        }

        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) #root {
          position: relative;
          z-index: 1;
          background: transparent !important;
        }

        body > [data-zuuzii-skin-overlay] {
          position: fixed;
          inset: 0;
          z-index: 0;
          pointer-events: none;
          background: var(--zuuzii-surface);
          opacity: 0.48;
          transition: opacity \(overlayMotionDuration) cubic-bezier(.2,.8,.2,1), filter \(overlayMotionDuration) cubic-bezier(.2,.8,.2,1);
        }

        body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="hero"] {
          object-position: var(--zuuzii-hero-position, center);
          transition: opacity \(overlayMotionDuration) cubic-bezier(.2,.8,.2,1);
        }

        body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="ambient"] {
          background:
            linear-gradient(90deg, var(--zuuzii-scrim) 0%, rgba(7, 11, 18, 0.30) 36%, rgba(7, 11, 18, 0.08) 68%, transparent 94%),
            linear-gradient(0deg, rgba(7, 11, 18, 0.62) 0%, rgba(7, 11, 18, 0.02) 56%),
            radial-gradient(circle at 72% 18%, rgba(101, 216, 232, 0.18), transparent 42%);
        }

        body > [data-zuuzii-skin-overlay][data-skin-mode="full"][data-hero-state="ready"] {
          opacity: 1;
          filter: saturate(1.02) contrast(1.01);
        }

        body > [data-zuuzii-skin-overlay][data-skin-mode="token-only"] {
          opacity: 0;
        }

        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) .app-shell-left-panel,
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-testid="app-shell-floating-left-panel"] {
          background: linear-gradient(90deg, var(--zuuzii-surface-glass) 72%, transparent 100%) !important;
          border-right: 0 !important;
          -webkit-backdrop-filter: blur(var(--zuuzii-sidebar-blur)) saturate(1.15);
          backdrop-filter: blur(var(--zuuzii-sidebar-blur)) saturate(1.15);
          box-shadow: none;
        }

        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-app-shell-main-content-layout],
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) main.main-surface {
          background: transparent !important;
        }

        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-app-shell-main-content-top-fade] {
          opacity: 0.35;
        }

        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-codex-composer-root] .composer-surface-chrome,
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-codex-composer-root] [class*="composer-surface"] {
          background: var(--zuuzii-composer-glass) !important;
          border: 1px solid var(--zuuzii-border) !important;
          -webkit-backdrop-filter: blur(var(--zuuzii-composer-blur)) saturate(1.15);
          backdrop-filter: blur(var(--zuuzii-composer-blur)) saturate(1.15);
          box-shadow: 0 10px 32px rgba(0, 0, 0, 0.20), inset 0 1px rgba(255, 255, 255, 0.05);
          transition: border-color \(controlMotionDuration) ease, box-shadow \(controlMotionDuration) ease, transform \(controlMotionDuration) ease;
        }

        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-codex-composer-root]:focus-within .composer-surface-chrome,
        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-codex-composer-root]:focus-within [class*="composer-surface"] {
          border-color: var(--zuuzii-border-hover) !important;
          box-shadow: 0 12px 36px rgba(0, 0, 0, 0.24), 0 0 0 3px rgba(101, 216, 232, 0.12);
        }

        :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] {
          gap: 14px !important;
        }

        :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] button,
        :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] [role="button"] {
          min-height: 116px;
          background: var(--zuuzii-surface-glass) !important;
          border: 1px solid var(--zuuzii-border) !important;
          border-radius: 18px !important;
          -webkit-backdrop-filter: blur(18px) saturate(1.12);
          backdrop-filter: blur(18px) saturate(1.12);
          box-shadow: 0 8px 24px rgba(0, 0, 0, 0.16), inset 0 1px rgba(255, 255, 255, 0.035);
          color: var(--zuuzii-ink) !important;
          transition: transform \(controlMotionDuration) cubic-bezier(.2,.8,.2,1), border-color \(controlMotionDuration) ease, background \(controlMotionDuration) ease;
        }

        :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] button:hover,
        :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] [role="button"]:hover {
          transform: translateY(\(hoverTranslation));
          border-color: var(--zuuzii-border-hover) !important;
          background: var(--zuuzii-surface-elevated) !important;
        }

        :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) :focus-visible {
          outline: 2px solid var(--zuuzii-accent) !important;
          outline-offset: 2px !important;
        }

        body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="theme-label"] {
          position: absolute;
          top: 26px;
          left: max(322px, 22vw);
          color: var(--zuuzii-ink);
          font: 650 15px/1.25 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          letter-spacing: 0.02em;
          text-shadow: 0 2px 18px rgba(0, 0, 0, 0.52);
          opacity: 0;
          transform: translateY(\(labelTranslation));
          transition: opacity \(controlMotionDuration) ease, transform \(controlMotionDuration) ease;
        }

        body > [data-zuuzii-skin-overlay][data-skin-mode="full"] > [data-zuuzii-skin-role="theme-label"] {
          opacity: 1;
          transform: translateY(0);
        }

        @media (max-width: 1180px) {
          :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] {
            grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
          }
          body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="theme-label"] { display: none; }
        }

        @media (max-width: 1023px) {
          body > [data-zuuzii-skin-overlay] { opacity: 0 !important; }
          :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] button,
          :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] [role="button"] {
            min-height: 96px;
          }
        }

        @media (prefers-reduced-motion: reduce) {
          :root:has(body > [data-zuuzii-skin-overlay]) {
            scroll-behavior: auto !important;
          }
          body > [data-zuuzii-skin-overlay],
          body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="hero"],
          body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="theme-label"],
          :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-codex-composer-root] .composer-surface-chrome,
          :root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode="token-only"])) [data-codex-composer-root] [class*="composer-surface"],
          :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] button,
          :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] [role="button"] {
            animation: none !important;
            transition: none !important;
          }
          :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] button:hover,
          :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"]) [data-home-ambient-suggestions] [role="button"]:hover {
            transform: none;
          }
        }
        """
            + (try renderThemingExtensions(manifest: manifest))

        return RenderedSkin(
            css: css,
            hero: SkinHeroRenderAsset(
                dataURL: heroDataURL,
                focalPointX: manifest.hero.focalPoint.x,
                focalPointY: manifest.hero.focalPoint.y,
                pixelWidth: theme.heroAsset.pixelWidth,
                pixelHeight: theme.heroAsset.pixelHeight
            )
        )
    }

    // MARK: - schema v3.1 扩展 CSS（品牌印记 / 图标替换 / 文案）

    /// 渲染可选扩展块的 CSS。扩展全部缺省时返回空串，旧主题产物一字不变。
    private func renderThemingExtensions(manifest: ThemeManifestV3) throws -> String {
        let brand = manifest.brand
        let icons = manifest.icons
        let texts = manifest.texts
        guard brand != nil || icons != nil || texts != nil else { return "" }

        let palette = manifest.nativeTheme
        let tint = icons?.tint ?? palette.accent
        let accentSoftBackground = try rgba(palette.accent, opacity: 0.12)
        let accentSoftRing = try rgba(palette.accent, opacity: 0.24)
        let accentGlow = try rgba(palette.accent, opacity: 0.35)
        let gate =
            ":root:has(body > [data-zuuzii-skin-overlay]:not([data-skin-mode=\"token-only\"]))"
        let fullGate = ":root:has(body > [data-zuuzii-skin-overlay][data-skin-mode=\"full\"])"

        var sections: [String] = ["\n/* schema v3.1 主题扩展：品牌印记、图标替换、文案 */"]

        if let brand, brand.mark != nil || brand.wordmarkSuffix != nil {
            // 字标槽位：bootstrap 按 anchorText 找到原生字标按钮后打
            // data-zuuzii-anchor="wordmark"，此处只为它预留印记空间。
            let slotPadding = format(brand.wordmarkSlotPadding ?? 34)
            sections.append("""
            \(gate) [data-zuuzii-anchor="wordmark"] {
              padding-left: \(slotPadding)px !important;
            }
            """)
        }

        if brand?.mark != nil || brand?.wordmarkSuffix != nil {
            // owned 印记/后缀节点的几何位置由 bootstrap 按实测 rect 内联写入
            // （owned 节点允许内联样式；原生节点绝不写内联样式）。
            sections.append("""
            body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="brand-mark"],
            body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="brand-suffix"] {
              position: absolute;
              z-index: 3;
              pointer-events: none !important;
            }

            body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="brand-mark"] {
              overflow: visible;
            }

            body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="brand-mark"][data-glow="true"] {
              filter: drop-shadow(0 0 6px var(--zuuzii-accent)) drop-shadow(0 2px 10px rgba(0, 0, 0, 0.35));
            }

            body > [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="brand-suffix"] {
              font: 650 10px/1.2 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              letter-spacing: 0.3em;
              white-space: nowrap;
              color: var(--zuuzii-accent);
              text-shadow: 0 0 14px \(accentGlow);
            }
            """)
        }

        for (index, override) in (icons?.nav ?? []).enumerated() {
            let maskURL = iconMaskDataURL(path: override.path)
            sections.append("""
            \(gate) [data-zuuzii-anchor="nav-\(index)"] {
              position: relative !important;
            }

            \(gate) [data-zuuzii-anchor="nav-\(index)"] svg {
              visibility: hidden !important;
            }

            \(gate) [data-zuuzii-anchor="nav-\(index)"]::before {
              content: "";
              position: absolute;
              left: var(--zuuzii-icon-x-\(index), 0px);
              top: 50%;
              transform: translateY(-50%);
              width: 16px;
              height: 16px;
              background: \(tint);
              -webkit-mask: url("\(maskURL)") center / contain no-repeat;
              mask: url("\(maskURL)") center / contain no-repeat;
              pointer-events: none;
              z-index: 1;
            }
            """)
        }

        for (index, override) in (icons?.suggestions ?? []).enumerated() {
            let maskURL = iconMaskDataURL(path: override.path)
            sections.append("""
            \(fullGate) [data-zuuzii-anchor="sug-\(index)"] {
              position: relative !important;
            }

            \(fullGate) [data-zuuzii-anchor="sug-\(index)"] svg {
              visibility: hidden !important;
            }

            \(fullGate) [data-zuuzii-anchor="sug-\(index)"]::before {
              content: "";
              position: absolute;
              left: var(--zuuzii-sug-icon-x-\(index), 24px);
              top: var(--zuuzii-sug-icon-y-\(index), 24px);
              width: 38px;
              height: 38px;
              border-radius: 50%;
              background: \(accentSoftBackground);
              box-shadow: inset 0 0 0 1px \(accentSoftRing);
              pointer-events: none;
            }

            \(fullGate) [data-zuuzii-anchor="sug-\(index)"]::after {
              content: "";
              position: absolute;
              left: calc(var(--zuuzii-sug-icon-x-\(index), 24px) + 11px);
              top: calc(var(--zuuzii-sug-icon-y-\(index), 24px) + 11px);
              width: 16px;
              height: 16px;
              background: \(tint);
              -webkit-mask: url("\(maskURL)") center / contain no-repeat;
              mask: url("\(maskURL)") center / contain no-repeat;
              pointer-events: none;
            }
            """)
        }

        if let placeholder = texts?.composerPlaceholder {
            // 原生 placeholder 文案由 p.placeholder::after 的 content 渲染
            // （只读探测已确认），同钩子覆盖即可；文案经校验不含引号、
            // 反斜杠、尖括号与控制字符，CSS 通道无需转义。
            sections.append("""
            \(gate) [data-codex-composer-root] p.placeholder::after {
              content: "\(placeholder)" !important;
            }
            """)
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    /// 把 24×24 网格的图标 path 组装成独立 SVG 文档并编码为 data URL。
    /// base64 字母表不含引号与反斜杠，可安全通过 payload CSS 通道。
    private func iconMaskDataURL(path: String) -> String {
        let svg =
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\">"
            + "<path d=\"\(path)\"/></svg>"
        return "data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"
    }

    private func rgba(_ hex: String, opacity: Double) throws -> String {
        let value = hex.dropFirst()
        guard value.count == 6, let integer = Int(value, radix: 16) else {
            throw SkinError.invalidConfiguration("非法颜色：\(hex)")
        }
        let red = (integer >> 16) & 0xff
        let green = (integer >> 8) & 0xff
        let blue = integer & 0xff
        return "rgba(\(red), \(green), \(blue), \(format(opacity)))"
    }

    private func percentage(_ value: Double) -> String {
        "\(format(value * 100))%"
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private func readValidatedAsset(_ asset: LoadedThemeAsset) throws -> Data {
        let descriptor = asset.fileURL.path
        let fileDescriptor: Int32 = asset.fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fileDescriptor >= 0 else {
            throw SkinError.invalidConfiguration(
                "主题资源在验证后不可安全读取：\(descriptor)"
            )
        }
        defer { Darwin.close(fileDescriptor) }

        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= ThemeValidator.maximumAssetBytes,
              Int(metadata.st_size) == asset.byteCount
        else {
            throw SkinError.invalidConfiguration(
                "主题资源在验证后发生了类型或大小变化：\(descriptor)"
            )
        }

        var bytes = Data(count: asset.byteCount)
        try bytes.withUnsafeMutableBytes { buffer in
            guard asset.byteCount == 0 || buffer.baseAddress != nil else {
                throw SkinError.invalidConfiguration("无法分配主题资源缓冲区。")
            }
            var offset = 0
            while offset < asset.byteCount {
                let count = Darwin.read(
                    fileDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    asset.byteCount - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SkinError.invalidConfiguration(
                        "主题资源在读取期间发生了变化：\(descriptor)"
                    )
                }
                offset += count
            }
        }

        var trailingByte: UInt8 = 0
        let trailingCount = Darwin.read(fileDescriptor, &trailingByte, 1)
        guard trailingCount == 0 else {
            throw SkinError.invalidConfiguration(
                "主题资源在读取期间发生了大小变化：\(descriptor)"
            )
        }

        let actualSHA256 = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256.caseInsensitiveCompare(asset.sha256) == .orderedSame else {
            throw SkinError.invalidConfiguration(
                "主题资源在验证后发生了内容变化：\(descriptor)"
            )
        }
        return bytes
    }
}
