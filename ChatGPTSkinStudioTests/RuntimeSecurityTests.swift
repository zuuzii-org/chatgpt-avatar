import Darwin
import Foundation
import XCTest
@testable import ChatGPTSkinStudio

final class RuntimeSecurityTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSkinStudio-RuntimeSecurityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testProductionBundlePolicyPinsApplicationIdentityAndPath() {
        let policy = ChatGPTBundleVerifier.Policy.production
        XCTAssertEqual(policy.expectedBundleIdentifier, "com.openai.codex")
        XCTAssertEqual(policy.expectedTeamIdentifier, "2DC432GLL2")
        XCTAssertEqual(
            policy.allowedCanonicalAppURLs,
            [URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)]
        )
    }

    func testBundleVerifierAcceptsArbitraryVersionAndBuildWhenIdentityMatches() throws {
        let fixture = try makeBundleFixture()
        let verifier = makeBundleVerifier(
            fixture: fixture,
            version: "999.123-preview",
            build: "future-build-abc",
            signingTeam: "2DC432GLL2"
        )

        let verified = try verifier.verify(appURL: fixture.appURL)

        XCTAssertEqual(verified.appURL, fixture.appURL.standardizedFileURL)
        XCTAssertEqual(verified.executableURL, fixture.executableURL.standardizedFileURL)
        XCTAssertEqual(verified.bundleIdentifier, "com.openai.codex")
        XCTAssertEqual(verified.teamIdentifier, "2DC432GLL2")
        XCTAssertEqual(verified.shortVersion, "999.123-preview")
        XCTAssertEqual(verified.buildVersion, "future-build-abc")
    }

    func testBundleVerifierStillRejectsWrongBundleAndSigningIdentity() throws {
        let fixture = try makeBundleFixture()
        let wrongBundle = makeBundleVerifier(
            fixture: fixture,
            version: "26.707.99999",
            build: "future-build",
            signingTeam: "2DC432GLL2",
            metadataBundleIdentifier: "com.attacker.fake"
        )
        XCTAssertThrowsError(try wrongBundle.verify(appURL: fixture.appURL)) { error in
            guard case RuntimeSecurityError.bundleIdentifierMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let wrongSigningIdentifier = makeBundleVerifier(
            fixture: fixture,
            version: "999.123-preview",
            build: "future-build-abc",
            signingTeam: "2DC432GLL2",
            signingIdentifier: "com.attacker.fake"
        )
        XCTAssertThrowsError(
            try wrongSigningIdentifier.verify(appURL: fixture.appURL)
        ) { error in
            guard case RuntimeSecurityError.bundleIdentifierMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let wrongTeam = makeBundleVerifier(
            fixture: fixture,
            version: "999.123-preview",
            build: "future-build-abc",
            signingTeam: "UNTRUSTED01"
        )
        XCTAssertThrowsError(try wrongTeam.verify(appURL: fixture.appURL)) { error in
            guard case RuntimeSecurityError.teamIdentifierMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testBundleVerifierRejectsPathOutsideAllowlistAndSymlink() throws {
        let fixture = try makeBundleFixture()
        let verifier = makeBundleVerifier(
            fixture: fixture,
            version: "26.707.72221",
            build: "5307",
            signingTeam: "2DC432GLL2"
        )
        let otherApp = temporaryRoot.appendingPathComponent("Other.app", isDirectory: true)
        try FileManager.default.createDirectory(at: otherApp, withIntermediateDirectories: true)
        XCTAssertThrowsError(try verifier.verify(appURL: otherApp)) { error in
            guard case RuntimeSecurityError.appPathNotAllowed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let symlink = temporaryRoot.appendingPathComponent("ChatGPT-link.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.appURL)
        XCTAssertThrowsError(try verifier.verify(appURL: symlink)) { error in
            guard case RuntimeSecurityError.appPathIsSymbolicLink = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureStorageUses0700AndRemovesOnlyCapturedIdentity() throws {
        let manager = SecureIsolatedRuntimeStorageManager(temporaryRoot: temporaryRoot)
        let storage = try manager.createStorage()

        for directory in [
            storage.rootURL,
            storage.userDataDirectory,
            storage.codexHomeDirectory,
        ] {
            var info = stat()
            XCTAssertEqual(lstat(directory.path, &info), 0)
            XCTAssertEqual(info.st_uid, getuid())
            XCTAssertEqual(info.st_mode & mode_t(0o777), mode_t(0o700))
        }

        try manager.removeStorage(storage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.rootURL.path))
    }

    func testSecureStorageRefusesReplacedDirectory() throws {
        let manager = SecureIsolatedRuntimeStorageManager(temporaryRoot: temporaryRoot)
        let storage = try manager.createStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }

        try FileManager.default.removeItem(at: storage.userDataDirectory)
        try FileManager.default.createDirectory(
            at: storage.userDataDirectory,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(storage.userDataDirectory.path, mode_t(0o700)), 0)

        XCTAssertThrowsError(try manager.removeStorage(storage)) { error in
            guard case RuntimeSecurityError.secureDirectoryIdentityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.rootURL.path))
    }

    func testActivePortParserAcceptsCanonicalTwoLineFile() throws {
        let identifier = "4D36E96E-E325-4A73-B3A4-FA3A2E49AA10"
        let endpoint = try StrictDevToolsActivePortDiscoverer.parse(
            Data("53810\n/devtools/browser/\(identifier)\n".utf8)
        )
        XCTAssertEqual(endpoint.port, 53_810)
        XCTAssertEqual(endpoint.browserWebSocketPath, "/devtools/browser/\(identifier)")
    }

    func testActivePortParserRejectsReservedLeadingZeroAndMalformedPath() {
        let identifier = "4D36E96E-E325-4A73-B3A4-FA3A2E49AA10"
        let invalidFiles = [
            "1023\n/devtools/browser/\(identifier)\n",
            "053810\n/devtools/browser/\(identifier)\n",
            "53810\n/devtools/page/\(identifier)\n",
            "53810\n/devtools/browser/not-a-uuid\n",
            "53810\n/devtools/browser/\(identifier)\nextra\n",
        ]
        for contents in invalidFiles {
            XCTAssertThrowsError(
                try StrictDevToolsActivePortDiscoverer.parse(Data(contents.utf8)),
                "Expected rejection for \(contents.debugDescription)"
            ) { error in
                guard case RuntimeSecurityError.invalidActivePortFile = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testActivePortDiscovererReadsPrivateRegularFile() async throws {
        let profile = temporaryRoot.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(profile.path, mode_t(0o700)), 0)
        let identifier = "4D36E96E-E325-4A73-B3A4-FA3A2E49AA10"
        try Data("53810\n/devtools/browser/\(identifier)\n".utf8).write(
            to: profile.appendingPathComponent("DevToolsActivePort")
        )

        let endpoint = try await StrictDevToolsActivePortDiscoverer().waitForEndpoint(
            in: profile,
            timeout: .seconds(1)
        )

        XCTAssertEqual(endpoint.port, 53_810)
    }

    func testActivePortDiscovererRejectsSymbolicLink() async throws {
        let profile = temporaryRoot.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(profile.path, mode_t(0o700)), 0)
        let target = temporaryRoot.appendingPathComponent("attacker-controlled-port")
        try Data(
            "53810\n/devtools/browser/4D36E96E-E325-4A73-B3A4-FA3A2E49AA10\n".utf8
        ).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: profile.appendingPathComponent("DevToolsActivePort"),
            withDestinationURL: target
        )

        do {
            _ = try await StrictDevToolsActivePortDiscoverer().waitForEndpoint(
                in: profile,
                timeout: .milliseconds(1)
            )
            XCTFail("Expected symbolic link rejection")
        } catch RuntimeSecurityError.invalidActivePortFile {
            // Expected. O_NOFOLLOW must prevent reading the link target.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testActivePortFreshnessRequiresAdvancedMtimeAndChangedContents() {
        let baseline = DevToolsActivePortFileFingerprint(
            device: 1,
            inode: 10,
            size: 4,
            modificationSeconds: 100,
            modificationNanoseconds: 10,
            contents: Data("old".utf8)
        )
        XCTAssertFalse(
            StrictDevToolsActivePortDiscoverer.isFresh(
                baseline,
                comparedWith: baseline
            )
        )
        XCTAssertTrue(
            StrictDevToolsActivePortDiscoverer.isFresh(
                DevToolsActivePortFileFingerprint(
                    device: 1,
                    inode: 10,
                    size: 4,
                    modificationSeconds: 100,
                    modificationNanoseconds: 11,
                    contents: Data("new".utf8)
                ),
                comparedWith: baseline
            )
        )
        XCTAssertTrue(
            StrictDevToolsActivePortDiscoverer.isFresh(
                DevToolsActivePortFileFingerprint(
                    device: 1,
                    inode: 11,
                    size: 4,
                    modificationSeconds: 101,
                    modificationNanoseconds: 0,
                    contents: Data("new".utf8)
                ),
                comparedWith: baseline
            )
        )
        XCTAssertFalse(
            StrictDevToolsActivePortDiscoverer.isFresh(
                DevToolsActivePortFileFingerprint(
                    device: 2,
                    inode: 11,
                    size: 4,
                    modificationSeconds: 101,
                    modificationNanoseconds: 0,
                    contents: Data("new".utf8)
                ),
                comparedWith: baseline
            )
        )
        XCTAssertFalse(
            StrictDevToolsActivePortDiscoverer.isFresh(
                DevToolsActivePortFileFingerprint(
                    device: 1,
                    inode: 11,
                    size: 4,
                    modificationSeconds: 101,
                    modificationNanoseconds: 0,
                    contents: baseline.contents
                ),
                comparedWith: baseline
            )
        )
    }

    func testListenerVerifierRequiresExactLoopbackAndPID() throws {
        let verifier = makeListenerVerifier(
            "p42420\nf9\nn127.0.0.1:53810\nTST=LISTEN\nTQR=0\nTQS=0\n"
        )
        XCTAssertEqual(
            try verifier.verify(port: 53_810, belongsTo: 42_420),
            VerifiedDebugListener(pid: 42_420, address: "127.0.0.1", port: 53_810)
        )

        for invalidOutput in [
            "p42420\nn*:53810\nTST=LISTEN\n",
            "p42420\nn[::1]:53810\nTST=LISTEN\n",
            "p99999\nn127.0.0.1:53810\nTST=LISTEN\n",
            "p42420\nn127.0.0.1:53810\nTST=ESTABLISHED\n",
        ] {
            XCTAssertThrowsError(
                try makeListenerVerifier(invalidOutput).verify(
                    port: 53_810,
                    belongsTo: 42_420
                )
            ) { error in
                guard case RuntimeSecurityError.listenerVerificationFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    /// Reproduces the production failure: ChatGPT spawns a child service (for
    /// example SkyComputerUseService) that inherits the DevTools listen socket
    /// FD, so lsof reports two PIDs for the same listener. The expected leader
    /// plus same-process-group descendants must pass.
    func testListenerVerifierAcceptsSameGroupChildInheritingSocket() throws {
        let main = RuntimeProcessSnapshot(
            pid: 46_869,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            arguments: []
        )
        let child = RuntimeProcessSnapshot(
            pid: 46_939,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 102, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Users/test/.codex/computer-use/SkyComputerUseService"
            ),
            arguments: []
        )
        let secondChild = RuntimeProcessSnapshot(
            pid: 46_940,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/Frameworks/Helper"
            ),
            arguments: []
        )
        let verifier = makeListenerVerifier(
            "p46869\nf59\nn127.0.0.1:53810\nTST=LISTEN\n"
                + "p46939\nf59\nn127.0.0.1:53810\nTST=LISTEN\n"
                + "p46940\nf59\nn127.0.0.1:53810\nTST=LISTEN\n"
        )

        let listener = try verifier.verify(
            port: 53_810,
            belongsTo: 46_869,
            processInspector: DictionaryRuntimeProcessInspector(
                processes: [main, child, secondChild]
            )
        )

        XCTAssertEqual(
            listener,
            VerifiedDebugListener(pid: 46_869, address: "127.0.0.1", port: 53_810)
        )
    }

    func testListenerVerifierRejectsHolderOutsideExpectedProcessGroup() throws {
        let main = RuntimeProcessSnapshot(
            pid: 46_869,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            arguments: []
        )
        let foreign = RuntimeProcessSnapshot(
            pid: 46_939,
            processGroupID: 46_939,
            startTime: ProcessStartTime(seconds: 102, microseconds: 1),
            executableURL: URL(fileURLWithPath: "/usr/bin/nc"),
            arguments: []
        )
        let verifier = makeListenerVerifier(
            "p46869\nn127.0.0.1:53810\nTST=LISTEN\np46939\nn127.0.0.1:53810\nTST=LISTEN\n"
        )

        XCTAssertThrowsError(
            try verifier.verify(
                port: 53_810,
                belongsTo: 46_869,
                processInspector: DictionaryRuntimeProcessInspector(
                    processes: [main, foreign]
                )
            )
        ) { error in
            guard case RuntimeSecurityError.listenerVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testListenerVerifierRejectsHolderOlderThanExpectedProcess() throws {
        let main = RuntimeProcessSnapshot(
            pid: 46_869,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            arguments: []
        )
        // Same process group but started earlier: it cannot be a descendant of
        // the debug instance, so this is a stale or foreign holder.
        let stale = RuntimeProcessSnapshot(
            pid: 46_939,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 50, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/Frameworks/Helper"
            ),
            arguments: []
        )
        let verifier = makeListenerVerifier(
            "p46869\nn127.0.0.1:53810\nTST=LISTEN\np46939\nn127.0.0.1:53810\nTST=LISTEN\n"
        )

        XCTAssertThrowsError(
            try verifier.verify(
                port: 53_810,
                belongsTo: 46_869,
                processInspector: DictionaryRuntimeProcessInspector(
                    processes: [main, stale]
                )
            )
        ) { error in
            guard case RuntimeSecurityError.listenerVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testListenerVerifierFailsClosedOnMultipleHoldersWithoutInspector() throws {
        let verifier = makeListenerVerifier(
            "p46869\nn127.0.0.1:53810\nTST=LISTEN\np46939\nn127.0.0.1:53810\nTST=LISTEN\n"
        )

        XCTAssertThrowsError(
            try verifier.verify(port: 53_810, belongsTo: 46_869)
        ) { error in
            guard case RuntimeSecurityError.listenerVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testListenerVerifierFailsClosedWhenHolderSnapshotRaces() throws {
        let main = RuntimeProcessSnapshot(
            pid: 46_869,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            arguments: []
        )
        let verifier = makeListenerVerifier(
            "p46869\nn127.0.0.1:53810\nTST=LISTEN\np46939\nn127.0.0.1:53810\nTST=LISTEN\n"
        )

        // The child holder exited between lsof and the identity recheck: the
        // inherited-holder proof cannot complete, so verification must fail.
        XCTAssertThrowsError(
            try verifier.verify(
                port: 53_810,
                belongsTo: 46_869,
                processInspector: DictionaryRuntimeProcessInspector(processes: [main])
            )
        )
    }

    func testListenerVerifierRejectsMultiHolderOutputWithForeignBinding() throws {
        let main = RuntimeProcessSnapshot(
            pid: 46_869,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            arguments: []
        )
        let child = RuntimeProcessSnapshot(
            pid: 46_939,
            processGroupID: 46_869,
            startTime: ProcessStartTime(seconds: 102, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/Frameworks/Helper"
            ),
            arguments: []
        )
        // Even with a valid descendant holder, a wildcard or non-loopback
        // binding anywhere in the output must still be rejected.
        for invalidOutput in [
            "p46869\nn127.0.0.1:53810\nTST=LISTEN\np46939\nn*:53810\nTST=LISTEN\n",
            "p46869\nn127.0.0.1:53810\nTST=LISTEN\np46939\nn127.0.0.1:53810\nTST=ESTABLISHED\n",
        ] {
            XCTAssertThrowsError(
                try makeListenerVerifier(invalidOutput).verify(
                    port: 53_810,
                    belongsTo: 46_869,
                    processInspector: DictionaryRuntimeProcessInspector(
                        processes: [main, child]
                    )
                )
            ) { error in
                guard case RuntimeSecurityError.listenerVerificationFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testListenerVerifierRejectsExpectedProcessInsideOwnProcessGroup() throws {
        let ownGroup = getpgrp()
        let main = RuntimeProcessSnapshot(
            pid: 46_869,
            processGroupID: ownGroup,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            arguments: []
        )
        let child = RuntimeProcessSnapshot(
            pid: 46_939,
            processGroupID: ownGroup,
            startTime: ProcessStartTime(seconds: 102, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Applications/ChatGPT.app/Contents/Frameworks/Helper"
            ),
            arguments: []
        )
        let verifier = makeListenerVerifier(
            "p46869\nn127.0.0.1:53810\nTST=LISTEN\np46939\nn127.0.0.1:53810\nTST=LISTEN\n"
        )

        XCTAssertThrowsError(
            try verifier.verify(
                port: 53_810,
                belongsTo: 46_869,
                processInspector: DictionaryRuntimeProcessInspector(
                    processes: [main, child]
                )
            )
        ) { error in
            guard case RuntimeSecurityError.listenerVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testProductionDebugSessionValidatorAcceptsCapturedIdentity() async throws {
        let session = try makeProductionDebugSessionValidationFixture()
        let validator = ProductionDebugSessionValidator(
            processInspector: StaticRuntimeProcessInspector(
                process: session.process
            ),
            listenerVerifier: makeListenerVerifier(
                "p\(session.process.pid)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
            )
        )

        try await validator.validate(session)
    }

    func testProductionDebugSessionValidatorAcceptsInheritedSocketHolders() async throws {
        let session = try makeProductionDebugSessionValidationFixture()
        let childHolder = RuntimeProcessSnapshot(
            pid: session.process.pid + 70,
            processGroupID: session.process.processGroupID,
            startTime: ProcessStartTime(
                seconds: session.process.startTime.seconds + 2,
                microseconds: session.process.startTime.microseconds
            ),
            executableURL: URL(
                fileURLWithPath: "/Users/test/.codex/computer-use/SkyComputerUseService"
            ),
            arguments: []
        )
        let validator = ProductionDebugSessionValidator(
            processInspector: DictionaryRuntimeProcessInspector(
                processes: [session.process, childHolder]
            ),
            listenerVerifier: makeListenerVerifier(
                "p\(session.process.pid)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
                    + "p\(childHolder.pid)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
            )
        )

        try await validator.validate(session)
    }

    func testProductionDebugSessionValidatorRejectsForeignSocketHolder() async throws {
        let session = try makeProductionDebugSessionValidationFixture()
        let foreignHolder = RuntimeProcessSnapshot(
            pid: session.process.pid + 70,
            processGroupID: session.process.processGroupID + 9_999,
            startTime: ProcessStartTime(
                seconds: session.process.startTime.seconds + 2,
                microseconds: session.process.startTime.microseconds
            ),
            executableURL: URL(fileURLWithPath: "/usr/bin/nc"),
            arguments: []
        )
        let validator = ProductionDebugSessionValidator(
            processInspector: DictionaryRuntimeProcessInspector(
                processes: [session.process, foreignHolder]
            ),
            listenerVerifier: makeListenerVerifier(
                "p\(session.process.pid)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
                    + "p\(foreignHolder.pid)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
            )
        )

        do {
            try await validator.validate(session)
            XCTFail("Expected foreign socket holder rejection")
        } catch RuntimeSecurityError.listenerVerificationFailed {
            // Expected.
        }
    }

    func testProductionDebugSessionValidatorRejectsProcessIdentityDrift() async throws {
        let session = try makeProductionDebugSessionValidationFixture()
        let expected = session.process
        let drifts: [(String, RuntimeProcessSnapshot)] = [
            (
                "pid",
                RuntimeProcessSnapshot(
                    pid: expected.pid + 1,
                    processGroupID: expected.processGroupID,
                    startTime: expected.startTime,
                    executableURL: expected.executableURL,
                    arguments: expected.arguments
                )
            ),
            (
                "process group",
                RuntimeProcessSnapshot(
                    pid: expected.pid,
                    processGroupID: expected.processGroupID + 1,
                    startTime: expected.startTime,
                    executableURL: expected.executableURL,
                    arguments: expected.arguments
                )
            ),
            (
                "start time",
                RuntimeProcessSnapshot(
                    pid: expected.pid,
                    processGroupID: expected.processGroupID,
                    startTime: .init(
                        seconds: expected.startTime.seconds + 1,
                        microseconds: expected.startTime.microseconds
                    ),
                    executableURL: expected.executableURL,
                    arguments: expected.arguments
                )
            ),
            (
                "executable",
                RuntimeProcessSnapshot(
                    pid: expected.pid,
                    processGroupID: expected.processGroupID,
                    startTime: expected.startTime,
                    executableURL: URL(fileURLWithPath: "/tmp/foreign-chatgpt"),
                    arguments: expected.arguments
                )
            ),
            (
                "immutable arguments",
                RuntimeProcessSnapshot(
                    pid: expected.pid,
                    processGroupID: expected.processGroupID,
                    startTime: expected.startTime,
                    executableURL: expected.executableURL,
                    arguments: expected.arguments + ["--foreign-argument"]
                )
            ),
        ]

        for (name, driftedProcess) in drifts {
            let validator = ProductionDebugSessionValidator(
                processInspector: StaticRuntimeProcessInspector(
                    process: driftedProcess
                ),
                listenerVerifier: makeListenerVerifier(
                    "p\(expected.pid)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
                )
            )
            do {
                try await validator.validate(session)
                XCTFail("Expected \(name) drift rejection")
            } catch RuntimeSecurityError.processIdentityMismatch {
                // Expected.
            }
        }
    }

    func testProductionDebugSessionValidatorRejectsDriftDuringListenerVerification() async throws {
        let session = try makeProductionDebugSessionValidationFixture()
        let expected = session.process
        let drifted = RuntimeProcessSnapshot(
            pid: expected.pid,
            processGroupID: expected.processGroupID + 1,
            startTime: expected.startTime,
            executableURL: expected.executableURL,
            arguments: expected.arguments
        )
        let validator = ProductionDebugSessionValidator(
            processInspector: SequencedRuntimeProcessInspector(
                processes: [expected, drifted]
            ),
            listenerVerifier: makeListenerVerifier(
                "p\(expected.pid)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
            )
        )

        do {
            try await validator.validate(session)
            XCTFail("Expected post-listener process drift rejection")
        } catch RuntimeSecurityError.processIdentityMismatch {
            // Expected from the final immutable identity sample.
        }
    }

    func testProductionDebugSessionValidatorRejectsListenerOwnerDrift() async throws {
        let session = try makeProductionDebugSessionValidationFixture()
        let validator = ProductionDebugSessionValidator(
            processInspector: StaticRuntimeProcessInspector(
                process: session.process
            ),
            listenerVerifier: makeListenerVerifier(
                "p\(session.process.pid + 1)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
            )
        )

        do {
            try await validator.validate(session)
            XCTFail("Expected listener owner drift rejection")
        } catch RuntimeSecurityError.listenerVerificationFailed {
            // Expected.
        }
    }

    func testProductionDebugSessionValidatorRejectsUserDataIdentityDrift() async throws {
        let session = try makeProductionDebugSessionValidationFixture()
        try FileManager.default.removeItem(at: session.userDataDirectory)
        try FileManager.default.createDirectory(
            at: session.userDataDirectory,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(session.userDataDirectory.path, mode_t(0o700)), 0)
        let validator = ProductionDebugSessionValidator(
            processInspector: StaticRuntimeProcessInspector(
                process: session.process
            ),
            listenerVerifier: makeListenerVerifier(
                "p\(session.process.pid)\nn127.0.0.1:\(session.endpoint.port)\nTST=LISTEN\n"
            )
        )

        do {
            try await validator.validate(session)
            XCTFail("Expected user-data-dir identity drift rejection")
        } catch RuntimeSecurityError.secureDirectoryIdentityChanged {
            // Expected.
        }
    }

    func testDarwinInspectorCanReadCurrentProcessWithoutMutatingIt() throws {
        let currentPID = getpid()
        let inspector = DarwinRuntimeProcessInspector()
        let snapshot = try inspector.snapshot(pid: currentPID)

        XCTAssertEqual(snapshot.pid, currentPID)
        XCTAssertEqual(snapshot.processGroupID, getpgrp())
        XCTAssertFalse(snapshot.arguments.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.executableURL.path))
        XCTAssertTrue(
            try inspector.allUserProcesses().contains { $0.pid == currentPID }
        )
    }

    func testProcessGroupSignalerRejectsCurrentGroupWithoutSendingSignal() {
        // Signal 0 is intentionally harmless even if this safety check regresses.
        XCTAssertThrowsError(
            try DarwinProcessGroupSignaler().send(signal: 0, toProcessGroup: getpgrp())
        ) { error in
            guard case RuntimeSecurityError.unsafeProcessGroup = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExactProcessSignalerRejectsCurrentPIDWithoutSendingSignal() {
        // Signal 0 is intentionally harmless even if this safety check regresses.
        XCTAssertThrowsError(
            try DarwinExactProcessSignaler().send(signal: 0, toProcessID: getpid())
        ) { error in
            guard case RuntimeSecurityError.processIdentityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLauncherUsesIsolatedArgumentsAndCleansOnlyFakePGID() async throws {
        let fixture = try makeBundleFixture()
        let helperURL = fixture.appURL
            .appendingPathComponent("Contents/Frameworks/ChatGPT Helper.app/Contents/MacOS/ChatGPT Helper")
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: helperURL)

        let pid: pid_t = 42_420
        let harness = LaunchHarness(
            pid: pid,
            executableURL: fixture.executableURL,
            helperExecutableURL: helperURL
        )
        let listenerVerifier = makeListenerVerifier(
            "p\(pid)\nf9\nn127.0.0.1:53810\nTST=LISTEN\nTQR=0\nTQS=0\n"
        )
        let launcher = IsolatedDebugLauncher(
            storageManager: SecureIsolatedRuntimeStorageManager(temporaryRoot: temporaryRoot),
            workspaceLauncher: HarnessWorkspaceLauncher(harness: harness),
            processInspector: HarnessProcessInspector(harness: harness),
            endpointDiscoverer: StubEndpointDiscoverer(
                endpoint: DevToolsActivePort(
                    port: 53_810,
                    browserWebSocketPath: "/devtools/browser/4D36E96E-E325-4A73-B3A4-FA3A2E49AA10"
                )
            ),
            listenerVerifier: listenerVerifier,
            applicationController: HarnessIsolatedApplicationController(
                harness: harness,
                accepted: false,
                exitsGroup: false
            ),
            processGroupSignaler: HarnessProcessGroupSignaler(harness: harness),
            exactProcessSignaler: HarnessExactProcessSignaler(harness: harness),
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                terminationGracePeriod: .zero,
                killGracePeriod: .zero,
                pollInterval: .milliseconds(1)
            )
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let bundle = VerifiedChatGPTBundle(
            appURL: fixture.appURL,
            executableURL: fixture.executableURL,
            bundleIdentifier: "com.openai.codex",
            teamIdentifier: "2DC432GLL2",
            shortVersion: "26.707.72221",
            buildVersion: "5307"
        )

        let session = try await launcher.launch(
            verifiedBundle: bundle,
            consent: consent
        )
        let request = try XCTUnwrap(harness.capturedRequest())
        XCTAssertEqual(request.appURL, fixture.appURL)
        XCTAssertEqual(
            Set(request.arguments),
            [
                "--user-data-dir=\(session.storage.userDataDirectory.path)",
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=0",
            ]
        )
        XCTAssertEqual(
            request.environment,
            ["CODEX_HOME": session.storage.codexHomeDirectory.path]
        )
        XCTAssertEqual(session.process.pid, pid)
        XCTAssertEqual(session.process.processGroupID, pid)
        let activeBeforeCleanup = await launcher.isActive(session)
        XCTAssertTrue(activeBeforeCleanup)

        try await launcher.cleanup(session)

        XCTAssertEqual(
            harness.signalEvents(),
            [
                SignalEvent(signal: SIGTERM, processGroupID: pid),
                SignalEvent(signal: SIGKILL, processGroupID: pid),
            ]
        )
        let activeAfterCleanup = await launcher.isActive(session)
        XCTAssertFalse(activeAfterCleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.storage.rootURL.path))

        do {
            _ = try await launcher.launch(verifiedBundle: bundle, consent: consent)
            XCTFail("Expected consumed consent to be rejected")
        } catch let error as RuntimeSecurityError {
            XCTAssertEqual(error, .explicitRestartConsentRequired)
        }
    }

    func testCleanupRefusesForeignExecutableBeforeAnySignal() async throws {
        let fixture = try makeBundleFixture()
        let foreignHelper = temporaryRoot.appendingPathComponent("foreign-helper")
        try Data("foreign".utf8).write(to: foreignHelper)
        let pid: pid_t = 42_420
        let harness = LaunchHarness(
            pid: pid,
            executableURL: fixture.executableURL,
            helperExecutableURL: foreignHelper
        )
        let launcher = IsolatedDebugLauncher(
            storageManager: SecureIsolatedRuntimeStorageManager(temporaryRoot: temporaryRoot),
            workspaceLauncher: HarnessWorkspaceLauncher(harness: harness),
            processInspector: HarnessProcessInspector(harness: harness),
            endpointDiscoverer: StubEndpointDiscoverer(
                endpoint: DevToolsActivePort(
                    port: 53_810,
                    browserWebSocketPath: "/devtools/browser/4D36E96E-E325-4A73-B3A4-FA3A2E49AA10"
                )
            ),
            listenerVerifier: makeListenerVerifier(
                "p\(pid)\nn127.0.0.1:53810\nTST=LISTEN\n"
            ),
            applicationController: HarnessIsolatedApplicationController(
                harness: harness,
                accepted: false,
                exitsGroup: false
            ),
            processGroupSignaler: HarnessProcessGroupSignaler(harness: harness),
            exactProcessSignaler: HarnessExactProcessSignaler(harness: harness),
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                terminationGracePeriod: .zero,
                killGracePeriod: .zero,
                pollInterval: .milliseconds(1)
            )
        )
        let bundle = VerifiedChatGPTBundle(
            appURL: fixture.appURL,
            executableURL: fixture.executableURL,
            bundleIdentifier: "com.openai.codex",
            teamIdentifier: "2DC432GLL2",
            shortVersion: "26.707.72221",
            buildVersion: "5307"
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let session = try await launcher.launch(
            verifiedBundle: bundle,
            consent: consent
        )

        do {
            try await launcher.cleanup(session)
            XCTFail("Expected foreign executable rejection")
        } catch RuntimeSecurityError.unsafeProcessGroup {
            // Expected: the group is not signaled unless every member is safe.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.signalEvents().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    func testIsolatedCleanupGracefullyExitsGroupContainingStoragePlugin() async throws {
        let fixture = try makeBundleFixture()
        let appHelper = fixture.appURL
            .appendingPathComponent("Contents/Frameworks/ChatGPT Helper")
        try FileManager.default.createDirectory(
            at: appHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: appHelper)
        let pid: pid_t = 42_420
        let harness = LaunchHarness(
            pid: pid,
            executableURL: fixture.executableURL,
            helperExecutableURL: appHelper
        )
        let launcher = makeIsolatedLauncher(
            harness: harness,
            listenerPID: pid,
            gracefulAccepted: true,
            gracefulExitsGroup: true
        )
        let bundle = makeVerifiedBundle(fixture)
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let session = try await launcher.launch(
            verifiedBundle: bundle,
            consent: consent
        )
        let pluginExecutable = session.storage.codexHomeDirectory
            .appendingPathComponent("plugins/chatgpt-for-chrome/ChatGPT for Chrome")
        try FileManager.default.createDirectory(
            at: pluginExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plugin".utf8).write(to: pluginExecutable)
        harness.setHelperExecutableURL(pluginExecutable)

        try await launcher.cleanup(session)

        XCTAssertTrue(harness.signalEvents().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    func testIsolatedCleanupUsesExactPIDForStoragePluginBeforeGroupFallback() async throws {
        let fixture = try makeBundleFixture()
        let appHelper = fixture.appURL
            .appendingPathComponent("Contents/Frameworks/ChatGPT Helper")
        try FileManager.default.createDirectory(
            at: appHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: appHelper)
        let pid: pid_t = 42_420
        let harness = LaunchHarness(
            pid: pid,
            executableURL: fixture.executableURL,
            helperExecutableURL: appHelper
        )
        let launcher = makeIsolatedLauncher(
            harness: harness,
            listenerPID: pid,
            gracefulAccepted: true,
            gracefulExitsGroup: false
        )
        let bundle = makeVerifiedBundle(fixture)
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let session = try await launcher.launch(
            verifiedBundle: bundle,
            consent: consent
        )
        let pluginExecutable = session.storage.codexHomeDirectory
            .appendingPathComponent("plugins/chatgpt-for-chrome/ChatGPT for Chrome")
        try FileManager.default.createDirectory(
            at: pluginExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plugin".utf8).write(to: pluginExecutable)
        harness.setHelperExecutableURL(pluginExecutable)

        try await launcher.cleanup(session)

        XCTAssertEqual(
            harness.exactSignalEvents(),
            [
                ExactSignalEvent(signal: SIGTERM, processID: pid + 1),
                ExactSignalEvent(signal: SIGKILL, processID: pid + 1),
            ]
        )
        XCTAssertEqual(
            harness.signalEvents(),
            [SignalEvent(signal: SIGTERM, processGroupID: pid)]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    func testCleanupTerminatesCrossPGIDStorageHostWithoutTouchingChrome() async throws {
        let fixture = try makeBundleFixture()
        let appHelper = fixture.appURL
            .appendingPathComponent("Contents/Frameworks/ChatGPT Helper")
        try FileManager.default.createDirectory(
            at: appHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: appHelper)
        let leaderPID: pid_t = 42_420
        let chromePID: pid_t = 20_764
        let pluginPID: pid_t = 49_302
        let harness = LaunchHarness(
            pid: leaderPID,
            executableURL: fixture.executableURL,
            helperExecutableURL: appHelper
        )
        let launcher = makeIsolatedLauncher(
            harness: harness,
            listenerPID: leaderPID,
            gracefulAccepted: true,
            gracefulExitsGroup: true
        )
        let session = try await launcher.launch(
            verifiedBundle: makeVerifiedBundle(fixture),
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )
        let pluginExecutable = session.storage.codexHomeDirectory
            .appendingPathComponent("plugins/chatgpt-for-chrome/ChatGPT for Chrome")
        try FileManager.default.createDirectory(
            at: pluginExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plugin".utf8).write(to: pluginExecutable)
        let chromeExecutable = temporaryRoot.appendingPathComponent("Google Chrome")
        try Data("chrome".utf8).write(to: chromeExecutable)
        harness.addUserProcess(
            RuntimeProcessSnapshot(
                pid: chromePID,
                processGroupID: chromePID,
                startTime: ProcessStartTime(seconds: 50, microseconds: 1),
                executableURL: chromeExecutable,
                arguments: [chromeExecutable.path]
            )
        )
        harness.addUserProcess(
            RuntimeProcessSnapshot(
                pid: pluginPID,
                processGroupID: chromePID,
                startTime: ProcessStartTime(seconds: 102, microseconds: 1),
                executableURL: pluginExecutable,
                arguments: [pluginExecutable.path, "--native-messaging-host"]
            )
        )

        try await launcher.cleanup(session)

        XCTAssertEqual(
            harness.exactSignalEvents(),
            [
                ExactSignalEvent(signal: SIGTERM, processID: pluginPID),
                ExactSignalEvent(signal: SIGKILL, processID: pluginPID),
            ]
        )
        XCTAssertTrue(harness.signalEvents().isEmpty)
        XCTAssertFalse(harness.containsUserProcess(pluginPID))
        XCTAssertTrue(harness.containsUserProcess(chromePID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    func testCleanupRejectsPIDReuseBeforeExactSignalAndPreservesStorage() async throws {
        let fixture = try makeBundleFixture()
        let appHelper = fixture.appURL
            .appendingPathComponent("Contents/Frameworks/ChatGPT Helper")
        try FileManager.default.createDirectory(
            at: appHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: appHelper)
        let leaderPID: pid_t = 42_420
        let pluginPID: pid_t = 49_302
        let harness = LaunchHarness(
            pid: leaderPID,
            executableURL: fixture.executableURL,
            helperExecutableURL: appHelper
        )
        let launcher = makeIsolatedLauncher(
            harness: harness,
            listenerPID: leaderPID,
            gracefulAccepted: true,
            gracefulExitsGroup: true
        )
        let session = try await launcher.launch(
            verifiedBundle: makeVerifiedBundle(fixture),
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )
        let pluginExecutable = session.storage.codexHomeDirectory
            .appendingPathComponent("plugins/chatgpt-for-chrome/ChatGPT for Chrome")
        try FileManager.default.createDirectory(
            at: pluginExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plugin".utf8).write(to: pluginExecutable)
        let original = RuntimeProcessSnapshot(
            pid: pluginPID,
            processGroupID: 20_764,
            startTime: ProcessStartTime(seconds: 102, microseconds: 1),
            executableURL: pluginExecutable,
            arguments: [pluginExecutable.path]
        )
        harness.addUserProcess(original)
        harness.replaceSnapshot(
            for: pluginPID,
            with: RuntimeProcessSnapshot(
                pid: pluginPID,
                processGroupID: 20_764,
                startTime: ProcessStartTime(seconds: 999, microseconds: 1),
                executableURL: pluginExecutable,
                arguments: original.arguments
            )
        )

        do {
            try await launcher.cleanup(session)
            XCTFail("Expected PID reuse rejection")
        } catch RuntimeSecurityError.processIdentityMismatch {
            // Expected: exact PID is never signaled after start-time drift.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.exactSignalEvents().isEmpty)
        XCTAssertTrue(harness.signalEvents().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    func testCleanupRejectsExecutableLeavingStorageBeforeExactSignal() async throws {
        let fixture = try makeBundleFixture()
        let appHelper = fixture.appURL
            .appendingPathComponent("Contents/Frameworks/ChatGPT Helper")
        try FileManager.default.createDirectory(
            at: appHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: appHelper)
        let leaderPID: pid_t = 42_420
        let pluginPID: pid_t = 49_302
        let harness = LaunchHarness(
            pid: leaderPID,
            executableURL: fixture.executableURL,
            helperExecutableURL: appHelper
        )
        let launcher = makeIsolatedLauncher(
            harness: harness,
            listenerPID: leaderPID,
            gracefulAccepted: true,
            gracefulExitsGroup: true
        )
        let session = try await launcher.launch(
            verifiedBundle: makeVerifiedBundle(fixture),
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )
        let pluginExecutable = session.storage.codexHomeDirectory
            .appendingPathComponent("plugins/chatgpt-for-chrome/ChatGPT for Chrome")
        try FileManager.default.createDirectory(
            at: pluginExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plugin".utf8).write(to: pluginExecutable)
        let escapedExecutable = temporaryRoot.appendingPathComponent("escaped-helper")
        try Data("escaped".utf8).write(to: escapedExecutable)
        let startTime = ProcessStartTime(seconds: 102, microseconds: 1)
        harness.addUserProcess(
            RuntimeProcessSnapshot(
                pid: pluginPID,
                processGroupID: 20_764,
                startTime: startTime,
                executableURL: pluginExecutable,
                arguments: [pluginExecutable.path]
            )
        )
        harness.replaceSnapshot(
            for: pluginPID,
            with: RuntimeProcessSnapshot(
                pid: pluginPID,
                processGroupID: 20_764,
                startTime: startTime,
                executableURL: escapedExecutable,
                arguments: [pluginExecutable.path]
            )
        )

        do {
            try await launcher.cleanup(session)
            XCTFail("Expected executable path drift rejection")
        } catch RuntimeSecurityError.processIdentityMismatch {
            // Expected: an outside-root replacement is never signaled.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.exactSignalEvents().isEmpty)
        XCTAssertTrue(harness.signalEvents().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    func testCleanupRejectsArgumentDriftBeforeExactSignal() async throws {
        let fixture = try makeBundleFixture()
        let appHelper = fixture.appURL
            .appendingPathComponent("Contents/Frameworks/ChatGPT Helper")
        try FileManager.default.createDirectory(
            at: appHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: appHelper)
        let leaderPID: pid_t = 42_420
        let pluginPID: pid_t = 49_302
        let harness = LaunchHarness(
            pid: leaderPID,
            executableURL: fixture.executableURL,
            helperExecutableURL: appHelper
        )
        let launcher = makeIsolatedLauncher(
            harness: harness,
            listenerPID: leaderPID,
            gracefulAccepted: true,
            gracefulExitsGroup: true
        )
        let session = try await launcher.launch(
            verifiedBundle: makeVerifiedBundle(fixture),
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )
        let pluginExecutable = session.storage.codexHomeDirectory
            .appendingPathComponent("plugins/chatgpt-for-chrome/ChatGPT for Chrome")
        try FileManager.default.createDirectory(
            at: pluginExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plugin".utf8).write(to: pluginExecutable)
        let startTime = ProcessStartTime(seconds: 102, microseconds: 1)
        harness.addUserProcess(
            RuntimeProcessSnapshot(
                pid: pluginPID,
                processGroupID: 20_764,
                startTime: startTime,
                executableURL: pluginExecutable,
                arguments: [pluginExecutable.path, "--native-messaging-host"]
            )
        )
        harness.replaceSnapshot(
            for: pluginPID,
            with: RuntimeProcessSnapshot(
                pid: pluginPID,
                processGroupID: 20_764,
                startTime: startTime,
                executableURL: pluginExecutable,
                arguments: [pluginExecutable.path, "--changed"]
            )
        )

        do {
            try await launcher.cleanup(session)
            XCTFail("Expected argument drift rejection")
        } catch RuntimeSecurityError.processIdentityMismatch {
            // Expected: argv is part of the exact-process identity.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.exactSignalEvents().isEmpty)
        XCTAssertTrue(harness.signalEvents().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    func testCleanupRejectsUnreadableArgumentsInsideStorage() async throws {
        let fixture = try makeBundleFixture()
        let appHelper = fixture.appURL
            .appendingPathComponent("Contents/Frameworks/ChatGPT Helper")
        try FileManager.default.createDirectory(
            at: appHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: appHelper)
        let leaderPID: pid_t = 42_420
        let pluginPID: pid_t = 49_302
        let harness = LaunchHarness(
            pid: leaderPID,
            executableURL: fixture.executableURL,
            helperExecutableURL: appHelper
        )
        let launcher = makeIsolatedLauncher(
            harness: harness,
            listenerPID: leaderPID,
            gracefulAccepted: true,
            gracefulExitsGroup: true
        )
        let session = try await launcher.launch(
            verifiedBundle: makeVerifiedBundle(fixture),
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )
        let pluginExecutable = session.storage.codexHomeDirectory
            .appendingPathComponent("plugins/chatgpt-for-chrome/ChatGPT for Chrome")
        try FileManager.default.createDirectory(
            at: pluginExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plugin".utf8).write(to: pluginExecutable)
        harness.addUserCandidate(
            RuntimeProcessCandidate(
                pid: pluginPID,
                processGroupID: 20_764,
                startTime: ProcessStartTime(seconds: 102, microseconds: 1),
                executableURL: pluginExecutable,
                arguments: nil
            )
        )

        do {
            try await launcher.cleanup(session)
            XCTFail("Expected unreadable storage argv rejection")
        } catch RuntimeSecurityError.processIdentityMismatch {
            // Expected: unreadable argv is tolerated only outside the protected root.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.exactSignalEvents().isEmpty)
        XCTAssertTrue(harness.signalEvents().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.storage.rootURL.path))
    }

    func testProductionRestarterFailsClosedForMultipleMainInstances() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let first = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let second = makeProcess(pid: 1_002, executableURL: fixture.executableURL)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [
                makeRunningApplication(first, bundle: bundle),
                makeRunningApplication(second, bundle: bundle),
            ],
            snapshots: [first.pid: first, second.pid: second],
            plannedLaunches: [],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 2_001
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: consent
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected multiple-instance rejection")
        } catch let RuntimeSecurityError.multipleRunningChatGPTInstances(count) {
            XCTAssertEqual(count, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.terminationRequests().isEmpty)
        XCTAssertTrue(harness.launchRequests().isEmpty)
    }

    func testProductionRestarterRejectsRunningExecutableMismatch() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let process = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let wrongExecutable = temporaryRoot.appendingPathComponent("Impostor")
        try Data("impostor".utf8).write(to: wrongExecutable)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [
                RunningChatGPTApplication(
                    pid: process.pid,
                    bundleIdentifier: bundle.bundleIdentifier,
                    executableURL: wrongExecutable
                ),
            ],
            snapshots: [process.pid: process],
            plannedLaunches: [],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 2_001
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: consent
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected executable mismatch rejection")
        } catch RuntimeSecurityError.runningApplicationIdentityMismatch {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(harness.terminationRequests().isEmpty)
        XCTAssertTrue(harness.launchRequests().isEmpty)
    }

    func testProductionRestarterRejectsExplicitUserDataDirAsNormalBeforeMutation() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let process = makeProcess(
            pid: 1_001,
            executableURL: fixture.executableURL,
            arguments: ["--user-data-dir=/tmp/not-a-normal-launch"]
        )
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(process, bundle: bundle)],
            snapshots: [process.pid: process],
            plannedLaunches: [],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 2_001
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: try XCTUnwrap(
                ExplicitRestartConsent(userConfirmed: true)
            )
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected explicit user-data-dir rejection")
        } catch let error as RuntimeSecurityError {
            guard case .runningApplicationIdentityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(harness.terminationRequests().isEmpty)
        XCTAssertTrue(harness.launchRequests().isEmpty)
    }

    func testProductionRestarterAllowsVersionDriftAndUsesLatestBundle() async throws {
        let fixture = try makeBundleFixture()
        let authorizedBundle = makeVerifiedBundle(fixture)
        let latestBundle = makeVerifiedBundle(
            fixture,
            shortVersion: "999.123-preview",
            buildVersion: "future-build-abc"
        )
        let debugPID: pid_t = 2_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: authorizedBundle.bundleIdentifier,
            applications: [],
            snapshots: [:],
            plannedLaunches: [
                .init(
                    pid: debugPID,
                    executableURL: fixture.executableURL,
                    startSeconds: 200
                ),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: authorizedBundle,
            reverifiedBundle: latestBundle,
            listenerPID: debugPID
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(
            bundle: authorizedBundle,
            consent: consent
        )

        let session = try await restarter.restartForDebugging(request)

        XCTAssertEqual(session.bundle, latestBundle)
        XCTAssertEqual(session.process.pid, debugPID)
        XCTAssertEqual(harness.launchRequests().map(\.appURL), [latestBundle.appURL])
    }

    func testProductionRestarterRejectsStableBundleIdentityDrift() async throws {
        let fixture = try makeBundleFixture()
        let authorizedBundle = makeVerifiedBundle(fixture)
        let identityDrifts: [(String, VerifiedChatGPTBundle)] = [
            (
                "app URL",
                makeVerifiedBundle(
                    fixture,
                    appURL: temporaryRoot.appendingPathComponent(
                        "Replacement.app",
                        isDirectory: true
                    )
                )
            ),
            (
                "executable URL",
                makeVerifiedBundle(
                    fixture,
                    executableURL: temporaryRoot.appendingPathComponent(
                        "Replacement.app/Contents/MacOS/ChatGPT"
                    )
                )
            ),
            (
                "bundle identifier",
                makeVerifiedBundle(
                    fixture,
                    bundleIdentifier: "com.attacker.fake"
                )
            ),
            (
                "team identifier",
                makeVerifiedBundle(
                    fixture,
                    teamIdentifier: "UNTRUSTED01"
                )
            ),
        ]

        for (field, reverifiedBundle) in identityDrifts {
            let harness = ProductionRestartHarness(
                bundleIdentifier: authorizedBundle.bundleIdentifier,
                applications: [],
                snapshots: [:],
                plannedLaunches: [],
                terminationBehavior: .remove
            )
            let restarter = makeProductionRestarter(
                harness: harness,
                bundle: authorizedBundle,
                reverifiedBundle: reverifiedBundle,
                listenerPID: 2_001
            )
            let consent = try XCTUnwrap(
                ExplicitRestartConsent(userConfirmed: true)
            )
            let request = try ProductionRestartGate().makeRequest(
                bundle: authorizedBundle,
                consent: consent
            )

            do {
                _ = try await restarter.restartForDebugging(request)
                XCTFail("Expected \(field) drift rejection")
            } catch RuntimeSecurityError.runningApplicationIdentityMismatch {
                // Expected before any termination or launch side effect.
            } catch {
                XCTFail("Unexpected \(field) drift error: \(error)")
            }
            XCTAssertTrue(
                harness.terminationRequests().isEmpty,
                "Unexpected termination for \(field) drift"
            )
            XCTAssertTrue(
                harness.launchRequests().isEmpty,
                "Unexpected launch for \(field) drift"
            )
        }
    }

    func testProductionRestarterTimesOutWithoutForceTerminating() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let process = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(process, bundle: bundle)],
            snapshots: [process.pid: process],
            plannedLaunches: [],
            terminationBehavior: .keepRunning
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 2_001
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: consent
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected graceful termination timeout")
        } catch let RuntimeSecurityError.gracefulTerminationTimedOut(pid) {
            XCTAssertEqual(pid, process.pid)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(harness.terminationRequests(), [process.pid])
        XCTAssertTrue(harness.launchRequests().isEmpty)
        XCTAssertEqual(harness.forceTerminationCount(), 0)
    }

    /// End-to-end reproduction of the production failure: the debug instance's
    /// child service inherits the DevTools listen socket FD, so lsof reports
    /// both PIDs. The restart must still succeed when every extra holder is a
    /// same-process-group descendant of the debug leader.
    func testRestartSucceedsWhenChildInheritsDebugListenerSocket() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let childHolder = RuntimeProcessSnapshot(
            pid: 2_002,
            processGroupID: debugPID,
            startTime: ProcessStartTime(seconds: 201, microseconds: 1),
            executableURL: URL(
                fileURLWithPath: "/Users/test/.codex/computer-use/SkyComputerUseService"
            ),
            arguments: []
        )
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal, childHolder.pid: childHolder],
            plannedLaunches: [
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID,
            listenerOutput: "p2001\nf59\nn127.0.0.1:53810\nTST=LISTEN\n"
                + "p2002\nf59\nn127.0.0.1:53810\nTST=LISTEN\n"
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )

        let session = try await restarter.restartForDebugging(request)

        XCTAssertEqual(session.process.pid, debugPID)
        XCTAssertEqual(
            session.listener,
            VerifiedDebugListener(pid: debugPID, address: "127.0.0.1", port: 53_810)
        )

        let restored = try await restarter.rollbackToNormal(session)
        XCTAssertEqual(restored.process.pid, 3_001)
    }

    /// Reproduces the second half of the production failure: the relaunched
    /// app accepts the quit request but never exits on the first attempts.
    /// Recovery must keep re-sending the graceful request until it takes effect.
    func testPendingRecoveryRetriesGracefulTerminationUntilItSucceeds() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove
        )
        // The first two quit requests are accepted but never take effect,
        // matching the observed production behavior after a debug relaunch.
        harness.ignoreTerminationRequests(for: debugPID, count: 2)
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 9_999,
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                gracefulTerminationTimeout: .seconds(5),
                terminationRetryInterval: .milliseconds(20),
                pollInterval: .milliseconds(5)
            )
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected listener verification failure")
        } catch RuntimeSecurityError.listenerVerificationFailed {
            // The rollback succeeded, so the primary error must surface intact.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            harness.terminationRequests(),
            [normal.pid, debugPID, debugPID, debugPID]
        )
        XCTAssertEqual(harness.launchRequests().count, 2)
        XCTAssertEqual(
            harness.runningApplications(bundleIdentifier: bundle.bundleIdentifier)
                .map(\.pid),
            [3_001]
        )
        XCTAssertEqual(harness.forceTerminationCount(), 0)
        let hasPendingRecovery = await restarter.hasPendingRecovery()
        XCTAssertFalse(hasPendingRecovery)
    }

    /// If the debug instance never exits, recovery must still fail closed: no
    /// force termination, pending recovery retained for an explicit retry, and
    /// the combined error must keep the primary failure visible.
    func testPendingRecoveryKeepsFailingClosedWhenTerminationNeverTakesEffect() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove
        )
        harness.ignoreTerminationRequests(for: debugPID, count: 1_000_000)
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 9_999,
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                gracefulTerminationTimeout: .milliseconds(200),
                terminationRetryInterval: .milliseconds(20),
                pollInterval: .milliseconds(5)
            )
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected combined rollback failure")
        } catch let error as RuntimeSecurityError {
            guard case let .automaticRollbackFailed(primary, rollback) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(primary.contains("CDP listener 校验失败"))
            XCTAssertTrue(rollback.contains("优雅退出超时"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let debugTerminationRequests = harness.terminationRequests()
            .filter { $0 == debugPID }
        XCTAssertGreaterThanOrEqual(debugTerminationRequests.count, 3)
        XCTAssertEqual(harness.forceTerminationCount(), 0)
        XCTAssertEqual(harness.launchRequests().count, 1)
        let hasPendingRecovery = await restarter.hasPendingRecovery()
        XCTAssertTrue(hasPendingRecovery)
    }

    func testCancellationDuringAcceptedTerminationRecoversNormalDetached() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .cancelAndRemove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 2_001
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: consent
        )

        let restartTask = Task {
            try await restarter.restartForDebugging(request)
        }
        do {
            _ = try await restartTask.value
            XCTFail("Expected cancellation after accepted termination")
        } catch is CancellationError {
            // Detached recovery completed before the cancellation escaped.
        }

        XCTAssertEqual(harness.terminationRequests(), [normal.pid])
        XCTAssertEqual(harness.launchRequests().count, 1)
        XCTAssertEqual(
            harness.runningApplications(bundleIdentifier: bundle.bundleIdentifier)
                .map(\.pid),
            [3_001]
        )
        let hasPendingRecovery = await restarter.hasPendingRecovery()
        XCTAssertFalse(hasPendingRecovery)
    }

    func testUnverifiedReturnedPIDIsReverifiedAndRolledBackSafely() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove,
            snapshotFailuresRemaining: [debugPID: 1]
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: consent
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected initial process discovery failure")
        } catch let RuntimeSecurityError.processUnavailable(pid) {
            XCTAssertEqual(pid, debugPID)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])
        XCTAssertEqual(harness.launchRequests().count, 2)
        XCTAssertEqual(
            harness.runningApplications(bundleIdentifier: bundle.bundleIdentifier)
                .map(\.pid),
            [3_001]
        )
        let hasPendingRecovery = await restarter.hasPendingRecovery()
        XCTAssertFalse(hasPendingRecovery)
    }

    func testReturnedPIDWithConflictingDebugControlsIsNeverTerminated() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let restoredPID: pid_t = 3_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(
                    pid: debugPID,
                    executableURL: fixture.executableURL,
                    startSeconds: 200,
                    additionalArguments: ["--remote-debugging-address=0.0.0.0"]
                ),
                .init(
                    pid: restoredPID,
                    executableURL: fixture.executableURL,
                    startSeconds: 300
                ),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: try XCTUnwrap(
                ExplicitRestartConsent(userConfirmed: true)
            )
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected conflicting debug control rejection")
        } catch let error as RuntimeSecurityError {
            guard case .automaticRollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("未发送任何退出信号"))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid])
        XCTAssertEqual(
            harness.runningApplications(bundleIdentifier: bundle.bundleIdentifier)
                .map(\.pid),
            [debugPID]
        )
        let hasPendingBeforeRetry = await restarter.hasPendingRecovery()
        XCTAssertTrue(hasPendingBeforeRetry)

        harness.removeProcess(pid: debugPID)
        let optionalRestored = try await restarter.recoverPendingToNormal(
            verifiedBundle: bundle,
            consent: try XCTUnwrap(
                ExplicitRestartConsent(userConfirmed: true)
            )
        )
        let restored = try XCTUnwrap(optionalRestored)
        XCTAssertEqual(restored.process.pid, restoredPID)
        XCTAssertEqual(harness.terminationRequests(), [normal.pid])
        let hasPendingAfterRetry = await restarter.hasPendingRecovery()
        XCTAssertFalse(hasPendingAfterRetry)
    }

    func testAmbiguousReturnedPIDIsNotTerminatedAndPendingRecoveryUsesFreshConsent() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let impostorExecutable = temporaryRoot.appendingPathComponent("Impostor-main")
        try Data("impostor".utf8).write(to: impostorExecutable)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(
                    pid: debugPID,
                    executableURL: fixture.executableURL,
                    startSeconds: 200,
                    runningApplicationExecutableURL: impostorExecutable
                ),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove,
            snapshotFailuresRemaining: [debugPID: 1]
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID
        )
        let applyConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: applyConsent
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected pending recovery")
        } catch let error as RuntimeSecurityError {
            guard case .automaticRollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("未发送任何退出信号"))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid])
        let hasPendingAfterAmbiguity = await restarter.hasPendingRecovery()
        XCTAssertTrue(hasPendingAfterAmbiguity)

        do {
            _ = try await restarter.recoverPendingToNormal(
                verifiedBundle: bundle,
                consent: applyConsent
            )
            XCTFail("Expected apply-consent replay rejection")
        } catch let error as RuntimeSecurityError {
            XCTAssertEqual(error, .explicitRestartConsentRequired)
        }

        let firstRecoveryConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        do {
            _ = try await restarter.recoverPendingToNormal(
                verifiedBundle: bundle,
                consent: firstRecoveryConsent
            )
            XCTFail("Expected identity ambiguity to remain pending")
        } catch let error as RuntimeSecurityError {
            guard case .automaticRollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid])

        harness.replaceRunningApplicationExecutable(
            pid: debugPID,
            executableURL: fixture.executableURL
        )
        do {
            _ = try await restarter.recoverPendingToNormal(
                verifiedBundle: bundle,
                consent: firstRecoveryConsent
            )
            XCTFail("Expected failed-recovery consent replay rejection")
        } catch let error as RuntimeSecurityError {
            XCTAssertEqual(error, .explicitRestartConsentRequired)
        }

        let finalConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let optionalRestored = try await restarter.recoverPendingToNormal(
            verifiedBundle: bundle,
            consent: finalConsent
        )
        let restored = try XCTUnwrap(optionalRestored)
        XCTAssertEqual(restored.process.pid, 3_001)
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])
        let hasPendingAfterRecovery = await restarter.hasPendingRecovery()
        XCTAssertFalse(hasPendingAfterRecovery)
    }

    func testLaunchWithoutReturnedPIDNeverTerminatesCandidateAndCanRecoverAfterItExits() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(
                    pid: debugPID,
                    executableURL: fixture.executableURL,
                    startSeconds: 200,
                    throwsAfterCreating: true
                ),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: try XCTUnwrap(
                ExplicitRestartConsent(userConfirmed: true)
            )
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected launch failure with pending recovery")
        } catch let error as RuntimeSecurityError {
            guard case .automaticRollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("未向任何候选进程发送退出信号"))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid])
        XCTAssertEqual(harness.launchRequests().count, 1)
        let hasPendingAfterLaunchFailure = await restarter.hasPendingRecovery()
        XCTAssertTrue(hasPendingAfterLaunchFailure)

        harness.removeProcess(pid: debugPID)
        let recoveryConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let optionalRestored = try await restarter.recoverPendingToNormal(
            verifiedBundle: bundle,
            consent: recoveryConsent
        )
        let restored = try XCTUnwrap(optionalRestored)
        XCTAssertEqual(restored.process.pid, 3_001)
        XCTAssertEqual(harness.terminationRequests(), [normal.pid])
        XCTAssertEqual(harness.launchRequests().count, 2)
        let hasPendingAfterRecovery = await restarter.hasPendingRecovery()
        XCTAssertFalse(hasPendingAfterRecovery)
    }

    func testConcurrentPendingRecoveryIsRejectedWithoutDuplicateTerminationOrConsentUse() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let impostorExecutable = temporaryRoot.appendingPathComponent("Concurrent-impostor")
        try Data("impostor".utf8).write(to: impostorExecutable)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(
                    pid: debugPID,
                    executableURL: fixture.executableURL,
                    startSeconds: 200,
                    runningApplicationExecutableURL: impostorExecutable
                ),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 400),
            ],
            terminationBehavior: .remove,
            snapshotFailuresRemaining: [debugPID: 1]
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID,
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                gracefulTerminationTimeout: .seconds(1),
                pollInterval: .milliseconds(5)
            )
        )
        let applyConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: applyConsent
        )
        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected initial ambiguous recovery")
        } catch let error as RuntimeSecurityError {
            guard case .automaticRollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        harness.replaceRunningApplicationExecutable(
            pid: debugPID,
            executableURL: fixture.executableURL
        )
        harness.setTerminationBehavior(.keepRunning)
        let firstConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let firstRecovery = Task {
            try await restarter.recoverPendingToNormal(
                verifiedBundle: bundle,
                consent: firstConsent
            )
        }
        for _ in 0 ..< 100 {
            if harness.terminationRequests().count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])

        let concurrentConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        do {
            _ = try await restarter.recoverPendingToNormal(
                verifiedBundle: bundle,
                consent: concurrentConsent
            )
            XCTFail("Expected in-progress recovery rejection")
        } catch let error as RuntimeSecurityError {
            XCTAssertTrue(error.localizedDescription.contains("正在执行"))
            XCTAssertTrue(error.localizedDescription.contains("未消费新的授权"))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])

        harness.removeProcess(pid: debugPID)
        let optionalFirstRestored = try await firstRecovery.value
        let firstRestored = try XCTUnwrap(optionalFirstRestored)
        XCTAssertEqual(firstRestored.process.pid, 3_001)
        let hasPendingAfterRecovery = await restarter.hasPendingRecovery()
        XCTAssertFalse(hasPendingAfterRecovery)

        harness.setTerminationBehavior(.remove)
        let replayableRequest = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: concurrentConsent
        )
        let debugSession = try await restarter.restartForDebugging(
            replayableRequest
        )
        XCTAssertEqual(debugSession.process.pid, debugPID)
    }

    func testConcurrentRestartTransactionIsRejectedWithoutConsumingConsent() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .keepRunning
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID,
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                gracefulTerminationTimeout: .seconds(1),
                pollInterval: .milliseconds(5)
            )
        )
        let firstRequest = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: try XCTUnwrap(
                ExplicitRestartConsent(userConfirmed: true)
            )
        )
        let firstRestart = Task {
            try await restarter.restartForDebugging(firstRequest)
        }
        for _ in 0 ..< 100 {
            if harness.terminationRequests() == [normal.pid] { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let concurrentConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let concurrentRequest = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: concurrentConsent
        )
        do {
            _ = try await restarter.restartForDebugging(concurrentRequest)
            XCTFail("Expected concurrent restart rejection")
        } catch let error as RuntimeSecurityError {
            XCTAssertTrue(error.localizedDescription.contains("正在执行"))
            XCTAssertTrue(error.localizedDescription.contains("未消费授权"))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid])

        harness.removeProcess(pid: normal.pid)
        let debugSession = try await firstRestart.value
        XCTAssertEqual(debugSession.process.pid, debugPID)

        harness.setTerminationBehavior(.remove)
        let restored = try await restarter.restoreToNormal(
            debugSession,
            consent: concurrentConsent
        )
        XCTAssertEqual(restored.process.pid, 3_001)
    }

    func testConcurrentManagedRestoreIsRejectedWithoutDuplicateTerminationOrConsentUse() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 400),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID,
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                gracefulTerminationTimeout: .seconds(1),
                pollInterval: .milliseconds(5)
            )
        )
        let applyRequest = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: try XCTUnwrap(
                ExplicitRestartConsent(userConfirmed: true)
            )
        )
        let debugSession = try await restarter.restartForDebugging(applyRequest)

        harness.setTerminationBehavior(.keepRunning)
        let firstRestore = Task {
            try await restarter.restoreToNormal(
                debugSession,
                consent: try XCTUnwrap(
                    ExplicitRestartConsent(userConfirmed: true)
                )
            )
        }
        for _ in 0 ..< 100 {
            if harness.terminationRequests() == [normal.pid, debugPID] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])

        let concurrentConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        do {
            _ = try await restarter.restoreToNormal(
                debugSession,
                consent: concurrentConsent
            )
            XCTFail("Expected concurrent managed restore rejection")
        } catch let error as RuntimeSecurityError {
            XCTAssertTrue(error.localizedDescription.contains("已在执行"))
            XCTAssertTrue(error.localizedDescription.contains("未消费新的授权"))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])

        harness.removeProcess(pid: debugPID)
        let restored = try await firstRestore.value
        XCTAssertEqual(restored.process.pid, 3_001)

        harness.setTerminationBehavior(.remove)
        let replayableRequest = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: concurrentConsent
        )
        let replayedSession = try await restarter.restartForDebugging(
            replayableRequest
        )
        XCTAssertEqual(replayedSession.process.pid, debugPID)
    }

    func testCallerCancellationCannotStrandManagedRestoreAfterTermination() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let restoredPID: pid_t = 3_001
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: restoredPID, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID,
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                gracefulTerminationTimeout: .seconds(1),
                pollInterval: .milliseconds(5)
            )
        )
        let debugSession = try await restarter.restartForDebugging(
            try ProductionRestartGate().makeRequest(
                bundle: bundle,
                consent: try XCTUnwrap(
                    ExplicitRestartConsent(userConfirmed: true)
                )
            )
        )

        harness.setTerminationBehavior(.keepRunning)
        let restoreTask = Task {
            try await restarter.restoreToNormal(
                debugSession,
                consent: try XCTUnwrap(
                    ExplicitRestartConsent(userConfirmed: true)
                )
            )
        }
        for _ in 0 ..< 100 {
            if harness.terminationRequests() == [normal.pid, debugPID] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])

        restoreTask.cancel()
        harness.removeProcess(pid: debugPID)
        let restored = try await restoreTask.value
        XCTAssertEqual(restored.process.pid, restoredPID)
        let remainedActive = await restarter.isActive(debugSession)
        let hasPending = await restarter.hasPendingRecovery()
        XCTAssertFalse(remainedActive)
        XCTAssertFalse(hasPending)
    }

    func testManagedRestoreValidationFailureKeepsPendingReturnedNormalRecoverable() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let debugPID: pid_t = 2_001
        let returnedNormalPID: pid_t = 3_001
        let impostorExecutable = temporaryRoot.appendingPathComponent(
            "Normal-validation-impostor"
        )
        try Data("impostor".utf8).write(to: impostorExecutable)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: debugPID, executableURL: fixture.executableURL, startSeconds: 200),
                .init(
                    pid: returnedNormalPID,
                    executableURL: fixture.executableURL,
                    startSeconds: 300,
                    runningApplicationExecutableURL: impostorExecutable
                ),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: debugPID
        )
        let debugSession = try await restarter.restartForDebugging(
            try ProductionRestartGate().makeRequest(
                bundle: bundle,
                consent: try XCTUnwrap(
                    ExplicitRestartConsent(userConfirmed: true)
                )
            )
        )

        do {
            _ = try await restarter.restoreToNormal(
                debugSession,
                consent: try XCTUnwrap(
                    ExplicitRestartConsent(userConfirmed: true)
                )
            )
            XCTFail("Expected returned normal identity validation failure")
        } catch let error as RuntimeSecurityError {
            guard case .automaticRollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])
        let remainedActive = await restarter.isActive(debugSession)
        let hasPending = await restarter.hasPendingRecovery()
        XCTAssertTrue(remainedActive)
        XCTAssertTrue(hasPending)

        do {
            _ = try await restarter.rollbackToNormal(debugSession)
            XCTFail("Expected pending retry to require fresh consent")
        } catch let error as RuntimeSecurityError {
            guard case .automaticRollbackFailed = error else {
                return XCTFail("Unexpected no-consent retry error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("新的明确授权"))
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])

        let misroutedConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        do {
            _ = try await restarter.recoverPendingToNormal(
                verifiedBundle: bundle,
                consent: misroutedConsent
            )
            XCTFail("Expected managed pending route rejection")
        } catch let error as RuntimeSecurityError {
            guard case .runningApplicationIdentityMismatch = error else {
                return XCTFail("Unexpected managed route error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("未消费授权"))
        }

        do {
            _ = try await restarter.restoreToNormal(
                debugSession,
                consent: misroutedConsent
            )
            XCTFail("Expected ambiguous returned normal to remain pending")
        } catch let error as RuntimeSecurityError {
            guard case .automaticRollbackFailed = error else {
                return XCTFail("Unexpected retry error: \(error)")
            }
        }
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])
        let activeAfterFailedRetry = await restarter.isActive(debugSession)
        let pendingAfterFailedRetry = await restarter.hasPendingRecovery()
        XCTAssertTrue(activeAfterFailedRetry)
        XCTAssertTrue(pendingAfterFailedRetry)

        harness.replaceRunningApplicationExecutable(
            pid: returnedNormalPID,
            executableURL: fixture.executableURL
        )
        let restored = try await restarter.restoreToNormal(
            debugSession,
            consent: try XCTUnwrap(
                ExplicitRestartConsent(userConfirmed: true)
            )
        )
        XCTAssertEqual(restored.process.pid, returnedNormalPID)
        XCTAssertEqual(harness.terminationRequests(), [normal.pid, debugPID])
        let isStillActive = await restarter.isActive(debugSession)
        let stillHasPending = await restarter.hasPendingRecovery()
        XCTAssertFalse(isStillActive)
        XCTAssertFalse(stillHasPending)
    }

    func testProductionRestarterRejectsSymlinkAndWritableProfile() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let emptyHarness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [],
            snapshots: [:],
            plannedLaunches: [],
            terminationBehavior: .remove
        )
        let profileTarget = symlinkFreeTemporaryRoot()
            .appendingPathComponent("profile-target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profileTarget,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(profileTarget.path, mode_t(0o700)), 0)
        let profileLink = symlinkFreeTemporaryRoot()
            .appendingPathComponent("profile-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: profileLink,
            withDestinationURL: profileTarget
        )
        let linkRestarter = makeProductionRestarter(
            harness: emptyHarness,
            bundle: bundle,
            listenerPID: 2_001,
            profile: profileLink
        )
        let linkConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let linkRequest = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: linkConsent
        )
        do {
            _ = try await linkRestarter.restartForDebugging(linkRequest)
            XCTFail("Expected profile symlink rejection")
        } catch RuntimeSecurityError.secureDirectoryIdentityChanged {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let writableProfile = symlinkFreeTemporaryRoot()
            .appendingPathComponent("writable-profile", isDirectory: true)
        try FileManager.default.createDirectory(
            at: writableProfile,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(writableProfile.path, mode_t(0o770)), 0)
        let writableRestarter = makeProductionRestarter(
            harness: emptyHarness,
            bundle: bundle,
            listenerPID: 2_001,
            profile: writableProfile
        )
        let writableConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let writableRequest = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: writableConsent
        )
        do {
            _ = try await writableRestarter.restartForDebugging(writableRequest)
            XCTFail("Expected group-writable profile rejection")
        } catch RuntimeSecurityError.secureDirectoryIdentityChanged {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(emptyHarness.launchRequests().isEmpty)
    }

    func testListenerFailureAutomaticallyRollsBackToNormal() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: 2_001, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 9_999
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: consent
        )

        do {
            _ = try await restarter.restartForDebugging(request)
            XCTFail("Expected listener owner rejection")
        } catch RuntimeSecurityError.listenerVerificationFailed {
            // The original failure is returned after successful rollback.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(harness.terminationRequests(), [1_001, 2_001])
        let launchRequests = harness.launchRequests()
        guard launchRequests.count == 2 else {
            return XCTFail("Expected debug launch plus normal rollback, got \(launchRequests.count)")
        }
        XCTAssertTrue(launchRequests[1].arguments.isEmpty)
        XCTAssertEqual(
            harness.runningApplications(
                bundleIdentifier: bundle.bundleIdentifier
            ).map(\.pid),
            [3_001]
        )
    }

    func testProductionRestartAndTransactionalRollbackUseRealProfileWithoutDeletingIt() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: 2_001, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove
        )
        let profile = symlinkFreeTemporaryRoot().appendingPathComponent(
            "Library/Application Support/Codex",
            isDirectory: true
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 2_001,
            profile: profile
        )
        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: consent
        )

        let debugSession = try await restarter.restartForDebugging(request)
        let requestsAfterDebugLaunch = harness.launchRequests()
        guard requestsAfterDebugLaunch.count == 1 else {
            return XCTFail("Expected one debug launch, got \(requestsAfterDebugLaunch.count)")
        }
        XCTAssertEqual(
            Set(requestsAfterDebugLaunch[0].arguments),
            [
                "--user-data-dir=\(profile.path)",
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=0",
            ]
        )
        XCTAssertEqual(requestsAfterDebugLaunch[0].environment, [:])
        XCTAssertEqual(debugSession.process.pid, 2_001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))

        let normalSession = try await restarter.rollbackToNormal(debugSession)

        let allRequests = harness.launchRequests()
        guard allRequests.count == 2 else {
            return XCTFail("Expected debug and normal launches, got \(allRequests.count)")
        }
        XCTAssertTrue(allRequests[1].arguments.isEmpty)
        XCTAssertEqual(allRequests[1].environment, [:])
        XCTAssertEqual(normalSession.process.pid, 3_001)
        XCTAssertFalse(
            normalSession.process.arguments.contains {
                $0.hasPrefix("--remote-debugging")
            }
        )
        XCTAssertEqual(harness.terminationRequests(), [1_001, 2_001])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
        let isActive = await restarter.isActive(debugSession)
        XCTAssertFalse(isActive)
    }

    func testUserRestoreRequiresFreshConsentAndRejectsReplay() async throws {
        let fixture = try makeBundleFixture()
        let bundle = makeVerifiedBundle(fixture)
        let normal = makeProcess(pid: 1_001, executableURL: fixture.executableURL)
        let harness = ProductionRestartHarness(
            bundleIdentifier: bundle.bundleIdentifier,
            applications: [makeRunningApplication(normal, bundle: bundle)],
            snapshots: [normal.pid: normal],
            plannedLaunches: [
                .init(pid: 2_001, executableURL: fixture.executableURL, startSeconds: 200),
                .init(pid: 3_001, executableURL: fixture.executableURL, startSeconds: 300),
            ],
            terminationBehavior: .remove
        )
        let restarter = makeProductionRestarter(
            harness: harness,
            bundle: bundle,
            listenerPID: 2_001
        )
        let applyConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let request = try ProductionRestartGate().makeRequest(
            bundle: bundle,
            consent: applyConsent
        )
        let debugSession = try await restarter.restartForDebugging(request)

        do {
            _ = try await restarter.restoreToNormal(
                debugSession,
                consent: applyConsent
            )
            XCTFail("Expected consent replay rejection")
        } catch let error as RuntimeSecurityError {
            XCTAssertEqual(error, .explicitRestartConsentRequired)
        }
        XCTAssertEqual(harness.terminationRequests(), [1_001])

        let restoreConsent = try XCTUnwrap(
            ExplicitRestartConsent(userConfirmed: true)
        )
        let restored = try await restarter.restoreToNormal(
            debugSession,
            consent: restoreConsent
        )
        XCTAssertEqual(restored.process.pid, 3_001)
        XCTAssertEqual(harness.terminationRequests(), [1_001, 2_001])
    }

    func testRestartGateCannotCreateRequestWithoutAffirmativeConsent() throws {
        XCTAssertNil(ExplicitRestartConsent(userConfirmed: false))
        let fixture = try makeBundleFixture()
        let bundle = VerifiedChatGPTBundle(
            appURL: fixture.appURL,
            executableURL: fixture.executableURL,
            bundleIdentifier: "com.openai.codex",
            teamIdentifier: "2DC432GLL2",
            shortVersion: "26.707.72221",
            buildVersion: "5307"
        )
        XCTAssertThrowsError(
            try ProductionRestartGate().makeRequest(bundle: bundle, consent: nil)
        ) { error in
            XCTAssertEqual(error as? RuntimeSecurityError, .explicitRestartConsentRequired)
        }

        let consent = try XCTUnwrap(ExplicitRestartConsent(userConfirmed: true))
        let request = try ProductionRestartGate().makeRequest(bundle: bundle, consent: consent)
        XCTAssertEqual(request.bundle, bundle)
        XCTAssertEqual(request.consent, consent)
    }

    private func makeBundleFixture() throws -> BundleFixture {
        let appURL = temporaryRoot.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/ChatGPT")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("executable".utf8).write(to: executableURL)
        return BundleFixture(appURL: appURL, executableURL: executableURL)
    }

    private func makeBundleVerifier(
        fixture: BundleFixture,
        version: String,
        build: String,
        signingTeam: String,
        metadataBundleIdentifier: String = "com.openai.codex",
        signingIdentifier: String = "com.openai.codex"
    ) -> ChatGPTBundleVerifier {
        ChatGPTBundleVerifier(
            policy: .init(
                allowedCanonicalAppURLs: [fixture.appURL.standardizedFileURL],
                expectedBundleIdentifier: "com.openai.codex",
                expectedTeamIdentifier: "2DC432GLL2"
            ),
            metadataLoader: StubBundleMetadataLoader(
                metadata: ChatGPTBundleMetadata(
                    bundleIdentifier: metadataBundleIdentifier,
                    shortVersion: version,
                    buildVersion: build,
                    executableURL: fixture.executableURL
                )
            ),
            signatureValidator: StubSignatureValidator(
                identity: CodeSigningIdentity(
                    identifier: signingIdentifier,
                    teamIdentifier: signingTeam
                )
            )
        )
    }

    private func makeProductionDebugSessionValidationFixture() throws
        -> ProductionDebugSession
    {
        let userDataDirectory = temporaryRoot.appendingPathComponent(
            "production-validator-profile",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: userDataDirectory,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(userDataDirectory.path, mode_t(0o700)), 0)
        var info = stat()
        guard lstat(userDataDirectory.path, &info) == 0 else {
            throw RuntimeSecurityError.secureDirectoryCreationFailed(
                userDataDirectory.path
            )
        }

        let appURL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app",
            isDirectory: true
        )
        let executableURL = appURL.appendingPathComponent(
            "Contents/MacOS/ChatGPT"
        )
        let process = RuntimeProcessSnapshot(
            pid: 43_210,
            processGroupID: 43_210,
            startTime: .init(seconds: 4_321, microseconds: 10),
            executableURL: executableURL,
            arguments: [
                executableURL.path,
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=0",
                "--user-data-dir=\(userDataDirectory.path)",
            ]
        )
        let bundle = VerifiedChatGPTBundle(
            appURL: appURL,
            executableURL: executableURL,
            bundleIdentifier: "com.openai.codex",
            teamIdentifier: "2DC432GLL2",
            shortVersion: "99.0",
            buildVersion: "validator-test-build"
        )
        return ProductionDebugSession(
            id: UUID(),
            bundle: bundle,
            process: process,
            userDataDirectory: userDataDirectory,
            userDataIdentity: FileIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                owner: info.st_uid
            ),
            endpoint: DevToolsActivePort(
                port: 53_810,
                browserWebSocketPath: "/devtools/browser/validator-test"
            ),
            listener: VerifiedDebugListener(
                pid: process.pid,
                address: "127.0.0.1",
                port: 53_810
            )
        )
    }

    private func makeListenerVerifier(_ output: String) -> DebugListenerVerifier {
        DebugListenerVerifier(
            commandExecutor: StubCommandExecutor(
                result: CommandExecutionResult(
                    terminationStatus: 0,
                    standardOutput: Data(output.utf8),
                    standardError: Data()
                )
            )
        )
    }

    private func makeVerifiedBundle(
        _ fixture: BundleFixture,
        appURL: URL? = nil,
        executableURL: URL? = nil,
        bundleIdentifier: String = "com.openai.codex",
        teamIdentifier: String = "2DC432GLL2",
        shortVersion: String = "26.707.72221",
        buildVersion: String = "5307"
    ) -> VerifiedChatGPTBundle {
        VerifiedChatGPTBundle(
            appURL: appURL ?? fixture.appURL,
            executableURL: executableURL ?? fixture.executableURL,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
    }

    private func makeProcess(
        pid: pid_t,
        executableURL: URL,
        arguments: [String] = []
    ) -> RuntimeProcessSnapshot {
        RuntimeProcessSnapshot(
            pid: pid,
            processGroupID: pid,
            startTime: ProcessStartTime(seconds: UInt64(pid), microseconds: 1),
            executableURL: executableURL,
            arguments: arguments
        )
    }

    private func makeRunningApplication(
        _ process: RuntimeProcessSnapshot,
        bundle: VerifiedChatGPTBundle
    ) -> RunningChatGPTApplication {
        RunningChatGPTApplication(
            pid: process.pid,
            bundleIdentifier: bundle.bundleIdentifier,
            executableURL: process.executableURL
        )
    }

    private func makeIsolatedLauncher(
        harness: LaunchHarness,
        listenerPID: pid_t,
        gracefulAccepted: Bool,
        gracefulExitsGroup: Bool
    ) -> IsolatedDebugLauncher {
        IsolatedDebugLauncher(
            storageManager: SecureIsolatedRuntimeStorageManager(
                temporaryRoot: temporaryRoot
            ),
            workspaceLauncher: HarnessWorkspaceLauncher(harness: harness),
            processInspector: HarnessProcessInspector(harness: harness),
            endpointDiscoverer: StubEndpointDiscoverer(
                endpoint: DevToolsActivePort(
                    port: 53_810,
                    browserWebSocketPath: "/devtools/browser/4D36E96E-E325-4A73-B3A4-FA3A2E49AA10"
                )
            ),
            listenerVerifier: makeListenerVerifier(
                "p\(listenerPID)\nn127.0.0.1:53810\nTST=LISTEN\n"
            ),
            applicationController: HarnessIsolatedApplicationController(
                harness: harness,
                accepted: gracefulAccepted,
                exitsGroup: gracefulExitsGroup
            ),
            processGroupSignaler: HarnessProcessGroupSignaler(harness: harness),
            exactProcessSignaler: HarnessExactProcessSignaler(harness: harness),
            timing: .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                terminationGracePeriod: .zero,
                killGracePeriod: .zero,
                pollInterval: .milliseconds(1)
            )
        )
    }

    private func makeProductionRestarter(
        harness: ProductionRestartHarness,
        bundle: VerifiedChatGPTBundle,
        reverifiedBundle: VerifiedChatGPTBundle? = nil,
        listenerPID: pid_t,
        listenerOutput: String? = nil,
        profile: URL? = nil,
        timing: ProductionChatGPTRestarter.Timing? = nil
    ) -> ProductionChatGPTRestarter {
        ProductionChatGPTRestarter(
            bundleVerifier: StubBundleVerifier(
                verifiedBundle: reverifiedBundle ?? bundle
            ),
            applicationController: HarnessRunningApplicationController(
                harness: harness
            ),
            workspaceLauncher: ProductionHarnessWorkspaceLauncher(
                harness: harness
            ),
            processInspector: ProductionHarnessProcessInspector(
                harness: harness
            ),
            endpointDiscoverer: StubFreshEndpointDiscoverer(
                endpoint: DevToolsActivePort(
                    port: 53_810,
                    browserWebSocketPath: "/devtools/browser/4D36E96E-E325-4A73-B3A4-FA3A2E49AA10"
                )
            ),
            listenerVerifier: makeListenerVerifier(
                listenerOutput
                    ?? "p\(listenerPID)\nn127.0.0.1:53810\nTST=LISTEN\n"
            ),
            userDataDirectory: profile ?? symlinkFreeTemporaryRoot().appendingPathComponent(
                "Library/Application Support/Codex",
                isDirectory: true
            ),
            timing: timing ?? .init(
                processDiscoveryTimeout: .zero,
                activePortTimeout: .zero,
                gracefulTerminationTimeout: .zero,
                pollInterval: .milliseconds(1)
            )
        )
    }

    private func symlinkFreeTemporaryRoot() -> URL {
        let path = temporaryRoot.path
        if path == "/var" || path.hasPrefix("/var/")
            || path == "/tmp" || path.hasPrefix("/tmp/")
        {
            return URL(fileURLWithPath: "/private\(path)", isDirectory: true)
        }
        return temporaryRoot.standardized
    }
}

private struct BundleFixture {
    let appURL: URL
    let executableURL: URL
}

private struct StubBundleMetadataLoader: ChatGPTBundleMetadataLoading {
    let metadata: ChatGPTBundleMetadata

    func metadata(at appURL: URL) throws -> ChatGPTBundleMetadata {
        metadata
    }
}

private struct StubSignatureValidator: ChatGPTCodeSignatureValidating {
    let identity: CodeSigningIdentity

    func validate(
        appURL: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> CodeSigningIdentity {
        identity
    }
}

private struct StubCommandExecutor: CommandExecuting {
    let result: CommandExecutionResult

    func run(executableURL: URL, arguments: [String]) throws -> CommandExecutionResult {
        result
    }
}

private struct StaticRuntimeProcessInspector: RuntimeProcessInspecting {
    let process: RuntimeProcessSnapshot

    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot {
        process
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        [process]
    }

    func allUserProcesses() throws -> [RuntimeProcessCandidate] {
        [RuntimeProcessCandidate(process)]
    }
}

private struct DictionaryRuntimeProcessInspector: RuntimeProcessInspecting {
    private let processes: [pid_t: RuntimeProcessSnapshot]

    init(processes: [RuntimeProcessSnapshot]) {
        self.processes = Dictionary(
            processes.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot {
        guard let process = processes[pid] else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }
        return process
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        processes.values
            .filter { $0.processGroupID == processGroupID }
            .sorted { $0.pid < $1.pid }
    }

    func allUserProcesses() throws -> [RuntimeProcessCandidate] {
        processes.values
            .map(RuntimeProcessCandidate.init)
            .sorted { $0.pid < $1.pid }
    }
}

private final class SequencedRuntimeProcessInspector:
    RuntimeProcessInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var processes: [RuntimeProcessSnapshot]

    init(processes: [RuntimeProcessSnapshot]) {
        self.processes = processes
    }

    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !processes.isEmpty else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }
        if processes.count == 1 {
            return processes[0]
        }
        return processes.removeFirst()
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        []
    }

    func allUserProcesses() throws -> [RuntimeProcessCandidate] {
        []
    }
}

private struct StubEndpointDiscoverer: DevToolsActivePortDiscovering {
    let endpoint: DevToolsActivePort

    func waitForEndpoint(
        in userDataDirectory: URL,
        timeout: Duration
    ) async throws -> DevToolsActivePort {
        endpoint
    }
}

private struct StubBundleVerifier: ChatGPTBundleVerifying {
    let verifiedBundle: VerifiedChatGPTBundle

    func verify(appURL: URL) throws -> VerifiedChatGPTBundle {
        verifiedBundle
    }
}

private struct StubFreshEndpointDiscoverer: FreshDevToolsActivePortDiscovering {
    let endpoint: DevToolsActivePort

    func captureBaseline(
        in userDataDirectory: URL
    ) throws -> DevToolsActivePortFileFingerprint? {
        nil
    }

    func waitForFreshEndpoint(
        in userDataDirectory: URL,
        differentFrom baseline: DevToolsActivePortFileFingerprint?,
        timeout: Duration
    ) async throws -> DevToolsActivePort {
        endpoint
    }
}

private struct PlannedProductionLaunch: Sendable {
    let pid: pid_t
    let executableURL: URL
    let startSeconds: UInt64
    let runningApplicationExecutableURL: URL
    let throwsAfterCreating: Bool
    let additionalArguments: [String]

    init(
        pid: pid_t,
        executableURL: URL,
        startSeconds: UInt64,
        runningApplicationExecutableURL: URL? = nil,
        throwsAfterCreating: Bool = false,
        additionalArguments: [String] = []
    ) {
        self.pid = pid
        self.executableURL = executableURL
        self.startSeconds = startSeconds
        self.runningApplicationExecutableURL =
            runningApplicationExecutableURL ?? executableURL
        self.throwsAfterCreating = throwsAfterCreating
        self.additionalArguments = additionalArguments
    }
}

private enum HarnessTerminationBehavior: Sendable {
    case remove
    case keepRunning
    case reject
    case cancelAndRemove
}

private final class ProductionRestartHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let bundleIdentifier: String
    private var applications: [RunningChatGPTApplication]
    private var snapshots: [pid_t: RuntimeProcessSnapshot]
    private var plannedLaunches: [PlannedProductionLaunch]
    private var terminationBehavior: HarnessTerminationBehavior
    private var terminationIgnoresRemaining: [pid_t: Int] = [:]
    private var snapshotFailuresRemaining: [pid_t: Int]
    private var capturedLaunchRequests: [WorkspaceApplicationLaunchRequest] = []
    private var capturedTerminationPIDs: [pid_t] = []
    private var capturedForceTerminationCount = 0

    init(
        bundleIdentifier: String,
        applications: [RunningChatGPTApplication],
        snapshots: [pid_t: RuntimeProcessSnapshot],
        plannedLaunches: [PlannedProductionLaunch],
        terminationBehavior: HarnessTerminationBehavior,
        snapshotFailuresRemaining: [pid_t: Int] = [:]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applications = applications
        self.snapshots = snapshots
        self.plannedLaunches = plannedLaunches
        self.terminationBehavior = terminationBehavior
        self.snapshotFailuresRemaining = snapshotFailuresRemaining
    }

    func runningApplications(bundleIdentifier requestedIdentifier: String)
        -> [RunningChatGPTApplication]
    {
        lock.lock()
        defer { lock.unlock() }
        return applications.filter {
            $0.bundleIdentifier == requestedIdentifier
        }
    }

    func requestTermination(of application: RunningChatGPTApplication) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        capturedTerminationPIDs.append(application.pid)
        if let ignores = terminationIgnoresRemaining[application.pid], ignores > 0 {
            // Simulates a quit AppleEvent that was accepted but never took
            // effect, as seen when the relaunched app is still starting up.
            terminationIgnoresRemaining[application.pid] = ignores - 1
            return true
        }
        switch terminationBehavior {
        case .remove:
            applications.removeAll { $0.pid == application.pid }
            snapshots.removeValue(forKey: application.pid)
            return true
        case .keepRunning:
            return true
        case .reject:
            return false
        case .cancelAndRemove:
            applications.removeAll { $0.pid == application.pid }
            snapshots.removeValue(forKey: application.pid)
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return true
        }
    }

    func launch(_ request: WorkspaceApplicationLaunchRequest) throws -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        guard !plannedLaunches.isEmpty else {
            throw RuntimeSecurityError.workspaceLaunchFailed(
                "fake launch queue is empty"
            )
        }
        let plan = plannedLaunches.removeFirst()
        capturedLaunchRequests.append(request)
        let process = RuntimeProcessSnapshot(
            pid: plan.pid,
            processGroupID: plan.pid,
            startTime: ProcessStartTime(
                seconds: plan.startSeconds,
                microseconds: 1
            ),
            executableURL: plan.executableURL,
            arguments: request.arguments + plan.additionalArguments
        )
        snapshots[plan.pid] = process
        applications = [
            RunningChatGPTApplication(
                pid: plan.pid,
                bundleIdentifier: bundleIdentifier,
                executableURL: plan.runningApplicationExecutableURL
            ),
        ]
        if plan.throwsAfterCreating {
            throw RuntimeSecurityError.workspaceLaunchFailed(
                "planned LaunchServices failure after process creation"
            )
        }
        return plan.pid
    }

    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if let failures = snapshotFailuresRemaining[pid], failures > 0 {
            snapshotFailuresRemaining[pid] = failures - 1
            throw RuntimeSecurityError.processUnavailable(pid)
        }
        guard let snapshot = snapshots[pid] else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }
        return snapshot
    }

    func launchRequests() -> [WorkspaceApplicationLaunchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedLaunchRequests
    }

    func terminationRequests() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return capturedTerminationPIDs
    }

    func forceTerminationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedForceTerminationCount
    }

    func replaceRunningApplicationExecutable(
        pid: pid_t,
        executableURL: URL
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = applications.firstIndex(where: { $0.pid == pid }) else {
            return
        }
        applications[index] = RunningChatGPTApplication(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            executableURL: executableURL
        )
    }

    func setTerminationBehavior(_ behavior: HarnessTerminationBehavior) {
        lock.lock()
        terminationBehavior = behavior
        lock.unlock()
    }

    func ignoreTerminationRequests(for pid: pid_t, count: Int) {
        lock.lock()
        terminationIgnoresRemaining[pid] = count
        lock.unlock()
    }

    func removeProcess(pid: pid_t) {
        lock.lock()
        applications.removeAll { $0.pid == pid }
        snapshots.removeValue(forKey: pid)
        lock.unlock()
    }
}

private struct HarnessRunningApplicationController:
    RunningChatGPTApplicationControlling
{
    let harness: ProductionRestartHarness

    @MainActor
    func runningApplications(
        bundleIdentifier: String
    ) -> [RunningChatGPTApplication] {
        harness.runningApplications(bundleIdentifier: bundleIdentifier)
    }

    @MainActor
    func requestTermination(of application: RunningChatGPTApplication) -> Bool {
        harness.requestTermination(of: application)
    }
}

private struct ProductionHarnessWorkspaceLauncher: WorkspaceApplicationLaunching {
    let harness: ProductionRestartHarness

    @MainActor
    func launch(_ request: WorkspaceApplicationLaunchRequest) async throws -> pid_t {
        try harness.launch(request)
    }
}

private struct ProductionHarnessProcessInspector: RuntimeProcessInspecting {
    let harness: ProductionRestartHarness

    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot {
        try harness.snapshot(pid: pid)
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        []
    }

    func allUserProcesses() throws -> [RuntimeProcessCandidate] {
        []
    }
}

private struct SignalEvent: Sendable, Equatable {
    let signal: Int32
    let processGroupID: pid_t
}

private struct ExactSignalEvent: Sendable, Equatable {
    let signal: Int32
    let processID: pid_t
}

private final class LaunchHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private let executableURL: URL
    private var helperExecutableURL: URL
    private var request: WorkspaceApplicationLaunchRequest?
    private var phase = 0
    private var signals: [SignalEvent] = []
    private var exactSignals: [ExactSignalEvent] = []
    private var exactRemovedPIDs: Set<pid_t> = []
    private var exactExitOnTermPIDs: Set<pid_t> = []
    private var extraProcesses: [pid_t: RuntimeProcessSnapshot] = [:]
    private var extraCandidates: [pid_t: RuntimeProcessCandidate] = [:]
    private var replacementSnapshots: [pid_t: RuntimeProcessSnapshot] = [:]

    init(pid: pid_t, executableURL: URL, helperExecutableURL: URL) {
        self.pid = pid
        self.executableURL = executableURL
        self.helperExecutableURL = helperExecutableURL
    }

    func capture(_ request: WorkspaceApplicationLaunchRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func capturedRequest() -> WorkspaceApplicationLaunchRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func snapshot(pid requestedPID: pid_t) throws -> RuntimeProcessSnapshot {
        let request = try currentRequest()
        lock.lock()
        let currentPhase = phase
        let helperExecutableURL = self.helperExecutableURL
        let removed = exactRemovedPIDs.contains(requestedPID)
        let extra = extraProcesses[requestedPID]
        let replacement = replacementSnapshots[requestedPID]
        lock.unlock()

        if let replacement { return replacement }
        guard !removed else {
            throw RuntimeSecurityError.processUnavailable(requestedPID)
        }
        if requestedPID == pid, currentPhase < 2 {
            return leader(arguments: request.arguments)
        }
        if requestedPID == pid + 1, currentPhase < 2 {
            return helper(executableURL: helperExecutableURL)
        }
        if let extra { return extra }
        throw RuntimeSecurityError.processUnavailable(requestedPID)
    }

    func allUserProcesses() throws -> [RuntimeProcessCandidate] {
        lock.lock()
        let request = self.request
        let currentPhase = phase
        let helperExecutableURL = self.helperExecutableURL
        let removed = exactRemovedPIDs
        let extras = Array(extraProcesses.values)
        let candidates = Array(extraCandidates.values)
        lock.unlock()

        var processes: [RuntimeProcessSnapshot] = []
        if let request {
            if currentPhase == 0 {
                processes.append(leader(arguments: request.arguments))
                processes.append(helper(executableURL: helperExecutableURL))
            } else if currentPhase == 1 {
                processes.append(helper(executableURL: helperExecutableURL))
            }
        }
        processes.append(contentsOf: extras)
        let processCandidates = processes
            .filter { !removed.contains($0.pid) }
            .sorted { $0.pid < $1.pid }
            .map { RuntimeProcessCandidate($0) }
        return (processCandidates + candidates)
            .filter { !removed.contains($0.pid) }
            .sorted { $0.pid < $1.pid }
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        let request = try currentRequest()
        guard processGroupID == pid else { return [] }
        lock.lock()
        let currentPhase = phase
        lock.unlock()
        switch currentPhase {
        case 0:
            return [leader(arguments: request.arguments), helper()]
                .filter { !isExactlyRemoved($0.pid) }
        case 1:
            return [helper()].filter { !isExactlyRemoved($0.pid) }
        default:
            return []
        }
    }

    func record(signal: Int32, processGroupID: pid_t) throws {
        guard processGroupID == pid else {
            throw RuntimeSecurityError.unsafeProcessGroup("unexpected fake PGID")
        }
        lock.lock()
        signals.append(SignalEvent(signal: signal, processGroupID: processGroupID))
        if signal == SIGTERM { phase = 1 }
        if signal == SIGKILL { phase = 2 }
        lock.unlock()
    }

    func setHelperExecutableURL(_ url: URL) {
        lock.lock()
        helperExecutableURL = url
        lock.unlock()
    }

    func addUserProcess(_ process: RuntimeProcessSnapshot) {
        lock.lock()
        extraProcesses[process.pid] = process
        lock.unlock()
    }

    func addUserCandidate(_ candidate: RuntimeProcessCandidate) {
        lock.lock()
        extraCandidates[candidate.pid] = candidate
        lock.unlock()
    }

    func replaceSnapshot(
        for processID: pid_t,
        with replacement: RuntimeProcessSnapshot
    ) {
        lock.lock()
        replacementSnapshots[processID] = replacement
        lock.unlock()
    }

    func setExactExitOnTerm(processID: pid_t) {
        lock.lock()
        exactExitOnTermPIDs.insert(processID)
        lock.unlock()
    }

    func recordExact(signal: Int32, processID: pid_t) {
        lock.lock()
        exactSignals.append(ExactSignalEvent(signal: signal, processID: processID))
        if signal == SIGKILL || exactExitOnTermPIDs.contains(processID) {
            exactRemovedPIDs.insert(processID)
        }
        lock.unlock()
    }

    func exactSignalEvents() -> [ExactSignalEvent] {
        lock.lock()
        defer { lock.unlock() }
        return exactSignals
    }

    func containsUserProcess(_ processID: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return extraProcesses[processID] != nil && !exactRemovedPIDs.contains(processID)
    }

    func requestGracefulTermination(
        pid requestedPID: pid_t,
        accepted: Bool,
        exitsGroup: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard requestedPID == pid, accepted else { return false }
        if exitsGroup { phase = 2 }
        return true
    }

    func signalEvents() -> [SignalEvent] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }

    private func currentRequest() throws -> WorkspaceApplicationLaunchRequest {
        lock.lock()
        defer { lock.unlock() }
        guard let request else {
            throw RuntimeSecurityError.processUnavailable(pid)
        }
        return request
    }

    private func leader(arguments: [String]) -> RuntimeProcessSnapshot {
        RuntimeProcessSnapshot(
            pid: pid,
            processGroupID: pid,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executableURL: executableURL,
            arguments: arguments
        )
    }

    private func helper() -> RuntimeProcessSnapshot {
        lock.lock()
        let executableURL = helperExecutableURL
        lock.unlock()
        return helper(executableURL: executableURL)
    }

    private func helper(executableURL: URL) -> RuntimeProcessSnapshot {
        return RuntimeProcessSnapshot(
            pid: pid + 1,
            processGroupID: pid,
            startTime: ProcessStartTime(seconds: 101, microseconds: 1),
            executableURL: executableURL,
            arguments: []
        )
    }

    private func isExactlyRemoved(_ processID: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return exactRemovedPIDs.contains(processID)
    }
}

private struct HarnessWorkspaceLauncher: WorkspaceApplicationLaunching {
    let harness: LaunchHarness

    @MainActor
    func launch(_ request: WorkspaceApplicationLaunchRequest) async throws -> pid_t {
        harness.capture(request)
        return try harness.snapshot(pid: 42_420).pid
    }
}

private struct HarnessIsolatedApplicationController:
    RunningChatGPTApplicationControlling
{
    let harness: LaunchHarness
    let accepted: Bool
    let exitsGroup: Bool

    @MainActor
    func runningApplications(
        bundleIdentifier: String
    ) -> [RunningChatGPTApplication] {
        []
    }

    @MainActor
    func requestTermination(of application: RunningChatGPTApplication) -> Bool {
        harness.requestGracefulTermination(
            pid: application.pid,
            accepted: accepted,
            exitsGroup: exitsGroup
        )
    }
}

private struct HarnessProcessInspector: RuntimeProcessInspecting {
    let harness: LaunchHarness

    func snapshot(pid: pid_t) throws -> RuntimeProcessSnapshot {
        try harness.snapshot(pid: pid)
    }

    func groupMembers(processGroupID: pid_t) throws -> [RuntimeProcessSnapshot] {
        try harness.groupMembers(processGroupID: processGroupID)
    }

    func allUserProcesses() throws -> [RuntimeProcessCandidate] {
        try harness.allUserProcesses()
    }
}

private struct HarnessProcessGroupSignaler: ProcessGroupSignaling {
    let harness: LaunchHarness

    func send(signal: Int32, toProcessGroup processGroupID: pid_t) throws {
        try harness.record(signal: signal, processGroupID: processGroupID)
    }
}

private struct HarnessExactProcessSignaler: ExactProcessSignaling {
    let harness: LaunchHarness

    func send(signal: Int32, toProcessID processID: pid_t) throws {
        harness.recordExact(signal: signal, processID: processID)
    }
}
