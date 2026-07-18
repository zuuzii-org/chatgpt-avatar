import Foundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct CDPDiscoveryClient: Sendable {
    static let maximumResponseBytes = 1_048_576

    func fetchTargets(port: Int) async throws -> [CDPTarget] {
        guard (1_024...65_535).contains(port) else {
            throw CDPClientError.invalidPort(port)
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            throw CDPClientError.invalidEndpoint("127.0.0.1:\(port)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let delegate = NoRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CDPClientError.malformedResponse("missing HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if (300...399).contains(httpResponse.statusCode) {
                throw CDPClientError.redirectRejected
            }
            throw CDPClientError.unexpectedStatus(httpResponse.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw CDPClientError.responseTooLarge(data.count)
        }

        let targets: [CDPTarget]
        do {
            targets = try JSONDecoder().decode([CDPTarget].self, from: data)
        } catch {
            throw CDPClientError.malformedResponse(error.localizedDescription)
        }

        return try targets.map { target in
            guard let endpoint = target.webSocketDebuggerUrl else { return target }
            try validateWebSocketEndpoint(endpoint, discoveryPort: port)
            return target
        }
    }

    func waitForTargets(
        port: Int,
        timeout: Duration = .seconds(12),
        pollInterval: Duration = .milliseconds(160)
    ) async throws -> [CDPTarget] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?

        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                let targets = try await fetchTargets(port: port)
                if !targets.isEmpty { return targets }
            } catch {
                lastError = error
            }
            try await clock.sleep(for: pollInterval)
        }

        if let lastError { throw lastError }
        throw CDPClientError.noRenderer
    }

    private func validateWebSocketEndpoint(_ rawValue: String, discoveryPort: Int) throws {
        guard
            let components = URLComponents(string: rawValue),
            components.scheme == "ws",
            components.host == "127.0.0.1",
            components.port == discoveryPort,
            components.path.hasPrefix("/devtools/")
        else {
            throw CDPClientError.invalidEndpoint(rawValue)
        }
    }
}
