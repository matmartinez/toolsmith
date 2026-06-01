import Foundation
import Testing

@testable import Toolsmith

private actor MockHTTPClient: HTTPClient {
    private(set) var requestLog: [HTTPRequest] = []
    private var streamContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var bufferedLines: [String] = []
    private var streamStatus: Int = 200
    private var sendHandler: (@Sendable (HTTPRequest) async throws -> HTTPResponse)?

    func setStreamStatus(_ status: Int) { streamStatus = status }
    func setSendHandler(_ handler: @Sendable @escaping (HTTPRequest) async throws -> HTTPResponse) {
        sendHandler = handler
    }

    func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        requestLog.append(request)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        streamContinuation = continuation
        for line in bufferedLines { continuation.yield(line) }
        bufferedLines.removeAll()
        return HTTPStreamResponse(statusCode: streamStatus, headers: [:], lines: stream)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestLog.append(request)
        if let sendHandler { return try await sendHandler(request) }
        return HTTPResponse(statusCode: 200)
    }

    func feed(_ line: String) {
        if let c = streamContinuation {
            c.yield(line)
        } else {
            bufferedLines.append(line)
        }
    }

    func feedLines(_ lines: [String]) {
        for line in lines { feed(line) }
    }

    func finishStream() { streamContinuation?.finish() }
    func failStream(_ error: Error) { streamContinuation?.finish(throwing: error) }
}

@Suite("SSEClientTransport")
struct SSEClientTransportTests {
    private let serverURL = URL(string: "https://server.example/sse")!

    @Test("start opens GET with Accept: text/event-stream and waits for endpoint")
    func startOpensGet() async throws {
        let client = MockHTTPClient()
        let transport = SSEClientTransport(url: serverURL, httpClient: client)

        async let started: Void = transport.start()
        await client.feedLines([
            "event: endpoint",
            "data: /messages/abc",
            "",
        ])
        try await started

        let log = await client.requestLog
        #expect(log.count == 1)
        #expect(log[0].method == "GET")
        #expect(log[0].url == serverURL)
        #expect(log[0].headers.contains { $0.0 == "Accept" && $0.1 == "text/event-stream" })
    }

    @Test("incoming yields JSON-RPC messages from event:message records")
    func incomingYieldsMessages() async throws {
        let client = MockHTTPClient()
        let transport = SSEClientTransport(url: serverURL, httpClient: client)

        async let started: Void = transport.start()
        await client.feedLines([
            "event: endpoint",
            "data: /messages/abc",
            "",
            "event: message",
            #"data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#,
            "",
        ])
        try await started

        var iterator = transport.incoming.makeAsyncIterator()
        let first = try await iterator.next()
        guard case .response(let response) = first else {
            Issue.record("expected response, got \(String(describing: first))")
            return
        }
        #expect(response.id == .number(1))
    }

    @Test("send POSTs to the endpoint URL with JSON content type")
    func sendPostsToEndpoint() async throws {
        let client = MockHTTPClient()
        let transport = SSEClientTransport(url: serverURL, httpClient: client)

        async let started: Void = transport.start()
        await client.feedLines(["event: endpoint", "data: /messages/abc", ""])
        try await started

        try await transport.send(.request(JSONRPCRequest(id: 1, method: "ping")))

        let log = await client.requestLog
        #expect(log.count == 2)
        let post = log[1]
        #expect(post.method == "POST")
        #expect(post.url == URL(string: "https://server.example/messages/abc"))
        #expect(post.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/json" })
        let bodyString = String(decoding: post.body ?? Data(), as: UTF8.self)
        #expect(bodyString.contains(#""method":"ping""#))
    }

    @Test("send completes after endpoint event arrives")
    func sendWaitsForEndpoint() async throws {
        let client = MockHTTPClient()
        let transport = SSEClientTransport(url: serverURL, httpClient: client)

        async let started: Void = transport.start()
        async let sendResult: Void = transport.send(.notification(JSONRPCNotification(method: "n")))
        await client.feedLines(["event: endpoint", "data: /post", ""])
        try await started
        try await sendResult

        let log = await client.requestLog
        #expect(log.count == 2)
        #expect(log[1].method == "POST")
    }

    @Test("start propagates non-2xx status")
    func badStatusFails() async throws {
        let client = MockHTTPClient()
        await client.setStreamStatus(401)
        let transport = SSEClientTransport(url: serverURL, httpClient: client)

        await #expect(throws: SSEClientTransport.Failure.self) {
            try await transport.start()
        }
    }

    @Test("Malformed message JSON finishes the stream with decodingFailed")
    func decodingError() async throws {
        let client = MockHTTPClient()
        let transport = SSEClientTransport(url: serverURL, httpClient: client)

        async let started: Void = transport.start()
        await client.feedLines([
            "event: endpoint",
            "data: /messages/abc",
            "",
            "event: message",
            "data: {not json}",
            "",
        ])
        try await started

        await #expect(throws: SSEClientTransport.Failure.self) {
            for try await _ in transport.incoming {}
        }
    }

    @Test("Custom request headers are forwarded on both GET and POST")
    func customHeadersForwarded() async throws {
        let client = MockHTTPClient()
        let transport = SSEClientTransport(
            url: serverURL,
            headers: [("Authorization", "Bearer abc"), ("X-Trace", "t-1")],
            httpClient: client
        )

        async let started: Void = transport.start()
        await client.feedLines(["event: endpoint", "data: /messages/x", ""])
        try await started

        try await transport.send(.request(JSONRPCRequest(id: 1, method: "ping")))

        let log = await client.requestLog
        for req in log {
            #expect(req.headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer abc" })
            #expect(req.headers.contains { $0.0 == "X-Trace" && $0.1 == "t-1" })
        }
    }

    @Test("Endpoint string can be an absolute URL")
    func absoluteEndpoint() async throws {
        let client = MockHTTPClient()
        let transport = SSEClientTransport(url: serverURL, httpClient: client)

        async let started: Void = transport.start()
        await client.feedLines([
            "event: endpoint",
            "data: https://other.example/post-here",
            "",
        ])
        try await started

        try await transport.send(.request(JSONRPCRequest(id: 1, method: "ping")))
        let log = await client.requestLog
        #expect(log[1].url == URL(string: "https://other.example/post-here"))
    }

    @Test("Server stream finishing closes incoming cleanly")
    func streamFinishes() async throws {
        let client = MockHTTPClient()
        let transport = SSEClientTransport(url: serverURL, httpClient: client)

        async let started: Void = transport.start()
        await client.feedLines(["event: endpoint", "data: /post", ""])
        try await started
        await client.finishStream()

        var count = 0
        for try await _ in transport.incoming { count += 1 }
        #expect(count == 0)
    }

    @Test("resolveEndpoint resolves relative and absolute paths")
    func resolveEndpoint() {
        let base = URL(string: "https://server.example/sse")!
        #expect(
            SSEClientTransport.resolveEndpoint("/messages/abc", against: base)
                == URL(string: "https://server.example/messages/abc")
        )
        #expect(
            SSEClientTransport.resolveEndpoint("https://other.example/p", against: base)
                == URL(string: "https://other.example/p")
        )
    }
}
