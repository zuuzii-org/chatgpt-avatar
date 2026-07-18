import AppKit
import Sparkle
import SwiftUI

struct AboutView: View {
    let updater: SPUUpdater

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "local"
        return "版本 \(version)（\(build)）"
    }

    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityLabel("ChatGPT Skin Studio 图标")

            VStack(spacing: 6) {
                Text("ChatGPT Skin Studio")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(StudioVisualTokens.text)
                Text("安全、可恢复的 ChatGPT macOS 完整皮肤控制器")
                    .font(.callout)
                    .foregroundStyle(StudioVisualTokens.muted)
                Text(versionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioVisualTokens.muted)
            }

            CheckForUpdatesView(updater: updater)
                .buttonStyle(.borderedProminent)
                .tint(StudioVisualTokens.cyan)

            Text("更新由 Sparkle 验证；检查更新不会启动或重启 ChatGPT。")
                .font(.caption)
                .foregroundStyle(StudioVisualTokens.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 42)
        .padding(.vertical, 34)
        .frame(width: 440)
        .background(StudioVisualTokens.canvas)
    }
}
