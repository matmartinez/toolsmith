import Foundation

/// Client side of the MCP "SSE" transport. The proxy holds a long-lived
/// GET `text/event-stream` connection to the remote server; the first
/// event from the server is `event: endpoint` with a URL/path that the
/// client POSTs subsequent JSON-RPC messages to. The server pushes
/// responses + notifications back over the SSE stream as
/// `event: message` records.
public actor SSEClientTransport {
    public enum Failure: Error, Sendable, Equatable {
        case alreadyStarted
        case badStatus(Int)
        case invalidEndpoint(String)
        case decodingFailed(String)
        case streamClosed
    }

    public let url: URL
    private let httpClient: HTTPClient
    private let extraHeaders: [(String, String)]

    private let messageStream: AsyncThrowingStream<JSONRPCMessage, Error>
    private let messageContinuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation

    private var streamTask: Task<Void, Never>?
    private var endpointURL: URL?
    private var endpointWaiters: [CheckedContinuation<URL, Error>] = []

    public init(url: URL, headers: [(String, String)] = [], httpClient: HTTPClient) {
        self.url = url
        self.httpClient = httpClient
        self.extraHeaders = headers
        let (stream, continuation) = AsyncThrowingStream<JSONRPCMessage, Error>.makeStream()
        self.messageStream = stream
        self.messageContinuation = continuation
    }

    /// Inbound JSON-RPC messages decoded from `event: message` records.
    /// Safe to read before `start()`; will simply block until the stream
    /// is opened and the server begins sending events.
    public nonisolated var incoming: AsyncThrowingStream<JSONRPCMessage, Error> {
        messageStream
    }

    /// Open the GET stream. Returns once the server's first `endpoint`
    /// event has been received so subsequent `send` calls know where
    /// to POST.
    public func start() async throws {
        guard streamTask == nil else { throw Failure.alreadyStarted }

        var headers = extraHeaders
        headers.append(("Accept", "text/event-stream"))
        let request = HTTPRequest(method: "GET", url: url, headers: headers)

        let response: HTTPStreamResponse
        do {
            response = try await httpClient.openStream(request)
        } catch {
            messageContinuation.finish(throwing: error)
            throw error
        }
        guard 200..<300 ~= response.statusCode else {
            let failure = Failure.badStatus(response.statusCode)
            messageContinuation.finish(throwing: failure)
            throw failure
        }

        streamTask = Task { [weak self] in
            var parser = SSEParser()
            do {
                for try await line in response.lines {
                    if let event = parser.feed(line: line) {
                        await self?.handle(event: event)
                    }
                }
                await self?.finishStream()
            } catch {
                await self?.failStream(with: error)
            }
        }

        _ = try await awaitEndpoint()
    }

    /// POST a JSON-RPC message to the previously-announced endpoint URL.
    /// Suspends until the endpoint event has been received.
    public func send(_ message: JSONRPCMessage) async throws {
        let endpoint = try await awaitEndpoint()
        let body = try WireJSON.encoder().encode(message)
        var headers = extraHeaders
        headers.append(("Content-Type", "application/json"))
        let request = HTTPRequest(method: "POST", url: endpoint, headers: headers, body: body)
        let response = try await httpClient.send(request)
        guard 200..<300 ~= response.statusCode else {
            throw Failure.badStatus(response.statusCode)
        }
    }

    public func close() {
        streamTask?.cancel()
        streamTask = nil
        messageContinuation.finish()
        for waiter in endpointWaiters { waiter.resume(throwing: Failure.streamClosed) }
        endpointWaiters.removeAll()
    }

    private func awaitEndpoint() async throws -> URL {
        if let endpointURL { return endpointURL }
        return try await withCheckedThrowingContinuation { continuation in
            endpointWaiters.append(continuation)
        }
    }

    private func handle(event: SSEEvent) {
        switch event.event {
        case "endpoint":
            let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved = Self.resolveEndpoint(trimmed, against: url) else {
                failStream(with: Failure.invalidEndpoint(event.data))
                return
            }
            endpointURL = resolved
            let waiters = endpointWaiters
            endpointWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: resolved) }
        case "message":
            do {
                let message = try WireJSON.decoder().decode(
                    JSONRPCMessage.self,
                    from: Data(event.data.utf8)
                )
                messageContinuation.yield(message)
            } catch {
                failStream(with: Failure.decodingFailed(event.data))
            }
        default:
            break
        }
    }

    private func failStream(with error: Error) {
        messageContinuation.finish(throwing: error)
        let waiters = endpointWaiters
        endpointWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func finishStream() {
        messageContinuation.finish()
        let waiters = endpointWaiters
        endpointWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: Failure.streamClosed) }
    }

    static func resolveEndpoint(_ raw: String, against base: URL) -> URL? {
        if let absolute = URL(string: raw), absolute.scheme != nil {
            return absolute
        }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}
