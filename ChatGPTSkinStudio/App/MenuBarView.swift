import Sparkle
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow

    /// Version + bundle build time, so a stale duplicate app copy can be
    /// identified at a glance (2026-07-17: a pre-fix duplicate kept relaunching).
    private var buildStamp: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        let mtime = try? Bundle.main.executableURL?
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let stamp = mtime.map { Self.stampFormatter.string(from: $0) } ?? "unknown"
        return "v\(version) · 构建 \(stamp)"
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                MenuBarBrandMark(size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ChatGPT Skin Studio")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.state.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(buildStamp)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            if let theme = model.activeTheme ?? model.selectedTheme {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.activeTheme == nil ? "所选主题" : "当前皮肤")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(theme.manifest.name)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }

            Divider()

            Button("打开主题库") {
                openWindow(id: "studio")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)

            if model.isActive {
                if model.canApply {
                    Button("无重启切换到所选主题") {
                        model.requestApply()
                    }
                }
                Button("恢复原生界面") {
                    model.requestRestore()
                    openWindow(id: "studio")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                Button("应用所选主题…") {
                    model.requestApply()
                    openWindow(id: "studio")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .disabled(!model.canApply)
            }

            Divider()

            CheckForUpdatesView(updater: updater)

            Button("关于 ChatGPT Skin Studio") {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            if model.isActive {
                Text("退出前建议先恢复原生界面；否则需手动重启 ChatGPT 才会清理调试 listener。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(model.isActive ? "退出 Controller（皮肤保持）" : "退出 Skin Studio") {
                NSApp.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 310)
    }
}
