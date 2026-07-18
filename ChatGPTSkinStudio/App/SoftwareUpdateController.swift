import Combine
import Foundation
import Sparkle
import SwiftUI

struct SoftwareUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL?
    let publicEDKey: String?

    init(infoDictionary: [String: Any]) {
        if let rawFeedURL = infoDictionary["SUFeedURL"] as? String {
            feedURL = URL(string: rawFeedURL)
        } else {
            feedURL = nil
        }
        publicEDKey = infoDictionary["SUPublicEDKey"] as? String
    }

    var isReady: Bool {
        guard feedURL?.scheme?.lowercased() == "https",
              let publicEDKey,
              let keyData = Data(base64Encoded: publicEDKey),
              keyData.count == 32
        else {
            return false
        }
        return true
    }
}

@MainActor
final class SoftwareUpdateController {
    let updaterController: SPUStandardUpdaterController
    let configuration: SoftwareUpdateConfiguration

    init(bundle: Bundle = .main, startingUpdater: Bool = true) {
        configuration = SoftwareUpdateConfiguration(
            infoDictionary: bundle.infoDictionary ?? [:]
        )
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater && configuration.isReady,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater {
        updaterController.updater
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    @MainActor
    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(
            wrappedValue: CheckForUpdatesViewModel(updater: updater)
        )
    }

    var body: some View {
        Button("检查更新…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
