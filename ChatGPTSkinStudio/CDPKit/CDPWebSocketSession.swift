import Foundation

private final class CDPWebSocketConnectionDelegate:
    NSObject,
    URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    enum Event: Sendable {
        case opened(taskIdentifier: Int)
        case closed(taskIdentifier: Int)
        case failed(taskIdentifier: Int, message: String)
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    override init() {
        let stream = AsyncStream<Event>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        super.init()
    }

    func finish() {
        continuation.finish()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        continuation.yield(.opened(taskIdentifier: webSocketTask.taskIdentifier))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        continuation.yield(.closed(taskIdentifier: webSocketTask.taskIdentifier))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        continuation.yield(
            .failed(
                taskIdentifier: task.taskIdentifier,
                message:
                    "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
            )
        )
    }
}

actor CDPWebSocketSession {
    typealias EventHandler = @Sendable (CDPEnvelope) async -> Void

    /// CDP peers can emit multi-megabyte messages (page console events, large
    /// evaluate results). URLSessionWebSocketTask's default message cap kills
    /// the whole session with EMSGSIZE when one arrives, so the transport
    /// ceiling sits well above the validated theme payload budget (21 MB hero).
    static let maximumMessageSize = 64 * 1024 * 1024

    static func makeWebSocketTask(
        session: URLSession,
        endpoint: URL
    ) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: endpoint)
        task.maximumMessageSize = maximumMessageSize
        return task
    }

    enum ConnectionTermination: Sendable, Equatable {
        case unexpectedClosure
    }

    private struct PendingCommand {
        let continuation: CheckedContinuation<[String: JSONValue], Error>
        let timeoutTask: Task<Void, Never>
    }

    private let endpoint: URL
    private let connectionDelegate: CDPWebSocketConnectionDelegate
    private let session: URLSession
    private let connectionTerminationsStream: AsyncStream<ConnectionTermination>
    private let connectionTerminationsContinuation:
        AsyncStream<ConnectionTermination>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var socketTaskIdentifier: Int?
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var connectionEventTask: Task<Void, Never>?
    private var nextIdentifier = 1
    private var pending: [Int: PendingCommand] = [:]
    private var handlers: [UUID: EventHandler] = [:]
    private var isConnected = false
    private var isClosed = false

    init(endpoint: URL) throws {
        guard
            endpoint.scheme == "ws",
            endpoint.host == "127.0.0.1",
            endpoint.port != nil,
            endpoint.path.hasPrefix("/devtools/")
        else {
            throw CDPClientError.invalidEndpoint(endpoint.absoluteString)
        }
        let connectionDelegate = CDPWebSocketConnectionDelegate()
        let connectionTerminations = AsyncStream<ConnectionTermination>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.endpoint = endpoint
        self.connectionDelegate = connectionDelegate
        self.connectionTerminationsStream = connectionTerminations.stream
        self.connectionTerminationsContinuation = connectionTerminations.continuation
        self.session = URLSession(
            configuration: .ephemeral,
            delegate: connectionDelegate,
            delegateQueue: nil
        )
    }

    func connect(timeout: Duration = .seconds(5)) async throws {
        if isConnected { return }
        guard socket == nil, !isClosed else { throw CDPClientError.socketClosed }

        let task = Self.makeWebSocketTask(session: session, endpoint: endpoint)
        socket = task
        socketTaskIdentifier = task.taskIdentifier
        let events = connectionDelegate.events
        connectionEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleConnectionEvent(event)
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectionContinuation = continuation
                connectionTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.timeOutConnection()
                }
                task.resume()
            }
        } onCancel: {
            Task { await self.cancelConnection() }
        }
        try Task.checkCancellation()
    }

    func addEventHandler(_ handler: @escaping EventHandler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func removeEventHandler(_ id: UUID) {
        handlers.removeValue(forKey: id)
    }

    func connectionTerminations() -> AsyncStream<ConnectionTermination> {
        connectionTerminationsStream
    }

    func command(
        _ method: String,
        params: [String: JSONValue] = [:],
        timeout: Duration = .seconds(5)
    ) async throws -> [String: JSONValue] {
        guard !isClosed, isConnected, let socket else {
            throw CDPClientError.socketClosed
        }
        let id = nextIdentifier
        nextIdentifier += 1
        let message = try Self.makeCommandMessage(
            id: id,
            method: method,
            params: params
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.timeOutCommand(id: id, method: method)
                }
                pending[id] = PendingCommand(continuation: continuation, timeoutTask: timeoutTask)

                socket.send(message) { [weak self] error in
                    guard let error else { return }
                    Task { await self?.failCommand(id: id, error: error) }
                }
            }
        } onCancel: {
            Task { await self.failCommand(id: id, error: CancellationError()) }
        }
    }

    nonisolated static func makeCommandMessage(
        id: Int,
        method: String,
        params: [String: JSONValue]
    ) throws -> URLSessionWebSocketTask.Message {
        let payload = try JSONEncoder().encode(
            CDPCommand(id: id, method: method, params: params)
        )
        guard let text = String(data: payload, encoding: .utf8) else {
            throw CDPClientError.malformedResponse(
                "无法把 CDP command 编码为 UTF-8 text frame"
            )
        }
        // Chromium CDP accepts JSON text messages. Sending the same bytes as a
        // binary frame makes Chromium close the otherwise valid connection.
        return .string(text)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isConnected = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionEventTask?.cancel()
        connectionEventTask = nil
        connectionContinuation?.resume(throwing: CDPClientError.socketClosed)
        connectionContinuation = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketTaskIdentifier = nil
        connectionDelegate.finish()
        connectionTerminationsContinuation.finish()
        session.invalidateAndCancel()
        let commands = pending.values
        pending.removeAll()
        for command in commands {
            command.timeoutTask.cancel()
            command.continuation.resume(throwing: CDPClientError.socketClosed)
        }
        handlers.removeAll()
    }

    private func handleConnectionEvent(_ event: CDPWebSocketConnectionDelegate.Event) {
        guard !isClosed, let socketTaskIdentifier else { return }

        switch event {
        case .opened(let taskIdentifier) where taskIdentifier == socketTaskIdentifier:
            guard let continuation = connectionContinuation else { return }
            connectionContinuation = nil
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            isConnected = true
            receiveNext()
            continuation.resume()
        case .closed(let taskIdentifier) where taskIdentifier == socketTaskIdentifier:
            closeWithError(CDPClientError.socketClosed)
        case .failed(let taskIdentifier, let message) where taskIdentifier == socketTaskIdentifier:
            let phase = isConnected ? "WebSocket 连接中断" : "WebSocket 握手失败"
            DiagnosticsLogger.shared.log(
                "cdp-transport-failed",
                "phase=\(phase) detail=\(message)"
            )
            closeWithError(
                CDPClientError.malformedResponse("\(phase)：\(message)")
            )
        default:
            break
        }
    }

    private func timeOutConnection() {
        guard connectionContinuation != nil else { return }
        closeWithError(CDPClientError.timeout(method: "WebSocket.connect"))
    }

    private func cancelConnection() {
        guard connectionContinuation != nil else { return }
        closeWithError(CancellationError())
    }

    private func receiveNext() {
        guard !isClosed, let socket else { return }
        socket.receive { [weak self] result in
            Task { await self?.handleReceive(result) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) async {
        guard !isClosed else { return }
        switch result {
        case .failure(let error):
            DiagnosticsLogger.shared.log(
                "cdp-receive-failed",
                "detail=\(error.localizedDescription)"
            )
            closeWithError(error)
        case .success(let message):
            do {
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default:
                    throw CDPClientError.malformedResponse("unknown WebSocket message")
                }
                let envelope = try JSONDecoder().decode(CDPEnvelope.self, from: data)
                if let id = envelope.id {
                    completeCommand(id: id, envelope: envelope)
                } else if envelope.method != nil {
                    for handler in handlers.values {
                        Task { await handler(envelope) }
                    }
                }
                receiveNext()
            } catch {
                closeWithError(error)
            }
        }
    }

    private func completeCommand(id: Int, envelope: CDPEnvelope) {
        guard let command = pending.removeValue(forKey: id) else { return }
        command.timeoutTask.cancel()
        if let error = envelope.error {
            command.continuation.resume(throwing: CDPClientError.commandFailed(code: error.code, message: error.message))
        } else {
            command.continuation.resume(returning: envelope.result ?? [:])
        }
    }

    private func timeOutCommand(id: Int, method: String) {
        guard let command = pending.removeValue(forKey: id) else { return }
        command.continuation.resume(throwing: CDPClientError.timeout(method: method))
    }

    private func failCommand(id: Int, error: Error) {
        guard let command = pending.removeValue(forKey: id) else { return }
        command.timeoutTask.cancel()
        command.continuation.resume(throwing: error)
    }

    private func closeWithError(_ error: Error) {
        guard !isClosed else { return }
        let wasConnected = isConnected
        isClosed = true
        isConnected = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionEventTask?.cancel()
        connectionEventTask = nil
        connectionContinuation?.resume(throwing: error)
        connectionContinuation = nil
        socket?.cancel(with: .abnormalClosure, reason: nil)
        socket = nil
        socketTaskIdentifier = nil
        connectionDelegate.finish()
        if wasConnected {
            connectionTerminationsContinuation.yield(.unexpectedClosure)
        }
        connectionTerminationsContinuation.finish()
        session.invalidateAndCancel()
        let commands = pending.values
        pending.removeAll()
        for command in commands {
            command.timeoutTask.cancel()
            command.continuation.resume(throwing: error)
        }
        handlers.removeAll()
    }
}
