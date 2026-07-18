import Sparkle
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow

    private var visibleTheme: LoadedTheme? {
        model.activeTheme ?? model.selectedTheme
    }

    private var themeStatusTitle: String? {
        guard let theme = visibleTheme else { return nil }
        let prefix = model.activeTheme == nil ? "所选主题" : "当前皮肤"
        return "\(prefix)：\(theme.manifest.name)"
    }

    private var applyTitle: String {
        model.isActive ? "切换到所选主题" : "应用所选主题…"
    }

    var body: some View {
        if let themeStatusTitle {
            Label(
                themeStatusTitle,
                systemImage: model.activeTheme == nil ? "paintpalette" : "paintbrush.pointed.fill"
            )
            .disabled(true)
        } else {
            Label("尚未选择主题", systemImage: "paintpalette")
                .disabled(true)
        }

        Divider()

        Button {
            openStudio()
        } label: {
            Label("打开主题库", systemImage: "square.grid.2x2")
        }
        .keyboardShortcut(",", modifiers: .command)

        if model.isActive {
            if model.canApply {
                Button {
                    model.requestApply()
                } label: {
                    Label(applyTitle, systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Button {
                model.requestRestore()
                openStudio()
            } label: {
                Label("恢复原生界面", systemImage: "arrow.counterclockwise")
            }
        } else {
            Button {
                model.requestApply()
                openStudio()
            } label: {
                Label(applyTitle, systemImage: "paintbrush.pointed")
            }
            .disabled(!model.canApply)
        }

        Divider()

        CheckForUpdatesView(updater: updater)

        Button {
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("关于 ChatGPT Skin Studio", systemImage: "info.circle")
        }

        Divider()

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("退出 ChatGPT Skin Studio", systemImage: "power")
        }
        .keyboardShortcut("q")
    }

    private func openStudio() {
        openWindow(id: "studio")
        NSApp.activate(ignoringOtherApps: true)
    }
}
