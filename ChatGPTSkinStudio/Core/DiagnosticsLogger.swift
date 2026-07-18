import Foundation
import OSLog

/// Persistent field diagnostics for skin-session runtime events.
///
/// The app previously had no durable log: when a skin applied and reverted in
/// the field there was no way to reconstruct which probe, render check, or
/// rollback step caused it. Events are mirrored to os_log and appended to a
/// size-capped file under Application Support so the exact failure chain can
/// be read back after the fact.
final class DiagnosticsLogger: @unchecked Sendable {
    static let shared = DiagnosticsLogger()

    private static let fileName = "diagnostics.log"
    private static let previousFileName = "diagnostics.prev.log"
    private static let maximumFileBytes: UInt64 = 2 * 1024 * 1024
    private static let maximumFieldLength = 512

    private let lock = NSLock()
    private let fileURL: URL
    private let previousFileURL: URL
    private var fileHandle: FileHandle?
    private let osLog = Logger(
        subsystem: "com.zuuzii.chatgpt-skin-studio",
        category: "diagnostics"
    )
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private convenience init() {
        let fileManager = FileManager.default
        let supportRoot = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        self.init(
            directoryURL: supportRoot.appendingPathComponent(
                ThemeRepository.applicationSupportDirectoryName,
                isDirectory: true
            )
        )
    }

    init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent(Self.fileName)
        previousFileURL = directoryURL.appendingPathComponent(Self.previousFileName)
        prepareLogFile(directoryURL: directoryURL)
    }

    deinit {
        lock.lock()
        try? fileHandle?.close()
        lock.unlock()
    }

    /// Records one runtime event. `event` is a stable machine-readable token;
    /// `detail` carries variable context (generation, signatures, messages).
    func log(_ event: String, _ detail: String = "") {
        let sanitizedEvent = Self.sanitize(event)
        let sanitizedDetail = Self.sanitize(detail)
        osLog.info(
            "\(sanitizedEvent, privacy: .public) \(sanitizedDetail, privacy: .public)"
        )
        lock.lock()
        defer { lock.unlock() }
        let timestamp = timestampFormatter.string(from: Date())
        let line = sanitizedDetail.isEmpty
            ? "\(timestamp) \(sanitizedEvent)\n"
            : "\(timestamp) \(sanitizedEvent) \(sanitizedDetail)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? fileHandle?.write(contentsOf: data)
    }

    private func prepareLogFile(directoryURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? UInt64,
           size > Self.maximumFileBytes
        {
            try? fileManager.removeItem(at: previousFileURL)
            try? fileManager.moveItem(at: fileURL, to: previousFileURL)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        if let fileHandle {
            _ = try? fileHandle.seekToEnd()
        }
    }

    private static func sanitize(_ value: String) -> String {
        String(
            value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .prefix(maximumFieldLength)
        )
    }
}
