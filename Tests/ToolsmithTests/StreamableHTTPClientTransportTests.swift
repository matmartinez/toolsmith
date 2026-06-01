import Foundation
import Testing

@testable import Toolsmith

private actor ScriptedHTTPClient: HTTPClient {
    private(set) var requestLog: [HTTPRequest] = []
    private var queuedResponses: [() async -> HTTPStreamResponse] = []

    func enqueue(
        status: Int,
        contentType: String? = nil,
        bodyLines: [String] = []
    ) {
        queuedResponses.append {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            for line in bodyLines { continuation.yield(line) }
            continuation.finish()
            var headers: [String: String] = [:]
            if let contentType { headers["Content-Type"] = contentType }
            return HTTPStreamResponse(statusCode: status, headers: headers, lines: stream)
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestLog.append(request)
        return HTTPResponse(statusCode: 200)
    }

    func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        requestLog.append(request)
        guard !queuedResponses.isEmpty else {
            return HTTPStreamResponse(
                statusCode: 200,
                headers: [:],
                lines: AsyncThrowingStream { $0.finish() }
            )
        }
        return await queuedResponses.removeFirst()()
    }
}

@Suite("StreamableHTTPClientTransport")
struct StreamableHTTPClientTransportTests {
    private let endpoint = URL(string: "https://server.example/mcp")!

    @Test("POST headers include Content-Type and the dual Accept value")
    func postHeaders() async throws {
        let client = ScriptedHTTPClient()
        await client.enqueue(status: 202)
        let transport = StreamableHTTPClientTransport(url: endpoint, httpClient: client)
        try await transport.send(.notification(JSONRPCNotification(method: "notifications/initialized")))

        let log = await client.requestLog
        #expect(log[0].method == "POST")
        #expect(log[0].url == endpoint)
        #expect(log[0].headers.contains { $0.0 == "Content-Type" && $0.1 == "application/json" })
        #expect(log[0].headers.contains { $0.0 == "Accept" && $0.1.contains("application/json") && $0.1.contains("text/event-stream") })
    }

    @Test("202 Accepted yields nothing")
    func acceptedYieldsNothing() async throws {
        let client = ScriptedHTTPClient()
        await client.enqueue(status: 202)
        let transport = StreamableHTTPClientTransport(url: endpoint, httpClient: client)
        try await transport.send(.notification(JSONRPCNotification(method: "x")))

        await transport.close()
        var count = 0
        for try await _ in transport.incoming { count += 1 }
        #expect(count == 0)
    }

    @Test("JSON response yields a single decoded message")
    func jsonResponseYieldsMessage() async throws {
        let client = ScriptedHTTPClient()
        await client.enqueue(
            status: 200,
            contentType: "application/json",
            bodyLines: [#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#]
        )
        let transport = StreamableHTTPClientTransport(url: endpoint, httpClient: client)
        try await transport.send(.request(JSONRPCRequest(id: 1, method: "ping")))

        await transport.close()
        var collected: [JSONRPCMessage] = []
        for try await message in transport.incoming { collected.append(message) }
        #expect(collected.count == 1)
        guard case .response(let response) = collected.first else {
            Issue.record("expected response")
            return
        }
        #expect(response.id == .number(1))
    }

    @Test("SSE response yields one message per event:message record")
    func sseResponseYieldsMessages() async throws {
        let client = ScriptedHTTPClient()
        await client.enqueue(
            status: 200,
            contentType: "text/event-stream",
            bodyLines: [
                "event: message",
                #"data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"t","progress":50}}"#,
                "",
                "event: message",
                #"data: {"jsonrpc":"2.0","id":1,"result":{"done":true}}"#,
                "",
            ]
        )
        let transport = StreamableHTTPClientTransport(url: endpoint, httpClient: client)
        try await transport.send(.request(JSONRPCRequest(id: 1, method: "tools/call")))

        await transport.close()
        var methods: [String] = []
        var results: Int = 0
        for try await message in transport.incoming {
            switch message {
            case .notification(let n): methods.append(n.method)
            case .response: results += 1
            case .request: break
            }
        }
        #expect(methods == ["notifications/progress"])
        #expect(results == 1)
    }

    @Test("Non-2xx surfaces as badStatus")
    func badStatus() async throws {
        let client = ScriptedHTTPClient()
        await client.enqueue(status: 500)
        let transport = StreamableHTTPClientTransport(url: endpoint, httpClient: client)
        await #expect(throws: StreamableHTTPClientTransport.Failure.badStatus(500)) {
            try await transport.send(.request(JSONRPCRequest(id: 1, method: "x")))
        }
    }

    @Test("Unknown content type surfaces as unexpectedContentType")
    func unexpectedContentType() async throws {
        let client = ScriptedHTTPClient()
        await client.enqueue(status: 200, contentType: "text/plain", bodyLines: ["whatever"])
        let transport = StreamableHTTPClientTransport(url: endpoint, httpClient: client)
        await #expect(throws: StreamableHTTPClientTransport.Failure.self) {
            try await transport.send(.request(JSONRPCRequest(id: 1, method: "x")))
        }
    }

    @Test("Malformed JSON body surfaces as decodingFailed")
    func decodingError() async throws {
        let client = ScriptedHTTPClient()
        await client.enqueue(
            status: 200,
            contentType: "application/json",
            bodyLines: ["not json"]
        )
        let transport = StreamableHTTPClientTransport(url: endpoint, httpClient: client)
        await #expect(throws: StreamableHTTPClientTransport.Failure.self) {
            try await transport.send(.request(JSONRPCRequest(id: 1, method: "x")))
        }
    }

    @Test("Custom request headers flow through")
    func customHeaders() async throws {
        let client = ScriptedHTTPClient()
        await client.enqueue(status: 202)
        let transport = StreamableHTTPClientTransport(
            url: endpoint,
            headers: [("X-Trace", "abc")],
            httpClient: client
        )
        try await transport.send(.notification(JSONRPCNotification(method: "n")))
        let log = await client.requestLog
        #expect(log[0].headers.contains { $0.0 == "X-Trace" && $0.1 == "abc" })
    }
}
