import Foundation

struct ChatGPTStructuralAdapterV1: ChatGPTAdapter {
    static let adapterID = "chatgpt-macos-structural-v1"
    static let protocolID = "chatgpt-macos-renderer"
    static let protocolAPIVersion = 1

    let manifest = ChatGPTAdapterManifest(
        identifier: Self.adapterID,
        protocolContract: ChatGPTAdapterProtocolContract(
            identifier: Self.protocolID,
            apiVersion: Self.protocolAPIVersion,
            bundleIdentifier: "com.openai.codex",
            entryScriptPathPattern: #"^/assets/index-[A-Za-z0-9_-]+\.js$"#
        ),
        minimumStructuralWidth: 1_024,
        selectors: [
            "electronRoot": ":root[data-codex-window-type=\"electron\"]",
            "rootMount": "#root",
            "mainViewport": "[data-app-shell-main-content-layout]",
            "mainTopFade": "[data-app-shell-main-content-top-fade]",
            "composerRoot": "[data-codex-composer-root]",
            "composer": "[data-codex-composer]",
            "activeTab": "[data-app-shell-tabs=\"true\"]",
            "rightPanel": "[data-app-shell-focus-area=\"right-panel\"]",
            "bottomPanel": "[data-app-shell-focus-area=\"bottom-panel\"]",
            "tabPanel": "[role=\"tabpanel\"][data-app-shell-tab-panel-controller][data-tab-id]",
            "threadFooter": "[data-thread-scroll-footer=\"true\"]",
            "turn": "[data-turn-key], [data-content-search-turn-key]",
            "userMessage": "[data-user-message-bubble]",
            "chatGPTTurn": "[data-chatgpt-conversation-turn=\"true\"]",
            "threadTitle": "[data-thread-title]",
            "threadTitleTrigger": "[data-thread-title-trigger]",
            "projectKind": "[data-sidebar-project-kind]",
            "settingsSlug": "[data-settings-panel-slug]",
            "projectsHeader": "[data-projects-header]",
            "projectsRows": "[data-projects-rows]",
            "projectRowWrapper": "[data-project-row-wrapper]",
            "projectRow": "[data-project-row]",
            "avatarFrame": "[data-avatar-overlay-content-frame=\"true\"]",
            "avatarAsset": "[data-avatar-asset-ref][data-avatar-state]",
        ],
        routeCapabilities: Self.routes,
        cardinalityProbes: Self.probes
    )

    private static let fullCapabilities: [ChatGPTSkinCapability] = [
        .themeTokens,
        .decorativeOverlay,
        .homeHero,
        .sidebarGlass,
        .composerGlass,
    ]

    private static let coreCapabilities: [ChatGPTSkinCapability] = [
        .themeTokens,
        .decorativeOverlay,
        .composerGlass,
        .threadBackdrop,
    ]

    private static let tokenCapabilities: [ChatGPTSkinCapability] = [.themeTokens]

    private static let routes: [ChatGPTRouteCapability] = [
        ChatGPTRouteCapability(
            id: "avatar-overlay",
            pathPattern: "^/avatar-overlay(?:/|$)",
            mode: .tokenOnly,
            capabilities: tokenCapabilities,
            rendererTargetRole: .auxiliary
        ),
        ChatGPTRouteCapability(
            id: "compact-window",
            pathPattern:
                "^/(?:hotkey-window|chatgpt/(?:quick-chat|prewarm)|global-dictation|extension/panel/new)(?:/|$)",
            mode: .tokenOnly,
            capabilities: tokenCapabilities,
            rendererTargetRole: .auxiliary
        ),
        ChatGPTRouteCapability(
            id: "local-thread",
            pathPattern: "^/local/[^/]+(?:/|$)",
            mode: .core,
            capabilities: coreCapabilities,
            rendererTargetRole: .primary
        ),
        ChatGPTRouteCapability(
            id: "remote-thread",
            pathPattern: "^/remote/[^/]+(?:/|$)",
            mode: .core,
            capabilities: coreCapabilities,
            rendererTargetRole: .primary
        ),
        ChatGPTRouteCapability(
            id: "chatgpt-thread",
            pathPattern: "^/work/conversation/[^/]+(?:/|$)",
            mode: .core,
            capabilities: coreCapabilities,
            rendererTargetRole: .primary
        ),
        ChatGPTRouteCapability(
            id: "home",
            pathPattern: "^/$",
            mode: .full,
            capabilities: fullCapabilities,
            rendererTargetRole: .primary
        ),
        ChatGPTRouteCapability(
            id: "projects",
            pathPattern: "^/projects(?:/|$)",
            mode: .tokenOnly,
            capabilities: tokenCapabilities,
            rendererTargetRole: .primary
        ),
        ChatGPTRouteCapability(
            id: "settings",
            pathPattern: "^/settings(?:/|$)",
            mode: .tokenOnly,
            capabilities: tokenCapabilities,
            rendererTargetRole: .primary
        ),
        ChatGPTRouteCapability(
            id: "diff-review",
            pathPattern: "^/(?:diff|plan-summary|review|pull-requests?|approvals?)(?:/|$)",
            mode: .tokenOnly,
            capabilities: tokenCapabilities,
            rendererTargetRole: .primary
        ),
        ChatGPTRouteCapability(
            id: "onboarding",
            pathPattern: "^/(?:login|welcome|onboarding|select-workspace)(?:/|$)",
            mode: .tokenOnly,
            capabilities: tokenCapabilities,
            rendererTargetRole: .primary
        ),
        ChatGPTRouteCapability(
            id: "fallback",
            pathPattern: "^/.*$",
            mode: .tokenOnly,
            capabilities: tokenCapabilities,
            rendererTargetRole: .primary
        ),
    ]

    private static let standardRouteIDs = [
        "home", "local-thread", "remote-thread", "chatgpt-thread",
    ]

    private static let threadRouteIDs = [
        "local-thread", "remote-thread", "chatgpt-thread",
    ]

    private static let panelRejection =
        "[data-app-shell-focus-area=\"right-panel\"], [data-app-shell-focus-area=\"bottom-panel\"], [data-app-shell-tab-panel-controller]"

    private static let probes: [ChatGPTCardinalityProbe] = [
        ChatGPTCardinalityProbe(
            id: "electron-root",
            selector: ":root[data-codex-window-type=\"electron\"]",
            scopeSelector: nil,
            rejectedAncestorSelector: nil,
            minimumCount: 1,
            maximumCount: 1,
            visibleOnly: false,
            severity: .hard,
            routeIDs: [],
            modes: ChatGPTSkinRouteMode.allCases
        ),
        ChatGPTCardinalityProbe(
            id: "root-mount",
            selector: "#root",
            scopeSelector: nil,
            rejectedAncestorSelector: nil,
            minimumCount: 1,
            maximumCount: 1,
            visibleOnly: false,
            severity: .hard,
            routeIDs: [],
            modes: ChatGPTSkinRouteMode.allCases
        ),
        ChatGPTCardinalityProbe(
            id: "main-viewport",
            selector: "[data-app-shell-main-content-layout]",
            scopeSelector: nil,
            rejectedAncestorSelector: panelRejection,
            minimumCount: 1,
            maximumCount: 1,
            visibleOnly: true,
            severity: .hard,
            routeIDs: standardRouteIDs,
            modes: [.full, .core]
        ),
        ChatGPTCardinalityProbe(
            id: "primary-composer-home",
            selector: "[data-codex-composer-root]",
            scopeSelector: "[data-app-shell-main-content-layout]",
            rejectedAncestorSelector: panelRejection,
            minimumCount: 1,
            maximumCount: 1,
            visibleOnly: true,
            severity: .hard,
            routeIDs: ["home"],
            modes: [.full]
        ),
        ChatGPTCardinalityProbe(
            id: "primary-composer-thread",
            selector: "[data-codex-composer-root]",
            scopeSelector: "[data-app-shell-main-content-layout]",
            rejectedAncestorSelector: panelRejection,
            minimumCount: 0,
            maximumCount: 1,
            visibleOnly: true,
            severity: .hard,
            routeIDs: threadRouteIDs,
            modes: [.core]
        ),
        ChatGPTCardinalityProbe(
            id: "primary-thread-scroller",
            selector: ".thread-scroll-container",
            scopeSelector: "[data-app-shell-main-content-layout]",
            rejectedAncestorSelector: panelRejection,
            minimumCount: 0,
            maximumCount: 1,
            visibleOnly: true,
            severity: .hard,
            routeIDs: threadRouteIDs,
            modes: [.core]
        ),
        ChatGPTCardinalityProbe(
            id: "app-shell-active-tabs",
            selector: "[data-app-shell-tabs=\"true\"]",
            scopeSelector: nil,
            rejectedAncestorSelector: nil,
            minimumCount: 0,
            maximumCount: 2,
            visibleOnly: false,
            severity: .hard,
            routeIDs: standardRouteIDs,
            modes: [.full, .core]
        ),
        ChatGPTCardinalityProbe(
            id: "right-active-tab",
            selector: "[data-app-shell-tabs=\"true\"]",
            scopeSelector: "[data-app-shell-focus-area=\"right-panel\"]",
            rejectedAncestorSelector: nil,
            minimumCount: 0,
            maximumCount: 1,
            visibleOnly: false,
            severity: .hard,
            routeIDs: standardRouteIDs,
            modes: [.full, .core]
        ),
        ChatGPTCardinalityProbe(
            id: "bottom-active-tab",
            selector: "[data-app-shell-tabs=\"true\"]",
            scopeSelector: "[data-app-shell-focus-area=\"bottom-panel\"]",
            rejectedAncestorSelector: nil,
            minimumCount: 0,
            maximumCount: 1,
            visibleOnly: false,
            severity: .hard,
            routeIDs: standardRouteIDs,
            modes: [.full, .core]
        ),
        ChatGPTCardinalityProbe(
            id: "projects-regions",
            selector: "[data-projects-header], [data-projects-rows]",
            scopeSelector: nil,
            rejectedAncestorSelector: nil,
            minimumCount: 0,
            maximumCount: 2,
            visibleOnly: false,
            severity: .soft,
            routeIDs: ["projects"],
            modes: [.tokenOnly]
        ),
        ChatGPTCardinalityProbe(
            id: "settings-panel",
            selector: "[data-settings-panel-slug]",
            scopeSelector: nil,
            rejectedAncestorSelector: nil,
            minimumCount: 0,
            maximumCount: 1,
            visibleOnly: false,
            severity: .soft,
            routeIDs: ["settings"],
            modes: [.tokenOnly]
        ),
        ChatGPTCardinalityProbe(
            id: "avatar-frame",
            selector: "[data-avatar-overlay-content-frame=\"true\"]",
            scopeSelector: nil,
            rejectedAncestorSelector: nil,
            minimumCount: 0,
            maximumCount: 1,
            visibleOnly: false,
            severity: .soft,
            routeIDs: ["avatar-overlay"],
            modes: [.tokenOnly]
        ),
        // schema v3.1：扩展锚点一律 soft 级。minimumCount 为 0 时永不失败，
        // 计数只进入 pending 文案，不影响 hard 判定与 structuralFailureSignature。
        ChatGPTCardinalityProbe(
            id: "brand-wordmark",
            selector: "aside.app-shell-left-panel",
            scopeSelector: nil,
            rejectedAncestorSelector: nil,
            minimumCount: 0,
            maximumCount: 1,
            visibleOnly: false,
            severity: .soft,
            routeIDs: standardRouteIDs,
            modes: [.full, .core]
        ),
        ChatGPTCardinalityProbe(
            id: "suggestion-cards",
            selector: "[data-home-ambient-suggestions]",
            scopeSelector: "[data-app-shell-main-content-layout]",
            rejectedAncestorSelector: panelRejection,
            minimumCount: 0,
            maximumCount: 1,
            visibleOnly: false,
            severity: .soft,
            routeIDs: ["home"],
            modes: [.full]
        ),
    ]
}
