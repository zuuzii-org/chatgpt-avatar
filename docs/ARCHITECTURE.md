# Architecture and Trust Boundaries

ChatGPT Skin Studio is a native macOS controller for a verified installation of the ChatGPT desktop app. It does not fork or embed ChatGPT and does not patch the official application bundle.

For the full Chinese implementation contract, see [`ChatGPT_Skin_Studio_实施方案.md`](../ChatGPT_Skin_Studio_实施方案.md).

## System flow

```text
User selects a validated theme
  -> one-use restart confirmation
  -> verify /Applications/ChatGPT.app identity and signature
  -> gracefully stop the existing verified process
  -> launch a managed process with a random 127.0.0.1 CDP port
  -> verify process, profile, listener, and renderer target
  -> run content-minimized structural compatibility probes
  -> render validated CSS + typed image/extension payload
  -> attach generation-owned renderer nodes and reload bootstrap
  -> monitor route/reload/runtime invalidation
  -> cleanup and normal-launch recovery on terminal failure
```

## Components

| Component | Responsibility |
|---|---|
| `AppModel` / SwiftUI views | Theme library, import flow, diagnostics, explicit apply/restore consent, and active-session state |
| `ThemeKit` | Strict schema decoding, bundled/user theme discovery, image normalization, manifest validation, and atomic local imports |
| `ChatGPTRuntime` | Official app identity, process/profile/listener verification, graceful restart, and recovery transactions |
| `CDPKit` | Loopback discovery and bounded WebSocket request/response transport |
| Structural Adapter | Route classification, selector-cardinality probes, effective mode selection, and stable mismatch signatures |
| `SkinCSSRenderer` | CSS tokens, responsive gates, icon masks, and typed validated hero payload generation |
| `SkinInjector` | Trusted renderer selection, installation, reload bootstrap, runtime revalidation, and cleanup orchestration |
| `bootstrap.js` / `cleanup.js` | Generation-owned DOM behavior, optional soft visual anchors, and reversible renderer cleanup |
| `SoftwareUpdateController` / Sparkle | User-initiated update checks gated by a valid release EdDSA public key and signed appcast |

## Trust boundaries

### 1. Official application identity

The production policy accepts only the canonical `/Applications/ChatGPT.app` path, expected Bundle ID, expected OpenAI Team ID, and a valid strict code signature. Version and build are recorded for diagnostics but are not compatibility admission rules.

### 2. Restart authority

Initial apply and restoration each require fresh explicit user confirmation. Consent is single-use and bound to the verified target. The controller uses graceful termination and does not escalate to a force kill.

### 3. Local debugging endpoint

The managed process uses a random loopback port. The listener must belong to the expected process or an allowed same-process-group descendant created through descriptor inheritance. A non-loopback or unrelated listener fails closed.

### 4. Renderer compatibility

The adapter uses route, viewport, entry-script count, and selector cardinality. It does not use conversation text for the compatibility decision. A mismatch must be stable and repeated before being classified as incompatible; transient route/reload states are recoverable runtime failures.

Optional schema v3.1 visual extensions have a narrower, separate behavior: they may compare short visible button labels to attach theme-owned brand and icon accents. They do not move, delete, or reparent native nodes.

### 5. Theme data

Themes are local data packages, not executable plugins. The validator constrains schema fields, IDs, colors, compatibility range, asset paths, file types, byte/pixel limits, exact dimensions, hashes, SVG content, and extension values. It rejects remote URLs, arbitrary CSS/JavaScript, traversal, symlinks, and unsupported image structures.

### 6. Owned renderer state

Injected nodes, styles, payloads, timers, listeners, bindings, anchor attributes, and reload scripts carry a random generation identifier. Cleanup only owns project-marked state and is designed to remove every owned artifact without rebuilding native controls.

### 7. Software updates

Sparkle 2.9.2 is pinned through Swift Package Manager. The feed points to a release-hosted `appcast.xml`; the update controller remains disabled when the build does not contain a valid EdDSA public key. Code integration alone does not establish a working update channel—the appcast, signed archive, and release verification must also exist.

## Capability modes

| Mode | Intended surface | Contract |
|---|---|---|
| Full | Home/New Task at desktop width | Hero and complete visual treatment are allowed only after image decode, stylesheet, computed-style, and viewport coverage checks |
| Core | Thread at desktop width | Lower-noise atmosphere and glass treatment while preserving message readability |
| token-only | Sensitive routes and narrow windows | Conservative tokens only; hero and decorative extensions remain suppressed |

## Failure semantics

- **Incompatible:** repeated stable structural evidence proves the adapter contract is not present.
- **Runtime unavailable:** image decode, style visibility, pending state, listener, transport, or unstable probe behavior prevents a safe installation.
- **Recovery required:** cleanup or normal-launch restoration cannot be proven complete and user action is required.

An upgraded ChatGPT build is never rejected only because its version changed. It is also never assumed compatible only because an older build worked.

## Persistence and privacy

Skin injection is session-scoped. User-imported themes and bounded diagnostics persist under `~/Library/Application Support/ChatGPTSkinStudio`; ChatGPT application data remains in its own profile. See [`PRIVACY.md`](../PRIVACY.md) for the exact data boundary.

## Verification layers

1. Swift unit and contract tests for theme parsing, security policies, adapters, injection, cleanup, state races, and recovery.
2. JavaScript syntax and renderer-harness tests for bootstrap and cleanup behavior.
3. Isolated live E2E, enabled only with an explicit environment variable.
4. Production E2E and visual comparison, which interrupt the active ChatGPT session and therefore require a separate operational approval.

Passing layers 1–3 does not prove that a currently logged-in production renderer matches a visual reference. Release documentation must distinguish build/test evidence from live visual evidence.
