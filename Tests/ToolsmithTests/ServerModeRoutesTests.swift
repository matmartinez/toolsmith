import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

@Suite("Server-mode MCP routes (E2E via /bin/cat)")
struct ServerModeRoutesTests {
    @Test("GET /sse emits endpoint event then child messages as SSE")
    func endToEnd() async throws {
        let child = ChildSession(executable: URL(fileURLWithPath: "/bin/cat"))
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

        // /bin/cat echoes the request back; expect to see it on the SSE stream.
        var echoed: SSEEvent?
        while echoed == nil {
            guard let line = try await iterator.next() else { break }
            if let event = parser.feed(line: line) { echoed = event }
        }
        #expect(echoed?.event == "message")
        let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data((echoed?.data ?? "").utf8))
        #expect(decoded == request)
    }

    @Test("POST /messages with malformed body returns 400")
    func malformedBody() async throws {
        let child = ChildSession(executable: URL(fileURLWithPath: "/bin/cat"))
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
