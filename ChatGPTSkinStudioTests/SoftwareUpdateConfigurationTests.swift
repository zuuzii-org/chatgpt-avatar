import Foundation
import XCTest
@testable import ChatGPTSkinStudio

final class SoftwareUpdateConfigurationTests: XCTestCase {
    private let validPublicKey = Data(repeating: 0x2A, count: 32).base64EncodedString()

    func testReadyConfigurationRequiresHTTPSFeedAndEd25519PublicKey() {
        let configuration = SoftwareUpdateConfiguration(
            infoDictionary: [
                "SUFeedURL": "https://example.com/appcast.xml",
                "SUPublicEDKey": validPublicKey,
            ]
        )

        XCTAssertTrue(configuration.isReady)
    }

    func testRejectsInsecureFeedURL() {
        let configuration = SoftwareUpdateConfiguration(
            infoDictionary: [
                "SUFeedURL": "http://example.com/appcast.xml",
                "SUPublicEDKey": validPublicKey,
            ]
        )

        XCTAssertFalse(configuration.isReady)
    }

    func testRejectsMissingOrMalformedPublicKey() {
        let missingKey = SoftwareUpdateConfiguration(
            infoDictionary: [
                "SUFeedURL": "https://example.com/appcast.xml",
            ]
        )
        let malformedKey = SoftwareUpdateConfiguration(
            infoDictionary: [
                "SUFeedURL": "https://example.com/appcast.xml",
                "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
            ]
        )

        XCTAssertFalse(missingKey.isReady)
        XCTAssertFalse(malformedKey.isReady)
    }

    func testApplicationBundleUsesStableGitHubReleaseFeed() {
        let applicationBundle = Bundle(for: AppModel.self)

        XCTAssertEqual(
            applicationBundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            "https://github.com/zuuzii-org/chatgpt-avatar/releases/latest/download/appcast.xml"
        )
    }
}
