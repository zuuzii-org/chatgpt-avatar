import Foundation
import XCTest

@testable import ChatGPTSkinStudio

final class DiagnosticsLoggerTests: XCTestCase {

    func testLogAppendsSanitizedTimestampedLines() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticsLogger(directoryURL: directory)

        logger.log("runtime-signal", "generation=g-1 event=adapter-probe-failed")
        logger.log("multiline", "first line\nsecond line\rthird")
        logger.log("event-only")

        let contents = try String(
            contentsOf: directory.appendingPathComponent("diagnostics.log"),
            encoding: .utf8
        )
        let lines = contents.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("runtime-signal"))
        XCTAssertTrue(lines[0].contains("generation=g-1 event=adapter-probe-failed"))
        XCTAssertFalse(lines[0].hasPrefix("runtime-signal"), "line must be timestamped")
        XCTAssertTrue(lines[1].contains("first line second line third"))
        XCTAssertTrue(lines[2].hasSuffix(" event-only"))
        XCTAssertFalse(lines[2].contains("  "), "detail-less events keep a single separator")
    }

    func testLogTruncatesOverlongFields() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticsLogger(directoryURL: directory)

        logger.log(String(repeating: "e", count: 600), String(repeating: "d", count: 600))

        let contents = try String(
            contentsOf: directory.appendingPathComponent("diagnostics.log"),
            encoding: .utf8
        )
        let line = contents.split(separator: "\n").map(String.init).first ?? ""
        XCTAssertLessThan(line.count, 30 + 512 + 1 + 512)
        XCTAssertTrue(line.contains(String(repeating: "e", count: 512)))
        XCTAssertTrue(line.contains(String(repeating: "d", count: 512)))
    }

    func testLogRotatesWhenExistingFileExceedsCap() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("diagnostics.log")
        let oversized = Data(repeating: 0x61, count: 2 * 1024 * 1024 + 16)
        try oversized.write(to: logURL)

        let logger = DiagnosticsLogger(directoryURL: directory)
        logger.log("after-rotation")

        let previousURL = directory.appendingPathComponent("diagnostics.prev.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previousURL.path))
        let previousSize = try FileManager.default
            .attributesOfItem(atPath: previousURL.path)[.size] as? UInt64
        XCTAssertEqual(previousSize, UInt64(oversized.count))

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(contents.contains(String(repeating: "a", count: 64)))
        XCTAssertTrue(contents.contains("after-rotation"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLoggerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
