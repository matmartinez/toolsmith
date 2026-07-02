import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

/// Minimal JSON-RPC responder: echoes each request's method back in the
/// result, replying with the id it was given. `-u` keeps stdio unbuffered.
private let kResponder = """
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if isinstance(msg, dict) and 'id' in msg and 'method' in msg:
        print(json.dumps({'jsonrpc': '2.0', 'id': msg['id'],
                          'result': {'echoed': msg.get('method')}}), flush=True)
"""

private func makeResponder() -> ChildSession {
    ChildSession(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        args: ["python3", "-u", "-c", kResponder]
    )
}

@Suite("Server-mode MCP routes (E2E via SSE transport)")
struct ServerModeRoutesTests {
    @Test("GET /sse emits endpoint event then the request's response as SSE")
    func endToEnd() async throws {
        let child = makeResponder()
        try await child.start()

        var router = ServerRouter()
        ServerModeRoutes.register(on: &router, backend: child)

        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer {
            Task {
                try? await server.stop()
                await child.stop()
            }
        }

        let baseURL = URL(string: "http://127.0.0.1:\(address.port!)")!
        let httpClient = URLSessionHTTPClient()

        // Open the SSE stream.
        let streamResponse = try await httpClient.openStream(
            HTTPRequest(method: "GET", url: baseURL.appendingPathComponent("sse"), headers: [("Accept", "text/event-stream")])
        )
        #expect(streamResponse.statusCode == 200)

        var parser = SSEParser()
        var iterator = streamResponse.lines.makeAsyncIterator()

        // First record must be the endpoint announcement.
        var endpointEvent: SSEEvent?
        while endpointEvent == nil {
            guard let line = try await iterator.next() else { break }
            if let event = parser.feed(line: line) { endpointEvent = event }
        }
        #expect(endpointEvent?.event == "endpoint")
        #expect(endpointEvent?.data == "/messages")

        // POST a request to /messages.
        let request = JSONRPCMessage.request(JSONRPCRequest(id: 1, method: "ping"))
        let body = try WireJSON.encoder().encode(request)
        let postResponse = try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: baseURL.appendingPathComponent("messages"),
                headers: [("Content-Type", "application/json")],
                body: body
            )
        )
        #expect(postResponse.statusCode == 202)

        // The reply arrives out-of-band on the SSE stream, carrying our id.
        var messageEvent: SSEEvent?
        while messageEvent == nil {
            guard let line = try await iterator.next() else { break }
            if let event = parser.feed(line: line), event.event == "message" { messageEvent = event }
        }
        #expect(messageEvent?.event == "message")
        let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data((messageEvent?.data ?? "").utf8))
        guard case .response(let response) = decoded else {
            Issue.record("expected response, got \(decoded)")
            return
        }
        #expect(response.id == .number(1))
        #expect(response.result == .object(["echoed": .string("ping")]))
    }

    @Test("POST /messages with malformed body returns 400")
    func malformedBody() async throws {
        let child = makeResponder()
        try await child.start()

        var router = ServerRouter()
        ServerModeRoutes.register(on: &router, backend: child)
        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer {
            Task {
                try? await server.stop()
                await child.stop()
            }
        }

        let baseURL = URL(string: "http://127.0.0.1:\(address.port!)")!
        let httpClient = URLSessionHTTPClient()
        let response = try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: baseURL.appendingPathComponent("messages"),
                headers: [("Content-Type", "application/json")],
                body: Data("not json".utf8)
            )
        )
        #expect(response.statusCode == 400)
    }
}
