import XCTest
@testable import ChatGPTSkinStudio

final class CDPKitTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "enabled": .bool(true),
            "name": .string("skin"),
            "items": .array([.number(1), .null])
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testJSONValueIntegerExtractionIsStrict() {
        XCTAssertEqual(JSONValue.number(42).integerValue, 42)
        XCTAssertNil(JSONValue.number(42.5).integerValue)
        XCTAssertNil(JSONValue.string("42").integerValue)
        XCTAssertNil(JSONValue.number(.infinity).integerValue)
    }

    func testDiscoveryRejectsReservedAndOutOfRangePorts() async {
        let client = CDPDiscoveryClient()
        for port in [0, 80, 1023, 65_536] {
            do {
                _ = try await client.fetchTargets(port: port)
                XCTFail("Expected invalid port \(port)")
            } catch let error as CDPClientError {
                XCTAssertEqual(error, .invalidPort(port))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWebSocketSessionRejectsRemoteHosts() async {
        do {
            _ = try CDPWebSocketSession(endpoint: URL(string: "ws://example.com:9341/devtools/page/1")!)
            XCTFail("Expected endpoint rejection")
        } catch let error as CDPClientError {
            XCTAssertEqual(error, .invalidEndpoint("ws://example.com:9341/devtools/page/1"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandsAreEncodedAsUTF8WebSocketTextFrames() throws {
        let message = try CDPWebSocketSession.makeCommandMessage(
            id: 7,
            method: "Runtime.enable",
            params: ["enabled": .bool(true)]
        )

        switch message {
        case .string(let text):
            let data = try XCTUnwrap(text.data(using: .utf8))
            let command = try JSONDecoder().decode(CDPCommand.self, from: data)
            XCTAssertEqual(command.id, 7)
            XCTAssertEqual(command.method, "Runtime.enable")
            XCTAssertEqual(command.params["enabled"], .bool(true))
        case .data:
            XCTFail("CDP JSON must not be sent as a binary WebSocket frame.")
        @unknown default:
            XCTFail("Unexpected WebSocket message type.")
        }
    }

    func testIntentionalWebSocketCloseFinishesWithoutUnexpectedTermination() async throws {
        let session = try CDPWebSocketSession(
            endpoint: URL(string: "ws://127.0.0.1:53812/devtools/page/test")!
        )
        let terminations = await session.connectionTerminations()

        await session.close()

        var iterator = terminations.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event)
    }

    func testWebSocketTaskRaisesMessageCeilingAboveThemePayloadBudget() throws {
        let endpoint = try XCTUnwrap(
            URL(string: "ws://127.0.0.1:53812/devtools/page/test")
        )
        let task = CDPWebSocketSession.makeWebSocketTask(
            session: URLSession(configuration: .ephemeral),
            endpoint: endpoint
        )

        XCTAssertEqual(task.maximumMessageSize, CDPWebSocketSession.maximumMessageSize)
        XCTAssertGreaterThanOrEqual(
            CDPWebSocketSession.maximumMessageSize,
            32 * 1024 * 1024,
            "传输上限必须覆盖已校验的主题 payload 预算（21MB hero + 协议开销）；"
                + "默认上限会让超大 CDP 消息以 EMSGSIZE 杀死整个调试会话。"
        )
    }
}
