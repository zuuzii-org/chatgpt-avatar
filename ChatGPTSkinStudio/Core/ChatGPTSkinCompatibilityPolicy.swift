import Foundation

/// Native preflight only checks stable identity and the skin protocol contract.
/// ChatGPT version/build metadata remains available for diagnostics but is never
/// an admission criterion; renderer compatibility is decided by adapter probes.
enum ChatGPTSkinCompatibilityPolicy {
    static func validate(
        adapter: any ChatGPTAdapter,
        themeCompatibility: ThemeCompatibility,
        verifiedBundle: VerifiedChatGPTBundle
    ) throws {
        let contract = adapter.manifest.protocolContract
        guard contract.accepts(bundleIdentifier: verifiedBundle.bundleIdentifier) else {
            throw SkinError.incompatibleApp(
                "当前 adapter 不支持 bundle \(verifiedBundle.bundleIdentifier)。"
            )
        }
        guard themeCompatibility.supports(contract) else {
            throw SkinError.incompatibleApp(
                "主题要求 \(themeCompatibility.adapterProtocol) API "
                    + "v\(themeCompatibility.minimumAPIVersion)..."
                    + "\(themeCompatibility.maximumAPIVersion)，当前 adapter 提供 "
                    + "\(contract.identifier) API v\(contract.apiVersion)。"
            )
        }
    }
}
