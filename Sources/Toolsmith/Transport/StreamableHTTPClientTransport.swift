import Foundation

/// Client side of the MCP "Streamable HTTP" transport. Each outbound
/// JSON-RPC message is POSTed to the configured URL. The server's
/// response indicates how the result arrives:
///
///   - `202 Accepted` with no body for notifications
///   - `application/json` with a single JSON-RPC message in the body
///   - `text/event-stream` with one or more `event: message` records,
///     used when the server wants to interleave progress notifications
///     with a final response
///
/// Decoded server messages flow through the `incoming` stream so the
/// proxy core can treat both transports the same way.
public actor StreamableHTTPClientTransport {
    public enum Failure: Error, Sendable, Equatable {
        case badStatus(Int)
        case unexpectedContentType(String)
        case decodingFailed(String)
    }

    public let url: URL
    private let httpClient: HTTPClient
    private let extraHeaders: [(String, String)]

    private let messageStream: AsyncThrowingStream<JSONRPCMessage, Error>
    private let messageContinuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation

    public init(url: URL, headers: [(String, String)] = [], httpClient: HTTPClient) {
        self.url = url
        self.httpClient = httpClient
        self.extraHeaders = headers
        let (stream, continuation) = AsyncThrowingStream<JSONRPCMessage, Error>.makeStream()
        self.messageStream = stream
        self.messageContinuation = continuation
    }

    public nonisolated var incoming: AsyncThrowingStream<JSONRPCMessage, Error> {
        messageStream
    }

    public func close() {
        messageContinuation.finish()
    }

    /// POST `message` and process the response. For notifications the
    /// server should answer `202 Accepted` and this returns immediately.
    /// For requests the server replies with either a unary JSON body
    /// or an SSE stream of `event: message` records; decoded messages
    /// are yielded onto `incoming` before this call returns.
    public func send(_ message: JSONRPCMessage) async throws {
        let body = try WireJSON.encoder().encode(message)
        var headers = extraHeaders
        headers.append(("Content-Type", "application/json"))
        headers.append(("Accept", "application/json, text/event-stream"))
        let request = HTTPRequest(method: "POST", url: url, headers: headers, body: body)
        let response = try await httpClient.openStream(request)

        guard 200..<300 ~= response.statusCode else {
            throw Failure.badStatus(response.statusCode)
        }
        if response.statusCode == 202 { return }

        let contentType = Self.contentType(in: response.headers)
        if contentType.contains("text/event-stream") {
            try await consumeSSEBody(response.lines)
        } else if contentType.contains("application/json") || contentType.isEmpty {
            try await consumeJSONBody(response.lines)
        } else {
            throw Failure.unexpectedContentType(contentType)
        }
    }

    private func consumeJSONBody(_ lines: AsyncThrowingStream<String, Error>) async throws {
        var body = ""
        for try await line in lines {
            if !body.isEmpty { body += "\n" }
            body += line
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let decoded = try WireJSON.decoder().decode(
                JSONRPCMessage.self, from: Data(trimmed.utf8)
            )
            messageContinuation.yield(decoded)
        } catch {
            throw Failure.decodingFailed(trimmed)
        }
    }

    private func consumeSSEBody(_ lines: AsyncThrowingStream<String, Error>) async throws {
        var parser = SSEParser()
        for try await line in lines {
            guard let event = parser.feed(line: line) else { continue }
            guard event.event == "message" else { continue }
            do {
                let decoded = try WireJSON.decoder().decode(
                    JSONRPCMessage.self, from: Data(event.data.utf8)
                )
                messageContinuation.yield(decoded)
            } catch {
                throw Failure.decodingFailed(event.data)
            }
        }
    }

    private static func contentType(in headers: [String: String]) -> String {
        for (key, value) in headers where key.caseInsensitiveCompare("content-type") == .orderedSame {
            return value.lowercased()
        }
        return ""
    }
}
