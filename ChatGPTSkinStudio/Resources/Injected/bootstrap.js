(() => {
  "use strict";

  const BOOTSTRAP_VERSION = 7;
  const INSTALL_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.install");
  const STATE_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.state");
  const PAYLOAD_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.payload");
  const RUNTIME_BINDING_NAME_SYMBOL = Symbol.for(
    "com.zuuzii.chatgpt-skin.runtime-binding-name"
  );
  const OWNER_ATTRIBUTE = "data-zuuzii-skin-owner";
  // schema v3.1：打在原生元素上的样式定位钩子（只增删我们自己的属性，
  // 不 reparent/替换/删除原生节点；cleanup 时必须全部移除）。
  const ANCHOR_ATTRIBUTE = "data-zuuzii-anchor";
  const ANCHOR_GENERATION_ATTRIBUTE = "data-zuuzii-anchor-generation";
  const NATIVE_NODE_POLICY = "never-reparent-native-nodes";
  const MAX_CSS_LENGTH = 1024 * 1024;
  const MAX_HERO_DATA_URL_LENGTH = 21 * 1024 * 1024;
  const HERO_LOAD_TIMEOUT_MS = 12_000;
  // schema v3.1 扩展字段的防御性上限（与原生 ThemeValidator 一致）
  const MAX_SVG_BODY_BYTES = 4 * 1024;
  const MAX_ICON_PATH_BYTES = 2 * 1024;
  const MAX_ICON_OVERRIDES = 16;
  const MAX_EXTENSION_TEXT_LENGTH = 32;
  const WORDMARK_SLOT_PADDING_DEFAULT = 34;

  const existingInstaller = globalThis[INSTALL_SYMBOL];
  if (
    typeof existingInstaller === "function"
    && existingInstaller.bootstrapVersion === BOOTSTRAP_VERSION
  ) {
    return;
  }

  const bootstrapCSS = String.raw`
    /*
      Keep the owned hero's geometry outside cascade layers. Host releases can
      add unlayered global img rules, which outrank every named layer even when
      their selector is less specific. These !important declarations are safe
      because the node is created and exclusively owned by this bootstrap.
    */
    body > [data-zuuzii-skin-overlay]
      > [data-zuuzii-skin-role="hero"] {
      position: absolute !important;
      inset: 0 !important;
      z-index: 0 !important;
      display: block !important;
      width: 100% !important;
      height: 100% !important;
      max-width: none !important;
      max-height: none !important;
      object-fit: cover !important;
      opacity: 0 !important;
      pointer-events: none !important;
    }

    body > [data-zuuzii-skin-overlay][data-skin-mode="full"][data-hero-state="ready"]
      > [data-zuuzii-skin-role="hero"][data-image-state="ready"] {
      opacity: 1 !important;
    }

    body > [data-zuuzii-skin-overlay][data-skin-mode="full"] {
      opacity: 0 !important;
    }

    body > [data-zuuzii-skin-overlay][data-skin-mode="full"][data-hero-state="ready"] {
      opacity: 1 !important;
    }

    body > [data-zuuzii-skin-overlay][data-skin-mode="core"] {
      opacity: 0.72 !important;
    }

    body > [data-zuuzii-skin-overlay][data-skin-mode="token-only"] {
      opacity: 0 !important;
    }

    @layer zuuzii-skin-bootstrap {
      [data-zuuzii-skin-overlay] {
        position: fixed;
        inset: 0;
        z-index: 0;
        overflow: hidden;
        pointer-events: none !important;
        user-select: none;
        opacity: 0;
        background: var(--zuuzii-surface, transparent);
        transition: opacity 180ms cubic-bezier(0.2, 0, 0, 1);
        contain: strict;
        isolation: isolate;
      }

      [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="hero"],
      [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="ambient"],
      [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="theme-label"],
      [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="brand-mark"],
      [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="brand-suffix"] {
        position: absolute;
        pointer-events: none !important;
      }

      [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="hero"] {
        inset: 0;
        z-index: 0;
        width: 100%;
        height: 100%;
        object-fit: cover;
        object-position: var(--zuuzii-hero-position, center);
        opacity: 0;
        transition: opacity 220ms cubic-bezier(0.2, 0.8, 0.2, 1);
      }

      [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="ambient"] {
        inset: 0;
        z-index: 1;
        background:
          linear-gradient(
            180deg,
            color-mix(in srgb, var(--zuuzii-surface, #10131a) 8%, transparent),
            color-mix(in srgb, var(--zuuzii-surface, #10131a) 72%, transparent)
          ),
          radial-gradient(
            circle at 72% 18%,
            color-mix(in srgb, var(--zuuzii-accent, #7c9cff) 24%, transparent),
            transparent 42%
          );
      }

      [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="theme-label"] {
        z-index: 2;
      }

      [data-zuuzii-skin-overlay][data-skin-mode="full"] {
        opacity: 0;
      }

      [data-zuuzii-skin-overlay][data-skin-mode="full"][data-hero-state="ready"] {
        opacity: 1;
      }

      [data-zuuzii-skin-overlay][data-skin-mode="full"]
        > [data-zuuzii-skin-role="hero"][data-image-state="ready"] {
        opacity: 1;
      }

      [data-zuuzii-skin-overlay][data-skin-mode="core"] {
        opacity: 0.72;
        background:
          radial-gradient(
            circle at 78% 0%,
            color-mix(in srgb, var(--zuuzii-accent, #7c9cff) 10%, transparent),
            transparent 44%
          ),
          var(--zuuzii-surface, transparent);
      }

      [data-zuuzii-skin-overlay][data-skin-mode="token-only"] {
        opacity: 0;
      }

      :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"])
        body > #root,
      :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="core"])
        body > #root {
        position: relative;
        z-index: 1;
        background: transparent;
      }

      :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"])
        [data-app-shell-main-content-layout],
      :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="core"])
        [data-app-shell-main-content-layout] {
        background: transparent;
      }

      :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"])
        [data-codex-composer-root],
      :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="core"])
        [data-codex-composer-root] {
        border-color: color-mix(
          in srgb,
          var(--zuuzii-border, currentColor) 58%,
          transparent
        );
        background: color-mix(
          in srgb,
          var(--zuuzii-surface, canvas) var(--zuuzii-composer-opacity, 76%),
          transparent
        );
        box-shadow: var(
          --zuuzii-composer-shadow,
          0 10px 32px color-mix(in srgb, black 14%, transparent)
        );
        backdrop-filter: blur(var(--zuuzii-composer-blur, 24px)) saturate(1.08);
      }

      :root:has(body > [data-zuuzii-skin-overlay][data-skin-mode="full"])
        [data-testid="app-shell-floating-left-panel"] {
        border-color: color-mix(
          in srgb,
          var(--zuuzii-border, currentColor) 52%,
          transparent
        );
        background: color-mix(
          in srgb,
          var(--zuuzii-surface, canvas) var(--zuuzii-sidebar-opacity, 72%),
          transparent
        );
        backdrop-filter: blur(var(--zuuzii-sidebar-blur, 28px)) saturate(1.08);
      }

      @media (max-width: 1023px) {
        [data-zuuzii-skin-overlay] {
          opacity: 0 !important;
        }
      }

      @media (prefers-reduced-motion: reduce) {
        [data-zuuzii-skin-overlay],
        [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="hero"],
        [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="ambient"],
        [data-zuuzii-skin-overlay] > [data-zuuzii-skin-role="theme-label"] {
          animation: none !important;
          transition: none !important;
        }
      }
    }
  `;

  function failure(reason, detail) {
    return Object.freeze({
      ok: false,
      failClosed: true,
      pending: false,
      reason,
      detail: detail instanceof Error ? detail.message : String(detail || ""),
      nativeNodePolicy: NATIVE_NODE_POLICY,
    });
  }

  function reportRuntimeRevalidation(generation, event) {
    if (![
      "adapter-probe-failed",
      "renderer-not-ready",
      "runtime-install-failed",
    ].includes(event)) return;
    const bindingName = globalThis[RUNTIME_BINDING_NAME_SYMBOL];
    if (typeof bindingName !== "string" || bindingName.length > 128) return;
    const binding = globalThis[bindingName];
    if (typeof binding !== "function") return;
    try {
      binding(JSON.stringify({
        schemaVersion: 1,
        event,
        generation,
      }));
    } catch (_) {
      // Native reporting is best-effort; fail-closed cleanup already happened.
    }
  }

  function rendererPending(probeResult) {
    const counts = probeResult?.counts;
    const failures = probeResult?.failures;
    return Object.freeze({
      ok: false,
      failClosed: false,
      pending: true,
      reason: "renderer-not-ready",
      rawPath: typeof probeResult?.rawPath === "string" ? probeResult.rawPath : "unknown",
      path: typeof probeResult?.path === "string" ? probeResult.path : "unknown",
      routeID: typeof probeResult?.routeID === "string" ? probeResult.routeID : "unclassified",
      viewportWidth: Number.isFinite(probeResult?.viewportWidth)
        ? probeResult.viewportWidth
        : 0,
      entryScriptMatchCount: Number.isFinite(probeResult?.entryScriptMatchCount)
        ? probeResult.entryScriptMatchCount
        : 0,
      counts: counts && typeof counts === "object" && !Array.isArray(counts)
        ? counts
        : Object.freeze({}),
      failures: Array.isArray(failures) ? failures : Object.freeze([]),
      nativeNodePolicy: NATIVE_NODE_POLICY,
    });
  }

  function assetRenderPending(probeResult) {
    return Object.freeze({
      ok: false,
      failClosed: false,
      pending: true,
      reason: "asset-render-pending",
      routeID: typeof probeResult?.routeID === "string"
        ? probeResult.routeID
        : "unclassified",
      viewportWidth: Number.isFinite(probeResult?.viewportWidth)
        ? probeResult.viewportWidth
        : 0,
      entryScriptMatchCount: Number.isFinite(probeResult?.entryScriptMatchCount)
        ? probeResult.entryScriptMatchCount
        : 0,
      nativeNodePolicy: NATIVE_NODE_POLICY,
    });
  }

  function adapterProbeFailure(probeResult, error) {
    const counts = probeResult?.counts;
    const failures = probeResult?.failures;
    return Object.freeze({
      ok: false,
      failClosed: true,
      pending: false,
      reason: "adapter-probe-failed",
      detail: error instanceof Error ? error.message : "probe rejected renderer",
      routeID: typeof probeResult?.routeID === "string"
        ? probeResult.routeID
        : "unclassified",
      viewportWidth: Number.isFinite(probeResult?.viewportWidth)
        ? probeResult.viewportWidth
        : 0,
      entryScriptMatchCount: Number.isFinite(probeResult?.entryScriptMatchCount)
        ? probeResult.entryScriptMatchCount
        : 0,
      counts: counts && typeof counts === "object" && !Array.isArray(counts)
        ? counts
        : Object.freeze({}),
      failures: Array.isArray(failures) ? failures : Object.freeze([]),
      nativeNodePolicy: NATIVE_NODE_POLICY,
    });
  }

  function utf8ByteLength(value) {
    if (typeof TextEncoder === "function") {
      return new TextEncoder().encode(value).byteLength;
    }

    // JavaScriptCore unit-test contexts do not expose TextEncoder. Keep the
    // fail-safe calculation equivalent without allocating another large buffer.
    let byteLength = 0;
    for (let index = 0; index < value.length; index += 1) {
      const codeUnit = value.charCodeAt(index);
      if (codeUnit <= 0x7f) {
        byteLength += 1;
      } else if (codeUnit <= 0x7ff) {
        byteLength += 2;
      } else if (
        codeUnit >= 0xd800
        && codeUnit <= 0xdbff
        && index + 1 < value.length
        && value.charCodeAt(index + 1) >= 0xdc00
        && value.charCodeAt(index + 1) <= 0xdfff
      ) {
        byteLength += 4;
        index += 1;
      } else {
        byteLength += 3;
      }
      if (byteLength > MAX_CSS_LENGTH) return byteLength;
    }
    return byteLength;
  }

  function normalizePayload(payload) {
    if (!payload || typeof payload !== "object") {
      throw new TypeError("payload must be an object");
    }

    const generation = String(payload.generation || "");
    const themeID = String(payload.themeID || "");
    const themeName = String(payload.themeName || "");
    const css = payload.css;
    const hero = payload.hero;

    if (!/^[A-Za-z0-9._:-]{1,128}$/.test(generation)) {
      throw new TypeError("invalid generation");
    }
    if (!/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/.test(themeID)) {
      throw new TypeError("invalid themeID");
    }
    if (
      themeName.length === 0
      || themeName.length > 100
      || themeName.trim() !== themeName
    ) {
      throw new TypeError("invalid themeName");
    }
    if (
      typeof css !== "string"
      || utf8ByteLength(css) > MAX_CSS_LENGTH
      || css.includes("\0")
    ) {
      throw new TypeError("invalid css");
    }
    if (typeof payload.adapterProbe !== "function") {
      throw new TypeError("adapterProbe must be a trusted function");
    }
    if (!hero || typeof hero !== "object" || Array.isArray(hero)) {
      throw new TypeError("invalid hero");
    }

    const heroDataURL = hero.dataURL;
    const heroDataURLPattern = /^data:image\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/]*={0,2}$/i;
    if (
      typeof heroDataURL !== "string"
      || heroDataURL.length === 0
      || heroDataURL.length > MAX_HERO_DATA_URL_LENGTH
    ) {
      throw new TypeError("invalid hero data URL");
    }
    const heroPayloadOffset = heroDataURL.indexOf(",") + 1;
    if (
      !heroDataURLPattern.test(heroDataURL)
      || heroPayloadOffset <= 0
      || (heroDataURL.length - heroPayloadOffset) % 4 !== 0
    ) {
      throw new TypeError("invalid hero data URL");
    }
    if (
      !Number.isFinite(hero.focalPointX)
      || !Number.isFinite(hero.focalPointY)
      || hero.focalPointX < 0
      || hero.focalPointX > 1
      || hero.focalPointY < 0
      || hero.focalPointY > 1
      || !Number.isSafeInteger(hero.pixelWidth)
      || !Number.isSafeInteger(hero.pixelHeight)
      || hero.pixelWidth <= 0
      || hero.pixelHeight <= 0
    ) {
      throw new TypeError("invalid hero metadata");
    }

    // Image bytes travel through the typed hero payload. Keeping all url()
    // declarations out of CSS avoids Blink's per-token size limit and prevents
    // theme CSS from becoming a second resource-loading channel.
    //
    // v6 例外：原生渲染器为图标替换生成的 owned SVG mask data URL
    // （仅允许 "data:image/svg+xml;base64,..." 双引号形态，内容为本地数据，
    // 不构成远程加载通道）。剥离这批白名单片段后，其余 URL/指令照旧全禁。
    const cssWithoutOwnedMasks = css.replace(
      /url\(\s*"data:image\/svg\+xml;base64,[A-Za-z0-9+/]*={0,2}"\s*\)/g,
      ""
    );
    if (
      cssWithoutOwnedMasks.includes("\\")
      || /@import\b/i.test(cssWithoutOwnedMasks)
      || /expression\s*\(/i.test(cssWithoutOwnedMasks)
      || /url\s*\(/i.test(cssWithoutOwnedMasks)
      || /(?:https?:|\/\/|file:|javascript:)/i.test(cssWithoutOwnedMasks)
    ) {
      throw new TypeError("css contains a prohibited URL or directive");
    }

    return Object.freeze({
      generation,
      themeID,
      themeName,
      css,
      hero: Object.freeze({
        dataURL: heroDataURL,
        focalPointX: hero.focalPointX,
        focalPointY: hero.focalPointY,
        pixelWidth: hero.pixelWidth,
        pixelHeight: hero.pixelHeight,
      }),
      adapterProbe: payload.adapterProbe,
      // schema v3.1：可选扩展宽松透传 + 逐字段防御（非法片段丢弃并记日志，
      // 绝不因此让整个 install 失败）。
      brand: normalizeBrandExtension(payload.brand),
      icons: normalizeIconsExtension(payload.icons),
      texts: normalizeTextsExtension(payload.texts),
    });
  }

  // MARK: - schema v3.1 payload 扩展归一化

  function warnExtensionDrop(field, reason) {
    try {
      console.warn(`[zuuzii-skin] theming extension dropped: ${field} (${reason})`);
    } catch (_) {
      // console 不可用时静默；防御性丢弃已经发生。
    }
  }

  /// soft 级日志：console 缺失（如 JSContext 测试环境）时静默，
  /// 绝不因日志本身让扩展流程抛错。
  function warnSoft(...args) {
    try {
      console.warn(...args);
    } catch (_) {
      // best-effort
    }
  }

  /// SVG 片段安全检查：与原生 ThemeValidator 同规则，命中即丢弃。
  function sanitizeSVGFragment(value, maxBytes, field) {
    if (typeof value !== "string" || value.length === 0) {
      warnExtensionDrop(field, "not a non-empty string");
      return null;
    }
    if (utf8ByteLength(value) > maxBytes) {
      warnExtensionDrop(field, "byte limit exceeded");
      return null;
    }
    if (/<script/i.test(value)) {
      warnExtensionDrop(field, "<script");
      return null;
    }
    if (/on[A-Za-z]+\s*=/i.test(value)) {
      warnExtensionDrop(field, "event handler attribute");
      return null;
    }
    if (/http/i.test(value)) {
      warnExtensionDrop(field, "http");
      return null;
    }
    if (/url\s*\(/i.test(value)) {
      warnExtensionDrop(field, "url(");
      return null;
    }
    if (/javascript:/i.test(value)) {
      warnExtensionDrop(field, "javascript:");
      return null;
    }
    return value;
  }

  function normalizeExtensionText(value, field) {
    if (typeof value !== "string") return null;
    if (value.length === 0 || value.length > MAX_EXTENSION_TEXT_LENGTH) {
      warnExtensionDrop(field, "length outside 1...32");
      return null;
    }
    return value;
  }

  function normalizeBrandMark(rawMark) {
    if (!rawMark || typeof rawMark !== "object" || Array.isArray(rawMark)) return null;
    const anchorText = normalizeExtensionText(rawMark.anchorText, "brand.mark.anchorText");
    const svgViewBox = typeof rawMark.svgViewBox === "string"
      && /^-?\d+(?:\.\d+)?\s+-?\d+(?:\.\d+)?\s+\d+(?:\.\d+)?\s+\d+(?:\.\d+)?$/
        .test(rawMark.svgViewBox)
      ? rawMark.svgViewBox
      : null;
    if (!svgViewBox) warnExtensionDrop("brand.mark.svgViewBox", "invalid viewBox");
    const svgBody = sanitizeSVGFragment(
      rawMark.svgBody,
      MAX_SVG_BODY_BYTES,
      "brand.mark.svgBody"
    );
    const size = Number.isFinite(rawMark.size) && rawMark.size >= 12 && rawMark.size <= 48
      ? rawMark.size
      : null;
    if (size === null) warnExtensionDrop("brand.mark.size", "outside 12...48");
    if (!anchorText || !svgViewBox || !svgBody || size === null) return null;
    return Object.freeze({
      anchorText,
      size,
      svgViewBox,
      svgBody,
      glow: rawMark.glow === true,
    });
  }

  function normalizeBrandExtension(rawBrand) {
    if (!rawBrand || typeof rawBrand !== "object" || Array.isArray(rawBrand)) {
      return undefined;
    }
    const mark = normalizeBrandMark(rawBrand.mark);
    const wordmarkSuffix = normalizeExtensionText(
      rawBrand.wordmarkSuffix,
      "brand.wordmarkSuffix"
    );
    const wordmarkSlotPadding = Number.isFinite(rawBrand.wordmarkSlotPadding)
      && rawBrand.wordmarkSlotPadding >= 0
      && rawBrand.wordmarkSlotPadding <= 64
      ? rawBrand.wordmarkSlotPadding
      : null;
    if (!mark && !wordmarkSuffix) return undefined;
    return Object.freeze({ mark, wordmarkSuffix, wordmarkSlotPadding });
  }

  function normalizeIconOverride(rawEntry, field) {
    if (!rawEntry || typeof rawEntry !== "object" || Array.isArray(rawEntry)) return null;
    const match = normalizeExtensionText(rawEntry.match, `${field}.match`);
    if (!match) return null;
    const path = sanitizeSVGFragment(rawEntry.path, MAX_ICON_PATH_BYTES, `${field}.path`);
    if (!path || !/^\s*[Mm]/.test(path)) {
      warnExtensionDrop(`${field}.path`, "must start with M/m");
      return null;
    }
    return Object.freeze({ match, path });
  }

  function normalizeIconOverrideList(rawList, field) {
    if (!Array.isArray(rawList)) return Object.freeze([]);
    const entries = [];
    for (let index = 0; index < rawList.length; index += 1) {
      if (entries.length >= MAX_ICON_OVERRIDES) {
        warnExtensionDrop(field, "more than 16 overrides");
        break;
      }
      const entry = normalizeIconOverride(rawList[index], `${field}[${index}]`);
      if (entry) entries.push(entry);
    }
    return Object.freeze(entries);
  }

  function normalizeIconsExtension(rawIcons) {
    if (!rawIcons || typeof rawIcons !== "object" || Array.isArray(rawIcons)) {
      return undefined;
    }
    const tint = typeof rawIcons.tint === "string" && /^#[0-9A-Fa-f]{6}$/.test(rawIcons.tint)
      ? rawIcons.tint
      : null;
    const nav = normalizeIconOverrideList(rawIcons.nav, "icons.nav");
    const suggestions = normalizeIconOverrideList(
      rawIcons.suggestions,
      "icons.suggestions"
    );
    if (nav.length === 0 && suggestions.length === 0) return undefined;
    return Object.freeze({ tint, nav, suggestions });
  }

  function normalizeTextsExtension(rawTexts) {
    if (!rawTexts || typeof rawTexts !== "object" || Array.isArray(rawTexts)) {
      return undefined;
    }
    const composerPlaceholder = normalizeExtensionText(
      rawTexts.composerPlaceholder,
      "texts.composerPlaceholder"
    );
    if (!composerPlaceholder) return undefined;
    return Object.freeze({ composerPlaceholder });
  }

  function payloadForInstall(rawPayload) {
    if (
      rawPayload
      && typeof rawPayload === "object"
      && !Array.isArray(rawPayload)
      && Object.keys(rawPayload).length === 1
      && typeof rawPayload.resumeGeneration === "string"
    ) {
      const cached = globalThis[PAYLOAD_SYMBOL];
      if (
        cached
        && cached.generation === rawPayload.resumeGeneration
        && cached.payload?.generation === rawPayload.resumeGeneration
      ) {
        return cached.payload;
      }
      throw new TypeError("resume payload unavailable");
    }

    const payload = normalizePayload(rawPayload);
    globalThis[PAYLOAD_SYMBOL] = Object.freeze({
      generation: payload.generation,
      payload,
    });
    return payload;
  }

  function runProbe(adapterProbe) {
    try {
      const result = adapterProbe();
      if (
        result
        && typeof result === "object"
        && result.ok === false
        && result.failClosed === false
        && result.pending === true
        && result.reason === "renderer-not-ready"
      ) {
        return { status: "pending", result };
      }
      if (
        !result
        || typeof result !== "object"
        || result.ok !== true
        || result.failClosed !== false
        || result.pending === true
        || !["full", "core", "token-only"].includes(result.effectiveMode)
        || typeof result.routeID !== "string"
      ) {
        return { status: "hard-failure", result };
      }
      return { status: "ready", result };
    } catch (error) {
      return { status: "hard-failure", error };
    }
  }

  function removeOwnedNodes() {
    let count = 0;
    for (const node of document.querySelectorAll(`[${OWNER_ATTRIBUTE}]`)) {
      node.remove();
      count += 1;
    }
    return count;
  }

  function clearOwnedState(reason) {
    const activeState = globalThis[STATE_SYMBOL];
    if (activeState && typeof activeState.cleanup === "function") {
      try {
        activeState.cleanup(reason);
      } catch (_) {
        // Fail closed below even if a stale generation has a broken cleanup hook.
      }
    }
    if (globalThis[STATE_SYMBOL] === activeState) delete globalThis[STATE_SYMBOL];
    removeOwnedNodes();
  }

  function install(rawPayload) {
    let payload;
    try {
      payload = payloadForInstall(rawPayload);
    } catch (error) {
      return failure("invalid-payload", error);
    }

    const preflight = runProbe(payload.adapterProbe);
    const activeState = globalThis[STATE_SYMBOL];
    if (preflight.status === "pending") {
      clearOwnedState("renderer-not-ready");
      return rendererPending(preflight.result);
    }
    if (preflight.status !== "ready") {
      clearOwnedState("probe-fail-closed");
      return adapterProbeFailure(preflight.result, preflight.error);
    }

    if (
      activeState
      && activeState.active === true
      && activeState.generation === payload.generation
      && typeof activeState.refresh === "function"
    ) {
      return activeState.refresh("idempotent");
    }

    if (activeState && typeof activeState.cleanup === "function") {
      activeState.cleanup("replace-generation");
    }
    removeOwnedNodes();

    const controller = new AbortController();
    const observers = new Set();
    const timeouts = new Set();
    const intervals = new Set();
    const animationFrames = new Set();
    const manualCleanups = new Set();

    const style = document.createElement("style");
    style.setAttribute(OWNER_ATTRIBUTE, payload.generation);
    style.setAttribute("data-zuuzii-skin-role", "style");
    style.textContent = `${bootstrapCSS}\n${payload.css}`;

    const overlay = document.createElement("div");
    overlay.setAttribute(OWNER_ATTRIBUTE, payload.generation);
    overlay.setAttribute("data-zuuzii-skin-role", "overlay");
    overlay.setAttribute("data-zuuzii-skin-overlay", "");
    overlay.setAttribute("aria-hidden", "true");
    overlay.setAttribute("inert", "");
    overlay.dataset.themeId = payload.themeID;
    overlay.dataset.themeName = payload.themeName;
    overlay.dataset.heroState = "idle";

    const heroImage = document.createElement("img");
    heroImage.setAttribute("data-zuuzii-skin-role", "hero");
    heroImage.setAttribute("aria-hidden", "true");
    heroImage.setAttribute("alt", "");
    heroImage.dataset.imageState = "idle";
    heroImage.decoding = "async";
    heroImage.draggable = false;

    const ambient = document.createElement("div");
    ambient.setAttribute("data-zuuzii-skin-role", "ambient");
    ambient.setAttribute("aria-hidden", "true");

    const themeLabel = document.createElement("div");
    themeLabel.setAttribute("data-zuuzii-skin-role", "theme-label");
    themeLabel.setAttribute("aria-hidden", "true");
    themeLabel.textContent = payload.themeName;

    overlay.appendChild(heroImage);
    overlay.appendChild(ambient);
    overlay.appendChild(themeLabel);

    const heroLoad = {
      status: "idle",
      detail: "",
      timeoutID: null,
      runtimeFailureReported: false,
    };

    let scheduledTimeout = null;
    let state;
    let runtimeRetryScheduled = false;

    // Runtime failure debounce. A refresh() mismatch only tears the skin down
    // after the same failure signature is seen on 3 consecutive samples
    // spanning at least 600 ms. Transient host re-renders (React commits,
    // streaming updates, route transitions) keep the installed skin mounted.
    const runtimeFailure = {
      signature: "",
      count: 0,
      firstAt: 0,
    };

    function trackedTimeout(callback, delay) {
      const id = globalThis.setTimeout(() => {
        timeouts.delete(id);
        callback();
      }, delay);
      timeouts.add(id);
      return id;
    }

    function trackedAnimationFrame(callback) {
      const id = globalThis.requestAnimationFrame((timestamp) => {
        animationFrames.delete(id);
        callback(timestamp);
      });
      animationFrames.add(id);
      return id;
    }

    function applyProbeResult(probeResult) {
      overlay.dataset.skinMode = probeResult.effectiveMode;
      overlay.dataset.routeId = probeResult.routeID;
      overlay.dataset.reducedMotion = probeResult.reducedMotion ? "true" : "false";
      overlay.dataset.viewportWidth = String(probeResult.viewportWidth);
    }

    // MARK: - schema v3.1 主题扩展（品牌印记 / 图标替换 / 文案）
    //
    // 全部锚点都是 soft 级：找不到只跳过并 console.warn，绝不抛错、
    // 绝不影响皮肤主体。所有 DOM 操作遵守 never-reparent-native-nodes：
    // 只往 owned overlay/head 追加节点；对原生元素只增删我们自己的
    // data-zuuzii-anchor* 属性钩子（样式定位用途），不写内联样式、
    // 不移动/替换/删除任何原生节点。
    const extensionRuntime = {
      // 本次 refresh 实测的锚点槽位：[{ key, declarations: [[name, value]] }]
      anchorMeasurements: [],
      appliedDynamicCSS: "",
      brandSignature: "",
    };

    function extensionTextOf(node) {
      try {
        return String(node.textContent || "").replace(/\s+/g, " ").trim();
      } catch (_) {
        return "";
      }
    }

    function findExtensionButton(scope, matcher) {
      const root = scope || document;
      let candidates;
      try {
        candidates = root.querySelectorAll('button, a, [role="button"]');
      } catch (_) {
        return null;
      }
      for (const candidate of candidates) {
        try {
          if (matcher(extensionTextOf(candidate))) return candidate;
        } catch (_) {
          // 单个候选节点异常不影响其余匹配。
        }
      }
      return null;
    }

    function findSidebarScope() {
      try {
        return document.querySelector(
          'aside.app-shell-left-panel, .app-shell-left-panel, [data-testid="app-shell-floating-left-panel"]'
        );
      } catch (_) {
        return null;
      }
    }

    function findSuggestionsContainer() {
      try {
        return document.querySelector("[data-home-ambient-suggestions]");
      } catch (_) {
        return null;
      }
    }

    function markAnchor(node, kind) {
      if (
        node.getAttribute(ANCHOR_ATTRIBUTE) === kind
        && node.getAttribute(ANCHOR_GENERATION_ATTRIBUTE) === payload.generation
      ) {
        return; // 幂等：属主与种类都正确时不再触碰原生节点
      }
      node.setAttribute(ANCHOR_ATTRIBUTE, kind);
      node.setAttribute(ANCHOR_GENERATION_ATTRIBUTE, payload.generation);
    }

    function clearAnchorMarkers() {
      let nodes;
      try {
        nodes = document.querySelectorAll(`[${ANCHOR_ATTRIBUTE}]`);
      } catch (_) {
        return;
      }
      for (const node of nodes) {
        try {
          node.removeAttribute(ANCHOR_ATTRIBUTE);
          node.removeAttribute(ANCHOR_GENERATION_ATTRIBUTE);
        } catch (_) {
          // best-effort：单个节点失败不阻断其余清理。
        }
      }
    }

    function clearStaleAnchorMarkers() {
      let nodes;
      try {
        nodes = document.querySelectorAll(`[${ANCHOR_ATTRIBUTE}]`);
      } catch (_) {
        return;
      }
      for (const node of nodes) {
        try {
          if (node.getAttribute(ANCHOR_GENERATION_ATTRIBUTE) !== payload.generation) {
            node.removeAttribute(ANCHOR_ATTRIBUTE);
            node.removeAttribute(ANCHOR_GENERATION_ATTRIBUTE);
          }
        } catch (_) {
          // best-effort
        }
      }
    }

    /// 实测按钮内原生 svg 槽位相对按钮的偏移；拿不到返回 null（CSS 变量
    /// 维持默认值，规则自动降级）。
    function measureIconSlot(button) {
      let svg = null;
      try {
        svg = button.querySelector("svg");
      } catch (_) {
        return null;
      }
      if (!svg) return null;
      try {
        const buttonRect = button.getBoundingClientRect();
        const svgRect = svg.getBoundingClientRect();
        if (
          !Number.isFinite(svgRect.x)
          || !Number.isFinite(buttonRect.x)
          || !Number.isFinite(svgRect.y)
          || !Number.isFinite(buttonRect.y)
        ) {
          return null;
        }
        const round = (value) => Math.round(value * 100) / 100;
        return {
          x: round(svgRect.x - buttonRect.x),
          y: round(svgRect.y - buttonRect.y),
          width: round(svgRect.width),
          height: round(svgRect.height),
        };
      } catch (_) {
        return null;
      }
    }

    function recordMeasurement(key, name, value) {
      extensionRuntime.anchorMeasurements.push({ key, name, value });
    }

    function applyAnchorMarkers() {
      extensionRuntime.anchorMeasurements = [];
      clearStaleAnchorMarkers();

      const brand = payload.brand;
      const icons = payload.icons;

      // (a) 字标按钮：按 anchorText 匹配侧边栏按钮文本
      if (brand && (brand.mark || brand.wordmarkSuffix) && brand.mark) {
        const anchorText = brand.mark.anchorText;
        const sidebar = findSidebarScope();
        const wordmarkButton = sidebar
          ? findExtensionButton(
              sidebar,
              (text) => text === anchorText || text.startsWith(anchorText)
            )
          : null;
        if (wordmarkButton) {
          markAnchor(wordmarkButton, "wordmark");
        } else {
          warnSoft(`[zuuzii-skin] soft anchor missing: wordmark ("${anchorText}")`);
        }
      }

      // (b) nav 图标替换：按 match 匹配侧边栏按钮，实测 svg 槽位 x 偏移
      const navOverrides = icons ? icons.nav : [];
      for (let index = 0; index < navOverrides.length; index += 1) {
        const override = navOverrides[index];
        const kind = `nav-${index}`;
        const sidebar = findSidebarScope();
        const button = sidebar
          ? findExtensionButton(
              sidebar,
              (text) => text === override.match || text.startsWith(override.match)
            )
          : null;
        if (!button) {
          warnSoft(
            `[zuuzii-skin] soft anchor missing: ${kind} ("${override.match}")`
          );
          continue;
        }
        markAnchor(button, kind);
        const slot = measureIconSlot(button);
        if (slot) {
          recordMeasurement(kind, `--zuuzii-icon-x-${index}`, `${slot.x}px`);
        }
      }

      // (c) 建议卡图标：按 match 前缀匹配按钮文本，圆形底框对齐原生 svg 中心
      const suggestionOverrides = icons ? icons.suggestions : [];
      if (suggestionOverrides.length > 0) {
        const container = findSuggestionsContainer();
        if (!container) {
          warnSoft("[zuuzii-skin] soft anchor missing: suggestion-cards");
        } else {
          for (let index = 0; index < suggestionOverrides.length; index += 1) {
            const override = suggestionOverrides[index];
            const kind = `sug-${index}`;
            const button = findExtensionButton(
              container,
              (text) => text.startsWith(override.match)
            );
            if (!button) {
              warnSoft(
                `[zuuzii-skin] soft anchor missing: ${kind} ("${override.match}")`
              );
              continue;
            }
            markAnchor(button, kind);
            const slot = measureIconSlot(button);
            if (slot) {
              // 38px 圆形底框以原生 svg 中心为圆心
              recordMeasurement(
                kind,
                `--zuuzii-sug-icon-x-${index}`,
                `${Math.round((slot.x + slot.width / 2 - 19) * 100) / 100}px`
              );
              recordMeasurement(
                kind,
                `--zuuzii-sug-icon-y-${index}`,
                `${Math.round((slot.y + slot.height / 2 - 19) * 100) / 100}px`
              );
            }
          }
        }
      }
    }

    function removeBrandExtensionNodes() {
      let nodes;
      try {
        nodes = overlay.querySelectorAll(
          '[data-zuuzii-skin-role="brand-mark"], [data-zuuzii-skin-role="brand-suffix"]'
        );
      } catch (_) {
        return;
      }
      for (const node of nodes) {
        try {
          node.remove();
        } catch (_) {
          // best-effort
        }
      }
    }

    function buildBrandMarkNode(mark, slotPadding, rect) {
      if (typeof globalThis.DOMParser !== "function") {
        warnSoft("[zuuzii-skin] DOMParser unavailable; brand mark skipped");
        return null;
      }
      const size = mark.size;
      const documentText = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${mark.svgViewBox}" width="${size}" height="${size}">${mark.svgBody}</svg>`;
      let svgRoot = null;
      try {
        const parsed = new globalThis.DOMParser().parseFromString(
          documentText,
          "image/svg+xml"
        );
        svgRoot = parsed ? parsed.documentElement : null;
      } catch (error) {
        warnSoft("[zuuzii-skin] brand mark parse failed:", error);
        return null;
      }
      if (
        !svgRoot
        || String(svgRoot.tagName || "").toLowerCase() === "parsererror"
      ) {
        warnSoft("[zuuzii-skin] brand mark parse rejected");
        return null;
      }
      svgRoot.setAttribute(OWNER_ATTRIBUTE, payload.generation);
      svgRoot.setAttribute("data-zuuzii-skin-role", "brand-mark");
      svgRoot.setAttribute("data-glow", mark.glow ? "true" : "false");
      svgRoot.setAttribute("aria-hidden", "true");
      // owned 节点允许内联几何：印记放在按钮文本左侧预留槽位内并垂直居中。
      const left = rect.x + Math.max(0, (slotPadding - size) / 2);
      const top = rect.y + rect.height / 2 - size / 2;
      svgRoot.style.position = "absolute";
      svgRoot.style.left = `${left}px`;
      svgRoot.style.top = `${top}px`;
      svgRoot.style.width = `${size}px`;
      svgRoot.style.height = `${size}px`;
      return svgRoot;
    }

    function buildBrandSuffixNode(suffix, rect) {
      const node = document.createElement("span");
      node.setAttribute(OWNER_ATTRIBUTE, payload.generation);
      node.setAttribute("data-zuuzii-skin-role", "brand-suffix");
      node.setAttribute("aria-hidden", "true");
      node.textContent = suffix;
      node.style.position = "absolute";
      node.style.left = `${rect.x + 2}px`;
      // suffix 贴字标按钮下沿 +3px
      node.style.top = `${rect.y + rect.height + 3}px`;
      return node;
    }

    function applyBrandMarkNodes() {
      const brand = payload.brand;
      if (!brand || (!brand.mark && !brand.wordmarkSuffix)) {
        if (extensionRuntime.brandSignature) {
          removeBrandExtensionNodes();
          extensionRuntime.brandSignature = "";
        }
        return;
      }
      if (!brand.mark) {
        // suffix/槽位需要字标按钮锚点，而锚点文本由 mark.anchorText 提供；
        // 没有 mark 时无法定位，整块 soft 跳过。
        warnSoft("[zuuzii-skin] soft anchor missing: brand.mark");
        return;
      }
      let anchor = null;
      try {
        anchor = document.querySelector(
          `[${ANCHOR_ATTRIBUTE}="wordmark"][${ANCHOR_GENERATION_ATTRIBUTE}="${payload.generation}"]`
        );
      } catch (_) {
        anchor = null;
      }
      if (!anchor) {
        warnSoft("[zuuzii-skin] soft anchor missing: wordmark brand nodes");
        return;
      }
      let rect;
      try {
        rect = anchor.getBoundingClientRect();
      } catch (_) {
        rect = null;
      }
      if (
        !rect
        || !Number.isFinite(rect.x)
        || !Number.isFinite(rect.y)
        || rect.width <= 0
        || rect.height <= 0
      ) {
        warnSoft("[zuuzii-skin] wordmark anchor has no measurable rect");
        return;
      }
      // 幂等重放：几何签名未变时不重建 owned 节点，避免与 MutationObserver
      // 互相触发形成刷新循环。
      const signature = [
        Math.round(rect.x * 2) / 2,
        Math.round(rect.y * 2) / 2,
        Math.round(rect.width * 2) / 2,
        Math.round(rect.height * 2) / 2,
      ].join(",");
      if (signature === extensionRuntime.brandSignature) return;
      removeBrandExtensionNodes();
      const slotPadding = brand.wordmarkSlotPadding ?? WORDMARK_SLOT_PADDING_DEFAULT;
      if (brand.mark) {
        const markNode = buildBrandMarkNode(brand.mark, slotPadding, rect);
        if (markNode) overlay.appendChild(markNode);
      }
      if (brand.wordmarkSuffix) {
        overlay.appendChild(buildBrandSuffixNode(brand.wordmarkSuffix, rect));
      }
      extensionRuntime.brandSignature = signature;
    }

    /// 把实测槽位写成我们样式表末尾的 CSS 变量段；只有内容变化时才重建
    /// style.textContent（不触碰任何原生节点的内联样式）。
    function syncExtensionStyleSegment() {
      const declarationsByKey = new Map();
      for (const measurement of extensionRuntime.anchorMeasurements) {
        if (!declarationsByKey.has(measurement.key)) {
          declarationsByKey.set(measurement.key, []);
        }
        declarationsByKey
          .get(measurement.key)
          .push(`${measurement.name}:${measurement.value}`);
      }
      const rules = [];
      for (const [key, declarations] of declarationsByKey) {
        rules.push(`[${ANCHOR_ATTRIBUTE}="${key}"]{${declarations.join(";")}}`);
      }
      const dynamicCSS = rules.length > 0
        ? `\n/* schema v3.1 扩展锚点实测槽位（bootstrap 写入） */\n${rules.join("\n")}\n`
        : "";
      if (dynamicCSS === extensionRuntime.appliedDynamicCSS) return;
      extensionRuntime.appliedDynamicCSS = dynamicCSS;
      style.textContent = `${bootstrapCSS}\n${payload.css}${dynamicCSS}`;
    }

    function applyThemingExtensions() {
      // 每个阶段独立软失败：任何异常只记日志，绝不向 install/refresh 传播。
      try {
        applyAnchorMarkers();
      } catch (error) {
        warnSoft("[zuuzii-skin] theming anchors skipped:", error);
      }
      try {
        applyBrandMarkNodes();
      } catch (error) {
        warnSoft("[zuuzii-skin] brand mark skipped:", error);
      }
      try {
        syncExtensionStyleSegment();
      } catch (error) {
        warnSoft("[zuuzii-skin] extension style skipped:", error);
      }
    }

    function clearThemingExtensions() {
      try {
        clearAnchorMarkers();
      } catch (_) {
        // best-effort
      }
      extensionRuntime.anchorMeasurements = [];
      extensionRuntime.appliedDynamicCSS = "";
      extensionRuntime.brandSignature = "";
    }


    function clearHeroLoadTimeout() {
      if (heroLoad.timeoutID === null) return;
      globalThis.clearTimeout(heroLoad.timeoutID);
      timeouts.delete(heroLoad.timeoutID);
      heroLoad.timeoutID = null;
    }

    function reportRuntimeInstallFailureOnce() {
      if (heroLoad.runtimeFailureReported) return;
      heroLoad.runtimeFailureReported = true;
      reportRuntimeRevalidation(payload.generation, "runtime-install-failed");
    }

    function markHeroReady() {
      if (!state || state.active !== true || heroLoad.status !== "loading") return;
      if (
        heroImage.naturalWidth !== payload.hero.pixelWidth
        || heroImage.naturalHeight !== payload.hero.pixelHeight
      ) {
        markHeroFailed("hero dimensions changed after native validation");
        return;
      }
      clearHeroLoadTimeout();
      heroLoad.status = "ready";
      heroLoad.detail = "";
      overlay.dataset.heroState = "ready";
      heroImage.dataset.imageState = "ready";
      if (state.installationComplete === true) {
        scheduleRefresh("hero-ready");
      }
    }

    function markHeroFailed(detail) {
      if (!state || state.active !== true || heroLoad.status !== "loading") return;
      clearHeroLoadTimeout();
      heroLoad.status = "failed";
      heroLoad.detail = String(detail || "hero image failed to decode").slice(0, 160);
      overlay.dataset.heroState = "failed";
      heroImage.dataset.imageState = "failed";
      if (state?.installationComplete === true) {
        cleanup("asset-render-failed");
        removeOwnedNodes();
        reportRuntimeInstallFailureOnce();
      }
    }

    heroImage.onload = markHeroReady;
    heroImage.onerror = () => markHeroFailed("hero image failed to decode");

    function ensureHeroLoadStarted() {
      if (heroLoad.status !== "idle") return;
      heroLoad.status = "loading";
      overlay.dataset.heroState = "loading";
      heroImage.dataset.imageState = "loading";
      heroLoad.timeoutID = trackedTimeout(() => {
        heroLoad.timeoutID = null;
        markHeroFailed("hero image load timed out");
      }, HERO_LOAD_TIMEOUT_MS);
      heroImage.src = payload.hero.dataURL;
      if (heroImage.complete) {
        if (heroImage.naturalWidth > 0 && heroImage.naturalHeight > 0) {
          markHeroReady();
        } else {
          markHeroFailed("hero image failed to decode");
        }
      }
    }

    function mount(probeResult) {
      if (state.mounted) {
        applyProbeResult(probeResult);
        return;
      }

      (document.head || document.documentElement).appendChild(style);
      (document.body || document.documentElement).appendChild(overlay);
      applyProbeResult(probeResult);

      const mutationObserver = new MutationObserver(() => scheduleRefresh("dom-mutation"));
      mutationObserver.observe(document.documentElement, { childList: true, subtree: true });
      observers.add(mutationObserver);

      const resizeObserver = new ResizeObserver(() => scheduleRefresh("viewport-resize"));
      resizeObserver.observe(document.documentElement);
      observers.add(resizeObserver);

      const eventOptions = { signal: controller.signal };
      globalThis.addEventListener("popstate", () => scheduleRefresh("popstate"), eventOptions);
      globalThis.addEventListener("hashchange", () => scheduleRefresh("hashchange"), eventOptions);
      globalThis.addEventListener("pageshow", () => scheduleRefresh("pageshow"), eventOptions);
      globalThis.addEventListener("pagehide", (event) => {
        if (event?.persisted !== true) cleanup("pagehide");
      }, eventOptions);

      const motionQuery = globalThis.matchMedia("(prefers-reduced-motion: reduce)");
      const motionListener = () => scheduleRefresh("reduced-motion");
      motionQuery.addEventListener("change", motionListener, eventOptions);

      // This low-frequency guard catches SPA route changes that render no stable
      // mutation target. It is tracked and always cleared by cleanup().
      const intervalID = globalThis.setInterval(
        () => scheduleRefresh("route-heartbeat"),
        2_000
      );
      intervals.add(intervalID);
      state.mounted = true;
    }

    function renderingContractFailure(probeResult) {
      try {
        if (!style.isConnected || !overlay.isConnected || !heroImage.isConnected) {
          return "owned render nodes did not attach";
        }
        if (!style.sheet || style.sheet.cssRules.length === 0) {
          return "owned stylesheet was blocked or empty";
        }
        if (typeof globalThis.getComputedStyle !== "function") {
          return "computed style API unavailable";
        }

        const overlayStyle = globalThis.getComputedStyle(overlay);
        if (overlayStyle.position !== "fixed") {
          return `overlay position is ${String(overlayStyle.position || "unknown")}`;
        }
        const overlayRect = overlay.getBoundingClientRect();
        const viewportWidth = Math.max(
          0,
          Number(globalThis.innerWidth || document.documentElement?.clientWidth || 0)
        );
        const viewportHeight = Math.max(
          0,
          Number(globalThis.innerHeight || document.documentElement?.clientHeight || 0)
        );
        if (
          overlayRect.width < Math.max(1, viewportWidth - 1)
          || overlayRect.height < Math.max(1, viewportHeight - 1)
        ) {
          return `overlay coverage is ${overlayRect.width}x${overlayRect.height}`;
        }

        if (probeResult.effectiveMode === "full") {
          const heroStyle = globalThis.getComputedStyle(heroImage);
          if (heroStyle.position !== "absolute") {
            return `hero position is ${String(heroStyle.position || "unknown")}`;
          }
          if (heroStyle.objectFit !== "cover") {
            return `hero object-fit is ${String(heroStyle.objectFit || "unknown")}`;
          }
          if (heroStyle.display === "none" || heroStyle.visibility !== "visible") {
            return "hero is not visibly rendered";
          }
          if (Number.parseFloat(overlayStyle.opacity) < 0.99) {
            return `overlay opacity is ${String(overlayStyle.opacity || "unknown")}`;
          }
          if (Number.parseFloat(heroStyle.opacity) < 0.99) {
            return `hero opacity is ${String(heroStyle.opacity || "unknown")}`;
          }
          const heroRect = heroImage.getBoundingClientRect();
          if (
            heroRect.width < Math.max(1, overlayRect.width - 1)
            || heroRect.height < Math.max(1, overlayRect.height - 1)
          ) {
            return `hero coverage is ${heroRect.width}x${heroRect.height}`;
          }
        }
      } catch (error) {
        return error instanceof Error ? error.message : "render contract verification failed";
      }
      return "";
    }

    function installationResult(probeResult, reason, idempotent) {
      const heroRequired = probeResult.effectiveMode === "full";
      if (heroRequired) {
        ensureHeroLoadStarted();
        if (heroLoad.status === "loading") {
          resetRuntimeFailure();
          return assetRenderPending(probeResult);
        }
        if (heroLoad.status === "failed") {
          const detail = heroLoad.detail;
          cleanup("asset-render-failed");
          removeOwnedNodes();
          return failure("asset-render-failed", detail);
        }
      }

      mount(probeResult);
      const renderingFailure = renderingContractFailure(probeResult);
      if (renderingFailure) {
        if (state.installationComplete === true) {
          // Runtime refreshes confirm sustained render mismatches before
          // tearing down; the initial install below still fails fast.
          return runtimeFailureOrTeardown(
            "runtime-install-failed",
            "render-verification-failed",
            probeResult,
            renderingFailure,
            () => failure("render-verification-failed", renderingFailure)
          );
        }
        cleanup("render-verification-failed");
        removeOwnedNodes();
        return failure("render-verification-failed", renderingFailure);
      }
      resetRuntimeFailure();
      state.installationComplete = true;
      // schema v3.1：mount 完成后应用品牌印记/图标/文案扩展（soft 失败隔离）。
      applyThemingExtensions();
      return Object.freeze({
        ok: true,
        failClosed: false,
        pending: false,
        idempotent,
        reason,
        generation: payload.generation,
        themeID: payload.themeID,
        themeName: payload.themeName,
        routeID: probeResult.routeID,
        effectiveMode: probeResult.effectiveMode,
        hero: Object.freeze({
          ready: heroLoad.status === "ready",
          deferred: heroLoad.status === "idle",
          pixelWidth: heroImage.naturalWidth,
          pixelHeight: heroImage.naturalHeight,
        }),
        nativeNodePolicy: NATIVE_NODE_POLICY,
      });
    }

    function cleanup(reason = "cleanup") {
      if (!state || state.active !== true) {
        return Object.freeze({
          ok: true,
          cleaned: false,
          reason,
          generation: payload.generation,
        });
      }

      state.active = false;
      controller.abort(reason);
      clearHeroLoadTimeout();
      heroLoad.status = "cancelled";

      for (const observer of observers) observer.disconnect();
      observers.clear();

      for (const id of timeouts) globalThis.clearTimeout(id);
      timeouts.clear();
      scheduledTimeout = null;

      for (const id of intervals) globalThis.clearInterval(id);
      intervals.clear();

      for (const id of animationFrames) globalThis.cancelAnimationFrame(id);
      animationFrames.clear();

      for (const dispose of manualCleanups) {
        try {
          dispose();
        } catch (_) {
          // Cleanup remains best-effort and idempotent.
        }
      }
      manualCleanups.clear();

      heroImage.onload = null;
      heroImage.onerror = null;
      heroImage.removeAttribute("src");

      // schema v3.1：先摘除我们打在原生元素上的锚点属性钩子，再移除 owned 节点。
      clearThemingExtensions();

      style.remove();
      overlay.remove();
      for (const node of document.querySelectorAll(`[${OWNER_ATTRIBUTE}]`)) {
        if (node.getAttribute(OWNER_ATTRIBUTE) === payload.generation) node.remove();
      }

      if (globalThis[STATE_SYMBOL] === state) delete globalThis[STATE_SYMBOL];
      return Object.freeze({
        ok: true,
        cleaned: true,
        reason,
        generation: payload.generation,
      });
    }

    function resetRuntimeFailure() {
      runtimeFailure.signature = "";
      runtimeFailure.count = 0;
      runtimeFailure.firstAt = 0;
    }

    function runtimeFailureSignature(event, probeResult, detail) {
      const routeID = typeof probeResult?.routeID === "string"
        ? probeResult.routeID
        : "unclassified";
      let failures = "";
      if (Array.isArray(probeResult?.failures)) {
        failures = probeResult.failures
          .map((entry) => `${String(entry?.id ?? "unknown")}:${String(entry?.actualCount ?? "?")}`)
          .sort()
          .join(",");
      }
      let detailText = "";
      if (detail instanceof Error) {
        detailText = detail.message;
      } else if (typeof detail === "string") {
        detailText = detail;
      } else if (detail !== null && detail !== undefined) {
        detailText = String(detail);
      }
      return `${event}|${routeID}|${failures}|${detailText}`.slice(0, 256);
    }

    function confirmRuntimeFailure(signature) {
      const now = Date.now();
      if (runtimeFailure.signature !== signature) {
        runtimeFailure.signature = signature;
        runtimeFailure.count = 1;
        runtimeFailure.firstAt = now;
      } else {
        runtimeFailure.count += 1;
      }
      return runtimeFailure.count >= 3 && now - runtimeFailure.firstAt >= 600;
    }

    function scheduleRuntimeRetry() {
      if (runtimeRetryScheduled) return;
      runtimeRetryScheduled = true;
      trackedTimeout(() => {
        runtimeRetryScheduled = false;
        if (!state || state.active !== true) return;
        refresh("runtime-retry");
      }, 120);
    }

    // Keeps the installed skin mounted through transient mismatches: the
    // debounce window returns a pending result (native keeps polling) and
    // schedules a retry. Only a sustained, identical failure signature tears
    // down, reports to native, and returns the terminal failure object.
    function runtimeFailureOrTeardown(event, cleanupReason, probeResult, detail, buildFailure) {
      if (!confirmRuntimeFailure(runtimeFailureSignature(event, probeResult, detail))) {
        scheduleRuntimeRetry();
        return rendererPending(probeResult);
      }
      resetRuntimeFailure();
      cleanup(cleanupReason);
      removeOwnedNodes();
      reportRuntimeRevalidation(payload.generation, event);
      return buildFailure();
    }

    function refresh(reason = "refresh") {
      if (!state || state.active !== true) {
        return failure("inactive-generation", reason);
      }

      const nextProbe = runProbe(payload.adapterProbe);
      if (nextProbe.status === "pending") {
        return runtimeFailureOrTeardown(
          "renderer-not-ready",
          "renderer-not-ready",
          nextProbe.result,
          "",
          () => rendererPending(nextProbe.result)
        );
      }
      if (nextProbe.status !== "ready") {
        return runtimeFailureOrTeardown(
          "adapter-probe-failed",
          "probe-fail-closed",
          nextProbe.result,
          nextProbe.error,
          () => adapterProbeFailure(nextProbe.result, nextProbe.error)
        );
      }

      try {
        applyProbeResult(nextProbe.result);
        state.lastProbe = nextProbe.result;
        return installationResult(
          nextProbe.result,
          reason,
          reason === "idempotent"
        );
      } catch (error) {
        return runtimeFailureOrTeardown(
          "runtime-install-failed",
          "refresh-installation-error",
          nextProbe.result,
          error,
          () => failure("installation-error", error)
        );
      }
    }

    function scheduleRefresh(reason) {
      if (!state || state.active !== true || scheduledTimeout !== null) return;
      scheduledTimeout = trackedTimeout(() => {
        scheduledTimeout = null;
        trackedAnimationFrame(() => refresh(reason));
      }, 48);
    }

    state = {
      active: true,
      generation: payload.generation,
      themeID: payload.themeID,
      mounted: false,
      installationComplete: false,
      lastProbe: preflight.result,
      refresh,
      cleanup,
    };
    globalThis[STATE_SYMBOL] = state;

    try {
      return installationResult(preflight.result, "installed", false);
    } catch (error) {
      cleanup("installation-error");
      return failure("installation-error", error);
    }
  }

  Object.defineProperty(install, "bootstrapVersion", {
    value: BOOTSTRAP_VERSION,
    enumerable: false,
    configurable: false,
    writable: false,
  });
  globalThis[INSTALL_SYMBOL] = install;
})();
