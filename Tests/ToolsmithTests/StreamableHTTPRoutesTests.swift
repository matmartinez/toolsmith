import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

/// Tiny stdin/stdout JSON-RPC responder used as the child process for
/// streamable-HTTP server tests. For every line that parses as a
/// JSON-RPC *request*, it emits a matching response with a synthesized
/// result. Notifications and other input lines are ignored.
private let kPythonResponderScript = """
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
        resp = {
            'jsonrpc': '2.0',
            'id': msg['id'],
            'result': {'echoed': msg.get('method')},
        }
        print(json.dumps(resp), flush=True)
"""

private func makePythonResponder() -> ChildSession {
    // -u forces unbuffered stdin/stdout so each line is processed and
    // emitted immediately — otherwise Python's input buffering holds
    // the request until EOF.
    ChildSession(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        args: ["python3", "-u", "-c", kPythonResponderScript]
    )
}

@Suite("Streamable HTTP server routes")
struct StreamableHTTPRoutesTests {
    @Test("POST notification returns 202 with no body")
    func notificationReturns202() async throws {
        let child = makePythonResponder()
        try await child.start()
        defer { Task { await child.stop() } }

        var router = ServerRouter()
        StreamableHTTPRoutes.register(on: &router, child: child)
        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let httpClient = URLSessionHTTPClient()
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.notification(JSONRPCNotification(method: "notifications/initialized"))
        )
        let response = try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: URL(string: "http://127.0.0.1:\(address.port!)/mcp")!,
                headers: [("Content-Type", "application/json")],
                body: body
            )
        )
        #expect(response.statusCode == 202)
        #expect(response.body.isEmpty)
    }

    @Test("POST .response returns 400")
    func postResponseRejected() async throws {
        let child = makePythonResponder()
        try await child.start()
        defer { Task { await child.stop() } }

        var router = ServerRouter()
        StreamableHTTPRoutes.register(on: &router, child: child)
        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let httpClient = URLSessionHTTPClient()
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.response(JSONRPCResponse(id: 1, result: .null))
        )
        let response = try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: URL(string: "http://127.0.0.1:\(address.port!)/mcp")!,
                headers: [("Content-Type", "application/json")],
                body: body
            )
        )
        #expect(response.statusCode == 400)
    }

    @Test("POST request streams SSE and closes after matching reply")
    func requestStreamsAndCloses() async throws {
        let child = makePythonResponder()
        try await child.start()
        defer { Task { await child.stop() } }

        var router = ServerRouter()
        StreamableHTTPRoutes.register(on: &router, child: child)
        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let httpClient = URLSessionHTTPClient()
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(id: 42, method: "ping"))
        )
        let streamResponse = try await httpClient.openStream(
            HTTPRequest(
                method: "POST",
                url: URL(string: "http://127.0.0.1:\(address.port!)/mcp")!,
                headers: [("Content-Type", "application/json")],
                body: body
            )
        )
        #expect(streamResponse.statusCode == 200)
        #expect(streamResponse.headers["Content-Type"]?.contains("text/event-stream") == true)

        var parser = SSEParser()
        var messages: [JSONRPCMessage] = []
        for try await line in streamResponse.lines {
            if let event = parser.feed(line: line), event.event == "message" {
                let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
                messages.append(decoded)
            }
        }
        #expect(messages.count == 1)
        guard case .response(let response) = messages.first else {
            Issue.record("expected response, got \(String(describing: messages.first))")
            return
        }
        #expect(response.id == .number(42))
        #expect(response.result == .object(["echoed": .string("ping")]))
    }

    @Test("Malformed body returns 400")
    func malformedBody() async throws {
        let child = makePythonResponder()
        try await child.start()
        defer { Task { await child.stop() } }

        var router = ServerRouter()
        StreamableHTTPRoutes.register(on: &router, child: child)
        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let httpClient = URLSessionHTTPClient()
        let response = try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: URL(string: "http://127.0.0.1:\(address.port!)/mcp")!,
                headers: [("Content-Type", "application/json")],
                body: Data("not json".utf8)
            )
        )
        #expect(response.statusCode == 400)
    }

    @Test("GET /mcp opens a server-initiated SSE stream")
    func getOpensStream() async throws {
        let child = makePythonResponder()
        try await child.start()
        defer { Task { await child.stop() } }

        var router = ServerRouter()
        StreamableHTTPRoutes.register(on: &router, child: child)
        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let httpClient = URLSessionHTTPClient()
        let base = URL(string: "http://127.0.0.1:\(address.port!)")!

        // Open the long-running GET stream first.
        let streamResponse = try await httpClient.openStream(
            HTTPRequest(method: "GET", url: base.appendingPathComponent("mcp"))
        )
        #expect(streamResponse.statusCode == 200)
        #expect(streamResponse.headers["Content-Type"]?.contains("text/event-stream") == true)

        // Then POST a request — its response should also flow through this stream
        // (broadcast model). We collect a single message and stop.
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(id: 99, method: "pong"))
        )
        _ = try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: base.appendingPathComponent("mcp"),
                headers: [("Content-Type", "application/json")],
                body: body
            )
        )

        var parser = SSEParser()
        var collected: JSONRPCMessage?
        for try await line in streamResponse.lines {
            if let event = parser.feed(line: line), event.event == "message" {
                collected = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
                break
            }
        }
        guard case .response(let response) = collected else {
            Issue.record("expected response on GET stream, got \(String(describing: collected))")
            return
        }
        #expect(response.id == .number(99))
    }
}
