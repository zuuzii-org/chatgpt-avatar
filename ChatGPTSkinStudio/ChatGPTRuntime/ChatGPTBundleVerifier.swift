import Darwin
import Foundation
import Security

protocol ChatGPTBundleVerifying: Sendable {
    func verify(appURL: URL) throws -> VerifiedChatGPTBundle
}

protocol ChatGPTBundleMetadataLoading: Sendable {
    func metadata(at appURL: URL) throws -> ChatGPTBundleMetadata
}

protocol ChatGPTCodeSignatureValidating: Sendable {
    func validate(
        appURL: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> CodeSigningIdentity
}

struct SystemChatGPTBundleMetadataLoader: ChatGPTBundleMetadataLoading {
    func metadata(at appURL: URL) throws -> ChatGPTBundleMetadata {
        guard let bundle = Bundle(url: appURL) else {
            throw RuntimeSecurityError.bundleMetadataUnavailable("不是可读取的 .app bundle")
        }
        guard bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else {
            throw RuntimeSecurityError.bundleMetadataUnavailable("CFBundlePackageType 不是 APPL")
        }
        guard
            let bundleIdentifier = bundle.bundleIdentifier?.nonEmptyTrimmed,
            let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.nonEmptyTrimmed,
            let buildVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?.nonEmptyTrimmed,
            let executableURL = bundle.executableURL
        else {
            throw RuntimeSecurityError.bundleMetadataUnavailable("Bundle ID、版本、build 或 executable 缺失")
        }

        var executableInfo = stat()
        guard lstat(executableURL.path, &executableInfo) == 0 else {
            throw RuntimeSecurityError.bundleMetadataUnavailable("无法读取 executable：\(posixError())")
        }
        guard executableInfo.st_mode & S_IFMT == S_IFREG else {
            throw RuntimeSecurityError.bundleMetadataUnavailable("executable 不是普通文件")
        }

        let canonicalApp = appURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalExecutable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalExecutable.isStrictDescendant(of: canonicalApp.appendingPathComponent("Contents")) else {
            throw RuntimeSecurityError.bundleMetadataUnavailable("executable 逃出已验证的 app bundle")
        }

        return ChatGPTBundleMetadata(
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            executableURL: canonicalExecutable
        )
    }
}

struct SecurityFrameworkChatGPTCodeSignatureValidator: ChatGPTCodeSignatureValidating {
    func validate(
        appURL: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> CodeSigningIdentity {
        guard Self.isSafeRequirementAtom(expectedBundleIdentifier),
              Self.isSafeRequirementAtom(expectedTeamIdentifier)
        else {
            throw RuntimeSecurityError.codeSignatureValidationFailed("签名 requirement 参数包含非法字符")
        }

        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard status == errSecSuccess, let staticCode else {
            throw RuntimeSecurityError.codeSignatureValidationFailed(Self.describe(status))
        }

        let requirementText = "identifier \"\(expectedBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw RuntimeSecurityError.codeSignatureValidationFailed("无法建立签名 requirement：\(Self.describe(status))")
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        status = SecStaticCodeCheckValidity(staticCode, validationFlags, requirement)
        guard status == errSecSuccess else {
            throw RuntimeSecurityError.codeSignatureValidationFailed(Self.describe(status))
        }

        var signingInformation: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard status == errSecSuccess,
              let information = signingInformation as? [String: Any]
        else {
            throw RuntimeSecurityError.codeSignatureValidationFailed("无法读取签名身份：\(Self.describe(status))")
        }

        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        guard identifier == expectedBundleIdentifier, let identifier else {
            throw RuntimeSecurityError.bundleIdentifierMismatch(
                expected: expectedBundleIdentifier,
                actual: identifier
            )
        }
        guard teamIdentifier == expectedTeamIdentifier, let teamIdentifier else {
            throw RuntimeSecurityError.teamIdentifierMismatch(
                expected: expectedTeamIdentifier,
                actual: teamIdentifier
            )
        }
        return CodeSigningIdentity(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    private static func isSafeRequirementAtom(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (OSStatus \(status))"
        }
        return "OSStatus \(status)"
    }
}

struct ChatGPTBundleVerifier: ChatGPTBundleVerifying, Sendable {
    struct Policy: Sendable, Equatable {
        let allowedCanonicalAppURLs: Set<URL>
        let expectedBundleIdentifier: String
        let expectedTeamIdentifier: String

        static let production = Policy(
            allowedCanonicalAppURLs: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
                    .standardizedFileURL,
            ],
            expectedBundleIdentifier: "com.openai.codex",
            expectedTeamIdentifier: "2DC432GLL2"
        )
    }

    private let policy: Policy
    private let metadataLoader: any ChatGPTBundleMetadataLoading
    private let signatureValidator: any ChatGPTCodeSignatureValidating

    init(
        policy: Policy = .production,
        metadataLoader: any ChatGPTBundleMetadataLoading = SystemChatGPTBundleMetadataLoader(),
        signatureValidator: any ChatGPTCodeSignatureValidating = SecurityFrameworkChatGPTCodeSignatureValidator()
    ) {
        self.policy = policy
        self.metadataLoader = metadataLoader
        self.signatureValidator = signatureValidator
    }

    func verify(appURL requestedURL: URL) throws -> VerifiedChatGPTBundle {
        guard requestedURL.isFileURL else {
            throw RuntimeSecurityError.appPathNotAllowed(requestedURL.absoluteString)
        }

        let standardized = requestedURL.standardizedFileURL
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == canonical.path else {
            throw RuntimeSecurityError.appPathIsSymbolicLink(standardized.path)
        }
        guard policy.allowedCanonicalAppURLs.contains(canonical) else {
            throw RuntimeSecurityError.appPathNotAllowed(canonical.path)
        }

        var appInfo = stat()
        guard lstat(canonical.path, &appInfo) == 0, appInfo.st_mode & S_IFMT == S_IFDIR else {
            throw RuntimeSecurityError.appPathNotAllowed(canonical.path)
        }

        let metadata = try metadataLoader.metadata(at: canonical)
        let executable = metadata.executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard metadata.executableURL.isFileURL,
              executable.isStrictDescendant(
                of: canonical.appendingPathComponent("Contents", isDirectory: true)
              )
        else {
            throw RuntimeSecurityError.bundleMetadataUnavailable(
                "executable 不在已验证 app bundle 内"
            )
        }
        guard metadata.bundleIdentifier == policy.expectedBundleIdentifier else {
            throw RuntimeSecurityError.bundleIdentifierMismatch(
                expected: policy.expectedBundleIdentifier,
                actual: metadata.bundleIdentifier
            )
        }

        let signingIdentity = try signatureValidator.validate(
            appURL: canonical,
            expectedBundleIdentifier: policy.expectedBundleIdentifier,
            expectedTeamIdentifier: policy.expectedTeamIdentifier
        )
        guard signingIdentity.identifier == policy.expectedBundleIdentifier else {
            throw RuntimeSecurityError.bundleIdentifierMismatch(
                expected: policy.expectedBundleIdentifier,
                actual: signingIdentity.identifier
            )
        }
        guard signingIdentity.teamIdentifier == policy.expectedTeamIdentifier else {
            throw RuntimeSecurityError.teamIdentifierMismatch(
                expected: policy.expectedTeamIdentifier,
                actual: signingIdentity.teamIdentifier
            )
        }

        return VerifiedChatGPTBundle(
            appURL: canonical,
            executableURL: executable,
            bundleIdentifier: metadata.bundleIdentifier,
            teamIdentifier: signingIdentity.teamIdentifier,
            shortVersion: metadata.shortVersion,
            buildVersion: metadata.buildVersion
        )
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension URL {
    func isStrictDescendant(of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }
}

private func posixError() -> String {
    String(cString: strerror(errno))
}
