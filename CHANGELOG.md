# Changelog

All notable user-facing changes to ChatGPT Skin Studio are documented here.

The project follows [Semantic Versioning](https://semver.org/) for published releases where practical. Compatibility with ChatGPT itself is determined by runtime structure, not by the ChatGPT version string.

## [Unreleased]

No entries yet.

## [0.1.3] - 2026-07-19

### Changed

- Rebuilt the menu-bar extra as a compact native macOS menu instead of a custom window panel.
- Reduced the menu to the current theme, primary theme actions, update, About, and Quit; build timestamps no longer compete with primary actions.
- Replaced the diagonal Skin Peel mark with a lighter stacked-card Template Image that avoids a prohibited-symbol reading.

## [0.1.0] - 2026-07-18

First public beta.

### Added

- Native macOS controller and menu bar entry for applying and restoring ChatGPT skins.
- Home Full, Thread Core, and conservative token-only modes for sensitive or narrow surfaces.
- Ten bundled release themes and an on-device image-theme importer with focal-point editing.
- No-restart theme switching within an already active managed ChatGPT session.
- Schema v3.1 brand marks, navigation/suggestion icon accents, and composer text customization.
- Local compatibility diagnostics and size-capped rotating runtime logs.
- Sparkle 2.9.2 update integration with an EdDSA public-key gate and a release-hosted appcast endpoint.

### Security

- Exact path, Bundle ID, OpenAI Team ID, and code-signature verification for the target ChatGPT app.
- Random loopback CDP port with listener/process ownership checks.
- Strict local theme validation for schema, path, symlink, image format, size, dimensions, hashes, SVG content, and remote-value rejection.
- Explicit one-use confirmation around the initial apply and restoration restart.
- Generation-scoped cleanup and automatic normal-launch recovery attempts.

### Compatibility

- Removed fixed ChatGPT version/build rejection; runtime structural probes decide compatibility.
- Added stable-mismatch debouncing so transient route/reload states are not reported as version incompatibility.
- Added top-frame-only reload bootstrap, BFCache handling, payload resume, and runtime revalidation.
- Moved large hero images out of single CSS declarations into a validated typed-image channel.

### Known limitations

- The Controller UI is Simplified Chinese in v0.1.0.
- The first apply and restoration interrupt and relaunch ChatGPT; active work must be saved first.
- Compatibility with future ChatGPT builds is not guaranteed, even though no static version allowlist is used.
- Final visual appearance depends on the live, logged-in renderer and can degrade conservatively after a ChatGPT UI change.
- Third-party franchise references in bundled themes may require separate authorization for redistribution or commercial use.
- Remote automatic updating requires the corresponding Release to publish both its signed update archive and `appcast.xml`; code integration alone is insufficient.

[Unreleased]: https://github.com/zuuzii-org/chatgpt-avatar/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/zuuzii-org/chatgpt-avatar/releases/tag/v0.1.3
[0.1.0]: https://github.com/zuuzii-org/chatgpt-avatar/releases/tag/v0.1.0
