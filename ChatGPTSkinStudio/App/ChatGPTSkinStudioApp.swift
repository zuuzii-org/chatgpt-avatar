import SwiftUI

@main
struct ChatGPTSkinStudioApp: App {
    @StateObject private var model = AppModel()
    private let softwareUpdates = SoftwareUpdateController()

    var body: some Scene {
        Window("ChatGPT Skin Studio", id: "studio") {
            StudioView(model: model)
                .frame(minWidth: 960, minHeight: 680)
                .task { await model.start() }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)

        Window("关于 ChatGPT Skin Studio", id: "about") {
            AboutView(updater: softwareUpdates.updater)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView(model: model, updater: softwareUpdates.updater)
                .task { await model.start() }
        } label: {
            MenuBarBrandMark(size: 18)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: softwareUpdates.updater)
            }
        }
    }
}
